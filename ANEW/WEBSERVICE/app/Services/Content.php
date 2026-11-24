<?php

declare(strict_types=1);

namespace App\Services;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Http;
use RuntimeException;

final class Content
{
    public function validate(string $bytes): array
    {
        abort_if(strlen($bytes) > config('pot.max_project'), 413, 'The project is too large.');
        $canonical = $this->request('/v3/validate', $bytes, Wire::MIME, (int) config('pot.max_project'));
        $map = Wire::decode($canonical);
        abort_unless(is_array($map) && Identity::projectId($map['id'] ?? null)
            && is_string($map['name'] ?? null) && is_string($map['description'] ?? null), 502, 'Invalid project metadata from PotRenderService.');

        return [$map, $canonical];
    }

    public function project(string $digest): string
    {
        $data = @file_get_contents($this->path($digest, 'potbin'), false, null, 0, Wire::LIMIT);
        abort_unless(is_string($data) && hash_equals($digest, hash('sha256', $data)), 503, 'The published project is unavailable.');
        return $data;
    }

    public function store(string $bytes): string
    {
        $digest = hash('sha256', $bytes);
        $file = $this->path($digest, 'potbin');
        if (! is_file($file)) {
            $this->write($file, $bytes);
        }
        return $digest;
    }

    public function thumbnail(string $digest): string
    {
        $file = $this->path($digest, 'png');
        if (is_file($file)) {
            $image = @file_get_contents($file, false, null, 0, 1024 * 1024);
            if (is_string($image) && str_starts_with($image, "\x89PNG\r\n\x1a\n")) {
                return $image;
            }
        }
        $image = $this->request('/v3/render', $this->project($digest), 'image/png', 1024 * 1024);
        abort_unless(str_starts_with($image, "\x89PNG\r\n\x1a\n"), 502, 'The thumbnail response is invalid.');
        $this->write($file, $image);
        return $image;
    }

    private function path(string $digest, string $format): string
    {
        if (! preg_match('/\A[0-9a-f]{64}\z/', $digest)) {
            throw new RuntimeException('Invalid content address.');
        }
        return rtrim((string) config('pot.project_path'), '/').'/'.$digest.'.'.$format;
    }

    private function write(string $path, string $data): void
    {
        $root = dirname($path);
        if (! is_dir($root) && ! @mkdir($root, 0770, true) && ! is_dir($root)) {
            throw new RuntimeException('Could not create the project directory.');
        }
        $temp = $root.'/.upload-'.bin2hex(random_bytes(12));
        try {
            if (@file_put_contents($temp, $data, LOCK_EX) !== strlen($data) || ! @rename($temp, $path)) {
                throw new RuntimeException('Could not store published content.');
            }
        } finally {
            if (is_file($temp)) {
                @unlink($temp);
            }
        }
    }

    private function request(string $path, string $bytes, string $expected, int $max): string
    {
        try {
            $reply = Http::withOptions(['allow_redirects' => false, 'proxy' => ''])->connectTimeout(2)->timeout(7)
                ->withToken((string) config('pot.content_token'))->withBody($bytes, Wire::MIME)
                ->post(rtrim((string) config('pot.content_url'), '/').$path);
        } catch (ConnectionException) {
            abort(503, 'PotRenderService is unavailable.');
        }
        if ($reply->status() === 400 || $reply->status() === 422) {
            $message = 'The project did not pass runtime validation.';
            try {
                $error = Wire::decode($reply->body(), 4096);
                if (is_string($error['message'] ?? null)) {
                    $message = $error['message'];
                }
            } catch (\InvalidArgumentException) {}
            abort(422, $message);
        }
        abort_unless($reply->successful(), 503, 'PotRenderService is unavailable.');
        $body = $reply->body();
        abort_unless(explode(';', $reply->header('Content-Type'))[0] === $expected && strlen($body) <= $max,
            502, 'Invalid response from PotRenderService.');
        return $body;
    }
}
