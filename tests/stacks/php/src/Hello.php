<?php

declare(strict_types=1);

namespace App;

final class Hello
{
    public static function greet(string $name): string
    {
        return "Hello, {$name}!";
    }
}
