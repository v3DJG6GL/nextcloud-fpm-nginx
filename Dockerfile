ARG NC_VERSION=33.0.3
FROM nextcloud:${NC_VERSION}-fpm

USER root

# nginx & supervisor are pinned to exact Debian (Trixie) versions. Renovate
# tracks them via a custom datasource backed by Debian QA's madison service
# (qa.debian.org/madison.php, UDD-backed — see renovate.json `customDatasources`)
# so it opens a PR the moment Debian publishes a new revision in trixie,
# trixie-updates OR trixie-security. Two sources that look right are NOT:
#   * Repology strips the Debian -N+debNNuM suffix and reports only the bare
#     upstream version (1.26.3), so it never sees security rebuilds.
#   * Renovate's built-in `deb` datasource hard-codes `Packages.gz`, but the
#     security archive publishes only `Packages.xz` (renovatebot/renovate
#     #44330, PR #35865 unmerged) — the trixie-security registry 404s and is
#     skipped at DEBUG level, so security revisions were silently never seen
#     (bit us 2026-09-16: CI red for a month on nginx deb13u8/u9).
#
# How the archive behaves (and why the install below is shaped the way it is):
# the `trixie` suite keeps the point-release revision (e.g. …+deb13u7) while
# trixie-security carries the newer one (…+deb13u9). apt's candidate for every
# binary of src:nginx is therefore the security revision, and `nginx` depends
# on `nginx-common (= <exact same version>)`. Pinning `nginx=X` alone fails
# with "Depends: nginx-common (= X) but Y is to be installed" as soon as a
# security revision exists — ALL binaries of the source package must be pinned
# to the same revision in one apt-get call. Checking the index first
# (apt-cache madison) is not a valid test either: the old revision is still
# listed in `trixie`, the install just can't be resolved. So: attempt the exact
# pin; if apt cannot satisfy it for ANY reason, fall back to the latest
# available revision with a loud warning, so CI never hard-reds in the window
# before the Renovate PR merges. Transitive deps (libssl etc.) are refreshed by
# the staleness branch of the daily compute-matrix gate.
# renovate: datasource=custom.debian-madison depName=nginx versioning=deb
ARG NGINX_VERSION=1.26.3-3+deb13u10
# renovate: datasource=custom.debian-madison depName=supervisor versioning=deb
ARG SUPERVISOR_VERSION=4.2.5-3

# ffmpeg (installed below, intentionally unpinned) is the binary
# OC\Preview\Movie shells out to for video thumbnails — the base
# nextcloud:*-fpm image ships none. Kept outside the Renovate pinning set
# above to avoid constant churn from its large codec dependency chain.

