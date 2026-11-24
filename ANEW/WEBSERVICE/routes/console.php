<?php

use App\Services\Matchmaker;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('pot:prune', function (Matchmaker $matchmaker) {
    $matchmaker->prune();
})->purpose('Remove expired admissions and idle game server records.');

Schedule::command('pot:prune')->everyMinute()->onOneServer();
