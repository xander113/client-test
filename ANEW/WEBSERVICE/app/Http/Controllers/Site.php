<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Models\User;
use App\Services\Catalog;
use App\Services\Content;
use App\Services\Identity;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Validation\ValidationException;

final readonly class Site
{
    public function __construct(private Catalog $catalog, private Content $content) {}

    public function index(Request $request)
    {
        $games = $this->catalog->visible($request->user()?->id)->orderByDesc('p.updated_at')->orderBy('p.id')->paginate(18);
        return view('catalog', compact('games'));
    }

    public function game(Request $request, string $game)
    {
        $place = $this->catalog->visible($request->user()?->id)->where('e.id', $game)->first();
        abort_unless($place, 404);
        return view('game', compact('place'));
    }

    public function image(Request $request, string $world)
    {
        $place = $this->catalog->release($world, $request->user()?->id);
        return response($this->content->thumbnail($place->digest), 200,
            ['Content-Type' => 'image/png', 'Cache-Control' => 'private, max-age=60', 'X-Content-Type-Options' => 'nosniff']);
    }

    public function register(Request $request)
    {
        $request->merge(['email' => strtolower((string) $request->input('email', ''))]);
        $fields = $request->validate(['name' => ['required', 'string', 'max:24', 'not_regex:/\p{C}/u'],
            'email' => 'required|email:rfc|max:254|unique:users,email', 'password' => 'required|string|min:12|max:72|confirmed']);
        if (strlen($fields['password']) > 72 || str_contains($fields['password'], "\0")
            || strlen($fields['name']) > 80) {
            throw ValidationException::withMessages(['password' => 'Use a password of at most 72 bytes and a shorter display name.']);
        }
        try {
            $user = User::create(['public_id' => Identity::id(), 'name' => $fields['name'], 'email' => $fields['email'],
                'password' => Hash::make($fields['password'])]);
        } catch (UniqueConstraintViolationException) {
            throw ValidationException::withMessages(['email' => 'This email address is already registered.']);
        }
        Auth::login($user);
        $request->session()->regenerate();
        return redirect()->route('account')->with('notice', 'Your account is ready.');
    }

    public function login(Request $request)
    {
        $fields = $request->validate(['email' => 'required|string|max:254', 'password' => 'required|string|max:72']);
        $password = $fields['password'];
        if (strlen($password) > 72 || str_contains($password, "\0")
            || ! Auth::attempt(['email' => strtolower($fields['email']), 'password' => $password])) {
            throw ValidationException::withMessages(['email' => 'The email address or password is incorrect.']);
        }
        $request->session()->regenerate();
        return redirect()->intended(route('browse'));
    }

    public function logout(Request $request)
    {
        Auth::logout();
        $request->session()->invalidate();
        $request->session()->regenerateToken();
        return redirect()->route('browse');
    }

    public function account(Request $request)
    {
        $tokens = DB::table('desktop_tokens')->where('user_id', $request->user()->id)->where('expires', '>', time())->latest()->get();
        return response()->view('account', ['user' => $request->user(), 'tokens' => $tokens],
            headers: ['Cache-Control' => 'no-store']);
    }

    public function token(Request $request)
    {
        $fields = $request->validate(['label' => 'required|string|max:60']);
        $key = bin2hex(random_bytes(32));
        DB::table('desktop_tokens')->insert(['user_id' => $request->user()->id, 'label' => $fields['label'],
            'digest' => hash('sha256', $key), 'expires' => time() + 90 * 86400, 'created_at' => now(), 'updated_at' => now()]);
        return redirect()->route('account')->with('desktop_token', $key);
    }

    public function revoke(Request $request, string $token)
    {
        DB::table('desktop_tokens')->where(['id' => $token, 'user_id' => $request->user()->id])->delete();
        return redirect()->route('account')->with('notice', 'Desktop access revoked.');
    }

    public function palette(Request $request)
    {
        $request->user()->forceFill(Identity::look($request->all()))->save();
        return redirect()->route('account')->with('notice', 'Appearance saved. It applies when you next join.');
    }

    public function creator(Request $request)
    {
        $owned = DB::table('experiences')->where('owner_id', $request->user()->id);
        $games = (clone $owned)->orderByDesc('updated_at')->paginate(20);
        $options = $owned->orderBy('title')->get(['id', 'title']);
        return view('creator', compact('games', 'options'));
    }

    public function manage(Request $request, string $game)
    {
        $entry = $this->catalog->ownedGame($game, $request->user()->id);
        $places = DB::table('places')->where('experience_id', $game)->orderBy('title')->get();
        $versions = [];
        foreach ($places as $place) {
            $versions[$place->id] = DB::table('releases')->where('place_id', $place->id)->orderByDesc('number')->limit(12)->get();
        }
        return view('manage', compact('entry', 'places', 'versions'));
    }

    public function upload(Request $request)
    {
        $fields = $request->validate(['project' => 'required|file|max:1536', 'game' => 'nullable|string|size:26']);
        $file = $fields['project'];
        try {
            abort_unless(str_ends_with(strtolower($file->getClientOriginalName()), '.pot'), 422, 'Choose a binary .pot project.');
            $published = $this->catalog->publish($request->user()->id, $file->get(), targetGame: $fields['game'] ?? null);
        } catch (\Symfony\Component\HttpKernel\Exception\HttpExceptionInterface $e) {
            if ($e->getStatusCode() === 422) {
                throw ValidationException::withMessages(['project' => $e->getMessage()]);
            }
            throw $e;
        }
        return redirect()->route('manage', $published['experience'])->with('notice', 'Place version '.$published['version'].' published.');
    }

    public function settings(Request $request, string $game)
    {
        $fields = $request->validate(['start' => 'required|string|max:64', 'visibility' => 'required|in:private,public']);
        $this->catalog->settings($game, $request->user()->id, $fields['start'], $fields['visibility'] === 'public');
        return redirect()->route('manage', $game)->with('notice', 'Game settings saved.');
    }

    public function restore(Request $request, string $game, string $place, string $release)
    {
        $this->catalog->restore($game, $place, $release, $request->user()->id);
        return redirect()->route('manage', $game)->with('notice', 'Version restored for new sessions.');
    }
}
