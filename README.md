# qui-est-ce_infra

Docker Compose stack for the prod deployment of the *qui-est-ce* game.

> **The game is no longer maintained and is shut down** (October 2026). Its services
> (front, back, Keycloak, Postgres, MinIO) sit in the `qui-est-qui` compose profile, so
> `docker compose up -d` only starts Caddy, and Caddy answers `410` on the four hostnames.
> Volumes are kept. To bring it back: restore its sites in the `Caddyfile` (git history),
> update the images (Keycloak 26.0 and `minio/minio` are out of date), then
> `docker compose --profile qui-est-qui up -d`. The sections below describe the game as it was.

Shutting down a running VPS (once, after `git pull`):

```sh
docker compose rm -sf front back keycloak minio minio-init postgres
docker compose restart caddy   # restart, not up -d: the bind-mounted Caddyfile was replaced by git pull
```

It ran on a single VPS behind Caddy with auto Let's Encrypt TLS for the four hostnames:

| Service | Public URL | Internal target |
|---------|-----------|-----------------|
| Frontend | `https://qui-est-qui.lepgu.fr` | `front:80` |
| Backend (REST + WebSocket) | `https://api.qui-est-qui.lepgu.fr` | `back:8080` |
| Keycloak | `https://auth.qui-est-qui.lepgu.fr` | `keycloak:8080` |
| MinIO (image URLs) | `https://s3.qui-est-qui.lepgu.fr` | `minio:9000` |

Only Caddy publishes ports (80/443). All other services live on the internal Docker network.

## Homelab (Immich + Vaultwarden + Memos)

Caddy also fronts `photos.lepgu.fr` (Immich), `vault.lepgu.fr` (Vaultwarden) and `notes.lepgu.fr` (Memos, quick notes; §16), which run on a home server reached through Tailscale (no port open on the home router). The `homelab/` folder holds that server's stack and the encrypted Vaultwarden backup to this VPS. Full procedure: [docs/homelab-setup.md](docs/homelab-setup.md). Requires `HOMELAB_TAILNET_IP` in `.env`.

## Vulnerability scan

`.github/workflows/vulns.yml` scans every deployed image (VPS + homelab) daily, using the versions in the `.env.example` files: keep them in sync with the real `.env`. The job fails when an image ships a vulnerable Node.js or Bun runtime (minimum versions in `security/scan-images.sh`, e.g. Node2Shell / CVE-2026-111497), or a fixable vulnerability that is known exploited (CISA KEV) or in the EPSS top 10 %. Other fixable Critical/High findings are listed in the run summary. Same check locally: `security/scan-images.sh all`.

Local checks (Mac, needs Docker/OrbStack, not in CI): `homelab/tests/run.sh` runs shellcheck, systemd/sshd/ACL validation, bats tests of the backup script (fake restic/curl), `docker compose config` and `caddy validate`.

## Layout

```
.
├── docker-compose.yml
├── Caddyfile
├── .env.example
├── postgres/init/00-keycloak-db.sh    # creates the keycloak DB on first volume init
└── keycloak/realm-export-prod.json    # imported on Keycloak first boot (manual sync from the back repo)
```

## Prerequisites

- VPS with Docker + Compose plugin (see roadmap task 6 for the host setup).
- DNS A records for the four hostnames pointing at the VPS IP.
- Ports 80 and 443 open in the firewall.

## Images

CI/CD is not wired yet (roadmap task 8). For now, the back and front images are built and pushed manually from the dev machine:

```sh
# back
cd qui-est-ce_back
./mvnw package -DskipTests
docker build -f src/main/docker/Dockerfile.jvm -t ghcr.io/fileboss/qui-est-ce-back:latest .
docker push ghcr.io/fileboss/qui-est-ce-back:latest

# front
cd qui-est-ce_front
docker build -t ghcr.io/fileboss/qui-est-ce-front:latest .
docker push ghcr.io/fileboss/qui-est-ce-front:latest
```

GHCR requires a personal access token with `write:packages`: `docker login ghcr.io -u <github-username>`.

## First boot

1. SSH to the VPS, clone this repo, `cd` into it.
2. Copy `.env.example` to `.env` and fill in real secrets.
3. `docker compose pull && docker compose up -d`.
4. Watch the logs (`docker compose logs -f keycloak back`) until Keycloak imports the realm and the back is ready.
5. Open `https://auth.qui-est-qui.lepgu.fr`, log in with `KC_BOOTSTRAP_ADMIN_USERNAME` / `_PASSWORD`. In the `qui-est-ce` realm, regenerate the client secret for `qui-est-ce-back` (Clients → qui-est-ce-back → Credentials → Regenerate).
6. Paste the new value into `.env` as `OIDC_CLIENT_SECRET`, then `docker compose up -d back`.
7. Still in the admin console, create the first real user(s) and assign the `player` (or `admin`) realm role.

`--import-realm` runs only on the first Keycloak boot; subsequent restarts skip the import silently. The `minio-init` one-shot service sets the `download` (public read) policy on the `game-images` bucket on every `up` and is idempotent.

## Updating

```sh
# from the dev machine: rebuild + push (see "Images" above)
# on the VPS:
docker compose pull
docker compose up -d back     # or front, or both
```

## Troubleshooting

- `docker compose ps` — every service except `minio-init` should be `running` and healthy.
- `docker compose logs <service>` — tail logs.
- TLS issues: check `docker compose logs caddy`. Caddy logs Let's Encrypt errors clearly (rate limits, DNS resolution, etc.).
- Keycloak refuses to start: usually a `KC_HOSTNAME` mismatch — must match the public URL exactly (incl. scheme).
- Back returns 503 on `/q/health/ready`: usually Postgres or MinIO is not healthy yet. Inspect their logs.

## Related repos

- [qui-est-ce_back](https://github.com/Fileboss/qui-est-ce_back) — Quarkus backend, owns `realm-export-prod.json`. Keep `keycloak/realm-export-prod.json` here in sync manually if the realm template ever changes.
- [qui-est-ce_front](https://github.com/Fileboss/qui-est-ce_front) — frontend.
