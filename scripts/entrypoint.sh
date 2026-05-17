#!/bin/sh
# Container entrypoint (PID 1). Runs as root.
#
# 1. Optional: reassign www-data uid/gid from PUID/PGID, chown /var/www
#    when the uid actually changes. UMASK applied to all child processes.
# 2. Render env-var-driven config overrides (PHP/FPM/nginx).
# 3. Exec supervisord, which starts:
#      - the upstream Nextcloud entrypoint (runs install/upgrade +
#        before-starting hooks, then execs php-fpm)
#      - nginx
#      - optional: notify_push (NOTIFY_PUSH_ENABLE=true)
#      - optional: cron     (NEXTCLOUD_CRON_ENABLE=true)
set -eu

# --- Reassign www-data uid/gid ----------------------------------------------
# Apply only if either PUID or PGID is set.
#
# Two-stage gating to avoid the (potentially hours-long) `chown -R /var/www`
# on every container recreation:
#
# 1. groupmod/usermod always run when the in-container www-data uid/gid
#    don't match the target. That's cheap (one line in /etc/passwd) and
#    they MUST run every fresh-container boot because /etc/passwd lives
#    in the container layer, not in any bind mount, so it resets to the
#    upstream image's default (33:33) on every `docker compose up -d`
#    after an image pull.
#
# 2. The recursive chown only runs when files on disk are ACTUALLY owned
#    differently from the target. We probe a single persistent file
#    (`/var/www/html/version.php`) instead of stat-walking the whole
#    tree. On a multi-TB HDD data volume, the difference is "instant"
#    vs "hours".
if [ -n "${PUID:-}" ] || [ -n "${PGID:-}" ]; then
    target_uid="${PUID:-$(id -u www-data)}"
    target_gid="${PGID:-$(id -g www-data)}"
    current_uid="$(id -u www-data)"
    current_gid="$(id -g www-data)"

    if [ "$target_gid" != "$current_gid" ]; then
        echo "entrypoint: groupmod www-data $current_gid -> $target_gid" >&2
        groupmod -o -g "$target_gid" www-data
    fi
    if [ "$target_uid" != "$current_uid" ]; then
        echo "entrypoint: usermod www-data $current_uid -> $target_uid" >&2
        usermod -o -u "$target_uid" www-data
    fi

    # --- Dual-sentinel-gated recursive chowns -----------------------------
    # Two distinct on-disk trees may need chowning:
    #   - /var/www         (the webroot — image-layer files + bind-mounted
    #                       webroot + nested data if datadir is the default
    #                       /var/www/html/data on the same mount)
    #   - $data_dir        (NC's actual data dir — could be on the SAME
    #                       bind mount as the webroot, or a SEPARATE one
    #                       even when nested under /var/www/html/)
    #
    # We check BOTH sentinels independently — bind mounts can be on
    # different filesystems even when paths look nested. Example: webroot
    # on SSD bind-mounted to /var/www/html, data dir on HDD bind-mounted
    # to /var/www/html/data. The /var/www chown traverses both, but if
    # an earlier chown was interrupted or one bind mount was rw and the
    # other was ro, the two trees can drift. version.php (on the SSD)
    # would say "everything OK" while .ncdata (on the HDD) is still
    # owned by the old uid. Hence: check both, chown what's wrong.
    #
    # Skip a chown ONLY when its sentinel BOTH exists AND already matches
    # the target. Sentinel files:
    #   - /var/www/html/version.php   — written by upstream rsync, always
    #                                   present on a healthy NC install
    #   - $data_dir/.ncdata           — written by NC on install, used by
    #                                   NC itself to validate the data dir
    #                                   on every boot (`.ocdata` legacy
    #                                   from ownCloud era is the fallback)

    # 1. Determine the data dir. Env var wins (fresh-install hint, used
    #    by the upstream entrypoint before config.php exists). Otherwise
    #    read from config.php via `php -r` (robust against config.php's
    #    array-syntax variations; the upstream image has the PHP CLI).
    data_dir=""
    if [ -n "${NEXTCLOUD_DATA_DIR:-}" ]; then
        data_dir="$NEXTCLOUD_DATA_DIR"
    elif [ -f /var/www/html/config/config.php ]; then
        data_dir=$(php -r '
            $CONFIG = [];
            @include "/var/www/html/config/config.php";
            echo $CONFIG["datadirectory"] ?? "";
        ' 2>/dev/null) || data_dir=""
    fi

    # 2. Check the /var/www sentinel.
    www_sentinel=/var/www/html/version.php
    www_needs_chown=1
    if [ -f "$www_sentinel" ] \
       && [ "$(stat -c '%u' "$www_sentinel")" = "$target_uid" ] \
       && [ "$(stat -c '%g' "$www_sentinel")" = "$target_gid" ]; then
        www_needs_chown=0
    fi

    # 3. Check the data-dir sentinel (always — even when datadir is the
    #    default /var/www/html/data, because it could still be on a
    #    different bind mount than the webroot).
    data_sentinel=""
    if [ -n "$data_dir" ]; then
        if [ -f "$data_dir/.ncdata" ]; then
            data_sentinel="$data_dir/.ncdata"
        elif [ -f "$data_dir/.ocdata" ]; then
            data_sentinel="$data_dir/.ocdata"
        fi
    fi
    data_needs_chown=0   # default: no separate data chown
    if [ -n "$data_dir" ] && [ -d "$data_dir" ]; then
        if [ -z "$data_sentinel" ] \
           || [ "$(stat -c '%u' "$data_sentinel")" != "$target_uid" ] \
           || [ "$(stat -c '%g' "$data_sentinel")" != "$target_gid" ]; then
            data_needs_chown=1
        fi
    fi

    # 4. Run the chowns.
    #
    # The KEY optimisation: if `data_dir` is nested under /var/www but its
    # sentinel says ownership is already correct, we PRUNE it from the
    # /var/www walk. Otherwise a multi-TB data subtree gets stat-walked
    # unnecessarily on every migration first-boot where version.php is
    # missing (e.g. after the LSIO-flatten step). With prune, the walk
    # touches only the webroot/code (small, fast) — the data subtree is
    # left alone since we already trust .ncdata.
    if [ "$www_needs_chown" = "1" ]; then
        if [ -f "$www_sentinel" ]; then
            www_reason="$www_sentinel was $(stat -c '%u:%g' "$www_sentinel"), target ${target_uid}:${target_gid}"
        else
            www_reason="fresh webroot — no $www_sentinel yet"
        fi

        # Decide whether to prune data_dir from the walk.
        prune_data=0
        case "$data_dir" in
            /var/www/*)
                # data_dir is nested under /var/www. Prune it ONLY when
                # its sentinel proved ownership is already correct
                # (data_needs_chown=0). If data also needs chowning, the
                # plain `chown -R /var/www` walks it transitively and we
                # save ourselves a second pass.
                if [ "$data_needs_chown" = "0" ] && [ -d "$data_dir" ]; then
                    prune_data=1
                fi
                ;;
        esac

        if [ "$prune_data" = "1" ]; then
            echo "entrypoint: chown -R ${target_uid}:${target_gid} /var/www [pruning $data_dir, .ncdata already $(stat -c '%u:%g' "$data_sentinel")] ($www_reason)" >&2
            find /var/www -path "$data_dir" -prune -o \
                -exec chown -h "${target_uid}:${target_gid}" {} +
        else
            echo "entrypoint: chown -R ${target_uid}:${target_gid} /var/www ($www_reason; may take a while)" >&2
            chown -R "${target_uid}:${target_gid}" /var/www
        fi
    fi

    if [ "$data_needs_chown" = "1" ]; then
        # Skip if the /var/www chown above already covered this path
        # (it didn't prune data_dir because data_needs_chown was 1).
        case "$data_dir" in
            /var/www/*)
                if [ "$www_needs_chown" = "1" ]; then
                    : # already chowned by /var/www walk (no prune happened)
                else
                    # /var/www was OK but data dir drifted (different
                    # bind mount under /var/www/html/data) — chown only it.
                    if [ -n "$data_sentinel" ]; then
                        reason="$data_sentinel was $(stat -c '%u:%g' "$data_sentinel"), target ${target_uid}:${target_gid} (separate bind mount?)"
                    else
                        reason="no .ncdata/.ocdata in $data_dir yet"
                    fi
                    echo "entrypoint: chown -R ${target_uid}:${target_gid} $data_dir ($reason; may take a while on large data)" >&2
                    chown -R "${target_uid}:${target_gid}" "$data_dir"
                fi
                ;;
            *)
                # External data dir — never covered by /var/www chown.
                if [ -n "$data_sentinel" ]; then
                    reason="$data_sentinel was $(stat -c '%u:%g' "$data_sentinel"), target ${target_uid}:${target_gid}"
                else
                    reason="no .ncdata/.ocdata sentinel in $data_dir yet (fresh data dir, or pre-NC-init)"
                fi
                echo "entrypoint: chown -R ${target_uid}:${target_gid} $data_dir ($reason; may take a while on large data)" >&2
                chown -R "${target_uid}:${target_gid}" "$data_dir"
                ;;
        esac
    fi
fi

# --- UMASK -------------------------------------------------------------------
# Propagated to supervisord and all its children (php-fpm, nginx, etc.).
if [ -n "${UMASK:-}" ]; then
    umask "$UMASK"
fi

# --- Render env-var-driven config overrides ---------------------------------
/usr/local/bin/render-overrides.sh

# --- Hand off to supervisord ------------------------------------------------
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
