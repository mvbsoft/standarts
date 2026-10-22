<?php

declare(strict_types=1);

namespace App\Tests;

use App\Hello;
use PHPUnit\Framework\TestCase;

final class HelloTest extends TestCase
{
    public function testGreet(): void
    {
        self::assertSame('Hello, world!', Hello::greet('world'));
    }
}
