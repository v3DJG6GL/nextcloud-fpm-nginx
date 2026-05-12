ARG NC_VERSION=33.0.3
FROM nextcloud:${NC_VERSION}-fpm

USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nginx \
        supervisor \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    ln -sf /dev/stdout /var/log/nginx/access.log; \
    ln -sf /dev/stderr /var/log/nginx/error.log; \
    mkdir -p /etc/supervisor/conf.d /etc/nginx/conf.d /var/log/supervisor

COPY nginx.conf                                /etc/nginx/nginx.conf
COPY supervisord.conf                          /etc/supervisor/supervisord.conf
COPY --chmod=0755 scripts/entrypoint.sh        /usr/local/bin/container-entrypoint.sh
COPY --chmod=0755 scripts/render-overrides.sh  /usr/local/bin/render-overrides.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS http://127.0.0.1/status.php 2>/dev/null \
        | grep -q '"installed":true' || exit 1

EXPOSE 80

# Override upstream ENTRYPOINT+CMD. Our entrypoint renders env overrides as
# root, then execs supervisord, which in turn starts the upstream entrypoint
# (for install/upgrade + php-fpm) and nginx.
ENTRYPOINT []
CMD ["/usr/local/bin/container-entrypoint.sh"]
