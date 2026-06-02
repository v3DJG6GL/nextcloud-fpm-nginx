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

# clean_val NAME — echoes the env var's value with surrounding whitespace and
# one pair of surrounding single/double quotes stripped. Returns empty if the
# var is unset, empty, whitespace-only, or "" / ''. This guards the INI
# emitters below against compose oddities like  FOO=''  or  FOO="  "  which
# would otherwise produce `key = ''` / `key =   ` — both rejected by the
# PHP/FPM INI parser as "value is NULL for a ZEND_INI_PARSER_ENTRY", killing
# php-fpm before it can serve a single request.
clean_val() {
    eval "raw=\${$1-}"
    # trim leading/trailing whitespace
    raw=${raw#"${raw%%[![:space:]]*}"}
    raw=${raw%"${raw##*[![:space:]]}"}
    # strip one matched pair of surrounding quotes
    case "$raw" in
        \"*\") raw=${raw#\"}; raw=${raw%\"} ;;
        \'*\') raw=${raw#\'}; raw=${raw%\'} ;;
    esac
    # re-trim after quote stripping (handles `" foo "`)
    raw=${raw#"${raw%%[![:space:]]*}"}
    raw=${raw%"${raw##*[![:space:]]}"}
    printf '%s' "$raw"
}

emit_ini() {
    file=$1; key=$2; var=$3
    val=$(clean_val "$var")
    if [ -z "$val" ]; then
        eval "orig=\${$var-__UNSET__}"
        if [ "$orig" != "__UNSET__" ] && [ -n "$orig" ]; then
            echo "render-overrides: skipping ${key} — \$${var} is empty/whitespace/quotes-only after trim" >&2
        fi
        return 0
    fi
    echo "${key}=${val}" >> "$file"
}

# --- PHP ini overrides --------------------------------------------------------

emit_ini "$php_ini" date.timezone                    PHP_TIMEZONE
emit_ini "$php_ini" opcache.enable                   PHP_OPCACHE_ENABLE
emit_ini "$php_ini" opcache.enable_cli               PHP_OPCACHE_ENABLE_CLI
emit_ini "$php_ini" opcache.interned_strings_buffer  PHP_OPCACHE_INTERNED_STRINGS_BUFFER
emit_ini "$php_ini" opcache.max_accelerated_files    PHP_OPCACHE_MAX_ACCELERATED_FILES
emit_ini "$php_ini" opcache.revalidate_freq          PHP_OPCACHE_REVALIDATE_FREQ
emit_ini "$php_ini" opcache.save_comments            PHP_OPCACHE_SAVE_COMMENTS
emit_ini "$php_ini" opcache.jit                      PHP_OPCACHE_JIT
emit_ini "$php_ini" opcache.jit_buffer_size          PHP_OPCACHE_JIT_BUFFER_SIZE

# --- FPM pool overrides -------------------------------------------------------

fpm_header=0
emit_fpm() {
    key=$1; var=$2
    val=$(clean_val "$var")
    if [ -z "$val" ]; then
        eval "orig=\${$var-__UNSET__}"
        if [ "$orig" != "__UNSET__" ] && [ -n "$orig" ]; then
            echo "render-overrides: skipping ${key} — \$${var} is empty/whitespace/quotes-only after trim" >&2
        fi
        return 0
    fi
    if [ "$fpm_header" -eq 0 ]; then
        echo "[www]" >> "$fpm_conf"
        fpm_header=1
    fi
    echo "${key} = ${val}" >> "$fpm_conf"
}

emit_fpm "pm"                          FPM_PM
emit_fpm "pm.max_children"             FPM_PM_MAX_CHILDREN
emit_fpm "pm.start_servers"            FPM_PM_START_SERVERS
emit_fpm "pm.min_spare_servers"        FPM_PM_MIN_SPARE_SERVERS
emit_fpm "pm.max_spare_servers"        FPM_PM_MAX_SPARE_SERVERS
emit_fpm "pm.max_requests"             FPM_PM_MAX_REQUESTS
emit_fpm "request_terminate_timeout"   FPM_REQUEST_TERMINATE_TIMEOUT
emit_fpm "request_slowlog_timeout"     FPM_REQUEST_SLOWLOG_TIMEOUT
emit_fpm "slowlog"                     FPM_SLOWLOG

# --- Nginx overrides ---------------------------------------------------------

# server_name patched in place — nginx doesn't honor server_name redeclared
# from an include in the same server {} block.
server_name="${NGINX_SERVER_NAME:-_}"
# Escape characters special to sed's replacement (\ and &) plus the | delimiter
# so a server name containing them can't garble or abort the s||| command —
# an aborted sed would, under `set -e`, kill the entrypoint before nginx starts.
server_name_escaped=$(printf '%s' "$server_name" | sed -e 's/[\\&|]/\\&/g')
sed -i "s|^\(\s*\)server_name .*;|\1server_name ${server_name_escaped};|" /etc/nginx/nginx.conf

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

# --- cron (optional) ---------------------------------------------------------
# Runs Nextcloud's background jobs every 5 min inside the same container.
# Alternative: a sidecar `cron` service in compose.yaml (commented in the
# example) that runs the same `/cron.sh`. The two are mutually exclusive —
# enabling both would just have cron fire twice.

cron_conf=/etc/supervisor/conf.d/cron.conf
case "${NEXTCLOUD_CRON_ENABLE:-false}" in
    true|1|yes|on)
        # Run as root because /cron.sh exec's `busybox crond -L /dev/stdout`,
        # which fails to reopen /dev/stdout under setuid(www-data) due to FD
        # owner mismatch. busybox crond reads /var/spool/cron/crontabs/www-data
        # and switches to www-data internally for each job — same effective
        # privilege drop, no permission error.
        cat > "$cron_conf" <<'EOF'
[program:cron]
command=/cron.sh
autostart=true
autorestart=true
priority=40
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stopsignal=TERM
stopwaitsecs=10
EOF
        ;;
    *)
        rm -f "$cron_conf"
        ;;
esac

exit 0
