@extends('layout')
@section('title', $place->game_title)
@section('content')
<a class="back" href="{{ route('browse') }}">Games</a>
<div class="detail">
    <img class="cover" src="{{ route('preview', $place->id) }}" alt="Map preview" width="480" height="270">
    <div>
        <h1>{{ $place->game_title }}</h1>
        @unless($place->published)<p class="muted">Private game</p>@endunless
        <p class="description">{{ $place->description }}</p>
        <dl>
            <dt>Start place</dt><dd>{{ $place->title }}</dd>
            <dt>World ID</dt><dd><code>{{ $place->id }}</code></dd>
        </dl>
        <p class="muted">Open Pot Client, choose this world, and select Join online.</p>
        @auth <a href="{{ route('account') }}">Set up desktop access</a> @endauth
    </div>
</div>
@endsection
