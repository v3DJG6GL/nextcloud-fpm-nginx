#!/bin/sh
# Container entrypoint (PID 1). Runs as root.
#
# 1. Renders env-var-driven config overrides (PHP/FPM/nginx) so they're in
#    place before supervisord starts.
# 2. Execs supervisord, which starts:
#      - the upstream Nextcloud entrypoint (runs install/upgrade +
#        before-starting hooks, then execs php-fpm)
#      - nginx
set -eu

/usr/local/bin/render-overrides.sh

exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
