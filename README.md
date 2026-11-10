# AGARI on a local k3d cluster

Helm charts (`charts/`), host-side scripts (`scripts/`) and two Dockerfiles
(`images/`) that bring the AGARI stack up on a single-node [k3d](https://k3d.io)
cluster backed by **rootless podman**.

Nothing outside this folder is modified: `../agari-platform` and
`../agari-frontend` are consumed as they are on disk (the SPA source is patched
inside the image build context only — see [Frontend](#frontend) below).

Deliberately *not* part of this stack: Song, Score, Maestro, Keycloak, Folio,
Arranger and Kafka. The platform in `../agari-platform` replaces Folio (object
storage + submissions) and Keycloak (its own OIDC surface), so those services
would only duplicate work. The SPA still has Song/Score URLs compiled in; they
point at the upstream staging deployment and are simply not exercised.

---

## What ends up running

| Chart | Workloads | Image | Role |
| --- | --- | --- | --- |
| `charts/postgres` | `deploy/agari-postgres` | `docker.io/library/postgres:17-alpine` | platform database (`agari`/`agari`) |
| `charts/minio` | `deploy/agari-minio`, bucket-setup Job | `docker.io/bitnamilegacy/minio:2025.5.24-debian-12-r5` | S3-compatible storage for uploads; creates the `agari-data` bucket |
| `charts/elasticsearch` | `deploy/agari-elasticsearch`, index-template Job | `docker.elastic.co/elasticsearch/elasticsearch:7.17.15` | search index (`agari-samples`); the Job pins `number_of_replicas: 0` so a single node reports `green` and applies the server's index body (`configs/agari-index-mapping.json`) |
| `charts/mailpit` | `deploy/agari-mailpit` | `docker.io/axllent/mailpit:v1.31.4` | mail catcher (SMTP + web inbox) that collects everything the platform mails — sign-in links, invitations |
| `charts/agari-platform` | `deploy/agari-platform-web` (gunicorn), `deploy/agari-platform-worker` (`manage.py agari_worker`), Job `agari-platform-migrate-<revision>` | `localhost/agari-platform:local` (built from `../agari-platform`) | the API, the background worker and the migrations/bootstrap |
| `charts/agari-frontend` | `deploy/agari-frontend` | `localhost/agari-frontend:local` (built from `../agari-frontend`) | the SPA, server-rendered by bun |
| `charts/agari-stack` | — | — | umbrella chart that wires the six above together |

The platform runs `config.settings.dev`, its worker listens on the
`default,submissions,search` queues, and the cluster has no TLS, one replica per
component and known passwords. **This is a development cluster, not a deployment
recipe.**

## Requirements

* Linux with cgroup v2 and rootless **podman 5.x** (tested on Fedora Kinoite 44).
* `k3d` ≥ 5.6, `kubectl`, `helm` (3.14+ or 4.x), `curl`, `python3` (used to patch
  the k3s binary), `tar`/`gzip` (used by `k3d image import`).
* Roughly 4 free CPUs, ~6 GiB of RAM and ~25 GiB of disk for the three volumes
  (8 GiB Postgres + 10 GiB MinIO + 4 GiB Elasticsearch).
* `vm.max_map_count >= 262144` for Elasticsearch:
  `sudo sysctl -w vm.max_map_count=1048576`.
* Host ports **8080** and **8443** free (override with `HTTP_PORT`/`HTTPS_PORT`);
  80/443 are avoided so nothing needs to run as root.
* `*.localhost` resolving to `127.0.0.1` — systemd's `nss-myhostname` and most
  glibc setups do this out of the box. If yours does not, add the six host
  names from the table below to `/etc/hosts`.

## Quick start

```sh
cd agari-stack

scripts/cluster-up.sh      # podman API + patched k3s node image + the k3d cluster
scripts/images-build.sh    # build agari-platform and agari-frontend, import them
scripts/deploy.sh          # helm upgrade --install --wait (migrations included)
scripts/verify.sh          # 28 checks, all through the ingress
```

`scripts/cluster-down.sh` deletes the cluster; `--stop-runtime` also stops the
podman API service that `cluster-up.sh` started. The images you imported stay in
podman, so the next `cluster-up.sh` needs no rebuild — but the cluster's volumes
(database, bucket, index) go away with it, so run `helm uninstall agari -n agari`
first if you want to keep them.

### URLs

| URL | What |
| --- | --- |
| <http://agari.localhost:8080/> | the SPA |
| <http://api.agari.localhost:8080/> | the API (`/docs/` swagger, `/admin/` Django admin) |
| <http://api.agari.localhost:8080/info/health> | API health |
| <http://minio.agari.localhost:8080/> | MinIO S3 API (presigned upload/download URLs point here) |
| <http://minio-console.agari.localhost:8080/> | MinIO console |
| <http://mailpit.agari.localhost:8080/> | Mailpit — the inbox of everything the platform mails (magic links, invitations) |
| <http://elastic.agari.localhost:8080/> | Elasticsearch (debug ingress, off by default in the chart; `values/k3d.yaml` enables it) |

### Credentials

| What | User | Password |
| --- | --- | --- |
| Platform administrator | `admin@agari.localhost` | `agari-admin` |
| Postgres | `agari` | `agari` |
| MinIO | `agari` | `agari12345` |
| Platform → SPA OIDC client (`dms`) | `dms` | `VDyLEjGR3xDQvoQlrHq5AB6OwbW0Refc` |

All of them live in `charts/agari-stack/values.yaml` and `values/k3d.yaml`; the
OIDC client secret is the one hardcoded in the SPA's own source, so the platform
has to accept exactly that pair.

### Try it

```sh
# a token the way the SPA asks for one
curl -s -H 'Host: api.agari.localhost' \
  -d 'grant_type=client_credentials&client_id=dms&client_secret=VDyLEjGR3xDQvoQlrHq5AB6OwbW0Refc' \
  http://127.0.0.1:8080/protocol/openid-connect/token | head -c 120

# as the administrator (all endpoints otherwise answer 401)
TOKEN=$(curl -s -H 'Host: api.agari.localhost' \
  -d 'grant_type=password&client_id=dms&client_secret=VDyLEjGR3xDQvoQlrHq5AB6OwbW0Refc&username=admin@agari.localhost&password=agari-admin&scope=openid' \
  http://127.0.0.1:8080/protocol/openid-connect/token | jq -r .access_token)
curl -s -H 'Host: api.agari.localhost' -H "Authorization: Bearer ${TOKEN}" \
  http://127.0.0.1:8080/projects/
```

### Seeding test data (optional)

`scripts/seed.sh` loads a throwaway fixture for testing roles — it is **not**
part of `deploy.sh`, so nothing on a real deployment ever runs it. It creates,
idempotently:

* two organisations: **National Institute for Communicable Diseases - RSA**
  (NICD) and **Kenya Medical Research Institute** (KEMRI);
* **one user per org role in each organisation** — the address says which is
  which: `nicd-org-owner@agari.localhost`, `nicd-org-admin@agari.localhost`,
  `kemri-org-viewer@agari.localhost`, … (4 roles × 2 orgs). The global roles
  (`system-admin@agari.localhost`, `agari-service-account@agari.localhost`)
  and project roles (`attr-project-admin@agari.localhost`, …) are a single
  account each;
* one pathogen + schema per file in `schemas/`, and one **public** project per
  schema dealt round-robin across the two orgs, each with all three
  `attr-project-*` members.

```sh
scripts/seed.sh                 # after scripts/deploy.sh
scripts/seed.sh --dry-run       # print the two kubectl commands, run nothing
```

The command itself is `manage.py seed_dev_data` (agari-platform): it refuses
to run when `DEBUG` is off unless you pass `--force`, so an accidental
production run fails loudly.

Every seeded user has the password `agari-seed` (override with
`AGARI_SEED_PASSWORD`) and `accepted_terms=True`, so both the magic-link flow
and `grant_type=password` work immediately — handy for sweeping through every
org role in both organisations:

```sh
for org in nicd kemri; do
  for role in org-owner org-admin org-contributor org-viewer; do
    user="${org}-${role}"
    TOKEN=$(curl -s -H 'Host: api.agari.localhost' \
      -d "grant_type=password&client_id=dms&client_secret=${DMS_SECRET:-VDyLEjGR3xDQvoQlrHq5AB6OwbW0Refc}&username=${user}@agari.localhost&password=agari-seed&scope=openid" \
      http://127.0.0.1:8080/protocol/openid-connect/token | jq -r .access_token)
    printf '%-24s %s\n' "${user}" "$(curl -s -H 'Host: api.agari.localhost' \
      -H "Authorization: Bearer ${TOKEN}" http://127.0.0.1:8080/info/whoami \
      | jq -c '.roles // .user.roles // empty')"
  done
done
```

The global and project roles use the same shape with their bare keys, e.g.
`system-admin@agari.localhost`, `attr-project-viewer@agari.localhost`.

### Signing in with a magic link

The SPA has no passwords. `http://agari.localhost:8080/login` asks for an email
address, the platform mails a single-use link that expires after ten minutes, and
clicking it signs you in. The mail never leaves the cluster: the stack runs
**Mailpit**, a mail catcher with an SMTP server and a web inbox, and the platform
is wired to it.

1. open <http://agari.localhost:8080/login>, type the address of an **existing**
   user (`admin@agari.localhost`, or one you created through the API) and click
   *Continue* — an unknown address gets no mail, by design;
2. open <http://mailpit.agari.localhost:8080/>; the message is at the top of the
   list, and the link inside it is the one that signs you in;
3. click it. The link points at the SPA's root (`/?userid=…&code=…`) and lands you
   on `/projects` as a signed-in user.

The same round trip, scriptable — it is what `scripts/verify.sh` does:

```sh
# what the login screen does: resolve the address, then ask for a link (needs
# a client_credentials token, see "Try it" above)
curl -s -H 'Host: api.agari.localhost' -H 'Content-Type: application/json' \
  -d '{"email":"admin@agari.localhost"}' http://127.0.0.1:8080/info/userid

curl -s -H 'Host: api.agari.localhost' -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@agari.localhost","redirect_uri":"http://agari.localhost:8080"}' \
  http://127.0.0.1:8080/users/

# Mailpit's own API - list messages, or read the newest one (the Text body
# HTML-escapes the ampersands, so unescape before reusing the link)
curl -s -H 'Host: mailpit.agari.localhost' http://127.0.0.1:8080/api/v1/messages
curl -s -H 'Host: mailpit.agari.localhost' http://127.0.0.1:8080/api/v1/message/latest
```

Two things that cost time if you do not know them:

* `redirect_uri` has to be the SPA's **origin** (`http://agari.localhost:8080`),
  not a path. The platform prepends it verbatim to
  `?userid=…&token=…&code=…`, and only the SPA's root route exchanges `code=`;
  a link carrying `/login` leaves you looking at the login form with the code
  still in the address bar. `verify.sh` asserts the mailed link targets the
  origin.
* Mailpit keeps everything in memory: at most `mailpit.maxMessages` (500)
  messages, and nothing survives a pod restart.

To hand the mail to something real instead, set `mailpit.enabled=false` and point
`agari-platform.config.email.{host,port,username,useTls,useSsl,defaultFrom}` (and
`agari-platform.secret.emailPassword`) at that server.

## Layout

```
agari-stack/
├── charts/
│   ├── agari-stack/      umbrella chart: dependencies + the wiring between them
│   ├── agari-platform/   API, worker, migration Job, config/secret, ingress
│   ├── agari-frontend/   SPA (bun SSR server) + ingress
│   ├── postgres/         single-replica Postgres + PVC
│   ├── minio/            MinIO + PVC + bucket-setup hook Job + ingresses
│   ├── elasticsearch/    single-node Elasticsearch + PVC + index-template Job (+ ingress)
│   └── mailpit/          mail catcher: SMTP sink + web inbox + ingress
├── values/k3d.yaml       overlay installed by scripts/deploy.sh (admin user, debug ingress)
├── scripts/              cluster-up, images-build, deploy, verify, cluster-down
│                         (+ _common.sh, build-k3s-image.sh, patch-validate-cgroups.py)
├── images/               Dockerfile.frontend (SPA), Dockerfile.k3s (patched node)
├── cluster/containers.conf   podman config that makes rootless k3d work
└── build/                scratch: k3s binary extracted and patched here
```

Every chart is standalone: `helm template charts/postgres --set persistence.size=1Gi`
renders on its own, and the umbrella chart only sets names, credentials and
host names that have to agree between two components.

## Configuration

Values are read bottom-up:

1. `charts/<component>/values.yaml` — a working default for every knob.
2. `charts/agari-stack/values.yaml` — the *wiring*: service names, credentials
   shared by two components, host names, images.
3. `values/k3d.yaml` — what is specific to a throwaway local cluster (an
   administrator to log in with, the Elasticsearch debug ingress).
4. anything you pass with `-f`/`--set`.

To change something without editing the repo:

```sh
cat > my-values.yaml <<'YAML'
agari-platform:
  config:
    externalPort: 9090        # keep in sync with HTTP_PORT
  secret:
    adminPassword: hunter2
minio:
  persistence:
    size: 2Gi
YAML

helm upgrade --install agari charts/agari-stack -n agari --create-namespace \
  -f values/k3d.yaml -f my-values.yaml --wait --timeout 15m
```

The scripts honour the same knobs through the environment (`HTTP_PORT`,
`HTTPS_PORT`, `CLUSTER_NAME`, `RELEASE`, `NAMESPACE`, `API_HOST`, `SPA_HOST`,
`MINIO_HOST`, `ELASTIC_HOST`, `MAILPIT_HOST`, `PLATFORM_DIR`, `FRONTEND_DIR`,
`HELM_TIMEOUT`, …). See `scripts/_common.sh` for the full list.

Each bundled dependency can be replaced by something outside the cluster with
`postgres.enabled=false` / `minio.enabled=false` / `elasticsearch.enabled=false` /
`mailpit.enabled=false` plus the matching `agari-platform.config.*` (or
`agari-platform.secret.*`) overrides — for the mail catcher that means
`agari-platform.config.email.*` and `agari-platform.secret.emailPassword`. With
`mailpit.enabled=false` the umbrella's SMTP wiring has nowhere to go, so either
point `config.email.host` at a relay of your own or set `config.email.backend`
back to the chart default, `django.core.mail.backends.console.EmailBackend`,
which only prints the mail into the web pod's log.

Search indices are created by the platform itself (one per model, `agari-samples`
for isolates), which means they inherit Elasticsearch's default of one replica —
unallocatable on a single node, hence a permanently `yellow` cluster. A small
post-install Job (`charts/elasticsearch/templates/index-template-job.yaml`)
therefore writes a composable index template for `agari-*` and aligns existing
indices. Turn it off, or scale it up, with:

```yaml
elasticsearch:
  indexDefaults:
    enabled: true
    numberOfReplicas: 0   # >0 only with more than one Elasticsearch node
```

## Migrations, roles and the first administrator

`helm install --wait` would deadlock if migrations ran as a `post-install` hook:
Helm waits for the Deployments to become ready *before* running post-install
hooks, and the worker cannot become ready before the schema exists. The stack
solves it the other way around:

* the migration Job is an ordinary resource, created in the same pass as the
  Deployments. Its name carries the revision (`agari-platform-migrate-1`,
  `-2`, …) because a Job spec is immutable, and it deletes itself a day after
  finishing (`migrations.ttlSecondsAfterFinished`).
* `web` and `worker` have a `wait-for-schema` init container that polls
  `python manage.py migrate --check` until it exits 0 (up to
  `migrations.waitForSchemaSeconds`). It also covers "the database is still
  starting".

The Job runs `migrate`, then `sync_roles` (RBAC groups from the permission
registry) and, when `bootstrap.adminEmail` is set, `bootstrap_admin`.

```sh
kubectl -n agari get pods,jobs
kubectl -n agari logs -l app.kubernetes.io/component=migrate --tail=50
```

Set `bootstrap.adminEmail` (and `secret.adminPassword`) in an overlay file, never
on the command line — a `--set` password ends up in the shell history and in the
release's stored values.

## Working on the stack afterwards

```sh
# after editing application code
scripts/images-build.sh platform      # or: frontend, or no argument for both
kubectl -n agari rollout restart deploy/agari-platform-web deploy/agari-platform-worker
kubectl -n agari logs -f deploy/agari-platform-web

# after editing a chart
helm dependency update charts/agari-stack   # re-packages charts/* into the umbrella!
scripts/deploy.sh
```

The images keep the tag `:local`, so importing a rebuilt image does **not**
restart the running pods by itself; the `rollout restart` above is what picks the
new image up. `helm dependency update` matters because the umbrella chart renders
from its own `charts/` copy, not from `charts/<component>` — and because a local
`file://` subchart is only re-packaged by `update`, not by `build`.

Useful one-offs (no ports are published for the databases):

```sh
kubectl -n agari port-forward svc/agari-postgres 5432:5432
kubectl -n agari exec -it deploy/agari-platform-web -c web -- python manage.py shell
kubectl -n agari exec deploy/agari-postgres -- psql -U agari -d agari -c '\dt'
```

## Data, and how to get rid of it

The volumes are `local-path` PVCs named `agari-postgres-data`,
`agari-minio-data` and `agari-elasticsearch-data`, stored inside the k3s node
container. They are annotated `helm.sh/resource-policy: keep`, so
`helm uninstall` leaves the data behind; `deploy.sh` reattaches it.

```sh
# start over with an empty database / bucket / index
helm uninstall agari -n agari
kubectl -n agari delete pvc -l app.kubernetes.io/instance=agari

# or wipe everything, including the cluster
scripts/cluster-down.sh
```

## Frontend

`images/Dockerfile.frontend` builds `../agari-frontend` the way upstream's own
Dockerfile does (bun install → `bun run build` → `bun run serve`), with two
build-time patches applied to the *copy* of the source:

1. `src/constants/serviceUrls.ts` hardcodes the `openup.org.za` endpoints. The
   `folio` and `keycloak` entries are rewritten to `AGARI_API_ORIGIN` (Song and
   Score are left alone — this stack does not run them), so the SPA talks to the
   local platform for auth, projects, uploads and search. The platform data path
   is `folioApi` (baseURL = `serviceUrls.folio`); `songApi`/`scoreApi`/
   `arrangerApi` only serve the study/analysis screens, which need the services
   this stack deliberately omits.
2. `src/services/authService.ts` appends `/realms/agari` to the Keycloak URL.
   The platform serves its OIDC surface at the root, so the prefix is dropped.

The patch is driven by `--build-arg AGARI_API_ORIGIN=...`; leaving it empty
builds the unmodified upstream client. `scripts/verify.sh` follows the client
bundle through the ingress and fails if it does not contain the local API host.
`env.agariEnv: staging` in the umbrella values selects which baked-in URL set the
SSR server reports.

## Rootless podman: the four things that had to be worked around

Everything here assumes podman without root, where k3d needs a few nudges. They
are already wired into `scripts/cluster-up.sh`; this is what they are for.

1. **`cluster/containers.conf`** (`[containers] cgroupns = "private"`). k3d asks
   podman's Docker-compatible API for a container with an empty
   `HostConfig.CgroupnsMode`; podman then falls back to the *host* cgroup
   namespace and a rootless k3s container dies instantly without logs. The
   scripts start a dedicated `podman system service` on
   `/tmp/agari-podman/podman.sock` with `CONTAINERS_CONF_OVERRIDE` pointing at
   this file, so your own `~/.config/containers/containers.conf` is untouched.
   `_common.sh` exports `DOCKER_HOST` for k3d and kubectl, and `DOCKER_SOCK`
   (see 4).
2. **A patched k3s binary** (`images/Dockerfile.k3s` +
   `scripts/patch-validate-cgroups.py`). k3s's cgroup v2 preflight check insists
   on a delegatable `cpuset` controller in the container's cgroup root, which a
   rootless container does not have. The check is patched out of the binary and
   the result is built as `localhost/agari-k3s:<version>-patched`.
3. **The k3d entrypoint scripts are baked into the node image**
   (`images/k3d-fixes/`). k3d normally writes them into the container as a
   pre-start hook; through podman's API those writes do not reliably land, and
   without them the container has no entrypoint at all
   (`catatonit: failed to exec pid1`). The baked-in copies are byte-identical to
   k3d's, so k3d overwriting them is harmless.
4. **`DOCKER_SOCK` for the k3d-tools node.** k3d starts a short-lived helper
   container (`k3d-<cluster>-tools`) whenever it creates or starts a cluster, and
   bind-mounts `GetRuntimePath()` into it. That path comes from `DOCKER_SOCK`,
   which defaults to `/var/run/docker.sock`; rootless podman cannot create that
   mount source and `k3d cluster create/start` dies with
   `mkdir /var/run/docker.sock: permission denied`. `_common.sh` sets
   `DOCKER_SOCK` to the podman socket, so k3d mounts something that exists.

`k3d image import` uses `--mode direct` from the scripts: it streams the image
into the node's containerd and skips the tools node entirely.

## Verifying

`scripts/verify.sh` walks the stack the way a user does — through the ingress, by
host name — and exits non-zero on failure:

* seven workloads rolled out (Mailpit is only reported on when it is installed),
  the newest migration Job complete;
* `/info/health`, `/docs/`, `/.well-known/openid-configuration`, the admin login
  form;
* a `client_credentials` token for the SPA's client id, and `GET /info/whoami`
  resolving it to a user (a token the API cannot resolve is what breaks the
  browser's login, so both halves are checked);
* Mailpit answering, the platform's `EMAIL_*` configuration pointing at it, and
  the **whole magic-link round trip**: mint a link as the administrator, read the
  mail back out of Mailpit, check the link targets the SPA origin, exchange its
  `code=` and resolve the token via `/info/whoami`;
* MinIO live, its console answering, and `agari-data` present on its volume;
* Elasticsearch up, its cluster health and the `agari-*` index settings (the
  index-template Job sets `number_of_replicas: 0`, so a single node is `green`; a
  `yellow` health is reported as a warning, not a failure);
* the SPA rendering, and its client bundle pointing at `api.agari.localhost`.

The deeper check — an isolate going database → task queue → worker →
Elasticsearch — can be repeated with any authenticated write; the worker logs are
the place to watch:

```sh
kubectl -n agari logs -f deploy/agari-platform-worker
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| node container exits immediately, no logs | the podman API was not started with `cluster/containers.conf` — use `scripts/cluster-up.sh` instead of `k3d cluster create` |
| `k3d ... failed to run k3d-tools node ... mkdir /var/run/docker.sock: permission denied` | k3d was run outside the scripts, without `DOCKER_SOCK` pointing at the podman socket; `_common.sh` exports it |
| `error: do not run this with sudo` (or `k3d not found in PATH` under sudo) | the stack is rootless: run the scripts as your own user, never with `sudo` |
| `ImagePullBackOff` on `localhost/agari-*` | the image was never imported: `scripts/images-build.sh` (needs the cluster to exist) |
| pods stuck in `wait-for-schema` init | the migration Job failed: `kubectl -n agari logs -l app.kubernetes.io/component=migrate` |
| `helm ... --wait` times out | `kubectl -n agari get pods,events --sort-by=.lastTimestamp` |
| Elasticsearch `OOMKilled` / exit 137 | raise the container limit in `charts/elasticsearch/values.yaml` and check `vm.max_map_count` |
| downloads 403 / SPA cannot reach the API | `agari-platform.config.externalPort`, `objectStorage.publicEndpoint` and `frontendUrl` have to match what the browser uses (`:8080`) |
| `*.localhost` does not resolve | add the six host names to `/etc/hosts` |
| login link never arrives | Mailpit is installed but the platform is not pointed at it, or the address has no account (the platform only mails users it knows). `kubectl -n agari get configmap agari-platform -o jsonpath='{.data.EMAIL_HOST}'` should print `agari-mailpit`; the inbox is <http://mailpit.agari.localhost:8080/> |
| clicking the mailed link leaves you on the login form | the link was built from a `redirect_uri` with a path (`/login`); it has to be the SPA origin, because only `/` exchanges `code=`. `verify.sh` asserts the mailed link targets the origin |
| login ends with `Token contained no recognizable user identification`, or the SPA has no user after a magic link | the platform is older than the `client_credentials`/`authorization_code` support: `scripts/verify.sh` checks that the SPA's token resolves via `/info/whoami`, and the link must carry `code=` |
| re-install complains about an existing resource | a previous release left it behind: `helm uninstall agari -n agari` and delete leftover PVCs/Jobs |

## Known issues

* **`POST /search/` returns a 500** (*pre-existing upstream bug*, not caused by
  these charts). `elasticsearch-py` 8.x returns an `ObjectApiResponse`, which the
  platform's `AgariJSONEncoder` (`apps/core/renderers.py`) cannot serialise:
  `TypeError: Object of type ObjectApiResponse is not JSON serializable`. It
  reproduces against upstream's own `deploy/docker/compose.yaml` (Elasticsearch
  7.17.15 + `elasticsearch==8.18.0`). The fix is one line in
  `apps/search/backend.py::search()` — return the body instead of the response
  object, i.e. `return dict(client.search(index=self.index, body=body))`.
  Indexing (the worker path) is unaffected.
* Elasticsearch runs as a single node. The index template the chart installs
  (`elasticsearch.indexDefaults`) keeps indices at zero replicas so the cluster
  can report `green`; if you delete the template, new indices go back to one
  replica and the health turns `yellow` without anything being broken. This
  includes indices created before the template existed — the Job patches them,
  so `helm upgrade` is enough to get back to `green`.
* The SPA is built with `AGARI_ENV=staging`, i.e. it reports the staging
  environment and keeps its Song/Score URLs pointing upstream.
* The charts intentionally use plain HTTP, fixed passwords and one replica each.
  Do not reuse them outside a local cluster.
