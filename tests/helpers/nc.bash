# Nextcloud-specific helpers wrapping `occ` and parsing /status.php.
# Sourced from bats files.

# nc_installed → exit 0 if status.php returns installed=true.
nc_installed() {
    nc_status_php 2>/dev/null | grep -q '"installed":true'
}

# nc_maintenance → exit 0 if status.php returns maintenance=true.
nc_maintenance() {
    nc_status_php 2>/dev/null | grep -q '"maintenance":true'
}

# nc_version → prints version from status.php (e.g., "33.0.3.2")
nc_version() {
    nc_status_php 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))'
}

# nc_versionstring → prints versionstring from status.php (e.g., "33.0.3")
nc_versionstring() {
    nc_status_php 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("versionstring",""))'
}

# nc_config_system_get <key> → echoes the value (occ output without trailing newline).
nc_config_system_get() {
    occ config:system:get "$1" 2>/dev/null | sed 's/[[:space:]]*$//'
}

# nc_app_enabled <app-id> → exit 0 if the app is enabled
nc_app_enabled() {
    occ app:list 2>/dev/null \
        | awk -v app="  - $1:" 'BEGIN{section=""} /^Enabled:/{section="enabled";next} /^Disabled:/{section="disabled";next} $0 ~ app{print section; exit}' \
        | grep -q '^enabled$'
}

# nc_supervisorctl_running <program> → exit 0 if RUNNING
nc_supervisorctl_running() {
    compose_exec supervisorctl status "$1" 2>/dev/null | grep -q RUNNING
}

# nc_supervisorctl_absent <program> → exit 0 if the program is NOT defined
nc_supervisorctl_absent() {
    ! compose_exec supervisorctl status "$1" >/dev/null 2>&1
}
