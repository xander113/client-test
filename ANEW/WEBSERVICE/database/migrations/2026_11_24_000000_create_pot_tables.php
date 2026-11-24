<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('users', function (Blueprint $t) {
            $t->id();
            $t->string('public_id', 26)->unique();
            $t->string('name', 80);
            $t->string('email', 254)->unique();
            $t->string('password');
            $t->char('skin', 7)->default('#dbccad');
            $t->char('shirt', 7)->default('#31a963');
            $t->char('pants', 7)->default('#354648');
            $t->char('visor', 7)->default('#1e403c');
            $t->unsignedBigInteger('balance')->default(0);
            $t->rememberToken();
            $t->timestamps();
        });
        Schema::create('sessions', function (Blueprint $t) {
            $t->string('id')->primary();
            $t->foreignId('user_id')->nullable()->index();
            $t->string('ip_address', 45)->nullable();
            $t->text('user_agent')->nullable();
            $t->longText('payload');
            $t->integer('last_activity')->index();
        });
        Schema::create('cache', function (Blueprint $t) {
            $t->string('key')->primary();
            $t->mediumText('value');
            $t->bigInteger('expiration')->index();
        });
        Schema::create('cache_locks', function (Blueprint $t) {
            $t->string('key')->primary();
            $t->string('owner');
            $t->bigInteger('expiration')->index();
        });
        Schema::create('desktop_tokens', function (Blueprint $t) {
            $t->id();
            $t->foreignId('user_id')->constrained()->cascadeOnDelete();
            $t->string('label', 60);
            $t->char('digest', 64)->unique();
            $t->bigInteger('expires')->index();
            $t->timestamps();
        });
        Schema::create('experiences', function (Blueprint $t) {
            $t->string('id', 26)->primary();
            $t->foreignId('owner_id')->constrained('users')->restrictOnDelete();
            $t->string('title', 320);
            $t->text('description');
            $t->string('start_place_id', 64);
            $t->boolean('published')->default(false)->index();
            $t->timestamps();
        });
        Schema::create('places', function (Blueprint $t) {
            $t->string('id', 64)->primary();
            $t->string('experience_id', 26);
            $t->foreign('experience_id')->references('id')->on('experiences')->restrictOnDelete();
            $t->string('title', 320);
            $t->text('description');
            $t->string('release_id', 26)->nullable();
            $t->timestamps();
        });
        Schema::create('releases', function (Blueprint $t) {
            $t->string('id', 26)->primary();
            $t->string('place_id', 64);
            $t->foreign('place_id')->references('id')->on('places')->restrictOnDelete();
            $t->unsignedInteger('number');
            $t->char('digest', 64);
            $t->string('title', 320);
            $t->text('description');
            $t->timestamp('created_at');
            $t->unique(['place_id', 'number']);
            $t->unique(['place_id', 'digest']);
        });
        Schema::create('workers', function (Blueprint $t) {
            $t->string('id', 40)->primary();
            $t->string('generation', 64);
            $t->unsignedInteger('limit');
            $t->bigInteger('heartbeat')->index();
        });
        Schema::create('game_servers', function (Blueprint $t) {
            $t->string('id', 26)->primary();
            $t->string('place_id', 64);
            $t->foreign('place_id')->references('id')->on('places')->restrictOnDelete();
            $t->string('release_id', 26);
            $t->foreign('release_id')->references('id')->on('releases')->restrictOnDelete();
            $t->string('worker_id', 40);
            $t->foreign('worker_id')->references('id')->on('workers')->restrictOnDelete();
            $t->string('generation', 64);
            $t->unsignedInteger('capacity');
            $t->bigInteger('created')->index();
            $t->index(['place_id', 'release_id']);
            $t->index(['worker_id', 'generation']);
        });
        Schema::create('admissions', function (Blueprint $t) {
            $t->string('id', 26)->primary();
            $t->char('digest', 64)->unique();
            $t->string('server_id', 26);
            $t->foreign('server_id')->references('id')->on('game_servers')->cascadeOnDelete();
            $t->foreignId('user_id')->nullable()->constrained()->cascadeOnDelete();
            $t->foreignId('desktop_token_id')->nullable()->constrained()->cascadeOnDelete();
            $t->bigInteger('expires')->index();
            $t->bigInteger('redeemed')->nullable();
            $t->index(['server_id', 'expires']);
        });
        Schema::create('wallet_entries', function (Blueprint $t) {
            $t->id();
            $t->foreignId('user_id')->constrained()->restrictOnDelete();
            $t->string('operation', 64);
            $t->bigInteger('delta');
            $t->unsignedBigInteger('balance');
            $t->timestamp('created_at');
            $t->unique(['user_id', 'operation']);
        });
    }

    public function down(): void
    {
        foreach (['wallet_entries', 'admissions', 'game_servers', 'workers', 'releases', 'places',
            'experiences', 'desktop_tokens', 'cache_locks', 'cache', 'sessions', 'users'] as $table) {
            Schema::dropIfExists($table);
        }
    }
};
