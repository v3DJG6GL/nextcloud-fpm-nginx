<?php
// Test fixture bind-mounted at /var/www/html/config/redis.config.php.
// Diverges from the upstream-seeded version — entrypoint should log a
// "differs" warning at start. tests/bats/28-config-drift.bats grep's for it.
$CONFIG = [
    'redis' => [
        'host'    => 'redis',
        'port'    => 6379,
        'timeout' => 999.0,   // ← deliberately divergent
    ],
];
