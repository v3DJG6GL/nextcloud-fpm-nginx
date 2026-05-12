#!/usr/bin/env bats
# 31-large-upload.bats — client_max_body_size / fastcgi_buffers /
# fastcgi_request_buffering / fastcgi_read_timeout settings must match the
# upstream NC nginx reference and accept large bodies.

load '../helpers/lib.bash'
load '../helpers/compose.bash'

@test "client_max_body_size = 512M (matches upstream NC reference)" {
    run compose_exec grep -E '^[[:space:]]*client_max_body_size[[:space:]]+512M;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "fastcgi_buffers 64 4K (NC required to avoid response truncation)" {
    run compose_exec grep -E 'fastcgi_buffers 64 4K;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "fastcgi_request_buffering on (NC PHP-FPM requires it)" {
    run compose_exec grep -E 'fastcgi_request_buffering on;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "fastcgi_max_temp_file_size = 0 (no spooling to disk during upload)" {
    run compose_exec grep -E 'fastcgi_max_temp_file_size 0;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "client_body_timeout 300s (matches upstream NC reference)" {
    run compose_exec grep -E '^[[:space:]]*client_body_timeout[[:space:]]+300s;' /etc/nginx/nginx.conf
    assert_status_zero "$status"
}

@test "PHP upload_max_filesize set by PHP_UPLOAD_LIMIT env (this scenario: 4G)" {
    # Our fixture sets PHP_UPLOAD_LIMIT=4G — verify
    run compose_exec php -r 'echo ini_get("upload_max_filesize");'
    assert_status_zero "$status"
    assert_eq "$output" "4G"
}
