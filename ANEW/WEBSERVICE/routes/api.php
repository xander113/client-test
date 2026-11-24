<?php

use App\Http\Controllers\PlatformApi as Api;
use Illuminate\Support\Facades\Route;

Route::middleware('throttle:catalog')->group(function () {
    Route::get('worlds', [Api::class, 'worlds']);
    Route::get('worlds/{world}/thumbnail', [Api::class, 'thumbnail']);
    Route::get('worlds/{world}/spawns', [Api::class, 'spawns']);
    Route::get('worlds/{world}', [Api::class, 'world']);
    Route::get('published', [Api::class, 'managed']);
    Route::get('published/{world}', [Api::class, 'world'])->name('pot.published');
});
Route::middleware('throttle:publish')->group(function () {
    Route::put('worlds/{world}', [Api::class, 'publish']);
    Route::delete('worlds/{world}', [Api::class, 'unpublish']);
});
Route::post('join', [Api::class, 'join'])->middleware('throttle:admission');
Route::middleware('throttle:account')->group(function () {
    Route::get('account/me', [Api::class, 'account']);
    Route::put('account/me/look', [Api::class, 'look']);
    Route::post('internal/accounts/{account}/currency', [Api::class, 'currency']);
});
Route::post('internal/workers/{worker}/{action}', [Api::class, 'worker'])
    ->whereIn('action', ['heartbeat', 'redeem', 'release']);
