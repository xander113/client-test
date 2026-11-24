@extends('layout')
@section('title', $register ? 'Create account' : 'Sign in')
@section('content')
<section class="form-page">
    <h1>{{ $register ? 'Create an account' : 'Sign in' }}</h1>
    <form class="card stack" method="post">
        @csrf
        @if($register)
            <label>Display name<input name="name" value="{{ old('name') }}" maxlength="24" required autocomplete="nickname"></label>
        @endif
        <label>Email address<input name="email" type="email" value="{{ old('email') }}" maxlength="254" required autocomplete="email"></label>
        <label>Password<input type="password" name="password" required autocomplete="{{ $register ? 'new-password' : 'current-password' }}"></label>
        @if($register)
            <small class="muted">Use at least 12 characters.</small>
            <label>Confirm password<input name="password_confirmation" type="password" required autocomplete="new-password"></label>
        @endif
        <button class="button">{{ $register ? 'Create account' : 'Sign in' }}</button>
    </form>
</section>
@endsection
