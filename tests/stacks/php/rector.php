<?php

declare(strict_types=1);

use Rector\Config\RectorConfig;

return RectorConfig::configure()
    ->withPaths([__DIR__ . '/src', __DIR__ . '/tests', __DIR__ . '/hello.php'])
    ->withCache('/tmp/rector')
    ->withPhpSets(php82: true);
