#!/usr/bin/env bats
# 31-large-upload.bats — client_max_body_size / fastcgi_buffers /
# fastcgi_request_buffering / client_body_timeout settings tuned for
# large DAV chunked uploads (multi-GiB).
#
# We deliberately DIVERGE from the upstream NC nginx reference here:
#   - client_max_body_size 0      (vs reference 512M) — let NC's
#       files.chunked_upload.max_size cap chunk size; avoid a dual-knob
#       tuning trap where bumping the NC value silently 413s at nginx.
#   - client_body_timeout 3600s   (vs reference 300s) — slow residential
#       uplinks can take >5min for one 100+MiB chunk.
#   - fastcgi_request_buffering off (vs default on) — stream body
#       straight to FPM; with buffering on, the entire chunk lands in
#       /var/lib/nginx/body on the container writable layer (HDD on
#       hybrid setups) before FPM sees a byte, and with
#       files.chunked_upload.max_parallel_count = N, that's
#       N × chunk_size of temp files in flight — bottleneck.

load '../helpers/lib.bash'
load '../helpers/compose.bash'

@test "client_max_body_size = 0 (unlimited; NC enforces the actual chunk cap)" {
    run compose_exec grep -E '^[[:space:]]*client_max_body_size[[:space:]]+0;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "fastcgi_buffers 64 4K (NC required to avoid response truncation)" {
    run compose_exec grep -E 'fastcgi_buffers 64 4K;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "fastcgi_request_buffering off (stream upload bodies; no overlayfs spooling)" {
    run compose_exec grep -E 'fastcgi_request_buffering off;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

# php-src #12343 — when nginx closes the FastCGI socket mid-stream,
# PHP misreads ret==0 as clean EOF instead of truncation. With
# fastcgi_request_buffering off + the default 60s fastcgi_send_timeout,
# slow uplinks reliably trigger this on chunked DAV uploads. Long
# timeouts (1h, matching client_body_timeout) keep the socket open
# until the body actually arrives.
@test "fastcgi_read_timeout 3600s (php-src #12343 truncation guard)" {
    run compose_exec grep -E '^[[:space:]]*fastcgi_read_timeout[[:space:]]+3600s;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "fastcgi_send_timeout 3600s (php-src #12343 truncation guard)" {
    run compose_exec grep -E '^[[:space:]]*fastcgi_send_timeout[[:space:]]+3600s;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "fastcgi_max_temp_file_size = 0 (no spooling to disk during upload)" {
    run compose_exec grep -E 'fastcgi_max_temp_file_size 0;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "client_body_timeout 3600s (1h ceiling for slow residential uplinks)" {
    run compose_exec grep -E '^[[:space:]]*client_body_timeout[[:space:]]+3600s;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "PHP upload_max_filesize set by PHP_UPLOAD_LIMIT env (this scenario: 4G)" {
    # Our fixture sets PHP_UPLOAD_LIMIT=4G — verify
    run compose_exec php -r 'echo ini_get("upload_max_filesize");'
    assert_status_zero "$status"
    assert_eq "$output" "4G"
}
