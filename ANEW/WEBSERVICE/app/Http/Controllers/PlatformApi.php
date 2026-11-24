<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Models\User;
use App\Services\Catalog;
use App\Services\Content;
use App\Services\Identity;
use App\Services\Matchmaker;
use App\Services\Wire;
use Illuminate\Http\Request;
use Illuminate\Http\Response;

final readonly class PlatformApi
{
    public function __construct(private Catalog $catalog, private Content $content, private Matchmaker $matchmaker) {}

    public function worlds(Request $request): Response
    {
        $token = Identity::desktop($request, false);
        return Wire::response($this->catalog->desktopList($token ? (int) $token->user_id : null));
    }

    public function managed(Request $request): Response
    {
        $token = Identity::desktop($request);
        return Wire::response($this->catalog->desktopList((int) $token->user_id, true));
    }

    public function world(Request $request, string $world): Response
    {
        $managed = $request->routeIs('pot.published');
        $token = Identity::desktop($request, $managed);
        $place = $this->catalog->release($world, $token ? (int) $token->user_id : null, $managed);
        return Wire::raw($this->content->project($place->digest));
    }

    public function thumbnail(Request $request, string $world): Response
    {
        $token = Identity::desktop($request, false);
        $place = $this->catalog->release($world, $token ? (int) $token->user_id : null);
        return Wire::raw($this->content->thumbnail($place->digest), 'image/png');
    }

    public function spawns(Request $request, string $world): Response
    {
        $token = Identity::desktop($request, false);
        $place = $this->catalog->release($world, $token ? (int) $token->user_id : null);
        $project = Wire::decode($this->content->project($place->digest));
        $points = [];
        foreach ($project['objects'] as $part) {
            if ($part['kind'] === 'spawn') {
                $points[] = ['id' => $part['id'], 'name' => $part['name'], 'enabled' => $part['enabled'],
                    'position' => $part['position'], 'yaw' => $part['rotation'][1]];
            }
        }
        return Wire::response(['allowReset' => $project['allowReset'], 'defaultSpawn' => $project['defaultSpawn'] ?? null,
            'fallback' => $project['spawn'], 'points' => $points]);
    }

    public function publish(Request $request, string $world): Response
    {
        abort_unless(Identity::projectId($world), 404);
        $token = Identity::desktop($request);
        return Wire::response($this->catalog->publish((int) $token->user_id, $request->getContent(), $world));
    }

    public function unpublish(Request $request, string $world): Response
    {
        $token = Identity::desktop($request);
        $this->catalog->unpublish($world, (int) $token->user_id);
        return Wire::response(true);
    }

    public function join(Request $request): Response
    {
        $token = Identity::desktop($request, false);
        $input = Wire::input($request->getContent());
        $world = is_array($input) ? ($input['world'] ?? null) : null;
        abort_unless(Identity::projectId($world), 422, 'Choose a valid place.');
        return Wire::response($this->matchmaker->join($world, $token));
    }

    public function account(Request $request): Response
    {
        $token = Identity::desktop($request);
        return Wire::response(User::query()->findOrFail($token->user_id)->profile());
    }

    public function look(Request $request): Response
    {
        $token = Identity::desktop($request);
        $look = Identity::look(Wire::input($request->getContent()));
        $user = User::query()->findOrFail($token->user_id);
        $user->forceFill($look)->save();
        return Wire::response($user->refresh()->profile());
    }

    public function currency(Request $request, string $account): Response
    {
        abort_unless(Identity::keyMatches($request->bearerToken(), config('pot.ledger_token')), 401, 'Currency authority is required.');
        $user = User::query()->where('public_id', $account)->firstOrFail();
        $input = Wire::input($request->getContent());
        return Wire::response(Identity::wallet($user, $input['operation'] ?? null, $input['delta'] ?? null));
    }

    public function worker(Request $request, string $worker, string $action): Response
    {
        abort_unless(Identity::keyMatches($request->bearerToken(), config('pot.nodes')[$worker] ?? null),
            401, 'A game-worker credential is required.');
        $body = Wire::input($request->getContent(), 48 * 1024);
        abort_unless(is_array($body), 422, 'Invalid worker packet.');
        $generation = $body['generation'] ?? null;
        if ($action === 'heartbeat') {
            return Wire::response($this->matchmaker->heartbeat($worker, $generation, $body['limit'] ?? null, $body['leases'] ?? []));
        }
        if ($action === 'redeem') {
            return Wire::response($this->matchmaker->redeem($worker, $generation, $body['ticket'] ?? null));
        }
        $this->matchmaker->release($worker, $generation, $body['admission'] ?? null);
        return Wire::response(true);
    }
}
