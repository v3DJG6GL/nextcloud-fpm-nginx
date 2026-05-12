<?php
// Synthetic version.php placed into a fresh /var/www/html volume so the
// entrypoint THINKS an old NC 31 install exists. Used by
// tests/bats/25-major-skip-refused.bats — when we then boot NC 33, the
// entrypoint must refuse because the major skip 31→33 is illegal.
$OC_Version = array(31, 0, 11, 1);
$OC_VersionString = '31.0.11';
$OC_Edition = '';
$OC_Channel = 'stable';
$OC_VersionCanBeUpgradedFrom = array (
  'nextcloud' =>
  array (
    '30.0' => true,
    '31.0' => true,
  ),
  'owncloud' =>
  array (
    '10.13' => true,
  ),
);
$OC_Build = '2024-12-12T00:00:00+00:00 abc1234';
$vendor = 'nextcloud';
