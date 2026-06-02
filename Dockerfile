ARG NC_VERSION=33.0.3
FROM nextcloud:${NC_VERSION}-fpm

USER root

# nginx & supervisor are pinned to exact Debian (Trixie) versions so Renovate
# can open a PR the moment Debian publishes a security update — see
# .github/renovate.json (Repology datasource, debian_13/<pkg>). The PR merging
# is what triggers a rebuild for these packages; transitive deps (libssl etc.)
# are refreshed by the staleness branch of the daily compute-matrix gate.
# renovate: datasource=repology depName=debian_13/nginx versioning=loose
ARG NGINX_VERSION=1.26.3-3+deb13u5
# renovate: datasource=repology depName=debian_13/supervisor versioning=loose
ARG SUPERVISOR_VERSION=4.2.5-3

# ffmpeg (installed below, intentionally unpinned) is the binary
# OC\Preview\Movie shells out to for video thumbnails — the base
# nextcloud:*-fpm image ships none. Kept outside the Renovate pinning set
# above to avoid constant churn from its large codec dependency chain.

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nginx=${NGINX_VERSION} \
        supervisor=${SUPERVISOR_VERSION} \
        ffmpeg \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    mkdir -p /etc/supervisor/conf.d /etc/nginx/conf.d /etc/nginx/snippets /var/log/supervisor

# nginx.conf `include`s nc-hsts.conf by literal path; render-overrides.sh
# (re)creates it at boot, but `nginx -t` also lints the static image (CST)
# BEFORE the entrypoint runs, and a missing include is a fatal emerg. Ship an
# empty stub so the un-booted image passes nginx -t.
RUN : > /etc/nginx/snippets/nc-hsts.conf

# Install the Nextcloud notify_push binary (companion to the upstream
# `notify_push` PHP app that ships in the official image). Disabled by default;
# opt in via NOTIFY_PUSH_ENABLE=true env var (see scripts/render-overrides.sh).
ARG NOTIFY_PUSH_VERSION=1.3.2
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64)  rust_arch=x86_64 ;; \
        aarch64) rust_arch=aarch64 ;; \
        *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused --retry-all-errors -o /usr/local/bin/notify_push \
        "https://github.com/nextcloud/notify_push/releases/download/v${NOTIFY_PUSH_VERSION}/notify_push-${rust_arch}-unknown-linux-musl"; \
    chmod 0755 /usr/local/bin/notify_push; \
    /usr/local/bin/notify_push --version

COPY nginx.conf                                     /etc/nginx/nginx.conf
COPY snippets/nc-security-headers.conf              /etc/nginx/snippets/nc-security-headers.conf
COPY supervisord.conf                               /etc/supervisor/supervisord.conf
COPY --chmod=0755 scripts/entrypoint.sh             /usr/local/bin/container-entrypoint.sh
COPY --chmod=0755 scripts/render-overrides.sh       /usr/local/bin/render-overrides.sh
COPY --chmod=0755 scripts/notify-push-wrapper.sh    /usr/local/bin/notify-push-wrapper.sh

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
