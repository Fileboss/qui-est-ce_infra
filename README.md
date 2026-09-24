# lepgu_infra — shared VPS infra for `*.lepgu.fr`

Docker Compose stack for every app hosted on the single `lepgu.fr` VPS, behind one
Caddy instance with automatic Let's Encrypt TLS.

> The GitHub repo is still named **`qui-est-ce_infra`**. Renaming it to `lepgu_infra`
> is a one-time manual step (GitHub → Settings → Repository name); afterwards run
> `git remote set-url origin git@github.com:Fileboss/lepgu_infra.git` in every clone.
> GitHub keeps redirecting the old name, so nothing breaks in the meantime.

Two apps live here today:

| App | Repos | Services in this stack |
|-----|-------|------------------------|
| **qui-est-ce** | [back](https://github.com/Fileboss/qui-est-ce_back) · [front](https://github.com/Fileboss/qui-est-ce_front) | `front`, `back`, `postgres` |
| **palais-divin** | [back](https://github.com/Fileboss/palais_divin-back) · [front](https://github.com/Fileboss/palais_divin-front) | `palaisdivin-front`, `palaisdivin-back`, `palaisdivin-postgres`, `palaisdivin-neo4j` |

Shared by both: **`caddy`** (the only service publishing ports), **`keycloak`**
(one instance, one realm per app) and **`minio`** (one instance, one bucket per app).
Data stores are per-app, so one app's database can never break the other's.

The unprefixed `front` / `back` / `postgres` service names predate the multi-app
layout and belong to qui-est-ce. They are left alone deliberately — renaming them
would churn the Caddyfile and recreate containers of a live site for cosmetics.

## Hostnames

| Public URL | Internal target | Notes |
|-----------|-----------------|-------|
| `https://qui-est-qui.lepgu.fr` | `front:80` (+ `back:8080` under `/api/*`, `/ws/*`) | qui-est-ce frontend |
| `https://api.qui-est-qui.lepgu.fr` | `back:8080` | qui-est-ce API |
| `https://auth.qui-est-qui.lepgu.fr` | `keycloak:8080` | **shared** Keycloak, all realms |
| `https://s3.qui-est-qui.lepgu.fr` | `minio:9000` | qui-est-ce images (public-read bucket) |
| `https://palais-divin.lepgu.fr` | `palaisdivin-front:3000` | palais-divin frontend (BFF — owns `/api/*` itself) |
| `https://api.palais-divin.lepgu.fr` | `palaisdivin-back:8080` | palais-divin API (smoke tests / debugging) |
| `https://s3.palais-divin.lepgu.fr` | `minio:9000` | palais-divin photos (private, presigned URLs) |

Keycloak's hostname stays `auth.qui-est-qui.lepgu.fr` for both apps: `KC_HOSTNAME`
is a single value and it is baked into the `iss` claim of every already-issued
qui-est-ce token, so changing it would invalidate live sessions. palais-divin's
issuer is therefore `https://auth.qui-est-qui.lepgu.fr/realms/palaisdivin`. Cosmetic
only; revisit if a third app shows up.

## Layout

```
.
├── docker-compose.yml
├── Caddyfile
├── .env.example
├── postgres/init/00-keycloak-db.sh          # creates the keycloak DB on first volume init
├── keycloak/
│   ├── realm-export-prod.json               # qui-est-ce realm  (owned by qui-est-ce_back)
│   └── realm-palaisdivin-prod.json          # palaisdivin realm (owned by palais_divin-back)
└── scripts/smoke-palais-divin.sh            # read-only post-deploy checks
```

Realm JSONs are imported on Keycloak boot. **Every** file under
`/opt/keycloak/data/import/` is processed and realms that already exist are skipped
(`IGNORE_EXISTING`), which is why adding the second file is safe on a running
instance — and also why edits to an already-imported realm never take effect (see
`todo.md`).

## Prerequisites

- VPS with Docker + Compose plugin.
- **≥ 4 GB RAM.** palais-divin adds a Spring Boot JVM, a Neo4j JVM and a Node
  server; the compose file caps them (`mem_limit` 1 GB / 1 GB / 512 MB) so they
  cannot OOM-kill qui-est-ce. Drop or raise the caps to taste.
- DNS **A records for all seven hostnames** above pointing at the VPS IP. Caddy
  cannot issue a certificate for a name that does not resolve; the three
  `palais-divin` records are new.
- Ports 80 and 443 open.
- The VPS must be able to reach **its own public hostnames from inside a
  container** (hairpin NAT / split-horizon DNS). Both backends depend on this:
  they fetch Keycloak's JWK set from the public issuer URL, and palais-divin mints
  MinIO presigned URLs against `https://s3.palais-divin.lepgu.fr`. qui-est-ce
  already relies on this today, so it is known to work — if it ever stops, see
  Troubleshooting.

## Images

CI/CD is not wired yet. Images are built and pushed manually from the dev machine;
GHCR needs a PAT with `write:packages` (`docker login ghcr.io -u <github-username>`).

```sh
# qui-est-ce back
cd qui-est-ce_back
./mvnw package -DskipTests
docker build -f src/main/docker/Dockerfile.jvm -t ghcr.io/fileboss/qui-est-ce-back:latest .
docker push ghcr.io/fileboss/qui-est-ce-back:latest

# qui-est-ce front
cd qui-est-ce_front
docker build -t ghcr.io/fileboss/qui-est-ce-front:latest .
docker push ghcr.io/fileboss/qui-est-ce-front:latest

# palais-divin back — multi-stage, builds the jar itself; context is the repo root
cd palais_divin-back
docker build -f src/main/docker/Dockerfile -t ghcr.io/fileboss/palais-divin-back:latest .
docker push ghcr.io/fileboss/palais-divin-back:latest

# palais-divin front
cd palais_divin-front
docker build -t ghcr.io/fileboss/palais-divin-front:latest .
docker push ghcr.io/fileboss/palais-divin-front:latest
```

Push the palais-divin images **before** the first `docker compose up -d`:
`pull_policy: always` means a missing image aborts the whole `up`.

## First boot

1. SSH to the VPS, clone this repo, `cd` into it.
2. Copy `.env.example` to `.env` and fill in every secret. Generate each with
   `openssl rand -hex 32` (hex avoids quoting problems — some values are
   interpolated into shell healthchecks), except `PALAISDIVIN_SESSION_SECRET`
   which must be base64: `openssl rand -base64 32`.
   The palais-divin backend refuses to start with a blank Keycloak client secret,
   and the Keycloak realm import bakes `PALAISDIVIN_BACKEND_CLIENT_SECRET` in on
   first import — so set it before the first `up`, not after.
3. `docker compose pull && docker compose up -d`.
4. `docker compose logs -f keycloak` until both realms are imported (`qui-est-ce`
   and `palaisdivin`), then `docker compose logs -f back palaisdivin-back`.
5. `./scripts/smoke-palais-divin.sh`.

### Bootstrapping the first palais-divin user

palais-divin is invitation-only: `POST /api/v1/admin/invitations` requires an
`ADMIN` token, and there is no self-service signup. The prod realm ships with **no
users** (unlike the dev realm), so the first one is created by hand:

1. `https://auth.qui-est-qui.lepgu.fr` → log in as the bootstrap admin → switch to
   the **palaisdivin** realm → **Users** → create a user, set a non-temporary
   password, assign the **ADMIN** realm role.
2. Log in at `https://palais-divin.lepgu.fr` as that user and grab its access token
   (DevTools → any `/api/*` request → `Authorization` header), then:
   `curl -X POST -H "Authorization: Bearer $TOKEN" https://api.palais-divin.lepgu.fr/api/v1/admin/invitations`
   The response carries the signup link.
3. Open that link and sign up. **This** is the account to actually use the app with:
   signup is what creates the Postgres `users` row, and every `/api/v1/user/**`
   endpoint resolves the caller through it. The hand-made Keycloak user has no such
   row, so it can issue invitations but cannot rate or follow anything.

### qui-est-ce, on an existing deployment

Nothing about qui-est-ce changes: same images, same env vars, same Caddy blocks,
same volumes. `docker compose up -d` recreates only the containers whose config
changed — `keycloak` (a second realm import file is mounted) and `caddy` (new
vhosts). Both come back in seconds and the qui-est-ce realm is *not* re-imported.

## Updating

```sh
# from the dev machine: rebuild + push (see "Images")
# on the VPS:
docker compose pull
docker compose up -d palaisdivin-back palaisdivin-front    # or back, front, or nothing named for all
```

## Troubleshooting

- `docker compose ps` — every service except `minio-init` should be running and
  healthy. `palaisdivin-back` reports no health status by design: its image is
  Distroless (no shell to exec a healthcheck with). Use
  `curl https://api.palais-divin.lepgu.fr/actuator/health` instead.
- TLS issues → `docker compose logs caddy`. Let's Encrypt errors (rate limits, DNS
  not resolving) are logged verbatim. A `palais-divin` cert failure does not affect
  the qui-est-ce vhosts.
- Keycloak refuses to start: usually a `KC_HOSTNAME` mismatch — it must equal the
  public URL exactly, scheme included.
- `palaisdivin-back` loops on startup:
  - `Failed to fetch remote JWK set` / connection timeout to
    `auth.qui-est-qui.lepgu.fr` → the container cannot reach the VPS's own public
    hostname. Fix at the network level, or give `caddy` a docker-network alias for
    the hostname so the lookup stays inside the bridge:
    ```yaml
    caddy:
      networks:
        default:
          aliases: [auth.qui-est-qui.lepgu.fr, s3.palais-divin.lepgu.fr]
    ```
  - `FlywayValidateException` / `relation does not exist` → the Postgres volume was
    created by a different image; `palaisdivin-postgres` must be `postgis/postgis`
    because `V1__restaurant.sql` runs `CREATE EXTENSION postgis`.
- Photo upload fails in the browser with a signature error → `MINIO_ENDPOINT` must
  be the **public** `https://s3.palais-divin.lepgu.fr`. SigV4 signs the Host header,
  so a URL minted against `http://minio:9000` is invalid for any other host (and
  unreachable from a browser anyway). If it fails on the *preflight* instead
  (`OPTIONS` blocked), that is MinIO's CORS: it allows any origin by default and
  this stack leaves that alone — tightening `MINIO_API_CORS_ALLOW_ORIGIN` would
  apply to qui-est-ce's bucket too.
- Restaurants appear but recommendations are empty → Neo4j is a *derived* store fed
  by the transactional outbox. Check `palaisdivin-neo4j` is healthy and the
  `outbox_event` table has no rows stuck in `PENDING`.
- Login loops back to the login page → the realm's `palais-divin-frontend` client
  must whitelist `https://palais-divin.lepgu.fr/*` as a redirect URI, and the front
  needs `ORIGIN` + `PUBLIC_ORIGIN` set to the public origin.

## Related repos

- [qui-est-ce_back](https://github.com/Fileboss/qui-est-ce_back) — Quarkus, owns
  `keycloak/realm-export-prod.json`.
- [qui-est-ce_front](https://github.com/Fileboss/qui-est-ce_front)
- [palais_divin-back](https://github.com/Fileboss/palais_divin-back) — Spring Boot,
  owns `keycloak/realm-palaisdivin-prod.json` (the dev original lives at
  `compose/keycloak/realm-palaisdivin.json`).
- [palais_divin-front](https://github.com/Fileboss/palais_divin-front) — SvelteKit BFF.

Realm JSONs are copies. If an app's realm template changes, mirror it here by hand —
and remember the import only applies to a realm that does not exist yet.
