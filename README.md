# nextcloud-fpm-nginx

Single-container Nextcloud built by layering nginx + supervisord on top of the
official [`nextcloud:<version>-fpm`](https://hub.docker.com/_/nextcloud) image.

- Same install/upgrade behavior as the upstream image (env-var auto-config,
  hook folders, htaccess maintenance, GPG-verified release tarball).
- nginx serves static assets and proxies PHP requests to php-fpm on
  `127.0.0.1:9000`.
- supervisord runs both processes as PID 1.
- One container behind your reverse proxy (Nginx Proxy Manager, Traefik,
  Caddy, etc.) — no separate webserver container needed.
- Versioned, immutable image tags on ghcr.io for reproducible deployments.

## Image tags

Replace `<OWNER>` with the GitHub user/org that owns this build (default:
`v3djg6gl`).

| Tag | What it tracks | Use this when… |
|---|---|---|
| `ghcr.io/<OWNER>/nextcloud-fpm-nginx:v33.0.3` | Pinned to Nextcloud 33.0.3 | You want byte-stable deploys. |
| `ghcr.io/<OWNER>/nextcloud-fpm-nginx:v33.0` | Latest 33.0.x (currently 33.0.3) | You want automatic patch upgrades within a minor line. |
| `ghcr.io/<OWNER>/nextcloud-fpm-nginx:v33` | Latest 33.x.x | You want all Nextcloud 33 patches. |
| `ghcr.io/<OWNER>/nextcloud-fpm-nginx:v32` | Latest 32.x.x | You're still on Nextcloud 32. |
| `ghcr.io/<OWNER>/nextcloud-fpm-nginx:latest` | Newest non-blocked major | Convenience only; auto-promotes on major bumps (be careful). |

Nextcloud uses `<major>.0.<patch>` exclusively today (e.g., `33.0.3`,
`32.0.9` — no `33.1.x` series), so `v33` and `v33.0` currently point at the
same image. The three-tag cascade is forward-compatible if Nextcloud ever
ships a non-zero minor.

## Quick start

Files you need: `compose.yaml` (in this repo), plus a `secrets/` directory:

```bash
mkdir -p secrets data
echo "$(openssl rand -hex 32)" > secrets/db_password
echo "$(openssl rand -hex 24)" > secrets/nc_admin_password
chmod 600 secrets/*
docker compose up -d
```

The image will fetch, the database will initialize, and Nextcloud will run
its first-time install. Watch progress with `docker compose logs -f app`.

The compose example assumes you already have an external Docker network
called `npm-proxy` for your reverse proxy to use. If you don't, run:

```bash
docker network create npm-proxy
```

…before `docker compose up -d`.

## Setting up Nginx Proxy Manager

1. Add NPM to the `npm-proxy` Docker network (or change the network name in
   `compose.yaml` to match NPM's existing network).
2. In the NPM UI, **Hosts → Proxy Hosts → Add Proxy Host**:
   - **Domain Names:** `cloud.example.com` (your hostname)
   - **Forward Hostname / IP:** `app` (the service name from `compose.yaml`)
   - **Forward Port:** `80`
   - **Cache Assets:** off
   - **Block Common Exploits:** **off** — it interferes with WebDAV.
   - **Websockets Support:** on
3. **SSL tab:**
   - **SSL Certificate:** request a Let's Encrypt cert.
   - **Force SSL:** on
   - **HTTP/2 Support:** on
   - **HSTS Enabled:** on (this is where HSTS should live, not inside
     this image's nginx).
4. **Advanced tab** — paste this nginx snippet to redirect `.well-known`
   discovery for CalDAV/CardDAV (Nextcloud's `.well-known` routing is
   handled by the inner nginx, but having NPM proxy them straight through
   avoids edge cases with some clients):

   ```nginx
   location = /.well-known/carddav { return 301 $scheme://$host/remote.php/dav/; }
   location = /.well-known/caldav  { return 301 $scheme://$host/remote.php/dav/; }
   ```

5. **Set `'overwriteprotocol' => 'https'`** in Nextcloud's `config.php` so
   the app generates `https://` URLs. The first time `app` starts you can
   either `docker compose exec -u www-data app php occ config:system:set
   overwriteprotocol --value=https` or drop a small fragment file —
   see "Bind-mount overrides" below.

6. Same for `'trusted_proxies'` if your NPM container's IP isn't already
   covered by this image's nginx `set_real_ip_from` (which trusts all
   RFC1918 + ULA by default).

## Environment variables

### Inherited from the upstream `nextcloud:fpm` image

Set these once at install time; some are also live-reload friendly. See the
[upstream image docs](https://github.com/nextcloud/docker#environment-variables)
for the full list — selected ones:

| Variable | Purpose |
|---|---|
| `NEXTCLOUD_ADMIN_USER`, `NEXTCLOUD_ADMIN_PASSWORD[_FILE]` | First-time admin account |
| `NEXTCLOUD_TRUSTED_DOMAINS` | Space-separated hostnames Nextcloud accepts |
| `NEXTCLOUD_DATA_DIR` | Alternate data dir (defaults to `/var/www/html/data`) |
| `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD[_FILE]` | Postgres connection |
| `MYSQL_HOST`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD[_FILE]` | MariaDB/MySQL connection |
| `SQLITE_DATABASE` | Use SQLite (testing only) |
| `REDIS_HOST`, `REDIS_HOST_PORT`, `REDIS_HOST_PASSWORD` | Distributed locking + memcache |
| `OBJECTSTORE_S3_*`, `OBJECTSTORE_SWIFT_*` | Use object storage instead of local FS |
| `PHP_MEMORY_LIMIT` | `memory_limit` (default `512M`) |
| `PHP_UPLOAD_LIMIT` | `upload_max_filesize` + `post_max_size` (default `512M`) |
| `PHP_OPCACHE_MEMORY_CONSUMPTION` | `opcache.memory_consumption` (default `128`) |

### Added by this image

PHP `.ini` overrides (written to `/usr/local/etc/php/conf.d/zz-env-overrides.ini`):

| Variable | Maps to | Default |
|---|---|---|
| `PHP_TIMEZONE` | `date.timezone` | (PHP default) |
| `PHP_OPCACHE_ENABLE` | `opcache.enable` | `1` (upstream) |
| `PHP_OPCACHE_ENABLE_CLI` | `opcache.enable_cli` | `1` (upstream) |
| `PHP_OPCACHE_INTERNED_STRINGS_BUFFER` | `opcache.interned_strings_buffer` | `32` (upstream) |
| `PHP_OPCACHE_MAX_ACCELERATED_FILES` | `opcache.max_accelerated_files` | `10000` (upstream) |
| `PHP_OPCACHE_REVALIDATE_FREQ` | `opcache.revalidate_freq` | `60` (upstream) |
| `PHP_OPCACHE_SAVE_COMMENTS` | `opcache.save_comments` | `1` (upstream) |
| `PHP_OPCACHE_JIT` | `opcache.jit` | `1255` (upstream) |
| `PHP_OPCACHE_JIT_BUFFER_SIZE` | `opcache.jit_buffer_size` | `8M` (upstream) |

FPM pool overrides (written to `/usr/local/etc/php-fpm.d/zz-env.conf`):

| Variable | Maps to |
|---|---|
| `FPM_PM` | `pm` (`dynamic`/`static`/`ondemand`) |
| `FPM_PM_MAX_CHILDREN` | `pm.max_children` |
| `FPM_PM_START_SERVERS` | `pm.start_servers` |
| `FPM_PM_MIN_SPARE_SERVERS` | `pm.min_spare_servers` |
| `FPM_PM_MAX_SPARE_SERVERS` | `pm.max_spare_servers` |
| `FPM_PM_MAX_REQUESTS` | `pm.max_requests` |
| `FPM_REQUEST_TERMINATE_TIMEOUT` | `request_terminate_timeout` |
| `FPM_REQUEST_SLOWLOG_TIMEOUT` | `request_slowlog_timeout` |
| `FPM_SLOWLOG` | `slowlog` (path) |

Nginx tweaks:

| Variable | Effect | Default |
|---|---|---|
| `NGINX_SERVER_NAME` | Replaces `server_name` in the server block | `_` (catch-all) |
| `NGINX_HSTS` | Value of `Strict-Transport-Security` header (emitted only when set) | unset |

Unsetting an env var on the next container start cleanly removes the
corresponding override (the hook script rebuilds all override files from
scratch each start).

## Bind-mount overrides

Anything our env vars don't expose can be set via bind-mounted config files —
the standard `php:fpm` pattern. PHP and FPM load `*.ini` / `*.conf` in lexical
order, so use prefixes like `99-` and `zzz-` to win over everything else.

```yaml
volumes:
  # PHP ini overrides
  - ./php-local.ini:/usr/local/etc/php/conf.d/99-local.ini:ro
  # FPM pool overrides
  - ./www2.conf:/usr/local/etc/php-fpm.d/zzz-local.conf:ro
  # Nextcloud config fragments (loaded after main config.php)
  - ./my-config.config.php:/var/www/html/config/zz-my-config.config.php:ro
```

The Nextcloud `*.config.php` fragment pattern is the same one the upstream
image uses for its seeded configs (`redis.config.php`, `apcu.config.php`,
etc.) — Nextcloud merges all `*.config.php` files in the config dir on load.

## Upgrade workflow

**Patch / minor upgrades (e.g., 33.0.3 → 33.0.4)**

```bash
docker compose pull       # pulls the latest v33 image
docker compose up -d      # recreates the container
```

The upstream entrypoint runs `occ upgrade` automatically on next start.
Always back up your data volume and database before any upgrade.

**Major upgrades (e.g., 33 → 34)**

Edit `compose.yaml` to bump the tag (`v33` → `v34`), then `docker compose
pull && docker compose up -d`. The Nextcloud entrypoint refuses to skip
majors (e.g., 32 → 34 directly), so go through every major in order. Back
up first.

**Removing a major from CI**

Add the major number to `.github/versions-blocklist.txt` and commit. The
next build run will skip it. Existing pinned tags on ghcr.io (`v33.0.3`,
etc.) remain available — they just stop receiving new builds.

## Updating the nginx config on Nextcloud major bumps

When Nextcloud ships a new major, fetch their nginx reference and diff
against what's in this repo:

```bash
curl -sSL https://docs.nextcloud.com/server/<NEW_MAJOR>/admin_manual/installation/nginx.html \
  | sed -n '/^upstream php-handler/,/^}/p' > /tmp/nc-upstream.conf
diff -u nginx.conf /tmp/nc-upstream.conf
```

Apply any new locations, security headers, or rewrite changes. The current
`nginx.conf` in this repo is based on the Nextcloud 33 reference,
`# Version 2025-07-23`. Rebuild and run the verification steps under "Build
locally" before tagging a new release.

## Build locally

```bash
# Default version
docker build -t local/nc-fpm-nginx:test .

# Pin to a specific Nextcloud version
docker build --build-arg NC_VERSION=33.0.3 -t local/nc-fpm-nginx:test .

# Smoke run with SQLite (no DB stack needed)
docker run --rm -d --name nc-test -p 8080:80 \
  -e SQLITE_DATABASE=nc.db \
  -e NEXTCLOUD_ADMIN_USER=admin \
  -e NEXTCLOUD_ADMIN_PASSWORD=changeme \
  -e NEXTCLOUD_TRUSTED_DOMAINS=localhost \
  local/nc-fpm-nginx:test

# Wait for install, then verify
timeout 60 sh -c 'until curl -fsS http://127.0.0.1:8080/status.php | grep -q "\"installed\":true"; do sleep 2; done'
curl -sI http://127.0.0.1:8080/ | grep -i x-frame-options
docker exec nc-test supervisorctl status
docker logs nc-test 2>&1 | grep -i error
docker stop nc-test
```

## Architecture notes

- **supervisord runs as PID 1** and starts two programs: `nextcloud` (which
  runs `/entrypoint.sh /usr/local/sbin/php-fpm -F` — i.e., the upstream
  entrypoint's full install/upgrade flow, then execs php-fpm in the
  foreground) and `nginx`. Both start in parallel.
- **Brief 502 window during fresh install / major upgrade** — nginx is up
  before php-fpm finishes installing. Reverse proxies that retry on 5xx
  hide this. The trade-off keeps the container simple.
- **php-fpm master** runs as root and listens on `127.0.0.1:9000`; worker
  pool drops to `www-data`. nginx **master** runs as root for the port 80
  bind; workers run as `www-data` so static-file delivery from
  `/var/www/html` works without permission gymnastics.
- **HSTS / TLS / `Strict-Transport-Security`** are NOT emitted by this nginx
  by default — they belong at the outer reverse proxy where TLS terminates.
  Set `NGINX_HSTS` if you specifically want this image to emit the header
  too (mostly useful for setups where the outer proxy doesn't add it).
- **`fastcgi_param HTTPS`** is dynamic from `X-Forwarded-Proto`, defaulting
  to `on`. That matches the upstream Nextcloud nginx reference and the
  assumed topology (TLS-terminating proxy in front). If you point the
  container directly at a plain-HTTP client and the client doesn't send
  `X-Forwarded-Proto`, Nextcloud will generate `https://` URLs anyway —
  fine if you're using TLS, broken if you're not.

## Citations

- **Nextcloud nginx reference (33):**
  https://docs.nextcloud.com/server/33/admin_manual/installation/nginx.html
  — config header `# Version 2025-07-23`. The `nginx.conf` in this repo is
  the verbatim upstream config with the documented behind-proxy adaptations.
- **Nextcloud Docker (upstream image):**
  https://github.com/nextcloud/docker — we layer on top of
  `nextcloud:<NC_VERSION>-fpm`, never rebuild from scratch.
- **linuxserver/nextcloud:**
  https://github.com/linuxserver/docker-nextcloud — reference only; their
  Alpine-from-scratch pattern is what this project consciously avoids.

## License

[AGPL-3.0](./LICENSE) — matches upstream Nextcloud.
