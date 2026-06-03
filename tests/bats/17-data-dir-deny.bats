#!/usr/bin/env bats
# 17-data-dir-deny.bats — admin warning: "data folder and your files are
# probably accessible from the Internet" if nginx serves /data. nginx.conf
# returns 404 for these paths. lsio#436.

load '../helpers/lib.bash'
load '../helpers/compose.bash'
load '../helpers/http.bash'

@test "/data is blocked" {
    run nc_status_code /data
    assert_status_zero "$status"
    assert_eq "$output" "404"
}

@test "/config is blocked" {
    run nc_status_code /config
    assert_status_zero "$status"
    assert_eq "$output" "404"
}

@test "/lib is blocked" {
    run nc_status_code /lib
    assert_status_zero "$status"
    assert_eq "$output" "404"
}

@test "/3rdparty is blocked" {
    run nc_status_code /3rdparty
    assert_status_zero "$status"
    assert_eq "$output" "404"
}

@test "/templates is blocked" {
    run nc_status_code /templates
    assert_status_zero "$status"
    assert_eq "$output" "404"
}

@test "/db_structure.xml (occ etc) blocked" {
    run nc_status_code /db_structure.xml
    assert_status_zero "$status"
    assert_eq "$output" "404"
    run nc_status_code /occ
    assert_status_zero "$status"
    assert_eq "$output" "404"
    run nc_status_code /console.php
    assert_status_zero "$status"
    assert_eq "$output" "404"
}
