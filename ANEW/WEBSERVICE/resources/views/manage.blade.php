@extends('layout')
@section('title', $entry->title)
@section('content')
<a class="back" href="{{ route('creator') }}">Creator</a>
<h1>{{ $entry->title }}</h1>
<div class="columns creator">
    <section>
        <h2>Places and versions</h2>
        @foreach($places as $place)
            <details class="versions" @if($loop->first) open @endif>
                <summary>{{ $place->title }} <small>{{ $place->id }}</small></summary>
                @foreach($versions[$place->id] as $version)
                    <div class="split list-row">
                        <span>Version {{ $version->number }} <small class="muted">{{ substr($version->created_at, 0, 10) }}</small></span>
                        @if($place->release_id === $version->id)
                            <small class="muted">Current</small>
                        @else
                            <form method="post" action="{{ route('restore', [$entry->id, $place->id, $version->id]) }}">
                                @csrf<button class="plain">Restore</button>
                            </form>
                        @endif
                    </div>
                @endforeach
            </details>
        @endforeach
    </section>
    <section class="card">
        <h2>Game settings</h2>
        <form class="stack" method="post" action="{{ route('settings', $entry->id) }}">
            @csrf
            <label>Start place<select name="start">
                @foreach($places as $place)<option value="{{ $place->id }}" @selected($entry->start_place_id === $place->id)>{{ $place->title }}</option>@endforeach
            </select></label>
            <label>Visibility<select name="visibility">
                <option value="private" @selected(!$entry->published)>Private</option>
                <option value="public" @selected($entry->published)>Public</option>
            </select></label>
            <button class="button">Save settings</button>
        </form>
    </section>
</div>
@endsection
