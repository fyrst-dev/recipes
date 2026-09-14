# VPS edge: host Caddy (TLS) → loopback Shopware

**Supported pattern (locked):** Caddy on the VPS host, Let's Encrypt via ACME, `reverse_proxy` to Shopware on **127.0.0.1:8000**. Traefik and nginx are not the fyrst-supported VPS edge.

`deploy/compose.prod.yaml` publishes:

```text
${HTTP_BIND:-127.0.0.1}:${HTTP_PORT:-8000}:8000
```

The app is not on `0.0.0.0:8000` unless you set `HTTP_BIND=0.0.0.0` (explicit, unsupported for live). **MySQL stays `ports: []`** — do not add a host mapping for 3306.

This host Caddy is **not** the Caddy (or FrankenPHP/nginx) inside the `web` image. The image already serves HTTP on container port 8000. Edge Caddy only terminates TLS on 80/443.

## One shop, one hostname (copy-paste)

1. Point DNS A/AAAA for `shop.example.com` at the VPS.
2. Install Caddy (`apt install caddy` or the [official repo](https://caddyserver.com/docs/install)).
3. Copy `deploy/edge/Caddyfile` to `/etc/caddy/Caddyfile` and replace `shop.example.com`.
4. `sudo systemctl enable --now caddy` (or `reload` if already running).
5. Open 80/443 on the host firewall. Do **not** open `HTTP_PORT` (8000) publicly.

Caddy's default ACME issuer is Let's Encrypt. Staging issuer (rate-limit safe):

```
{
	acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
}
```

Put that global block at the top of the Caddyfile while testing, then remove it.

### Caddy in Docker instead of apt

`--network host` is required so Caddy can reach `127.0.0.1:8000` and bind 80/443:

```bash
docker run -d --name shopware-edge --network host --restart unless-stopped \
  -v /etc/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v caddy_data:/data \
  caddy:2
```

## Several shops / live+staging on one VPS

Each stack has its own `SHOPWARE_SHOP_ID` + `SHOPWARE_DEPLOY_ENV` and a unique `HTTP_PORT` (and Compose project name). Host-based routing, not path-based:

```caddyfile
# live  — SHOPWARE_SHOP_ID=acme SHOPWARE_DEPLOY_ENV=live  HTTP_PORT=8000
www.example.com {
	encode gzip zstd
	reverse_proxy 127.0.0.1:8000
}

# staging — same shop id, SHOPWARE_DEPLOY_ENV=staging, HTTP_PORT=8001
staging.example.com {
	encode gzip zstd
	reverse_proxy 127.0.0.1:8001
}

# second shop — SHOPWARE_SHOP_ID=widgets HTTP_PORT=8010
widgets.example.com {
	encode gzip zstd
	reverse_proxy 127.0.0.1:8010
}
```

`SMOKE_URL` and healthchecks still use `http://127.0.0.1:${HTTP_PORT}` from the host (or from inside `web`, `http://127.0.0.1:8000/api/_info/health-check`).

## Go-live checklist

- [ ] Edge (this Caddyfile) is in front of Shopware **before** public DNS cutover
- [ ] `compose.prod.yaml` is in the `docker compose -f` list (`fyrst-cli shopware deploy release` already adds it)
- [ ] MySQL has no published host port
- [ ] Nightly `fyrst-cli shopware backup create` cron is on **live** (sync is not a backup)
