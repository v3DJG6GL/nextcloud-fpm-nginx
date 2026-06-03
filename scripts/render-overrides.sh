#!/bin/sh
# Render env-var-driven config overrides. Runs as root (PID 1 -> CMD) BEFORE
# supervisord starts, so we can write to /usr/local/etc/. Generates:
#   /usr/local/etc/php/conf.d/zz-env-overrides.ini  (PHP_*)
#   /usr/local/etc/php-fpm.d/zz-env.conf            (FPM_*)
#   /etc/nginx/snippets/nc-hsts.conf                (NGINX_HSTS)
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
hsts_snippet=/etc/nginx/snippets/nc-hsts.conf

: > "$php_ini"
: > "$fpm_conf"
# Always (re)create the HSTS snippet — nginx.conf `include`s it by literal path
# in two scopes, and a missing include fails `nginx -t`. Empty unless NGINX_HSTS
# is set; truncating each boot also clears a stale value from a previous start.
: > "$hsts_snippet"

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

# A literal newline, for the metacharacter check below.
nl='
'

# prepare_val KEY VAR — echoes a safe value for KEY, or nothing (and returns 1)
# when the override should be skipped. Skips empty/whitespace/quotes-only values,
# and values carrying an INI metacharacter — a `;` (starts a comment, truncating
# the directive), a newline (would inject a second line), or a stray `"`/`'`.
# clean_val only strips a *matched* surrounding pair, so an unbalanced lone quote
# (e.g. FPM_SLOWLOG='"') survives the trim and would emit an unterminated quoted
# value — php-fpm's pool parser rejects that with a syntax error and refuses to
# start, the exact crash class clean_val exists to prevent. No managed PHP_*/FPM_*
# value (timezone, opcache/pm numerics+enums, slowlog path, timeouts) legitimately
# contains a quote. Shared by the PHP-ini and FPM-pool emitters below.
prepare_val() {
    key=$1; var=$2
    val=$(clean_val "$var")
    if [ -z "$val" ]; then
        eval "orig=\${$var-__UNSET__}"
        if [ "$orig" != "__UNSET__" ] && [ -n "$orig" ]; then
            echo "render-overrides: skipping ${key} — \$${var} is empty/whitespace/quotes-only after trim" >&2
        fi
        return 1
    fi
    case "$val" in
        *';'* | *'"'* | *"'"* | *"$nl"*)
            echo "render-overrides: skipping ${key} — \$${var} contains an INI metacharacter (';', quote, or newline)" >&2
            return 1
            ;;
    esac
    printf '%s' "$val"
}

emit_ini() {
    file=$1; key=$2; var=$3
    v=$(prepare_val "$key" "$var") || return 0
    # printf, not echo: dash's `echo` expands backslash escapes (\n, \t, …),
    # which would re-inject the second directive line that prepare_val's
    # newline reject exists to prevent (and corrupt any value with a literal
    # backslash). printf '%s' emits the sanitized value verbatim.
    printf '%s=%s\n' "$key" "$v" >> "$file"
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
    v=$(prepare_val "$key" "$var") || return 0
    if [ "$fpm_header" -eq 0 ]; then
        echo "[www]" >> "$fpm_conf"
        fpm_header=1
    fi
    # printf, not echo — see emit_ini: dash's echo would expand \n/\t in $v.
    printf '%s = %s\n' "$key" "$v" >> "$fpm_conf"
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
# Reject three characters that never legitimately appear in a server_name (names
# are space-separated, so none is needed):
#   - a newline terminates the sed s||| command early ("unterminated `s'
#     command"), aborting the sed; under `set -e` that kills the entrypoint
#     before nginx starts. The replacement-escape below only handles \ & | —
#     sed can't escape a literal newline in the replacement.
#   - a ';' is nginx's statement terminator. The escape doesn't touch it, so a
#     value like `example.com; return 444` is written verbatim as
#     `server_name example.com; return 444;`, silently INJECTING an extra
#     directive (or breaking `nginx -t` and aborting boot).
#   - a '#' begins an nginx line comment that swallows the appended ';'
#     terminator, so a value like `example.com #` is written as
#     `server_name example.com #;` — the ';' is commented out, leaving the
#     directive UNTERMINATED. nginx then folds the next physical directive
#     (here `root /var/www/html;`) into the server_name arguments, yielding
#     `server_name example.com root /var/www/html;` — VALID config that passes
#     `nginx -t` but silently CONSUMES the `root` directive, so the site serves
#     from nginx's compiled-in default root (404s everywhere).
# Any case falls back to the default (mirrors the HSTS reject further down).
case "$server_name" in
    *"$nl"* | *';'* | *'#'*)
        echo "render-overrides: ignoring NGINX_SERVER_NAME — value contains a newline, ';' or '#' that would break or inject into the nginx directive" >&2
        server_name=_
        ;;
esac
# Escape characters special to sed's replacement (\ and &) plus the | delimiter
# so a server name containing them can't garble or abort the s||| command —
# an aborted sed would, under `set -e`, kill the entrypoint before nginx starts.
server_name_escaped=$(printf '%s' "$server_name" | sed -e 's/[\\&|]/\\&/g')
sed -i "s|^\(\s*\)server_name .*;|\1server_name ${server_name_escaped};|" /etc/nginx/nginx.conf

# HSTS gets its own sanitization rather than prepare_val: an HSTS value
# legitimately contains ';' (e.g. `max-age=…; includeSubDomains; preload`), so
# the INI metachar reject doesn't apply. We still trim/strip quotes via
# clean_val and reject four characters, none of which appear in a valid HSTS
# value (the grammar is `max-age=<digits>[; includeSubDomains][; preload]`):
#   - a literal '"' or newline would close the nginx string early and break
#     `nginx -t` (aborting the entrypoint).
#   - a '$' is interpolated by nginx: `add_header` evaluates `$var` references
#     in its value. A defined name (e.g. `$host`, `$request_id`) is silently
#     substituted at runtime — corrupting the header into an invalid HSTS value
#     that browsers ignore (a silent security downgrade) — and an undefined one
#     fails `nginx -t` ("unknown variable"), aborting boot.
#   - a '\' is nginx's escape character inside a quoted string. The value is
#     emitted raw into a "..." literal (unlike server_name, which is sed-escaped
#     so its backslashes are doubled), so a trailing '\' escapes the closing
#     quote: `"max-age=1\"` runs the string on through `always;` and the next
#     directive, yielding "unexpected end of file" — `nginx -t` fails and boot
#     aborts under `set -e`. (Verified: `nginx -t` rejects the run-on string.)
hsts_val=$(clean_val NGINX_HSTS)
case "$hsts_val" in
    *'"'* | *'$'* | *'\'* | *"$nl"*)
        echo "render-overrides: skipping NGINX_HSTS — value contains a '\"', '\$', '\\' or newline that would break or inject into the nginx directive" >&2
        ;;
    ?*)
        printf 'add_header Strict-Transport-Security "%s" always;\n' "$hsts_val" > "$hsts_snippet"
        ;;
esac

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
        # Best-effort double-fire guard: the compose `cron` sidecar runs in a
        # separate container we can't inspect from here, so this is a warning,
        # not an enforced lock. If both run, background jobs fire twice.
        echo "render-overrides: in-container cron ENABLED — ensure the compose 'cron' sidecar is NOT also running (set NEXTCLOUD_CRON_ENABLE=false if you use the sidecar), or background jobs fire twice" >&2
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
