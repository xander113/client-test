<?php

declare(strict_types=1);

namespace App\Providers;

use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;

final class AppServiceProvider extends ServiceProvider
{
    public function boot(): void
    {
        RateLimiter::for('catalog', fn (Request $r) => Limit::perMinute(240)->by($r->ip()));
        RateLimiter::for('admission', fn (Request $r) => Limit::perMinute(90)->by($r->ip()));
        RateLimiter::for('publish', fn (Request $r) => [
            Limit::perMinute(90)->by($r->ip()),
            Limit::perMinute(20)->by(hash('sha256', (string) $r->bearerToken())),
        ]);
        RateLimiter::for('account', fn (Request $r) => Limit::perMinute(120)->by($r->ip()));
    }
}
