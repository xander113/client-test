@extends('layout')
@section('title', 'Creator')
@section('content')
<h1>Creator</h1>
<div class="columns creator">
    <section>
        <h2>Your games</h2>
        @forelse($games as $game)
            <a class="split list-row" href="{{ route('manage', $game->id) }}">
                <strong>{{ $game->title }}</strong><small class="muted">{{ $game->published ? 'Public' : 'Private' }}</small>
            </a>
        @empty <p class="muted">Publish from Studio or upload a saved project here.</p> @endforelse
        @include('pagination', ['page' => $games])
    </section>
    <section class="card">
        <h2>Publish a place</h2>
        <form class="stack" enctype="multipart/form-data" method="post" action="{{ route('upload') }}">
            @csrf
            <label>Game<select name="game">
                <option value="">Create a new game</option>
                @foreach($options as $game)<option value="{{ $game->id }}">{{ $game->title }}</option>@endforeach
            </select></label>
            <label>Project file<input type="file" name="project" accept=".pot" required></label>
            <button class="button">Publish</button>
        </form>
    </section>
</div>
@endsection
