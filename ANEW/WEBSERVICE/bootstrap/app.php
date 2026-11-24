<?php

declare(strict_types=1);

use App\Services\Wire;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(web: __DIR__.'/../routes/web.php', api: __DIR__.'/../routes/api.php',
        commands: __DIR__.'/../routes/console.php', apiPrefix: 'v3', health: '/up')
    ->withMiddleware(function (Middleware $middleware): void {
        $middleware->trustProxies(at: env('POT_TRUSTED_PROXIES', ''));
        $middleware->redirectGuestsTo(fn () => route('login'));
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        $exceptions->render(function (HttpExceptionInterface $e, Request $request) {
            if ($request->is('v3/*')) {
                return Wire::response(['message' => $e->getMessage() ?: 'The request could not be completed.'],
                    $e->getStatusCode(), $e->getHeaders());
            }
        });
    })
    ->create();
