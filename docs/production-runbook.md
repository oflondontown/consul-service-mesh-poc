# Production Runbook (bundle-per-host, legacy apps on VM)

This runbook describes the **recommended** deployment shape for this repo:

- Apps (`webservice`, `ordermanager`, `refdata`, `itch-feed`) run as **host processes** on app VMs.
- Consul/Envoy run as **rootless Podman containers** on the same app VMs.
- A Consul server + mesh gateway run as **rootless Podman containers** on separate server VMs.
- Runtime start/stop is **Autosys/script-driven** (no Ansible required at runtime).

The single source of truth is an inventory-style YAML (`config/mesh.yml`) rendered into **one bundle JSON per host** at deploy time.

## Topology (minimal footprint)

Per datacenter:

- 1x **Consul server VM**: `consul-server` + `mesh-gateway`
- 1x **App VM**: `consul-agent` + per-service Envoy sidecars + legacy app processes

You can scale Consul servers to 3 per DC for HA/quorum; the runbook still applies (repeat the server steps on each server VM and set `consul_retry_join` appropriately).

Topology diagram:

- `docs/production-topology.puml`

## Dependencies / prerequisites

On every VM that runs containers:

- Podman 4.9+ (rootless)
- Python 3 (`python3` on Linux)
- Network access to pull images (or mirrored/pre-pulled):
  - `${consul_image}` (default `docker.io/hashicorp/consul:1.17`)
  - `${envoy_image}` (default `docker.io/envoyproxy/envoy:v1.29-latest`)

On app VMs only (to run the mock apps in this repo):

- Java 17

Optional (control machine / deploy time):

- `ansible-inventory` (only needed to convert `config/mesh.yml` to `inventory.json`)

## One-time deploy-time rendering

1) Copy `config/mesh.example.yml` to `config/mesh.yml` and edit:
   - hostnames
   - `host_ip`
   - `consul_retry_join` / `consul_retry_join_wan`
   - `service_catalog` (ports, health check paths, sidecar/upstreams)

2) Render one bundle per host (control machine):

```bash
ansible-inventory -i config/mesh.yml --list > inventory.json
python tools/render-mesh-bundles.py --inventory-json inventory.json -o run/mesh/bundles
```

3) Deploy to VMs:

- Deploy the repo to each VM (or at least `scripts/`, `tools/`, `docker/consul/client.hcl`).
- Copy the matching `run/mesh/bundles/<host>.bundle.json` onto each VM (same path is simplest).

## Runtime: startup order (Autosys-friendly)

### 1) Start Consul server + mesh gateway (server VMs)

Run on each server VM:

```bash
./scripts/prod/meshctl-up-server.sh --bundle run/mesh/bundles/<this-host>.bundle.json
python tools/meshctl.py verify --bundle run/mesh/bundles/<this-host>.bundle.json
```

Notes:
- `meshctl` waits for a leader and applies config entries before returning success.
- Consul UI/API is bound by `MGMT_BIND_ADDR` (default `127.0.0.1`). Use SSH tunnels, or set it to a management interface IP if allowed.

### 2) Start Consul agent + Envoy sidecars (app VMs)

Run on each app VM:

```bash
./scripts/prod/meshctl-up-app.sh --bundle run/mesh/bundles/<this-host>.bundle.json
python tools/meshctl.py verify --bundle run/mesh/bundles/<this-host>.bundle.json
```

### 3) Start legacy app processes (app VMs)

Start your Spring Boot / Java processes as you normally do (Autosys, systemd-user, etc.).

If using the repo mocks:

```bash
./scripts/mock/build-jars.sh
./scripts/mock/start-mocks.sh --dc dc1   # on dc1 app VM
./scripts/mock/start-mocks.sh --dc dc2   # on dc2 app VM
```

## Runtime: stop order

1) Stop legacy app processes (app VMs)
2) Stop app mesh containers:

```bash
./scripts/prod/meshctl-down-app.sh --bundle run/mesh/bundles/<this-host>.bundle.json
```

3) Stop server mesh containers:

```bash
./scripts/prod/meshctl-down-server.sh --bundle run/mesh/bundles/<this-host>.bundle.json
```

## Verification checklist

Server VM:

- Consul leader is elected:
  - `python tools/meshctl.py verify --bundle ...`
- UI reachable on the server VM:
  - `http://127.0.0.1:8500/ui` (or whatever `MGMT_BIND_ADDR` is)

App VM:

- Local agent reachable:
  - `curl -fsS http://127.0.0.1:8500/v1/agent/self >/dev/null`
- Envoy sidecars running:
  - `podman ps --format '{{.Names}}' | grep envoy`

## Failover drill (refdata)

Baseline (from dc1 app VM):

```bash
curl -fsS http://127.0.0.1:8080/api/refdata/demo
```

Trigger failover (simulate dc1 refdata unhealthy):

```bash
./scripts/failover-refdata.sh
```

Verify traffic is served by dc2:

```bash
curl -fsS http://127.0.0.1:8080/api/refdata/demo
```

Restore primary:

```bash
./scripts/restore-refdata.sh
```

## Operational notes (avoiding flapping)

The MVP uses health checks (interval + thresholds) to drive failover decisions. To add hysteresis/hold-down behavior:

- Increase `check.failures_before_critical` and/or `check.interval` in `config/mesh.yml` for the relevant services.
- Prefer **controlled failback**: keep recovered instances in maintenance mode until you’re ready to reintroduce them (prevents rapid failback if the instance is unstable).

## Logs / troubleshooting

- Consul server logs:
  - `podman logs -f consul-server-<dc>`
- Mesh gateway logs:
  - `podman logs -f mesh-gateway-<dc>`
- App host:
  - `podman logs -f consul-agent-<dc>`
  - `podman logs -f <service>-envoy-<dc>`

Generated runtime files:

- Bundle expansion directory:
  - `run/mesh/expanded/<host>/<role>/`
  - Contains the generated `runtime.env` plus generated config/templates used by the Podman wrappers.
