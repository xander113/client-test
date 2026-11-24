<?php

use App\Http\Controllers\Site;
use Illuminate\Support\Facades\Route;

Route::get('/', [Site::class, 'index'])->name('browse');
Route::get('/games/{game}', [Site::class, 'game'])->name('game');
Route::get('/previews/{world}', [Site::class, 'image'])->name('preview');
Route::middleware('guest')->group(function () {
    Route::get('/login', fn () => view('auth', ['register' => false]))->name('login');
    Route::get('/register', fn () => view('auth', ['register' => true]))->name('register');
    Route::post('/login', [Site::class, 'login'])->middleware('throttle:12,1');
    Route::post('/register', [Site::class, 'register'])->middleware('throttle:8,1');
});
Route::middleware('auth')->group(function () {
    Route::post('/logout', [Site::class, 'logout'])->name('logout');
    Route::get('/account', [Site::class, 'account'])->name('account');
    Route::post('/account/tokens', [Site::class, 'token'])->middleware('throttle:8,1')->name('tokens');
    Route::post('/account/tokens/{token}/revoke', [Site::class, 'revoke'])->whereNumber('token')->name('revoke');
    Route::post('/account/appearance', [Site::class, 'palette'])->name('appearance');
    Route::get('/creator', [Site::class, 'creator'])->name('creator');
    Route::post('/creator', [Site::class, 'upload'])->middleware('throttle:15,1')->name('upload');
    Route::get('/creator/{game}', [Site::class, 'manage'])->name('manage');
    Route::post('/creator/{game}/settings', [Site::class, 'settings'])->name('settings');
    Route::post('/creator/{game}/{place}/{release}/restore', [Site::class, 'restore'])->name('restore');
});
