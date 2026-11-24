@extends('layout')
@section('title', 'Account')
@section('content')
<h1>{{ $user->name }}</h1>
<div class="columns">
    <section class="card">
        <h2>Appearance</h2>
        <form class="stack" method="post" action="{{ route('appearance') }}">
            @csrf
            <div class="palette">
                @foreach($user->look() as $part => $color)
                    <label>{{ ucfirst($part) }}<input type="color" name="{{ $part }}" value="{{ $color }}" required></label>
                @endforeach
            </div>
            <button class="button">Save appearance</button>
        </form>
        <p>Balance <strong>{{ number_format($user->balance) }}</strong></p>
    </section>
    <section class="card">
        <h2>Desktop access</h2>
        <p class="muted">Set POT_API_ENDPOINT to <code>{{ rtrim(config('app.url'), '/') }}</code> and POT_ACCOUNT_TOKEN to your desktop key before launching Client or Studio.</p>
        @if(session('desktop_token'))
            <label>Copy your new key<input value="{{ session('desktop_token') }}" readonly autocomplete="off"></label>
            <p class="muted">This key is shown once. Keep it private.</p>
        @endif
        <form class="split token-form" method="post" action="{{ route('tokens') }}">
            @csrf<label>Device name<input name="label" maxlength="60" required placeholder="My PC"></label>
            <button class="button">Create key</button>
        </form>
        @foreach($tokens as $token)
            <div class="split list-row">
                <span>{{ $token->label }} <small class="muted">Expires {{ gmdate('Y-m-d', $token->expires) }}</small></span>
                <form method="post" action="{{ route('revoke', $token->id) }}">@csrf<button class="plain danger">Revoke</button></form>
            </div>
        @endforeach
    </section>
</div>
@endsection