# Exact pins with a fallback (rationale in the note above).
# apt_install_pinned <want> <pkg>...: install every listed package at exactly
# <want> in ONE apt-get call (same-source binaries must move together); if apt
# cannot resolve that, install the latest available revision and warn.
RUN set -eux; \
    apt-get update; \
    apt_install_pinned() { \
        want="$1"; shift; \
        pinned=""; for pkg in "$@"; do pinned="$pinned $pkg=$want"; done; \
        if apt-get install -y --no-install-recommends $pinned; then \
            echo "[apt-pin] $*: installed exact pin $want"; \
        else \
            echo "[apt-pin] WARNING: $*=$want not installable (Debian rotated the revision) — installing latest available until Renovate bumps the pin" >&2; \
            apt-get install -y --no-install-recommends "$@"; \
        fi; \
    }; \
    apt_install_pinned "${NGINX_VERSION}" nginx nginx-common; \
    apt_install_pinned "${SUPERVISOR_VERSION}" supervisor; \
    apt-get install -y --no-install-recommends ffmpeg; \
    rm -rf /var/lib/apt/lists/*; \
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    mkdir -p /etc/supervisor/conf.d /etc/nginx/conf.d /etc/nginx/snippets /var/log/supervisor

# nginx.conf `include`s nc-hsts.conf and nc-access-log.conf by literal path;
# render-overrides.sh (re)creates both at boot, but `nginx -t` also lints the
# static image (CST) BEFORE the entrypoint runs, and a missing include is a
# fatal emerg. Ship stubs so the un-booted image passes nginx -t. The access
# log stub carries the boot-time default (off) so the static image and the
# booted-without-NGINX_ACCESS_LOG container agree.
RUN : > /etc/nginx/snippets/nc-hsts.conf \
 && echo 'access_log off;' > /etc/nginx/snippets/nc-access-log.conf

# Drop the upstream php-fpm per-request access log. The `php:*-fpm` base sets
# `access.log = /proc/self/fd/2` in docker.conf, so every request nginx hands
# to FPM is logged TWICE on `docker logs` (nginx on stdout + FPM on stderr),
# and the FPM line carries strictly less information. The line must be
# DELETED, not overridden: php-fpm treats `access.log =` (empty) as a path and
# aborts at startup with "failed to open access log (): No such file or
# directory" (verified against nextcloud:33-fpm). Re-enable at runtime with
# FPM_ACCESS_LOG=/proc/self/fd/2 (rendered into zz-env.conf, which loads
# after docker.conf). The grep guard fails the build if upstream moves the
# directive, so a silent return of the duplicate lines can't slip through.
RUN set -eux; \
    f=/usr/local/etc/php-fpm.d/docker.conf; \
    grep -qE '^\s*access\.log\s*=' "$f"; \
    sed -i -E '/^\s*access\.log\s*=/d' "$f"; \
    ! grep -qE '^\s*access\.log\s*=' /usr/local/etc/php-fpm.d/*.conf

# Bundle the notify_push PHP app + binary. Disabled by default; opt in via
# NOTIFY_PUSH_ENABLE=true env var (see scripts/render-overrides.sh).
#
# The official image does NOT ship the app. It used to be `occ app:install`ed
# from apps.nextcloud.com by the wrapper on every fresh volume — 12× per CI
# run (one per notify test cell, ×6 retries ×2 occ calls when failing), which
# got the runner's shared egress IP 429-rate-limited by the app store
# (runs 744/747, 2026-10-21; NC reports a 429 as "not found on the appstore").
# Instead, fetch the signed release tarball once at build time — the same
# file the app store links to — into /usr/src/notify_push; the wrapper syncs
# it into custom_apps/ at boot. The tarball carries the per-arch binaries
# too (bin/<arch>/notify_push, identical to the standalone release assets),
# so /usr/local/bin/notify_push is a hard link into it: one download, and the
# app and binary versions can never drift apart.
# renovate: datasource=github-releases depName=nextcloud-releases/notify_push extractVersion=^v(?<version>.+)$
ARG NOTIFY_PUSH_VERSION=1.4.2
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64)  rust_arch=x86_64 ;; \
        aarch64) rust_arch=aarch64 ;; \
        *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused --retry-all-errors -o /tmp/notify_push.tar.gz \
        "https://github.com/nextcloud-releases/notify_push/releases/download/v${NOTIFY_PUSH_VERSION}/notify_push-v${NOTIFY_PUSH_VERSION}.tar.gz"; \
    tar -xzf /tmp/notify_push.tar.gz -C /usr/src --no-same-owner; \
    rm /tmp/notify_push.tar.gz; \
    chmod -R go-w /usr/src/notify_push; \
    grep -qF "<version>${NOTIFY_PUSH_VERSION}</version>" /usr/src/notify_push/appinfo/info.xml \
        || { echo "notify_push app version mismatch in appinfo/info.xml, want ${NOTIFY_PUSH_VERSION}" >&2; exit 1; }; \
    chmod 0755 "/usr/src/notify_push/bin/${rust_arch}/notify_push"; \
    ln "/usr/src/notify_push/bin/${rust_arch}/notify_push" /usr/local/bin/notify_push; \
    # Single source of truth: fail the build if the downloaded binary does not
    # report the pinned NOTIFY_PUSH_VERSION (wrong/empty/redirected download).
    # Downstream tests only assert the version *shape*, so a bump touches this
    # ARG and nothing else.
    ver="$(/usr/local/bin/notify_push --version)"; \
    [ "$ver" = "notify_push ${NOTIFY_PUSH_VERSION}" ] \
        || { echo "notify_push version mismatch: got '$ver', want 'notify_push ${NOTIFY_PUSH_VERSION}'" >&2; exit 1; }

# --chmod on EVERY COPY: without it the modes of the checkout propagate
# into the image, so the published artifact depends on the CI runner's
# umask/filesystem (observed: a runner whose workspace forced 0770 on all
# files shipped an executable group-writable nginx.conf).
COPY --chmod=0644 nginx.conf                                     /etc/nginx/nginx.conf
COPY --chmod=0644 snippets/nc-security-headers.conf              /etc/nginx/snippets/nc-security-headers.conf
COPY --chmod=0644 supervisord.conf                               /etc/supervisor/supervisord.conf
COPY --chmod=0755 scripts/entrypoint.sh             /usr/local/bin/container-entrypoint.sh
COPY --chmod=0755 scripts/render-overrides.sh       /usr/local/bin/render-overrides.sh
COPY --chmod=0755 scripts/notify-push-wrapper.sh    /usr/local/bin/notify-push-wrapper.sh

# Belt-and-braces mode enforcement in a RUN layer. Not redundant: BuildKit
# has been observed serving a `COPY --chmod=0755` step's cached result with
# the chmod NOT applied (registry-cache-imported fileop; layer carried the
# raw checkout mode 0770). A RUN executes in a container and its recorded
# result is the actual snapshot diff, so it cannot lose the chmod the same
# way. Costs one tiny metadata layer.
RUN chmod 0755 /usr/local/bin/container-entrypoint.sh \
               /usr/local/bin/render-overrides.sh \
               /usr/local/bin/notify-push-wrapper.sh \
 && chmod 0644 /etc/nginx/nginx.conf \
               /etc/nginx/snippets/nc-security-headers.conf \
               /etc/supervisor/supervisord.conf

# Best-practice pattern for containers with very-long first-boot init
# (Docker 25.0+ added `--start-interval` exactly for this case — see
# https://docs.docker.com/reference/dockerfile/#healthcheck):
#
#   --start-period=14400s (4 h)
#     Generous grace window where failures don't count toward retries.
#     Covers the one slow path that exists for real: a first-boot
#     `chown -R /var/www` (+ external data dir) on a migrated multi-TB
#     LSIO tree. Disk-bound storage routinely takes hours here (real
#     reports of ~50 min for a few TB on HDD, still growing). Once the
#     sentinels (version.php + .ncdata) match, the chown is skipped on
#     every subsequent boot and the container is healthy in <60s.
#   --start-interval=10s
#     During start-period, check every 10s instead of the 30s default.
#     The moment NC actually finishes booting, status.php responds and
#     the container transitions from "starting" to "healthy" within
#     seconds — no need to wait for the next 30-second interval tick.
#   --interval=30s --timeout=5s --retries=3
#     Normal post-startup behavior: a genuinely-broken NC is flagged
#     unhealthy after 90s of failures.
#
# For multi-TB migrations where 4h isn't enough, override start_period
# in compose, e.g.: `healthcheck: { start_period: 28800s }` (8h).
HEALTHCHECK --interval=30s --timeout=5s --start-period=14400s --start-interval=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1/status.php 2>/dev/null \
        | grep -q '"installed":true' || exit 1

EXPOSE 80

# Override upstream ENTRYPOINT+CMD. Our entrypoint renders env overrides as
# root, then execs supervisord, which in turn starts the upstream entrypoint
# (for install/upgrade + php-fpm) and nginx.
ENTRYPOINT []
CMD ["/usr/local/bin/container-entrypoint.sh"]
