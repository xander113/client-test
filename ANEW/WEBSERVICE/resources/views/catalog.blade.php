@extends('layout')
@section('content')
<h1>Games</h1>
<div class="games">
    @forelse($games as $game)
        <a class="game" href="{{ route('game', $game->experience_id) }}">
            <img src="{{ route('preview', $game->id) }}" alt="" width="480" height="270" loading="lazy">
            <span>{{ $game->game_title }}</span>
            @unless($game->published)<small>Private</small>@endunless
        </a>
    @empty
        <p class="muted">There are no games to show yet.</p>
    @endforelse
</div>
@include('pagination', ['page' => $games])
@endsection
