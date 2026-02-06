# Consul Service Mesh Failover (MVP)

This repo is a runnable POC that demonstrates **automatic primary -> secondary failover** for service-to-service calls using **Consul service mesh (Connect) + Envoy sidecars**, without pushing failover state into each application.

Supported (maintained) run mode: **production-shaped VMs** (apps as host processes, mesh in containers).

- Getting started: `GETTING_STARTED.md`
- Production runbook: `docs/production-runbook.md`
- Repo orientation: `docs/what-to-use.md`

## What it demonstrates

- `webservice` (Spring Boot) and `ordermanager` (Spring Boot) call `refdata` through a local upstream (`http://127.0.0.1:18082`) provided by an Envoy sidecar.
- `webservice`, `ordermanager`, and `refdata` run in **dc1 (primary)** and **dc2 (secondary/DR)**.
- When **dc1 `refdata` becomes unhealthy**, Consul `service-resolver` failover routes traffic to **dc2 `refdata`** automatically.
- A TCP example (`itch-feed` + `itch-consumer`) shows the same pattern works for **non-HTTP (TCP)** traffic.

## How you run it (supported path)

### 1) Maintain one config file

Copy `config/mesh.example.yml` to `config/mesh.yml` and edit:

- target hosts (dc1/dc2, server/app roles)
- host IPs and Consul peer addresses
- `service_catalog` (name/port/protocol/health check path, sidecar port, upstreams)

### 2) Deploy-time: render 1 bundle JSON per host

On your control/deploy machine:

```bash
ansible-inventory -i config/mesh.yml --list > inventory.json
python tools/render-mesh-bundles.py --inventory-json inventory.json -o run/mesh/bundles
```

Deploy the repo to each VM (or at least `config/`, `docker/consul/client.hcl`, `tools/`, `scripts/`) and copy the matching:

- `run/mesh/bundles/<host>.bundle.json`

onto that VM.

`ansible-inventory` is only required at deploy time (it’s used to evaluate/merge an Ansible-style inventory YAML into a single JSON structure).

### 2b) Deploy-time: expand the bundle on each VM (recommended)

To minimise runtime file writes, expand the bundle **once** during deployment on each VM:

```bash
python tools/meshctl.py expand --bundle run/mesh/bundles/<this-host>.bundle.json
```

### 3) Runtime: start/stop

On each VM (Autosys-friendly):

- Server VM (Consul server + mesh gateway):
  - `./scripts/prod/meshctl-up-server.sh --bundle run/mesh/bundles/<this-host>.bundle.json`
- App VM (Consul agent + Envoy sidecars):
  - `./scripts/prod/meshctl-up-app.sh --bundle run/mesh/bundles/<this-host>.bundle.json`

Verify:

- `python tools/meshctl.py verify --bundle run/mesh/bundles/<this-host>.bundle.json`

Stop:

- Server VM: `./scripts/prod/meshctl-down-server.sh --bundle run/mesh/bundles/<this-host>.bundle.json`
- App VM: `./scripts/prod/meshctl-down-app.sh --bundle run/mesh/bundles/<this-host>.bundle.json`

### 4) Start your apps

Start your Spring Boot / Java processes normally (Autosys etc).

For the mock apps in this repo:

```bash
./scripts/mock/build-jars.sh
./scripts/mock/start-mocks.sh --dc dc1   # on dc1 app VM
./scripts/mock/start-mocks.sh --dc dc2   # on dc2 app VM
```

### 5) Test failover

- `./scripts/smoke-test.sh`

If your endpoints aren’t the defaults, override:

```bash
WEBSERVICE_URL=http://127.0.0.1:8080 CONSUL_HTTP_ADDR=http://127.0.0.1:8500 ./scripts/smoke-test.sh
```

## Prereqs / dependencies

On each VM that runs containers:

- Podman 4.9+ (rootless supported)
- Python 3
- Network access to pull images (or pre-pulled images mirrored internally)

On app VMs only (if running mock apps):

- Java 17

## Repo layout (relevant)

- `config/mesh.yml` (source of truth; copy from `config/mesh.example.yml`)
- `tools/render-mesh-bundles.py` (deploy-time bundle renderer)
- `tools/meshctl.py` (runtime start/stop/verify; runs Podman directly)
- `scripts/prod/meshctl-*.sh` (thin wrappers for Autosys/operators)
- `docker/consul/client.hcl` (baseline Consul config enabling Connect)
- `scripts/mock/` and `services/` (optional mock apps)
- `archive/` (deprecated demos, Compose stacks, and old reference configs)
