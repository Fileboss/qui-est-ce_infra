# qui-est-ce_infra

Docker Compose stack for the prod deployment of the *qui-est-ce* game.

Runs on a single VPS behind Caddy with auto Let's Encrypt TLS for the four hostnames:

| Service | Public URL | Internal target |
|---------|-----------|-----------------|
| Frontend | `https://qui-est-qui.lepgu.fr` | `front:80` |
| Backend (REST + WebSocket) | `https://api.qui-est-qui.lepgu.fr` | `back:8080` |
| Keycloak | `https://auth.qui-est-qui.lepgu.fr` | `keycloak:8080` |
| MinIO (image URLs) | `https://s3.qui-est-qui.lepgu.fr` | `minio:9000` |

Only Caddy publishes ports (80/443). All other services live on the internal Docker network.

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
