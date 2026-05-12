<?php
// Test fixture bind-mounted at /var/www/html/config/zz-test.config.php.
// Used by tests/bats/22-bind-mount-overrides.bats to verify that
// drop-in *.config.php fragments are merged by Nextcloud's config loader.
$CONFIG = [
    'default_phone_region' => 'CH',
    'loglevel' => 2,
];
