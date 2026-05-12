# HTTP helpers. Most tests hit the nc service via curl through the host
# port mapping. Sourced from bats files.

# nc_curl <method> <path> [extra-curl-args...]
# Example: nc_curl GET /status.php
#          nc_curl HEAD / -H 'X-Forwarded-Proto: https'
nc_curl() {
    local method="$1" path="$2"; shift 2
    local base
    base=$(nc_host_url)
    curl -fsS -X "$method" -o /dev/stdout -w '\nHTTP:%{http_code}\n' \
        "$@" "${base}${path}"
}

# nc_headers <path> [extra-curl-args...]
# Returns the response headers (lowercased keys).
nc_headers() {
    local path="$1"; shift
    local base
    base=$(nc_host_url)
    curl -sSI "$@" "${base}${path}"
}

# nc_status_code <path> [extra-curl-args...]
nc_status_code() {
    local path="$1"; shift
    local base
    base=$(nc_host_url)
    curl -s -o /dev/null -w '%{http_code}' "$@" "${base}${path}"
}

# nc_status_php
# Returns the parsed JSON from /status.php. Use with jq from caller.
nc_status_php() {
    local base
    base=$(nc_host_url)
    curl -fsS "${base}/status.php"
}

# header_value <headers-blob> <header-name>
# Extracts the value of one header from a raw response-headers dump.
header_value() {
    printf '%s' "$1" | awk -v k="${2,,}" '
        BEGIN { IGNORECASE=1 }
        tolower($1) == k":" {
            sub(/^[^ ]+ +/, "")
            sub(/\r$/, "")
            print
            exit
        }
    '
}

# assert_header_present <path> <header-name> [extra-curl-args...]
assert_header_present() {
    local path="$1" name="$2"; shift 2
    local hdrs
    hdrs=$(nc_headers "$path" "$@")
    if ! printf '%s' "$hdrs" | grep -qiE "^${name}: "; then
        log "expected header '$name' in response to GET $path"
        log "raw headers:"
        printf '%s\n' "$hdrs" | sed 's/^/#   /' >&3
        return 1
    fi
}

# assert_header_absent <path> <header-name> [extra-curl-args...]
assert_header_absent() {
    local path="$1" name="$2"; shift 2
    local hdrs
    hdrs=$(nc_headers "$path" "$@")
    if printf '%s' "$hdrs" | grep -qiE "^${name}: "; then
        log "expected header '$name' to NOT be present, got it"
        return 1
    fi
}
