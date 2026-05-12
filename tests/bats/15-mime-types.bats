#!/usr/bin/env bats
# 15-mime-types.bats — .mjs (ES modules) and .wasm files must be served with
# correct MIME types or the Files app breaks in Edge/Safari (server#42989).

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "nginx adds text/javascript for .mjs" {
    run compose_exec sh -c 'grep -E "text/javascript mjs" /etc/nginx/nginx.conf'
    assert_status_zero "$status"
}

@test "mime.types declares application/wasm" {
    run compose_exec grep -E '^[[:space:]]*application/wasm' /etc/nginx/mime.types
    assert_status_zero "$status"
}

@test "static assets get long Cache-Control via the immutable-asset block" {
    # Nextcloud's nginx reference applies Cache-Control: public, max-age=15778463
    # to css/js/svg/png/etc — verify the location ~ \.(css|js|svg|...) block routes
    # correctly. Use core/img/favicon.svg (always shipped by Nextcloud).
    run nc_headers /core/img/favicon.svg
    assert_status_zero "$status"
    assert_match "$output" 'Cache-Control: public, max-age=15778463'
}
