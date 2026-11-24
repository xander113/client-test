<?php

declare(strict_types=1);

namespace App\Services;

use App\Models\User;
use Illuminate\Support\Facades\DB;

final readonly class Matchmaker
{
    private const TICKET_TTL = 30;
    private const LEASE_TTL = 45;
    private const WORKER_TTL = 20;

    public function __construct(private Catalog $catalog, private Content $content) {}

    public function join(string $world, ?object $token): array
    {
        $reservation = DB::transaction(function () use ($world, $token) {
            $time = time();
            // Workers are locked before any place or admission rows across the admission lifecycle.
            $workers = DB::table('workers')->whereIn('id', array_keys(config('pot.nodes')))
                ->where('heartbeat', '>', $time - self::WORKER_TTL)->orderBy('id')->lockForUpdate()->get()->keyBy('id');
            $place = $this->catalog->release($world, $token ? (int) $token->user_id : null, lock: true);
            abort_if($workers->isEmpty(), 503, 'Game servers are starting. Try again shortly.');
            $counts = DB::table('admissions as a')->join('game_servers as s', 's.id', '=', 'a.server_id')
                ->join('workers as w', 'w.id', '=', 's.worker_id')->whereColumn('s.generation', 'w.generation')
                ->where('a.expires', '>', $time)->whereIn('s.worker_id', $workers->keys())
                ->groupBy('s.id', 's.worker_id')->selectRaw('s.id, s.worker_id, count(*) as seats')->get();
            $spare = $workers->map(fn ($worker) => (int) $worker->limit)->all();
            foreach ($counts as $count) {
                $spare[$count->worker_id] -= (int) $count->seats;
            }
            $seats = $counts->pluck('seats', 'id');
            $best = null;
            $bestSize = -1;
            $servers = DB::table('game_servers')->where(['place_id' => $world, 'release_id' => $place->release_id])
                ->whereIn('worker_id', $workers->keys())->orderBy('created')->get();
            foreach ($servers as $server) {
                $used = (int) $seats->get($server->id, 0);
                if ($server->generation === $workers[$server->worker_id]->generation && $spare[$server->worker_id] > 0
                    && $used < $server->capacity && $used > $bestSize) {
                    $best = $server;
                    $bestSize = $used;
                }
            }
            if (! $best) {
                arsort($spare);
                $node = array_key_first($spare);
                abort_if($spare[$node] <= 0, 503, 'Game servers are full. Try again shortly.');
                $row = ['id' => Identity::id(), 'place_id' => $world, 'release_id' => $place->release_id,
                    'worker_id' => $node, 'generation' => $workers[$node]->generation,
                    'capacity' => config('pot.room_size'), 'created' => $time];
                DB::table('game_servers')->insert($row);
                $best = (object) $row;
            }
            $ticket = bin2hex(random_bytes(32));
            DB::table('admissions')->insert(['id' => Identity::id(), 'digest' => hash('sha256', $ticket),
                'server_id' => $best->id, 'user_id' => $token?->user_id, 'desktop_token_id' => $token?->id,
                'expires' => $time + self::TICKET_TTL]);
            return ['ticket' => $ticket, 'socket' => '/v3/instances/'.$best->worker_id.'/socket',
                'server' => $best->id, 'world' => $world, 'revision' => $place->digest, 'expiresIn' => self::TICKET_TTL];
        }, 3);

        $reservation['project'] = new Binary($this->content->project($reservation['revision']));
        return $reservation;
    }

    public function heartbeat(string $worker, mixed $generation, mixed $limit, mixed $leases): array
    {
        abort_unless(Identity::projectId($generation) && is_int($limit) && $limit >= 1 && $limit <= 1024
            && is_array($leases) && array_is_list($leases) && count($leases) <= $limit, 422, 'Invalid worker heartbeat.');
        foreach ($leases as $lease) {
            abort_unless(is_string($lease) && preg_match('/\A[a-z0-9]{26}\z/', $lease), 422, 'Invalid admission ID.');
        }
        $kept = DB::transaction(function () use ($worker, $generation, $limit, $leases) {
            $time = time();
            DB::table('workers')->upsert([['id' => $worker, 'generation' => $generation, 'limit' => $limit,
                'heartbeat' => $time]], ['id'], ['generation', 'limit', 'heartbeat']);
            $active = DB::table('admissions')->whereIn('id', $leases)->whereNotNull('redeemed')->where('expires', '>', $time)
                ->whereIn('server_id', fn ($q) => $q->select('id')->from('game_servers')
                    ->where(['worker_id' => $worker, 'generation' => $generation]));
            $kept = (clone $active)->pluck('id')->all();
            $active->update(['expires' => $time + self::LEASE_TTL]);
            return $kept;
        }, 3);
        return ['leases' => $kept];
    }

    public function redeem(string $worker, mixed $generation, mixed $ticket): array
    {
        $digest = Identity::digest($ticket);
        abort_unless($digest && Identity::projectId($generation), 401, 'Invalid join ticket.');
        $reservation = DB::transaction(function () use ($worker, $generation, $digest) {
            $time = time();
            $node = DB::table('workers')->where(['id' => $worker, 'generation' => $generation])
                ->where('heartbeat', '>', $time - self::WORKER_TTL)->lockForUpdate()->first();
            abort_unless($node, 503, 'Game worker is not registered.');
            $a = DB::table('admissions as a')->join('game_servers as s', 's.id', '=', 'a.server_id')
                ->join('releases as r', 'r.id', '=', 's.release_id')
                ->select('a.id', 'a.server_id', 'a.user_id', 's.place_id', 's.capacity', 'r.digest')
                ->where(['a.digest' => $digest, 's.worker_id' => $worker, 's.generation' => $generation])
                ->where('a.expires', '>', $time)->whereNull('a.redeemed')->first();
            abort_unless($a, 401, 'Join ticket expired or was already used.');
            $claimed = DB::table('admissions')->where('id', $a->id)->whereNull('redeemed')->where('expires', '>', $time)
                ->update(['redeemed' => $time, 'expires' => $time + self::LEASE_TTL]);
            abort_unless($claimed === 1, 401, 'Join ticket is no longer available.');
            return $a;
        }, 3);
        $user = $reservation->user_id ? User::query()->find($reservation->user_id) : null;
        return ['admission' => $reservation->id, 'server' => $reservation->server_id, 'world' => $reservation->place_id,
            'revision' => $reservation->digest, 'capacity' => (int) $reservation->capacity,
            'avatar' => $user ? ['displayName' => $user->name, 'look' => $user->look()] : null,
            'project' => new Binary($this->content->project($reservation->digest))];
    }

    public function release(string $worker, mixed $generation, mixed $admission): void
    {
        abort_unless(Identity::projectId($generation) && is_string($admission) && preg_match('/\A[a-z0-9]{26}\z/', $admission),
            422, 'Invalid admission release.');
        DB::table('admissions')->where('id', $admission)->whereNotNull('redeemed')
            ->whereIn('server_id', fn ($q) => $q->select('id')->from('game_servers')
                ->where(['worker_id' => $worker, 'generation' => $generation]))->delete();
    }

    public function prune(): void
    {
        DB::table('admissions')->where('expires', '<=', time())->delete();
        DB::table('game_servers')->where('created', '<', time() - 600)
            ->whereNotIn('id', fn ($q) => $q->select('server_id')->from('admissions'))->delete();
    }
}
