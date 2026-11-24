<?php

declare(strict_types=1);

namespace App\Services;

use Illuminate\Database\Query\Builder;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Support\Facades\DB;

final readonly class Catalog
{
    public function __construct(private Content $content) {}

    private function places(): Builder
    {
        return DB::table('places as p')->join('experiences as e', 'e.id', '=', 'p.experience_id')
            ->join('releases as r', 'r.id', '=', 'p.release_id')
            ->select('p.*', 'e.owner_id', 'e.published', 'e.start_place_id', 'e.title as game_title',
                'r.digest', 'r.number');
    }

    public function visible(?int $user): Builder
    {
        return $this->places()->whereColumn('p.id', 'e.start_place_id')
            ->where(function (Builder $q) use ($user) {
                $q->where('e.published', true);
                if ($user !== null) {
                    $q->orWhere('e.owner_id', $user);
                }
            });
    }

    public function desktopList(?int $user, bool $managed = false): array
    {
        $query = $managed ? $this->places()->where('e.owner_id', $user) : $this->visible($user);

        return $query->orderByDesc('p.updated_at')->orderBy('p.id')->limit(128)->get()
            ->map(fn ($place) => ['id' => $place->id, 'name' => $place->title, 'description' => $place->description,
                'published' => (bool) $place->published])->all();
    }

    public function release(string $id, ?int $user, bool $managed = false, bool $lock = false): object
    {
        abort_unless(Identity::projectId($id), 404);
        $query = $this->places()->where('p.id', $id)->where(function (Builder $q) use ($user, $managed) {
            if (! $managed) {
                $q->where('e.published', true);
            }
            if ($user !== null) {
                $q->orWhere('e.owner_id', $user);
            }
        });
        if ($lock) {
            $query->lockForUpdate();
        }
        $place = $query->first();
        abort_unless($place, 404, 'This place is not available.');
        return $place;
    }

    public function ownedGame(string $id, int $user, bool $lock = false): object
    {
        $query = DB::table('experiences')->where(['id' => $id, 'owner_id' => $user]);
        $game = ($lock ? $query->lockForUpdate() : $query)->first();
        abort_unless($game, 404, 'This game is not managed by your account.');
        return $game;
    }

    private function ownedPlace(string $id, int $user): object
    {
        $place = DB::table('places')->where('id', $id)->lockForUpdate()->first();
        abort_unless($place, 404, 'Place not found.');
        $this->ownedGame($place->experience_id, $user, true);
        return $place;
    }

    public function publish(int $user, string $bytes, ?string $expected = null, ?string $targetGame = null): array
    {
        if ($targetGame !== null) {
            $this->ownedGame($targetGame, $user);
        }
        [$project, $blob] = $this->content->validate($bytes);
        $id = $project['id'];
        abort_if($expected !== null && $expected !== $id, 422, 'The place and upload IDs differ.');
        $name = $project['name'];
        $description = $project['description'];
        try {
            return DB::transaction(function () use ($user, $id, $name, $description, $blob, $targetGame) {
                $place = DB::table('places')->where('id', $id)->lockForUpdate()->first();
                if ($place) {
                    $game = $this->ownedGame($place->experience_id, $user, true);
                    abort_if($targetGame !== null && $targetGame !== $game->id, 409, 'The place belongs to a different game.');
                } else {
                    if ($targetGame !== null) {
                        $game = $this->ownedGame($targetGame, $user, true);
                    } else {
                        $game = (object) ['id' => Identity::id(), 'start_place_id' => $id, 'published' => false];
                        DB::table('experiences')->insert(['id' => $game->id, 'owner_id' => $user,
                            'title' => $name, 'description' => $description, 'start_place_id' => $id,
                            'published' => false, 'created_at' => now(), 'updated_at' => now()]);
                    }
                    DB::table('places')->insert(['id' => $id, 'experience_id' => $game->id, 'title' => $name,
                        'description' => $description, 'created_at' => now(), 'updated_at' => now()]);
                }
                $digest = $this->content->store($blob);
                $release = DB::table('releases')->where(['place_id' => $id, 'digest' => $digest])->first();
                if (! $release) {
                    $number = (int) DB::table('releases')->where('place_id', $id)->max('number') + 1;
                    $release = (object) ['id' => Identity::id(), 'number' => $number];
                    DB::table('releases')->insert(['id' => $release->id, 'place_id' => $id, 'number' => $number,
                        'title' => $name, 'description' => $description, 'digest' => $digest, 'created_at' => now()]);
                }
                $this->setRelease($id, $game, $release->id, $name, $description);
                return ['id' => $id, 'experience' => $game->id, 'version' => (int) $release->number,
                    'public' => (bool) $game->published];
            }, 3);
        } catch (UniqueConstraintViolationException) {
            abort(409, 'This publication conflicts with a concurrent update. Refresh and try again.');
        }
    }

    private function setRelease(string $id, object $game, string $release, string $title, string $description): void
    {
        DB::table('places')->where('id', $id)->update(['release_id' => $release, 'title' => $title,
            'description' => $description, 'updated_at' => now()]);
        if ($game->start_place_id === $id) {
            DB::table('experiences')->where('id', $game->id)->update(['title' => $title, 'description' => $description,
                'updated_at' => now()]);
        }
    }

    public function unpublish(string $id, int $user): void
    {
        DB::transaction(function () use ($id, $user) {
            $place = $this->ownedPlace($id, $user);
            DB::table('places')->where('id', $place->id)->update(['release_id' => null, 'updated_at' => now()]);
            $this->cancelReservations(DB::table('game_servers')->where('place_id', $id));
        }, 3);
    }

    private function cancelReservations(Builder $servers): void
    {
        DB::table('admissions')->whereNull('redeemed')->whereIn('server_id', $servers->select('id'))->delete();
    }

    public function restore(string $game, string $id, string $release, int $user): void
    {
        DB::transaction(function () use ($game, $id, $release, $user) {
            $place = $this->ownedPlace($id, $user);
            abort_unless($game === $place->experience_id, 404);
            $version = DB::table('releases')->where(['id' => $release, 'place_id' => $id])->first();
            abort_unless($version, 404, 'Version not found.');
            $this->content->project($version->digest);
            $this->setRelease($id, $this->ownedGame($game, $user), $version->id, $version->title, $version->description);
        }, 3);
    }

    public function settings(string $game, int $user, string $start, bool $public): void
    {
        DB::transaction(function () use ($game, $user, $start, $public) {
            $this->ownedGame($game, $user, true);
            $place = DB::table('places')->where(['id' => $start, 'experience_id' => $game])->first();
            abort_unless($place && (! $public || $place->release_id), 422, 'Publish the start place before opening the game to everyone.');
            DB::table('experiences')->where('id', $game)->update(['start_place_id' => $start, 'published' => $public,
                'title' => $place->title, 'description' => $place->description, 'updated_at' => now()]);
            if (! $public) {
                $servers = DB::table('game_servers')->whereIn('place_id', DB::table('places')->where('experience_id', $game)->select('id'));
                $this->cancelReservations($servers);
            }
        }, 3);
    }
}
