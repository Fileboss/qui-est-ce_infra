# Deploying palais-divin

Step-by-step runbook for putting **palais-divin.lepgu.fr** on the shared VPS
without disturbing qui-est-ce. Follow it top to bottom the first time; later
deploys only need [§9 Redeploying](#9-redeploying).

See `README.md` for the architecture (what is shared, what is per-app, and why).

**Budget ~45 minutes** for a first deploy, most of it waiting on DNS propagation
and two image builds.

- [1. Prerequisites](#1-prerequisites)
- [2. DNS](#2-dns)
- [3. Build and push the images](#3-build-and-push-the-images)
- [4. Update the VPS checkout](#4-update-the-vps-checkout)
- [5. Secrets](#5-secrets)
- [6. Pre-flight checks](#6-pre-flight-checks)
- [7. Start it](#7-start-it)
- [8. Bootstrap the first user](#8-bootstrap-the-first-user)
- [9. Redeploying](#9-redeploying)
- [10. Rollback](#10-rollback)
- [11. Troubleshooting](#11-troubleshooting)
- [Appendix A — env var reference](#appendix-a--env-var-reference)
- [Appendix B — what changes for qui-est-ce](#appendix-b--what-changes-for-qui-est-ce)

---

## 1. Prerequisites

- [ ] **RAM.** palais-divin adds a Spring Boot JVM, a Neo4j JVM and a Node server.
      The compose file caps them at 1 GB + 1 GB + 512 MB so they cannot OOM-kill
      qui-est-ce. Check headroom: `free -h`. You want **≥ 4 GB total** on the box.
- [ ] **Disk.** `df -h` — the two new images are ~400 MB, plus two new volumes.
- [ ] **GHCR login on the dev machine.** A GitHub PAT with `write:packages`:
      `docker login ghcr.io -u <github-username>`.
- [ ] **Docker with BuildKit** on the dev machine (default since Docker 23; the
      backend Dockerfile uses `--mount=type=cache`).
- [ ] **A `TERM` the VPS recognises.** If you SSH from a terminal whose terminfo
      entry is not in Fedora's database — Ghostty (`xterm-ghostty`), Kitty,
      WezTerm — `nano` dies with `ncurses: cannot initialize terminal type` and
      `less` degrades. Install your entry on the VPS once, from your machine:
      `infocmp -x "$TERM" | ssh fedora@<vps> -- tic -x -`. Stopgap on the VPS:
      `export TERM=xterm-256color`.

### 1.1 Read this file on the VPS

Once §4 is done this runbook is checked out there, so read it from disk rather
than copying commands out of a chat window or a rendered view — those indent
code blocks, and the indentation comes along with the copy.

```sh
cat DEPLOY-palais-divin.md          # or: less DEPLOY-palais-divin.md
```

Every command here is written to survive a sloppy paste: one command per line,
no heredocs, nothing that depends on leading whitespace.

---

## 2. DNS

Three new **A records**, all pointing at the VPS IP, all at the same value as the
existing `qui-est-qui.lepgu.fr` record:

| Name | Type | Value |
|------|------|-------|
| `palais-divin` | A | `<VPS IP>` |
| `api.palais-divin` | A | `<VPS IP>` |
| `s3.palais-divin` | A | `<VPS IP>` |

All three are load-bearing. Caddy cannot issue a certificate for a name that
does not resolve, and `s3.palais-divin.lepgu.fr` is not optional: the backend
mints MinIO presigned URLs against it and SigV4 signs the Host header, so the
browser must reach MinIO under exactly that name.

Wait for propagation before §7 — Let's Encrypt has rate limits and a failed
issuance burns an attempt:

```sh
for h in palais-divin api.palais-divin s3.palais-divin; do
  printf '%-22s %s\n' "$h" "$(dig +short $h.lepgu.fr)"
done
```

All three must print the VPS IP.

---

## 3. Build and push the images

**From the dev machine**, not the VPS. Both builds are self-contained: the
backend one compiles the jar itself, so no local Maven or Node run is needed.

```sh
# Backend — context is the repo ROOT, Dockerfile lives under src/main/docker/
cd ~/Documents/repos/GitHub/palais_divin-back
docker build -f src/main/docker/Dockerfile -t ghcr.io/fileboss/palais-divin-back:latest .
docker push ghcr.io/fileboss/palais-divin-back:latest

# Frontend
cd ~/Documents/repos/GitHub/palais_divin-front
docker build -t ghcr.io/fileboss/palais-divin-front:latest .
docker push ghcr.io/fileboss/palais-divin-front:latest
```

The first backend build takes a few minutes (it downloads the whole dependency
tree into the BuildKit cache mount); later ones reuse it.

**Push before the first `docker compose up -d`.** The services use
`pull_policy: always`, so a missing image aborts the entire `up` — including the
services qui-est-ce needs.

Sanity-check the backend image before shipping it:

```sh
docker run --rm ghcr.io/fileboss/palais-divin-back:latest --version 2>&1 | head -3
```

It should fail with a Spring startup error about missing datasource config —
that proves the entrypoint and the extracted layer layout work. A
`ClassNotFoundException: org.springframework.boot.loader.launch.JarLauncher`
means the layer extraction went wrong.

---

## 4. Update the VPS checkout

```sh
ssh <vps>
cd ~/qui-est-ce_infra        # adjust to wherever it is cloned
git pull
```

`git status` must be clean apart from `.env`, which is gitignored and stays
untouched by the pull.

---

## 5. Secrets

### 5.1 What you must NOT touch

Everything already in `.env` — `DB_*`, `KC_DB_*`, `KC_BOOTSTRAP_ADMIN_*`,
`KC_ADMIN_BASIC_AUTH_HASH`, `S3_*`, `OIDC_CLIENT_SECRET`,
`KEYCLOAK_ADMIN_SECRET`, `CORS_ALLOWED_ORIGINS`.

These are baked into live state: the Postgres volume's password, MinIO's root
credentials, the qui-est-ce realm's already-imported client secrets. Changing any
of them breaks the running site. palais-divin reuses `S3_ACCESS_KEY` /
`S3_SECRET_KEY` as-is (same MinIO, different bucket) and adds nothing else to the
shared set.

### 5.2 The five new values

Run this **on the VPS**, so the secrets are generated where they are used and
never travel:

```sh
cd ~/qui-est-ce_infra
echo "" >> .env
echo "PALAISDIVIN_DB_USERNAME=palaisdivin" >> .env
echo "PALAISDIVIN_DB_PASSWORD=$(openssl rand -hex 32)" >> .env
echo "PALAISDIVIN_NEO4J_PASSWORD=$(openssl rand -hex 32)" >> .env
echo "PALAISDIVIN_BACKEND_CLIENT_SECRET=$(openssl rand -hex 32)" >> .env
echo "PALAISDIVIN_SESSION_SECRET=$(openssl rand -base64 32)" >> .env
chmod 600 .env
```

One independent command per line, deliberately — not a heredoc. A heredoc needs
its `EOF` terminator at column 0, and pasted blocks routinely arrive indented
(most renderers indent code blocks), which leaves the shell stuck at a `>`
continuation prompt swallowing everything you type. `<<-EOF` does not help: it
strips leading **tabs**, not spaces. With one `>>` per line, indentation is
irrelevant and a mangled line can be rerun on its own.

Check the result before moving on:

```sh
tail -7 .env
```

Five `PALAISDIVIN_*` lines, each with a real value after the `=` — 64 hex
characters, or 44 base64 for the session secret. An empty value means `openssl`
did not run: delete those lines and retry.

The formats are not interchangeable:

| Var | Format | Why that format |
|-----|--------|-----------------|
| `PALAISDIVIN_DB_USERNAME` | plain | Not a secret. The Postgres **superuser** name — `V1__restaurant.sql` runs `CREATE EXTENSION postgis`, which needs superuser. |
| `PALAISDIVIN_DB_PASSWORD` | hex | No shell-special characters. |
| `PALAISDIVIN_NEO4J_PASSWORD` | hex | Interpolated into a single-quoted healthcheck (`cypher-shell -p '…'`), so a `'` would break it. Neo4j also rejects passwords under 8 chars. |
| `PALAISDIVIN_BACKEND_CLIENT_SECRET` | hex | See §5.3. |
| `PALAISDIVIN_SESSION_SECRET` | **base64** | This is the raw AES-256-GCM key, not a passphrase. `src/lib/server/session.ts` does `Buffer.from(secret,'base64')` and requires ≥32 decoded bytes. A hex string here decodes to the wrong bytes and *silently works*, which is worse than failing — and it is checked lazily on first login, not at boot, so the symptom is a broken login, not a crashed container. |

### 5.3 The one real trap

`PALAISDIVIN_BACKEND_CLIENT_SECRET` is substituted into
`keycloak/realm-palaisdivin-prod.json` **at first import only**. Set it before
the first `up` or Keycloak permanently stores whatever was there, empty string
included.

This is the **opposite direction** from the qui-est-ce flow in `README.md`, where
you regenerate the secret in the admin console and paste it back. Here you
generate first and Keycloak takes your value.

If it does get imported wrong, the backend refuses to start (`@NotBlank` on
`app.keycloak.client-secret`), so you find out immediately. Recovery: admin
console → **palaisdivin** realm → Clients → `palais-divin-backend` →
Credentials → Regenerate → paste into `.env` →
`docker compose up -d palaisdivin-back`.

### 5.4 If you ever lose `.env`

Every value is recoverable from the running containers:

```sh
docker compose exec back env | grep -E 'DB_|S3_|OIDC_|KEYCLOAK_'
docker compose exec keycloak env | grep -E 'KC_DB_|KEYCLOAK_ADMIN'
docker inspect $(docker compose ps -q caddy) --format '{{json .Config.Env}}'
```

---

## 6. Pre-flight checks

```sh
cd ~/qui-est-ce_infra

# 1. No placeholder left anywhere. Must print 0.
docker compose config | grep -c change_me

# 2. No empty palais-divin value. Every line must have something after the colon.
docker compose config | grep -E 'PALAISDIVIN|SESSION_SECRET'

# 3. Compose parses and the qui-est-ce services are unchanged.
docker compose config -q && echo "config ok"
```

Compose **warns** about unset variables but does not fail, which is exactly how
an empty secret reaches Keycloak's one-shot import. Do not skip check 2.

---

## 7. Start it

```sh
docker compose pull
docker compose up -d
```

`up -d` recreates only containers whose config changed: `keycloak` (second realm
import file mounted) and `caddy` (new vhosts), plus the four new services. Both
restarts take seconds. **The qui-est-ce realm is not re-imported** — Keycloak
skips realms that already exist.

### 7.1 Watch the new realm import

```sh
docker compose logs -f keycloak
```

Look for the `palaisdivin` realm being imported and `qui-est-ce` being skipped.
The authoritative check, once it settles:

```sh
curl -s https://auth.qui-est-qui.lepgu.fr/realms/palaisdivin/.well-known/openid-configuration \
  | head -c 200
```

A JSON document with `"issuer":"https://auth.qui-est-qui.lepgu.fr/realms/palaisdivin"`
means the realm exists and is reachable. A 404 means the import did not happen —
see §11.

### 7.2 Watch the backend come up

```sh
docker compose logs -f palaisdivin-back
```

Expect, in order: Flyway applying V1…V18 against an empty database, Hibernate
validating the schema, then `Started PalaisdivinBackendApplication`.

`docker compose ps` shows **no health status** for `palaisdivin-back` — that is
by design, the image is Distroless and has no shell to run a healthcheck with.
Use the endpoint instead:

```sh
curl -s https://api.palais-divin.lepgu.fr/actuator/health
```

### 7.3 Certificates

```sh
docker compose logs caddy | grep -i -E 'certificate|obtain|error'
```

Three new certificates are issued on first request to each hostname. A failure on
a `palais-divin` name does **not** affect the qui-est-ce vhosts.

### 7.4 Smoke test

```sh
./scripts/smoke-palais-divin.sh
```

Nine checks, read-only, no data written. `/auth/login → 302` is the interesting
one: it proves the frontend can fetch Keycloak's discovery document, which is the
single most common first-deploy failure.

The two authenticated checks are skipped unless `SMOKE_BEARER_TOKEN` is set —
see §8.4 for why that is deliberately awkward.

### 7.5 Confirm qui-est-ce is still fine

```sh
curl -sI https://qui-est-qui.lepgu.fr | head -1
curl -sI https://api.qui-est-qui.lepgu.fr | head -1
docker compose ps
```

Every service except `minio-init` (one-shot, exits 0) should be running.

---

## 8. Bootstrap the first user

palais-divin is invitation-only: `POST /api/v1/admin/invitations` needs an
`ADMIN` token and there is no self-service signup. The prod realm ships with **no
users**, unlike the dev realm. So the first account is made by hand.

### 8.1 Create a Keycloak user with the ADMIN role

Via `kcadm` inside the container (one command, so the admin token does not expire
between steps). Read the passwords into shell vars first so they stay out of
history:

```sh
read -rs -p 'bootstrap admin password: ' KCPW; echo
read -rs -p 'new user password: ' NEWPW; echo

docker compose exec -e KCPW="$KCPW" -e NEWPW="$NEWPW" keycloak sh -c '
  K=/opt/keycloak/bin/kcadm.sh
  $K config credentials --server http://localhost:8080 --realm master \
      --user admin --password "$KCPW" &&
  $K create users -r palaisdivin \
      -s username=philippe \
      -s enabled=true \
      -s emailVerified=true \
      -s email=you@example.com \
      -s firstName=Philippe \
      -s lastName=Philippe &&
  $K set-password -r palaisdivin --username philippe --new-password "$NEWPW" &&
  $K add-roles -r palaisdivin --uusername philippe --rolename ADMIN &&
  echo OK
'
unset KCPW NEWPW
```

Replace `--user admin` if `KC_BOOTSTRAP_ADMIN_USERNAME` is not `admin`.

Two Keycloak 26 gotchas this command works around:

- **`lastName` cannot be empty.** The declarative user profile rejects it, so set
  it even if you set it to the same value as `firstName`.
- **The password must be permanent.** `set-password` without `--temporary` is
  permanent; a temporary one produces "Account is not fully set up" and blocks
  the token flow.

Or click through the admin console: `https://auth.qui-est-qui.lepgu.fr` → log in
as the bootstrap admin → realm switcher → **palaisdivin** → Users → Add user →
Credentials tab (**Temporary: off**) → Role mapping → assign **ADMIN**.

> The admin console is IP-restricted in the `Caddyfile` (`/admin*` is only
> reachable from the home IP, everything else gets a 403). If your IP changed,
> update that block or you will get "Forbidden 403" instead of the login page.

### 8.2 Issue the first invitation

The access token never reaches the browser — the BFF holds it in the encrypted
`pd_session` cookie and injects it server-side. So you cannot copy it out of the
network tab. Call the endpoint **through the BFF** instead, which checks your
session carries the `ADMIN` role and attaches the bearer for you.

1. Open `https://palais-divin.lepgu.fr` and log in as the user from §8.1.
2. Open DevTools → Console, and run:

```js
await (await fetch('/api/v1/admin/invitations', { method: 'POST' })).json()
```

The response carries the signup link (`APP_INVITATION_SIGNUP_BASE_URL` +
`?token=…`, i.e. `https://palais-divin.lepgu.fr/register?token=…`).

A 403 means the `ADMIN` realm role did not land on the account — the BFF checks
`realm_access.roles` from the access token. Log out and back in after assigning
the role; roles are read at login.

### 8.3 Sign up for real

Open the signup link and complete the form.

**This is the account to actually use the app with.** Signup is what creates the
Postgres `users` row, and every `/api/v1/user/**` endpoint resolves the caller
through it. The hand-made Keycloak user from §8.1 has no such row, so it can
issue invitations but cannot rate, follow or recommend anything. Use a different
email than the §8.1 user, then keep §8.1 purely as the invitation-issuing admin.

Password policy: ≥8 characters, at least one letter and one digit (enforced by
the backend before Keycloak is even called).

### 8.4 Optional: a token for the smoke script

`palais-divin-frontend` is a public client with `directAccessGrantsEnabled:
false` in prod, so there is no password grant to mint a token with — on purpose,
it keeps a brute-forceable endpoint off a public client.

If you want the two authenticated smoke checks, flip it on temporarily:

```sh
# admin console → palaisdivin → Clients → palais-divin-frontend
#   → Settings → Authentication flow → tick "Direct access grants" → Save

TOKEN=$(curl -s https://auth.qui-est-qui.lepgu.fr/realms/palaisdivin/protocol/openid-connect/token \
  -d grant_type=password -d client_id=palais-divin-frontend \
  -d username=<user> -d password=<password> | sed 's/.*"access_token":"\([^"]*\)".*/\1/')

SMOKE_BEARER_TOKEN="$TOKEN" ./scripts/smoke-palais-divin.sh

# then untick it again
```

Do not leave it enabled.

### 8.5 Verify the whole loop

Through the UI, as the §8.3 account:

1. **Create a restaurant** — exercises Postgres + PostGIS + the BAN geocoder
   (outbound internet to `api-adresse.data.gouv.fr`).
2. **Post a review** — exercises the write path and the transactional outbox.
3. **Upload a photo** — the single riskiest new piece: it goes browser → presigned
   PUT → `s3.palais-divin.lepgu.fr`, straight past the backend.
4. **Open recommendations** — reads Neo4j, which is only populated if the outbox
   worker drained.

Then confirm the outbox actually drained, rather than trusting the UI:

```sh
docker compose exec palaisdivin-postgres \
  psql -U palaisdivin -d palaisdivin -c \
  "SELECT status, count(*) FROM outbox_event GROUP BY status;"
```

`PROCESSED` rows are healthy. Rows stuck in `PENDING` mean the worker is not
running; `FAILED` rows carry the reason in `last_error`. Cross-check the graph:

```sh
docker compose exec palaisdivin-neo4j \
  cypher-shell -u neo4j -p "$(grep PALAISDIVIN_NEO4J_PASSWORD .env | cut -d= -f2)" \
  "MATCH (n) RETURN labels(n)[0] AS label, count(*) AS n ORDER BY label;"
```

Expect `User`, `Restaurant` and whatever tags you attached. Neo4j is eventually
consistent by design — give it a few seconds, the worker polls on a schedule.

---

## 9. Redeploying

```sh
# dev machine
cd ~/Documents/repos/GitHub/palais_divin-back
docker build -f src/main/docker/Dockerfile -t ghcr.io/fileboss/palais-divin-back:latest .
docker push ghcr.io/fileboss/palais-divin-back:latest

# VPS
cd ~/qui-est-ce_infra
docker compose pull palaisdivin-back
docker compose up -d palaisdivin-back
docker compose logs -f palaisdivin-back      # watch Flyway apply any new migration
./scripts/smoke-palais-divin.sh
```

Same shape for `palaisdivin-front`. Naming the service matters: a bare
`docker compose up -d` also re-pulls and potentially restarts qui-est-ce.

If `Caddyfile`, `docker-compose.yml` or `.env` changed, `git pull` first, then
`docker compose up -d` (unnamed) so Caddy and Keycloak pick the changes up.

**Realm changes do not redeploy.** Editing `realm-palaisdivin-prod.json` has no
effect once the realm exists — `--import-realm` skips existing realms. Mirror the
change by hand in the admin console. This is the same trap documented in
`todo.md` for qui-est-ce.

---

## 10. Rollback

**An image**, if you tagged the previous one (do this — `:latest` alone gives you
nothing to roll back to):

```sh
docker compose pull palaisdivin-back
# pin the previous digest or tag in docker-compose.yml, then:
docker compose up -d palaisdivin-back
```

**The whole app**, leaving qui-est-ce untouched:

```sh
docker compose stop palaisdivin-front palaisdivin-back palaisdivin-neo4j palaisdivin-postgres
docker compose rm -f palaisdivin-front palaisdivin-back palaisdivin-neo4j palaisdivin-postgres
```

Caddy keeps serving the qui-est-ce vhosts; the `palais-divin` ones return 502.
To also drop the vhosts, comment out the `palais-divin` blocks in `Caddyfile` and
`docker compose up -d caddy`.

**The infra change**, entirely: `git revert` the commit, `docker compose up -d`.
Keycloak keeps the imported `palaisdivin` realm (harmless, it is simply unused)
and the two volumes stay on disk until you `docker volume rm` them.

A full teardown including data:

```sh
docker volume rm qui-est-ce_infra_palaisdivin_postgres_data \
                 qui-est-ce_infra_palaisdivin_neo4j_data
```

Check the real names first with `docker volume ls` — the prefix follows the
compose project name (the directory name).

---

## 11. Troubleshooting

### Keycloak never imported the palaisdivin realm

`curl …/realms/palaisdivin/.well-known/openid-configuration` returns 404.

- `docker compose exec keycloak ls /opt/keycloak/data/import/` — both JSON files
  must be there. If not, the bind mount path is wrong.
- The import only runs at startup. `docker compose restart keycloak` and watch
  the logs.
- A malformed JSON file is skipped with an error in the log; validate it with
  `python3 -c "import json;json.load(open('keycloak/realm-palaisdivin-prod.json'))"`.

### `palaisdivin-back` restart-loops

`docker compose logs palaisdivin-back` and match the first error:

| Error | Cause |
|-------|-------|
| `app.keycloak.client-secret must not be blank` | `PALAISDIVIN_BACKEND_CLIENT_SECRET` empty in `.env`. |
| `Failed to fetch remote JWK set` / connect timeout to `auth.qui-est-qui.lepgu.fr` | The container cannot reach the VPS's own public hostname — see below. |
| `FlywayValidateException`, `type "geography" does not exist` | The volume was initialised by a non-PostGIS image. `palaisdivin-postgres` must be `postgis/postgis`. |
| `Connection refused` to `palaisdivin-neo4j:7687` | Neo4j still starting; it has a 60s `start_period`. If it persists, check its own logs for a memory error against the 1 GB `mem_limit`. |
| `password authentication failed` | `PALAISDIVIN_DB_PASSWORD` was changed after the volume was created. The password lives in the volume; either restore the old value or drop the volume. |

### Container cannot reach the VPS's own public hostnames

Both backends need this (JWK set fetch, presigned URL host), and qui-est-ce
already relies on it, so it normally works. If hairpin NAT breaks, keep the
lookup inside the Docker bridge by giving Caddy network aliases:

```yaml
  caddy:
    networks:
      default:
        aliases:
          - auth.qui-est-qui.lepgu.fr
          - s3.palais-divin.lepgu.fr
```

TLS still validates — Caddy serves the real certificate for those names.

### Login loops back to the login page

- The realm client must whitelist `https://palais-divin.lepgu.fr/*` as a redirect
  URI (it does, in the shipped realm JSON — check it survived any hand-editing).
- `PUBLIC_ORIGIN` **and** `ORIGIN` must both be `https://palais-divin.lepgu.fr`.
- A wrong `PALAISDIVIN_SESSION_SECRET` format silently produces undecryptable
  cookies: `decryptSession` swallows the error and returns `null`, which reads as
  "not logged in". Must be base64 decoding to ≥32 bytes.

### Photo upload fails in the browser

- **Signature error** → `MINIO_ENDPOINT` must be the public
  `https://s3.palais-divin.lepgu.fr`. SigV4 signs the Host header, so a URL
  minted against `http://minio:9000` verifies nowhere.
- **Preflight (`OPTIONS`) blocked** → MinIO's CORS. It allows any origin by
  default and this stack leaves that alone; tightening
  `MINIO_API_CORS_ALLOW_ORIGIN` would apply to qui-est-ce's bucket too.
- **404 on the bucket** → `minio-init` did not run. It is a one-shot service:
  `docker compose up minio-init` and read its output.

### Restaurants exist but recommendations are empty

Neo4j is a derived read model fed by the outbox, not a second write target. Check
for stuck rows and the graph contents with the two queries in §8.5.

### Certificate errors

`docker compose logs caddy | grep -i error`. Let's Encrypt messages are verbatim:
rate limit, DNS not resolving, port 80 unreachable. Fix DNS first (§2) — retrying
into a rate limit just extends the wait.

---

## Appendix A — env var reference

Everything the palais-divin services read. "Where" is where the value is set.

| Var | Where | Value |
|-----|-------|-------|
| `PALAISDIVIN_DB_USERNAME` | `.env` | `palaisdivin` |
| `PALAISDIVIN_DB_PASSWORD` | `.env` | `openssl rand -hex 32` |
| `PALAISDIVIN_NEO4J_PASSWORD` | `.env` | `openssl rand -hex 32` |
| `PALAISDIVIN_BACKEND_CLIENT_SECRET` | `.env` | `openssl rand -hex 32`, before first import |
| `PALAISDIVIN_SESSION_SECRET` | `.env` | `openssl rand -base64 32` |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | `.env`, pre-existing | shared with qui-est-ce, do not change |
| `SPRING_PROFILES_ACTIVE` | compose | `prod` — switches logging to JSON and stops the dev seed data loading |
| `SPRING_DATASOURCE_URL` | compose | `jdbc:postgresql://palaisdivin-postgres:5432/palaisdivin` |
| `SPRING_NEO4J_URI` | compose | `bolt://palaisdivin-neo4j:7687` |
| `KEYCLOAK_ISSUER_URI` | compose | **public** `https://auth.qui-est-qui.lepgu.fr/realms/palaisdivin` — must match the `iss` claim |
| `KEYCLOAK_BASE_URL` | compose | **internal** `http://keycloak:8080` — Admin API only |
| `MINIO_ENDPOINT` | compose | **public** `https://s3.palais-divin.lepgu.fr` — see §11 |
| `MINIO_BUCKET` | compose | `palaisdivin-photos`, created by `minio-init` |
| `APP_INVITATION_SIGNUP_BASE_URL` | compose | `https://palais-divin.lepgu.fr/register` |
| `MANAGEMENT_TRACING_ENABLED` | compose | `false` — no OTLP collector on this VPS yet |
| `API_BASE_URL` | compose | **internal** `http://palaisdivin-back:8080` |
| `PUBLIC_ORIGIN` / `ORIGIN` | compose | `https://palais-divin.lepgu.fr`; `ORIGIN` is what adapter-node checks POSTs against behind a proxy |

Why some are public and some internal: anything the **browser** follows must be
public (`KEYCLOAK_ISSUER_URI`, `MINIO_ENDPOINT`, the origins), and anything only
the **server** calls stays internal (`API_BASE_URL`, `KEYCLOAK_BASE_URL`,
datasource, bolt).

---

## Appendix B — what changes for qui-est-ce

Nothing functional. Verified by diffing the resolved compose config:

- `front`, `back` — **byte-identical**.
- `postgres`, `minio` — unchanged.
- `keycloak` — one env var (`PALAISDIVIN_BACKEND_CLIENT_SECRET`) and one extra
  read-only mount. Recreated on `up`, back in seconds, qui-est-ce realm untouched.
- `minio-init` — one extra `mc mb` for the new bucket. Idempotent.
- `caddy` — recreated for the new vhosts. Existing vhosts and their certificates
  are unchanged; `caddy_data` keeps the certs across the restart.

Two deliberate isolation choices:

- Caddy does **not** `depends_on` the palais-divin services. It would tie Caddy's
  startup to them, so a bad palais-divin image could take qui-est-ce offline.
- Every new service carries a `mem_limit`, so none of them can OOM-kill the live
  site.
