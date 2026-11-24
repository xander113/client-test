<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>@yield('title', 'Games') · Pot</title>
    <link rel="stylesheet" href="{{ asset('pot.css') }}">
</head>
<body>
<header>
    <nav class="container" aria-label="Main navigation">
        <a class="brand" href="{{ route('browse') }}">Pot</a>
        <a href="{{ route('browse') }}">Games</a>
        @auth
            <a href="{{ route('creator') }}">Creator</a>
            <div class="spacer"></div>
            <a href="{{ route('account') }}">Account</a>
            <form action="{{ route('logout') }}" method="post">@csrf<button class="plain">Sign out</button></form>
        @else
            <div class="spacer"></div>
            <a href="{{ route('login') }}">Sign in</a>
            <a class="button small" href="{{ route('register') }}">Create account</a>
        @endauth
    </nav>
</header>
<main class="container">
    @if(session('notice')) <p class="notice" role="status">{{ session('notice') }}</p> @endif
    @if($errors->any())
        <div class="notice error" role="alert">
            @foreach($errors->all() as $error) <div>{{ $error }}</div> @endforeach
        </div>
    @endif
    @yield('content')
</main>
</body>
</html>
