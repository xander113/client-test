<?php

declare(strict_types=1);

namespace App\Models;

use Illuminate\Foundation\Auth\User as Authenticatable;

final class User extends Authenticatable
{
    protected $fillable = ['public_id', 'name', 'email', 'password'];
    protected $hidden = ['password', 'remember_token'];
    protected $casts = ['password' => 'hashed', 'balance' => 'integer'];

    public function look(): array
    {
        return ['skin' => $this->skin, 'shirt' => $this->shirt, 'pants' => $this->pants, 'visor' => $this->visor];
    }

    public function profile(): array
    {
        return ['id' => $this->public_id, 'displayName' => $this->name, 'look' => $this->look(), 'balance' => $this->balance];
    }
}
