<?php

declare(strict_types=1);

$finder = (new PhpCsFixer\Finder())->in([__DIR__ . '/src', __DIR__ . '/tests'])->append([__DIR__ . '/hello.php']);

return (new PhpCsFixer\Config())
    ->setRules(['@PER-CS' => true])
    ->setCacheFile(sys_get_temp_dir() . '/php-cs-fixer.cache')
    ->setFinder($finder);
