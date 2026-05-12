#!/bin/sh
# Render env-var-driven config overrides. Runs as root (PID 1 -> CMD) BEFORE
# supervisord starts, so we can write to /usr/local/etc/. Generates:
#   /usr/local/etc/php/conf.d/zz-env-overrides.ini  (PHP_*)
#   /usr/local/etc/php-fpm.d/zz-env.conf            (FPM_*)
#   /etc/nginx/conf.d/90-env-overrides.conf         (NGINX_HSTS)
# The `zz-` prefix on the PHP ini ensures it loads AFTER the upstream image's
# `opcache-recommended.ini` and `nextcloud.ini` (lexical order).
# Plus in-place patches `server_name` in /etc/nginx/nginx.conf from
# NGINX_SERVER_NAME.
#
# All output files start empty so unsetting an env var on the next container
# start cleanly removes that override. Complements upstream's baked-in
# PHP_MEMORY_LIMIT / PHP_UPLOAD_LIMIT / PHP_OPCACHE_MEMORY_CONSUMPTION
# (wired via PHP's native ${VAR} ini-substitution).
#
# Nextcloud-level config (cache_path, tempdirectory, loglevel, etc.) is not
# wrapped here. Users set those via standard Nextcloud config: a bind-mounted
# *.config.php fragment in /var/www/html/config/, or `occ config:system:set`.

set -eu

php_ini=/usr/local/etc/php/conf.d/zz-env-overrides.ini
fpm_conf=/usr/local/etc/php-fpm.d/zz-env.conf
nginx_conf=/etc/nginx/conf.d/90-env-overrides.conf

: > "$php_ini"
: > "$fpm_conf"
: > "$nginx_conf"

# --- PHP ini overrides --------------------------------------------------------

[ -n "${PHP_TIMEZONE:-}" ] && \
    echo "date.timezone=${PHP_TIMEZONE}" >> "$php_ini"

[ -n "${PHP_OPCACHE_ENABLE:-}" ] && \
    echo "opcache.enable=${PHP_OPCACHE_ENABLE}" >> "$php_ini"
[ -n "${PHP_OPCACHE_ENABLE_CLI:-}" ] && \
    echo "opcache.enable_cli=${PHP_OPCACHE_ENABLE_CLI}" >> "$php_ini"
[ -n "${PHP_OPCACHE_INTERNED_STRINGS_BUFFER:-}" ] && \
    echo "opcache.interned_strings_buffer=${PHP_OPCACHE_INTERNED_STRINGS_BUFFER}" >> "$php_ini"
[ -n "${PHP_OPCACHE_MAX_ACCELERATED_FILES:-}" ] && \
    echo "opcache.max_accelerated_files=${PHP_OPCACHE_MAX_ACCELERATED_FILES}" >> "$php_ini"
[ -n "${PHP_OPCACHE_REVALIDATE_FREQ:-}" ] && \
    echo "opcache.revalidate_freq=${PHP_OPCACHE_REVALIDATE_FREQ}" >> "$php_ini"
[ -n "${PHP_OPCACHE_SAVE_COMMENTS:-}" ] && \
    echo "opcache.save_comments=${PHP_OPCACHE_SAVE_COMMENTS}" >> "$php_ini"
[ -n "${PHP_OPCACHE_JIT:-}" ] && \
    echo "opcache.jit=${PHP_OPCACHE_JIT}" >> "$php_ini"
[ -n "${PHP_OPCACHE_JIT_BUFFER_SIZE:-}" ] && \
    echo "opcache.jit_buffer_size=${PHP_OPCACHE_JIT_BUFFER_SIZE}" >> "$php_ini"

# --- FPM pool overrides -------------------------------------------------------

fpm_header=0
add_fpm() {
    if [ "$fpm_header" -eq 0 ]; then
        echo "[www]" >> "$fpm_conf"
        fpm_header=1
    fi
    echo "$1" >> "$fpm_conf"
}

[ -n "${FPM_PM:-}" ]                        && add_fpm "pm = ${FPM_PM}"
[ -n "${FPM_PM_MAX_CHILDREN:-}" ]           && add_fpm "pm.max_children = ${FPM_PM_MAX_CHILDREN}"
[ -n "${FPM_PM_START_SERVERS:-}" ]          && add_fpm "pm.start_servers = ${FPM_PM_START_SERVERS}"
[ -n "${FPM_PM_MIN_SPARE_SERVERS:-}" ]      && add_fpm "pm.min_spare_servers = ${FPM_PM_MIN_SPARE_SERVERS}"
[ -n "${FPM_PM_MAX_SPARE_SERVERS:-}" ]      && add_fpm "pm.max_spare_servers = ${FPM_PM_MAX_SPARE_SERVERS}"
[ -n "${FPM_PM_MAX_REQUESTS:-}" ]           && add_fpm "pm.max_requests = ${FPM_PM_MAX_REQUESTS}"
[ -n "${FPM_REQUEST_TERMINATE_TIMEOUT:-}" ] && add_fpm "request_terminate_timeout = ${FPM_REQUEST_TERMINATE_TIMEOUT}"
[ -n "${FPM_REQUEST_SLOWLOG_TIMEOUT:-}" ]   && add_fpm "request_slowlog_timeout = ${FPM_REQUEST_SLOWLOG_TIMEOUT}"
[ -n "${FPM_SLOWLOG:-}" ]                   && add_fpm "slowlog = ${FPM_SLOWLOG}"

# --- Nginx overrides ---------------------------------------------------------

# server_name patched in place — nginx doesn't honor server_name redeclared
# from an include in the same server {} block.
server_name="${NGINX_SERVER_NAME:-_}"
sed -i "s|^\(\s*\)server_name .*;|\1server_name ${server_name};|" /etc/nginx/nginx.conf

if [ -n "${NGINX_HSTS:-}" ]; then
    cat > "$nginx_conf" <<EOF
add_header Strict-Transport-Security "${NGINX_HSTS}" always;
EOF
fi

# --- notify_push (optional) --------------------------------------------------

np_conf=/etc/supervisor/conf.d/notify-push.conf
case "${NOTIFY_PUSH_ENABLE:-false}" in
    true|1|yes|on)
        cat > "$np_conf" <<'EOF'
[program:notify-push]
command=/usr/local/bin/notify-push-wrapper.sh
user=www-data
autostart=true
autorestart=true
startretries=999
priority=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stopsignal=TERM
stopwaitsecs=10
EOF
        ;;
    *)
        rm -f "$np_conf"
        ;;
esac

exit 0
