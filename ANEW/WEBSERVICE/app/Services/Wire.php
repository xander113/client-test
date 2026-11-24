<?php

declare(strict_types=1);

namespace App\Services;

use Illuminate\Http\Response;
use InvalidArgumentException;

final class Wire
{
    public const MIME = 'application/msgpack';
    public const LIMIT = 2_097_152;

    private int $offset = 0;

    private function __construct(private readonly string $bytes) {}

    public static function response(mixed $value, int $status = 200, array $headers = []): Response
    {
        return self::raw(self::encode($value), self::MIME, $status, $headers);
    }

    public static function raw(string $bytes, string $type = self::MIME, int $status = 200, array $headers = []): Response
    {
        return response($bytes, $status, ['Content-Type' => $type, 'Cache-Control' => 'no-store',
            'X-Content-Type-Options' => 'nosniff'] + $headers);
    }

    public static function input(string $bytes, int $limit = 4096): mixed
    {
        abort_if(strlen($bytes) > $limit, 413, 'Binary payload is too large.');
        try {
            return self::decode($bytes, $limit);
        } catch (InvalidArgumentException) {
            abort(400, 'Invalid MessagePack payload.');
        }
    }

    public static function decode(string $bytes, int $limit = self::LIMIT): mixed
    {
        if (strlen($bytes) > $limit) {
            throw new InvalidArgumentException('MessagePack packet exceeds its size limit.');
        }
        $r = new self($bytes);
        $value = $r->read(0);
        if ($r->offset !== strlen($bytes)) {
            throw new InvalidArgumentException('Unexpected trailing bytes.');
        }
        return $value;
    }

    private function take(int $count): string
    {
        if ($count < 0 || $count > strlen($this->bytes) - $this->offset) {
            throw new InvalidArgumentException('Truncated MessagePack value.');
        }
        $result = substr($this->bytes, $this->offset, $count);
        $this->offset += $count;
        return $result;
    }

    private function number(string $format, int $size): int|float
    {
        return unpack($format, $this->take($size))[1];
    }

    private function read(int $depth): mixed
    {
        if ($depth > 24) {
            throw new InvalidArgumentException('MessagePack nesting is too deep.');
        }
        $tag = ord($this->take(1));
        if ($tag <= 127) {
            return $tag;
        }
        if ($tag >= 224) {
            return $tag - 256;
        }
        if ($tag >= 160 && $tag <= 191) {
            return $this->take($tag - 160);
        }
        if ($tag >= 144 && $tag <= 159) {
            return $this->collection($tag - 144, $depth, false);
        }
        if ($tag >= 128 && $tag <= 143) {
            return $this->collection($tag - 128, $depth, true);
        }
        return match ($tag) {
            192 => null,
            194 => false,
            195 => true,
            196 => new Binary($this->take($this->number('C', 1))),
            197 => new Binary($this->take($this->number('n', 2))),
            198 => new Binary($this->take($this->number('N', 4))),
            202 => $this->number('G', 4),
            203 => $this->number('E', 8),
            204 => $this->number('C', 1),
            205 => $this->number('n', 2),
            206 => $this->number('N', 4),
            208 => $this->number('c', 1),
            209 => $this->signed($this->number('n', 2), 32768),
            210 => $this->signed($this->number('N', 4), 2147483648),
            217 => $this->take($this->number('C', 1)),
            218 => $this->take($this->number('n', 2)),
            219 => $this->take($this->number('N', 4)),
            220 => $this->collection($this->number('n', 2), $depth, false),
            221 => $this->collection($this->number('N', 4), $depth, false),
            222 => $this->collection($this->number('n', 2), $depth, true),
            223 => $this->collection($this->number('N', 4), $depth, true),
            default => throw new InvalidArgumentException('Unsupported MessagePack tag.'),
        };
    }

    private function signed(int $value, int $half): int
    {
        return $value >= $half ? $value - 2 * $half : $value;
    }

    private function collection(int $count, int $depth, bool $map): array
    {
        if ($count > 65536 || $count * ($map ? 2 : 1) > strlen($this->bytes) - $this->offset) {
            throw new InvalidArgumentException('Invalid collection length.');
        }
        $result = [];
        for ($i = 0; $i < $count; $i++) {
            if ($map) {
                $key = $this->read($depth + 1);
                if (! is_string($key) || array_key_exists($key, $result)) {
                    throw new InvalidArgumentException('Invalid or repeated map key.');
                }
                $result[$key] = $this->read($depth + 1);
            } else {
                $result[] = $this->read($depth + 1);
            }
        }
        return $result;
    }

    public static function encode(mixed $value, int $depth = 0): string
    {
        if ($depth > 24) {
            throw new InvalidArgumentException('MessagePack nesting is too deep.');
        }
        if ($value === null || is_bool($value)) {
            return chr($value === null ? 192 : ($value ? 195 : 194));
        }
        if (is_int($value)) {
            return match (true) {
                $value >= -32 && $value <= 127 => chr($value & 255),
                $value >= 0 && $value <= 255 => pack('CC', 204, $value),
                $value >= 0 && $value <= 65535 => pack('Cn', 205, $value),
                $value >= 0 && $value <= 4294967295 => pack('CN', 206, $value),
                $value >= -2147483648 && $value < 0 => pack('CN', 210, $value),
                default => pack('CE', 203, (float) $value),
            };
        }
        if (is_float($value)) {
            return pack('CE', 203, $value);
        }
        if (is_string($value) || $value instanceof Binary) {
            $binary = $value instanceof Binary;
            $bytes = $binary ? $value->data : $value;
            $n = strlen($bytes);
            if ($n > self::LIMIT) {
                throw new InvalidArgumentException('Binary field is too large.');
            }
            return match (true) {
                ! $binary && $n < 32 => chr(160 + $n),
                $n <= 255 => pack('CC', $binary ? 196 : 217, $n),
                $n <= 65535 => pack('Cn', $binary ? 197 : 218, $n),
                default => pack('CN', $binary ? 198 : 219, $n),
            }.$bytes;
        }
        if (is_array($value)) {
            $list = array_is_list($value);
            $n = count($value);
            $result = match (true) {
                $n < 16 => chr(($list ? 144 : 128) + $n),
                $n <= 65535 => pack('Cn', $list ? 220 : 222, $n),
                default => pack('CN', $list ? 221 : 223, $n),
            };
            foreach ($value as $key => $item) {
                if (! $list) {
                    $result .= self::encode((string) $key, $depth + 1);
                }
                $result .= self::encode($item, $depth + 1);
            }
            return $result;
        }

        throw new InvalidArgumentException('Unsupported MessagePack value.');
    }
}
