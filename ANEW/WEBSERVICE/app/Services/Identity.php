<?php

declare(strict_types=1);

namespace App\Services;

use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

final class Identity
{
    public static function id(): string
    {
        return strtolower((string) Str::ulid());
    }

    public static function projectId(mixed $value): bool
    {
        return is_string($value) && preg_match('/\A[a-z0-9][a-z0-9-]{0,63}\z/', $value) === 1;
    }

    public static function digest(mixed $token): ?string
    {
        return is_string($token) && preg_match('/\A[0-9a-f]{64}\z/', $token) ? hash('sha256', $token) : null;
    }

    public static function keyMatches(mixed $token, mixed $expected): bool
    {
        return is_string($expected) && self::digest($expected) !== null
            && is_string($token) && hash_equals($expected, $token);
    }

    public static function desktop(Request $request, bool $required = true): ?object
    {
        $value = $request->bearerToken();
        if ($value === null && ! $required) {
            return null;
        }
        $digest = self::digest($value);
        $token = $digest ? DB::table('desktop_tokens')->where('digest', $digest)->where('expires', '>', time())->first() : null;
        abort_unless($token, 401, 'A valid Pot desktop credential is required.');

        return $token;
    }

    public static function look(mixed $value): array
    {
        $look = [];
        foreach (['skin', 'shirt', 'pants', 'visor'] as $key) {
            $color = is_array($value) ? ($value[$key] ?? null) : null;
            abort_unless(is_string($color) && preg_match('/\A#[0-9a-fA-F]{6}\z/', $color), 422, 'Supply four #rrggbb colors.');
            $look[$key] = strtolower($color);
        }
        return $look;
    }

    public static function wallet(User $user, mixed $op, mixed $delta): array
    {
        abort_unless(self::projectId($op) && is_int($delta) && $delta !== 0 && abs($delta) <= 1_000_000_000, 422,
            'Supply a unique operation ID and a nonzero integer currency delta.');
        return DB::transaction(function () use ($user, $op, $delta) {
            $owner = User::query()->lockForUpdate()->findOrFail($user->id);
            $prior = DB::table('wallet_entries')->where(['user_id' => $owner->id, 'operation' => $op])->first();
            if ($prior) {
                abort_unless((int) $prior->delta === $delta, 409, 'The operation ID was used with a different amount.');
                return ['operation' => $op, 'delta' => $delta, 'balance' => (int) $prior->balance];
            }
            $balance = $owner->balance + $delta;
            abort_if($balance < 0 || $balance > 9_000_000_000_000, 409, 'The resulting balance is outside the allowed range.');
            DB::table('wallet_entries')->insert(['user_id' => $owner->id, 'operation' => $op,
                'delta' => $delta, 'balance' => $balance, 'created_at' => now()]);
            $owner->forceFill(['balance' => $balance])->save();
            return ['operation' => $op, 'delta' => $delta, 'balance' => $balance];
        }, 3);
    }
}
