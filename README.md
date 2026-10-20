
A minimal, self-contained bookstore REST API where **Valkey is the only datastore** — no relational database. Purpose-built to demonstrate the [SAP valkey-operator](https://github.com/SAP/valkey-operator) on a local [kind](https://kind.sigs.k8s.io/) cluster, running with **Sentinel** and **TLS** both enabled by default.

> **Sentinel** and **TLS** are both enabled by default. The [scripts/](scripts/) folder automates the whole flow (deploy, seed, test, remove); the sections below also give the manual equivalents.

## What's in the box

| Component | Tech | Purpose |
|-----------|------|---------|
| [app/main.py](app/main.py) | Python 3.12 + FastAPI + `valkey-py` 6 | Bookstore CRUD REST API — Sentinel + TLS aware |
| [k8s/app.yaml](k8s/app.yaml) | ConfigMap + Deployment + Service | Bookstore API on k8s — Sentinel + TLS env, `/certs` cert mount, and a `wait-for-tls-cert` init container |
| [k8s/valkey-operator/own-valkey.yaml](k8s/valkey-operator/own-valkey.yaml) | `cache.cs.sap.com/v1alpha1` Valkey CR | The operator-managed Valkey used by this demo (sentinel + TLS on) |
| [k8s/valkey-operator/valkey-cr.yaml](k8s/valkey-operator/valkey-cr.yaml) | Generic CR template | Reference only — for adapting to other operators |
| [k8s/valkey.yaml](k8s/valkey.yaml) | `valkey/valkey:8-alpine` | Optional baseline (plain Deployment, **not** wired into kustomize) |
| [scripts/](scripts/) | bash + curl + kubectl | `deploy.sh`, `add-data-to-valkey.sh`, `test-api.sh`, `delete-data-from-valkey.sh`, `remove.sh` — automate deploy/seed/test/cleanup |

## How the operator provisions Valkey

The SAP valkey-operator reconciles the `Valkey` CR by rendering the upstream **Bitnami Valkey Helm chart**, but overrides the container images to the official **[valkey.io](https://valkey.io/) `valkey/valkey`** images instead of Bitnami's. A small `bitnami-libs` ConfigMap shim supplies the shell helpers (and an `openssl`→`sha1sum` shim) that the chart's Sentinel scripts expect but that the minimal `valkey/valkey` image does not ship. This is all driven by the operator's `pkg/operator/data/parameters.yaml` (see the [SAP valkey-operator](https://github.com/SAP/valkey-operator)) — no fork of the chart. The demo's CR requests Valkey **9.1.2** (`spec.version`) with 3 replicas ([own-valkey.yaml](k8s/valkey-operator/own-valkey.yaml)).

## Data model in Valkey

Books are stored using native Valkey data structures — no JSON blobs, no serialization library:

```
book:{isbn}         → Hash    { isbn, title, author, year, price, description }
books               → Set     of all ISBNs  (used for LIST ALL)
books:author:{name} → Set     of ISBNs per author  (secondary index)
```

---

## Prerequisites

```
git
kind     >= 0.23   https://kind.sigs.k8s.io/docs/user/quick-start/#installation
kubectl  >= 1.28
docker
go       >= 1.23   # only to run the valkey-operator locally via `make run`
```

---

## Quick start (Sentinel + TLS via the operator)

End-to-end from an empty machine: clone the repo, spin up a local kind cluster, run
the valkey-operator, and deploy the bookstore app. The single-command
[scripts/deploy.sh](scripts/deploy.sh) covers steps 4–onward; the manual equivalents
are shown for clarity.

### 1. Clone the repository

```bash
git clone https://github.tools.sap/I344017/bookstore-valkey.git
cd bookstore-valkey
```

### 2. Create the kind cluster

```bash
# Simple (access via kubectl port-forward)
kind create cluster --name bookstore

# Or with a host port mapping so the API is reachable at localhost:8080
# without port-forward (see the notes inside kind-config.yaml)
kind create cluster --name bookstore --config kind-config.yaml
```

### 3. Install the valkey-operator (CRD + controller)

This demo requires the variant of the [SAP valkey-operator](https://github.com/SAP/valkey-operator)
that overrides the container images to the official [valkey.io](https://valkey.io/)
`valkey/valkey` images (driven by the operator's `pkg/operator/data/parameters.yaml`).
The unmodified upstream deploys Bitnami images instead.

Clone that operator and install its CRD, then run the controller against your kind
cluster. Running it **out-of-cluster** is the simplest path — it uses your current
kubeconfig, so it targets the kind cluster automatically:

```bash
git clone https://github.com/SAP/valkey-operator.git
cd valkey-operator

# Install the Valkey CRD (cache.cs.sap.com/v1alpha1)
kubectl apply -f crds/cache.cs.sap.com_valkeys.yaml

# Run the controller in the foreground — keep this terminal open for the rest of the demo
make run
```

`make run` reconciles the `Valkey` CR and creates the StatefulSet, Services, Secrets
and ConfigMaps in-cluster. Leave it running and continue in a second terminal (back in
the `bookstore-valkey` directory).

> **In-cluster alternative:** build and load a controller image instead of `make run`:
> `make docker-build IMG=valkey-operator:latest`,
> `kind load docker-image valkey-operator:latest --name bookstore`, then deploy it as a
> Deployment in the cluster.

### 4. Deploy the bookstore app + Valkey CR

[scripts/deploy.sh](scripts/deploy.sh) does the whole app rollout: build the image,
load it into kind, `kubectl apply -k k8s/` (namespace + the `Valkey` CR
[own-valkey.yaml](k8s/valkey-operator/own-valkey.yaml) + the app), wait for the
operator's password secret (and, when TLS is on, the cert secret), then restart the
app so it picks up both:

```bash
./scripts/deploy.sh
```

<details>
<summary>Manual equivalent (what deploy.sh runs)</summary>

```bash
# Build and load the app image into kind
docker build -t bookstore-api:latest ./app
kind load docker-image bookstore-api:latest --name bookstore

# Apply namespace + Valkey CR + app together
kubectl apply -k k8s/

# Wait for the operator to reconcile the CR
kubectl -n bookstore wait --for=create secret/valkey-valkey --timeout=300s
# When TLS is enabled, also wait for the cert secret
kubectl -n bookstore wait --for=create secret/valkey-valkey-crt --timeout=300s

# Restart so the app picks up the credentials and CA cert
kubectl rollout restart deployment/bookstore -n bookstore
kubectl rollout status  deployment/bookstore -n bookstore
```

</details>

The app's `wait-for-tls-cert` init container also blocks startup until `/certs/ca.crt`
is present, so the restart is safe even if the cert secret lands a moment later.

### 5. Access the API

```bash
kubectl port-forward -n bookstore svc/bookstore 8080:80
```

The API is now available at **http://localhost:8080**

- Swagger UI: http://localhost:8080/docs
- Health check: http://localhost:8080/health

> If you created the cluster with `kind-config.yaml`, you can skip the port-forward by
> patching the Service to `NodePort` instead — see the notes inside `kind-config.yaml`.

### 6. Seed sample data

```bash
./scripts/add-data-to-valkey.sh
```

### 7. Try the API

```bash
# List all books
curl http://localhost:8080/books | python3 -m json.tool

# Get one book by ISBN
curl http://localhost:8080/books/9780743273565

# Get books by author (case-insensitive)
curl "http://localhost:8080/books/author/Harper%20Lee"

# Create a new book
curl -X POST http://localhost:8080/books \
  -H "Content-Type: application/json" \
  -d '{"isbn":"9780385490818","title":"The Handmaid'\''s Tale","author":"Margaret Atwood","year":1985,"price":12.99,"description":"A dystopian novel set in a totalitarian theocracy."}'

# Update a book (partial)
curl -X PUT http://localhost:8080/books/9780385490818 \
  -H "Content-Type: application/json" \
  -d '{"price": 10.99}'

# Delete a book
curl -X DELETE http://localhost:8080/books/9780385490818
```

---

## How the app connects to Valkey

The app reads its connection settings from the `bookstore-config` ConfigMap and the operator-created secrets ([k8s/app.yaml](k8s/app.yaml)). Both Sentinel and TLS are **enabled by default** in this demo.

| Variable | Source | Description |
|----------|--------|-------------|
| `VALKEY_SENTINEL_ENABLED` | ConfigMap | `"true"` → connect via Sentinel (default) |
| `VALKEY_SENTINEL_HOSTS` | ConfigMap | Comma-separated `host:port` of Sentinel nodes (`valkey-valkey:26379`) |
| `VALKEY_SENTINEL_MASTER_NAME` | ConfigMap | Sentinel master group name (`myprimary`) |
| `VALKEY_TLS_ENABLED` | ConfigMap | `"true"` → connect over TLS (default) |
| `VALKEY_TLS_CA_CERT` | ConfigMap | Path to CA cert inside the pod (`/certs/ca.crt`) |
| `VALKEY_HOST` / `VALKEY_PORT` | ConfigMap | Direct primary endpoint — used only when Sentinel is disabled |
| `VALKEY_PASSWORD` | Secret `valkey-valkey` key `valkey-password` | Auto-generated by the operator |

The CA certificate is mounted into the bookstore app pod from the operator-created secret `valkey-valkey-crt` at `/certs` (the volume is `optional: true`, so the pod still starts if TLS is off). Because the operator generates that secret asynchronously, the Deployment includes a `wait-for-tls-cert` init container that blocks app startup until `/certs/ca.crt` exists whenever `VALKEY_TLS_ENABLED=true` (a no-op when TLS is off). The `/health` endpoint reports the active mode:

```json
{
  "status": "ok",
  "valkey": "sentinel://valkey-valkey:26379 master=myprimary",
  "sentinel": true,
  "tls": true,
  "books_in_store": 8
}
```

### What the operator creates (from `own-valkey.yaml`, sentinel + TLS)

| Resource | Name | Notes |
|----------|------|-------|
| StatefulSet | `valkey-valkey-node` | 3 node pods (`valkey-valkey-node-0..2`), each with `valkey` + `sentinel` + `metrics` containers |
| Service | `valkey-valkey` | Exposes **both** Valkey (TCP 6379) and Sentinel (TCP 26379) — the app connects here |
| Service | `valkey-valkey-headless` | Headless service backing the StatefulSet |
| Service | `valkey-valkey-node-0..2` | Per-node services (stable per-pod addressing for Sentinel) |
| Service | `valkey-valkey-metrics` | redis_exporter metrics endpoint (TCP 9121) |
| ConfigMap | `valkey-valkey-bitnami-libs` | Shell-library shims for the Sentinel start scripts (sentinel mode only) |
| Secret | `valkey-valkey` | Contains `valkey-password` |
| Secret | `valkey-valkey-binding` | Full connection binding |
| Secret | `valkey-valkey-crt` | `ca.crt` / `tls.crt` / `tls.key` — only when `tls.enabled: true` |

> **Note:** `valkey-valkey-primary` / `valkey-valkey-replicas` services exist **only** when Sentinel is disabled. In sentinel mode (the default here) the single `valkey-valkey` service carries both the Valkey and Sentinel ports.

### Inspect Valkey directly (with TLS)

The Valkey node pods mount the TLS certs at **`/opt/bitnami/valkey/certs/`** (the chart's path — different from the `/certs` path the bookstore app pod uses).

```bash
# Fetch the auto-generated password
VALKEY_PASS=$(kubectl get secret valkey-valkey -n bookstore \
  -o jsonpath='{.data.valkey-password}' | base64 -d)

# Ping the datastore (valkey container, port 6379) over TLS
kubectl exec -it -n bookstore valkey-valkey-node-0 -c valkey -- \
  valkey-cli --tls --cacert /opt/bitnami/valkey/certs/ca.crt -a "$VALKEY_PASS" ping

# Open an interactive shell:
kubectl exec -it -n bookstore valkey-valkey-node-0 -c valkey -- \
  valkey-cli --tls --cacert /opt/bitnami/valkey/certs/ca.crt -a "$VALKEY_PASS"

# Inside valkey-cli:
SMEMBERS books
HGETALL book:9780743273565
SMEMBERS "books:author:j.r.r. tolkien"
INFO keyspace

# Sentinel status (sentinel container listens on 26379):
kubectl exec -it -n bookstore valkey-valkey-node-0 -c sentinel -- \
  valkey-cli --tls --cacert /opt/bitnami/valkey/certs/ca.crt -p 26379 -a "$VALKEY_PASS" \
  sentinel master myprimary
```

> If TLS is disabled in the CR, omit the `--tls` and `--cacert` flags.

---

## Toggling Sentinel / TLS

Both are on by default. To change a mode, keep the app ConfigMap and the CR in sync.

**Disable Sentinel** (use the direct primary):

- [k8s/app.yaml](k8s/app.yaml) ConfigMap → `VALKEY_SENTINEL_ENABLED: "false"`, `VALKEY_HOST: "valkey-valkey-primary"`, `VALKEY_PORT: "6379"`
- [k8s/valkey-operator/own-valkey.yaml](k8s/valkey-operator/own-valkey.yaml) → `sentinel.enabled: false`

**Disable TLS:**

- [k8s/app.yaml](k8s/app.yaml) ConfigMap → `VALKEY_TLS_ENABLED: "false"`
- [k8s/valkey-operator/own-valkey.yaml](k8s/valkey-operator/own-valkey.yaml) → `tls.enabled: false`

---

## Baseline without the operator (optional)

[k8s/valkey.yaml](k8s/valkey.yaml) is a plain `valkey/valkey:8-alpine` Deployment + Service (no Sentinel, no TLS). It is **not** referenced by [kustomization.yaml](k8s/kustomization.yaml). To run the app against it instead of the operator, add `valkey.yaml` to the kustomization `resources`, remove `valkey-operator/own-valkey.yaml`, and set the ConfigMap to `VALKEY_SENTINEL_ENABLED: "false"` / `VALKEY_TLS_ENABLED: "false"` with `VALKEY_HOST: "valkey"`.

---

## Project structure

```
bookstore-valkey/
├── app/
│   ├── main.py               # FastAPI bookstore (valkey-py; Sentinel + TLS aware)
│   ├── requirements.txt      # pinned deps (valkey==6.0.2)
│   └── Dockerfile
├── k8s/
│   ├── namespace.yaml
│   ├── app.yaml              # ConfigMap (Sentinel + TLS) + Deployment + Service
│   ├── kustomization.yaml    # wires namespace + own-valkey.yaml + app.yaml
│   ├── valkey.yaml           # optional baseline Deployment (not in kustomization)
│   └── valkey-operator/
│       ├── own-valkey.yaml   # Valkey CR used here — sentinel: true, tls: true
│       └── valkey-cr.yaml    # generic CR template (reference)
├── scripts/
│   ├── deploy.sh                  # build image + load into kind + apply + wait + restart
│   ├── add-data-to-valkey.sh      # seed 8 sample books via the API
│   ├── delete-data-from-valkey.sh # delete all books via the API (data only)
│   ├── test-api.sh                # guided end-to-end API walkthrough
│   └── remove.sh                  # delete the Valkey CR + namespace (runs operator finalizers)
├── kind-config.yaml          # optional: kind cluster with host port mapping
└── README.md
```

---

## API reference

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Liveness/readiness — verifies Valkey connectivity, reports sentinel/TLS mode |
| `GET` | `/books` | List all books |
| `GET` | `/books/{isbn}` | Get one book by ISBN |
| `POST` | `/books` | Create a book |
| `PUT` | `/books/{isbn}` | Partial update |
| `DELETE` | `/books/{isbn}` | Delete a book |
| `GET` | `/books/author/{name}` | Books by author (case-insensitive) |
| `GET` | `/docs` | Swagger UI |

---

## Cleanup

```bash
# Delete the Valkey CR first so the operator runs its finalizers, then the namespace
kubectl delete -k k8s/ --ignore-not-found
kubectl delete namespace bookstore --ignore-not-found

# Or use the script (handles CR finalizers + namespace)
./scripts/remove.sh

# Delete kind cluster
kind delete cluster --name bookstore
```

If you ran the operator with `make run`, stop it with `Ctrl-C` (deleting the kind
cluster also drops its kubeconfig context, so the controller can no longer reconcile).
