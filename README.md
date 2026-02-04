# Consul Service Mesh Failover (MVP)

This repo is a runnable POC that demonstrates **automatic primary → secondary failover** for service-to-service calls using **Consul service mesh (Connect) + Envoy sidecars**, without pushing failover state into each application.

## What it demonstrates

- `webservice` (Spring Boot) and `ordermanager` (Spring Boot) call `refdata` through a local sidecar upstream (`http://127.0.0.1:18082`).
- `webservice`, `ordermanager`, and `refdata` run in **dc1 (primary)** and **dc2 (secondary/DR)**.
- When **dc1 `refdata` becomes unhealthy**, Consul’s `service-resolver` failover routes traffic to **dc2 `refdata`** automatically.
- A TCP example (`itch-feed` + `itch-consumer`) shows the same pattern works for **non-HTTP (TCP)** traffic.

## Architecture (Compose)

- Two Consul datacenters: `dc1` and `dc2` (WAN federated).
- A mesh gateway runs in each datacenter (data-plane hop for cross-DC traffic, port `:8443`).
- Each app has:
  - the app workload (container or host process)
  - a **local Consul client agent** (registers the service + health check)
  - an **Envoy sidecar** (Connect proxy)

This mirrors the VM pattern where each VM runs a local Consul agent + Envoy sidecar alongside the workload.

## What “WAN federated” means (in Consul terms)

Consul uses the term **datacenter** for an independent Consul server cluster (its own Raft quorum and catalog). **WAN federation** links multiple Consul datacenters together so they can:

- Discover services across datacenters (cross-DC queries)
- Apply cross-datacenter failover rules (like `service-resolver` failover)

Important nuance: WAN federation does **not** mean you run one Raft quorum stretched across the WAN. Each datacenter still runs independently; the “federation” is for cross-DC discovery.

### Two DR patterns (and why it matters)

There are two common patterns for “primary + DR site”, and they behave very differently:

1. **Cross-datacenter east–west failover (this repo’s model)**
   - `dc1` services can still reach `dc2` services during an incident.
   - Example: `webservice (dc1)` and `ordermanager (dc1)` can fail over their `refdata` upstream to `dc2` automatically when `dc1 refdata` is unhealthy.
   - This requires:
     - **Network reachability** from `dc1` to `dc2`. In production this is commonly done via **Consul mesh gateways** so only gateway nodes need cross-DC connectivity.
     - Some form of **cross-DC discovery** so `dc1` can learn about healthy endpoints in `dc2` (WAN federation is the OSS way).

2. **Site-level (north–south) DR failover (independent sites)**
   - During normal operation, `dc1` only calls `dc1` (no cross-site east–west traffic).
   - In a DR event, you fail over **ingress** (F5/DNS/GTM) so clients hit `webservice (dc2)`, and then everything stays inside `dc2`.
   - This can use two **fully independent** Consul clusters (one per site), because services never need to discover/reach across sites.

How this relates to a DR site:

- If you want **per-service failover** (e.g., `dc1 webservice` calling `dc2 refdata` during an incident), you need some form of cross-DC discovery and network reachability (WAN federation is the OSS way).
- If your DR strategy is **site-level failover** (you fail over the whole stack + ingress to `dc2`), you may not need cross-DC discovery at all; each site can run its own Consul cluster/config and you cut over traffic via F5/DNS/GTMs.

## Repository layout

- `services/`
  - Application code (mock services) and their container build files (Dockerfile format; works with Podman).
  - `services/webservice/` – Spring Boot “frontend” service; calls `refdata` + `ordermanager`; includes a WebSocket echo endpoint.
  - `services/ordermanager/` – Spring Boot service; calls `refdata`.
  - `services/refdata/` – vanilla Java HTTP service; exposes `/api/refdata/{key}` and a small admin toggle to simulate failure.
  - `services/itch-feed/` – vanilla Java TCP server that emits a line every second (stands in for ITCH over TCP / SoupBinTCP).
  - `services/itch-consumer/` – vanilla Java client that connects to the feed via a local sidecar upstream (reconnect loop).
- `docker/`
  - Consul/mesh **runtime configuration** mounted into containers by `docker-compose.yml`.
  - `docker/consul/server-*.hcl` – Consul server configs for `dc1` and `dc2` (Connect enabled, UI enabled, WAN join).
  - `docker/consul/client.hcl` – Consul client config used by per-service local agents.
  - `docker/consul/services/dc1/*.json` and `docker/consul/services/dc2/*.json` – service registrations + health checks + Connect sidecar upstream listeners (the `local_bind_port` values).
  - `docker/consul/services-vmhost/dc1/*.json` and `docker/consul/services-vmhost/dc2/*.json` – service registration templates for apps running on the VM while Consul/Envoy run in containers (uses `HOST_IP` substitution).
  - `docker/consul/config-entries/*.hcl` – central Consul config entries:
    - `service-defaults` (protocol http/tcp)
    - `service-intentions` (allowed callers)
    - `service-resolver` (cross-datacenter failover rules)
- `scripts/`
  - Convenience wrappers for starting/stopping the stack and running a simple failover demo (Podman).
- `vm/`
  - Non-root VM deployment scripts/config examples for RHEL 8.10 (run Consul agent + Envoy sidecar without containers): `vm/README.md`.
- `docker-compose.yml`
  - Defines the two Consul datacenters, the mock services, and sidecars; mounts `docker/` configs into the appropriate containers.
- `docker-compose.poc.single-vm.yml`
  - Single-VM POC mesh stack: runs Consul + mesh gateway + Envoy sidecars in containers (no app containers), so your application services can stay as legacy processes on the VM.
- `docker-compose.poc.single-vm.dc1.yml`
  - Optional overlay for dc1-only services (adds the demo `itch-consumer` sidecar).
- `docker-compose.prod.server.yml`
  - Production-shaped: runs a **Consul server + mesh gateway** on a dedicated Consul VM (run on multiple VMs per DC for quorum/HA).
- `docker-compose.prod.app.yml`
  - Production-shaped: runs a **Consul client agent + Envoy sidecars** on the application VM (apps run as legacy host processes).
- `docker-compose.prod.app.dc1.yml`
  - dc1 overlay for `docker-compose.prod.app.yml` (adds the demo `itch-consumer` sidecar).
- `build.gradle`, `settings.gradle`
  - Gradle multi-module build for the mock services (used by the container build stage).
- `docs/`
  - Project documentation, including PlantUML diagrams:
    - `docs/architecture.puml` (current runtime architecture)
    - `docs/deployment-option-1.puml` (topology option 1)
    - `docs/deployment-option-2.puml` (topology option 2)
    - `docs/deployment-option-3.puml` (topology option 3)

## Quickstart

If you want a copy/paste walkthrough, see: `quickstart/README.md`.

Prereqs:

- For the **all-in-one container demo** (`docker-compose.yml`): Podman with a Compose frontend:
  - `podman compose` (plugin) or `podman-compose`
- For the **prod-shaped demo** (apps as host processes, mesh in containers): Podman only (no Compose provider required) using `scripts/prod/*`.

Start:

- `./scripts/start.sh`
  - Starts the **all-in-one container demo** in `docker-compose.yml` (both DCs + mock services).

Status / stop:

- Status: `./scripts/status.sh`
- Stop: `./scripts/stop.sh` (add `REMOVE_VOLUMES=1` for a clean reset)

If you want to simulate production more closely (apps as host processes, Consul/Envoy in containers), skip to **Production quickstart** below.

UIs:

- Consul dc1 UI: `http://localhost:8500`
- Consul dc2 UI: `http://localhost:8501`

What to look for in the Consul UI:

- In **dc1 UI**, open **Services** and confirm you can see: `webservice`, `ordermanager`, `refdata`, `itch-feed`, `mesh-gateway-dc1`.
- In **dc2 UI**, confirm you can see: `webservice`, `ordermanager`, `refdata`, `itch-feed`, `mesh-gateway-dc2`.
- Open `refdata` in **dc1** and you should see `refdata-dc1` as **passing** initially.

Service endpoints (local dev):

- `webservice` dc1: `http://localhost:8080`
- `webservice` dc2: `http://localhost:8084`
- `ordermanager` dc1: `http://localhost:8081`
- `ordermanager` dc2: `http://localhost:8085`

Smoke test (includes a refdata failover + restore):

- `./scripts/smoke-test.sh`

Manual refdata failover toggle:

- Disable primary (dc1): `./scripts/failover-refdata.sh`
- Re-enable primary (dc1): `./scripts/restore-refdata.sh`

Notes:

- Health check hysteresis is enabled (3 failing checks to mark critical, 3 passing checks to recover). With 5s intervals, failover/failback usually takes ~15–30 seconds end-to-end.
- The smoke test disables **dc1** `refdata` (returns HTTP 503 on `/health`) and waits until `webservice` starts returning `refdata.datacenter=dc2`.

ITCH/TCP demo:

- Watch the consumer: `podman compose logs -f itch-consumer` (or `podman-compose logs -f itch-consumer`)
- Stop primary feed: `podman compose stop itch-feed-primary` (or `podman-compose stop itch-feed-primary`)

## Production quickstart (apps on VM, dedicated Consul servers)

This is the recommended topology if you can run **dedicated Consul server VMs** in each DC (apps still run as legacy host processes on a separate app VM).

### Containers per VM

- On each **Consul server VM** (`docker-compose.prod.server.yml`):
  - `consul-server` (server process; participates in quorum)
  - `consul-config` (one-shot; writes config entries like `service-resolver` failover policy)
  - `mesh-gateway` (Envoy mesh gateway, cross-DC data-plane hop on `:8443`)
- On each **application VM** (`docker-compose.prod.app.yml`):
  - `consul-agent` (client agent; registers services + runs health checks)
  - Sidecars (Envoy): `webservice-envoy`, `ordermanager-envoy`, `refdata-envoy`, `itch-feed-envoy`
  - Optional dc1-only demo: `itch-consumer-envoy` via `docker-compose.prod.app.dc1.yml`

Note: the official `hashicorp/consul` image does **not** include an `envoy` binary. These Compose files run Envoy from `${ENVOY_IMAGE}` and use one-shot `*-bootstrap` containers (Consul CLI) to generate `/bootstrap/bootstrap.json`. Seeing `*-bootstrap` containers exit is expected.

### Required environment variables

- `CONSUL_DATACENTER=dc1|dc2`
- `HOST_IP=<this VM IP>` (used for advertise + health check targets + mesh gateway address)
- Optional: `ENVOY_IMAGE=docker.io/envoyproxy/envoy:v1.29-latest` (override the Envoy image/tag)

### Start (example commands)

dc1 Consul server VM (repeat on all dc1 server VMs):

- `CONSUL_DATACENTER=dc1 HOST_IP=10.0.0.21 CONSUL_RETRY_JOIN=10.0.0.21,10.0.0.22,10.0.0.23 CONSUL_RETRY_JOIN_WAN=10.0.1.21,10.0.1.22,10.0.1.23 podman compose -f docker-compose.prod.server.yml up -d`

dc1 application VM:

- `CONSUL_DATACENTER=dc1 HOST_IP=10.0.0.10 CONSUL_RETRY_JOIN=10.0.0.21,10.0.0.22,10.0.0.23 podman compose -f docker-compose.prod.app.yml -f docker-compose.prod.app.dc1.yml up -d`

dc2 Consul server VM (repeat on all dc2 server VMs):

- `CONSUL_DATACENTER=dc2 HOST_IP=10.0.1.21 CONSUL_RETRY_JOIN=10.0.1.21,10.0.1.22,10.0.1.23 CONSUL_RETRY_JOIN_WAN=10.0.0.21,10.0.0.22,10.0.0.23 podman compose -f docker-compose.prod.server.yml up -d`

dc2 application VM:

- `CONSUL_DATACENTER=dc2 HOST_IP=10.0.1.10 CONSUL_RETRY_JOIN=10.0.1.21,10.0.1.22,10.0.1.23 podman compose -f docker-compose.prod.app.yml up -d`

### Start without Compose (Podman only)

If you **cannot / do not want to install a Compose provider** (`podman-compose`) on the VM, you can start the same containers using **Podman pods** + wrapper scripts (no `podman compose` needed):

- Create per-VM env files (recommended):
  - Server VM: `cp scripts/prod/server.env.example scripts/prod/server.env` (edit values)
  - App VM: `cp scripts/prod/app.env.example scripts/prod/app.env` (edit values)
  - Or start from the provided MVP examples and copy the right one for each VM:
    - `scripts/prod/server.dc1.env`, `scripts/prod/server.dc2.env`
    - `scripts/prod/app.dc1.env`, `scripts/prod/app.dc2.env`
- dc1 Consul server VM(s): `CONSUL_DATACENTER=dc1 HOST_IP=10.0.0.21 CONSUL_RETRY_JOIN=10.0.0.21,10.0.0.22,10.0.0.23 CONSUL_RETRY_JOIN_WAN=10.0.1.21,10.0.1.22,10.0.1.23 ./scripts/prod/podman-up-server.sh`
- dc1 application VM: `CONSUL_DATACENTER=dc1 HOST_IP=10.0.0.10 CONSUL_RETRY_JOIN=10.0.0.21,10.0.0.22,10.0.0.23 ./scripts/prod/podman-up-app.sh`
- dc2 Consul server VM(s): `CONSUL_DATACENTER=dc2 HOST_IP=10.0.1.21 CONSUL_RETRY_JOIN=10.0.1.21,10.0.1.22,10.0.1.23 CONSUL_RETRY_JOIN_WAN=10.0.0.21,10.0.0.22,10.0.0.23 ./scripts/prod/podman-up-server.sh`
- dc2 application VM: `CONSUL_DATACENTER=dc2 HOST_IP=10.0.1.10 CONSUL_RETRY_JOIN=10.0.1.21,10.0.1.22,10.0.1.23 ./scripts/prod/podman-up-app.sh`

Once you have `scripts/prod/server.env` / `scripts/prod/app.env` on the VM, you can simply run:

- Server VM: `./scripts/prod/podman-up-server.sh` (or `./scripts/prod/podman-up-server.sh --env-file scripts/prod/server.env`)
- App VM: `./scripts/prod/podman-up-app.sh` (or `./scripts/prod/podman-up-app.sh --env-file scripts/prod/app.env`)

Stop:

- Server VM: `CONSUL_DATACENTER=dc1 ./scripts/prod/podman-down-server.sh` (add `REMOVE_VOLUMES=1` to delete volumes)
- App VM: `CONSUL_DATACENTER=dc1 ./scripts/prod/podman-down-app.sh` (add `REMOVE_VOLUMES=1` to delete volumes)

If you created env files, you can stop without prefixing env vars:

- Server VM: `./scripts/prod/podman-down-server.sh`
- App VM: `./scripts/prod/podman-down-app.sh`

### Start mock apps on the application VM (non-container)

This repo includes simple **mock implementations** of your services under `services/`. To run them as **host processes** (closer to your “legacy on VM” model):

- Build jars (on each app VM; requires Java + Gradle): `./scripts/mock/build-jars.sh`
- Start mocks:
  - dc1 app VM: `./scripts/mock/start-mocks.sh --dc dc1`
  - dc2 app VM: `./scripts/mock/start-mocks.sh --dc dc2`
- Stop mocks:
  - `./scripts/mock/stop-mocks.sh --dc dc1` (or `--dc dc2`)

Once running, services should show as **passing** in the Consul UI (because the Consul agent checks `/actuator/health` or `/health`).

### View the Consul UI (prod-shaped)

In `docker-compose.prod.server.yml` and `scripts/prod/podman-up-server.sh`, the Consul UI/HTTP API is published on `127.0.0.1:8500` on the **server VM**.

- If you are running locally on that VM: open `http://localhost:8500/ui`
- If you are connecting from your laptop via SSH, use a tunnel (examples):
  - dc1: `ssh -L 8500:127.0.0.1:8500 <user>@<dc1-consul-server>`
  - dc2: `ssh -L 8501:127.0.0.1:8500 <user>@<dc2-consul-server>` then open `http://localhost:8501/ui`

### Test failover (prod-shaped)

Run on the **dc1 application VM** (where `webservice` is active for this demo):

- Baseline: `curl -fsS http://127.0.0.1:8080/api/refdata/demo`
- Trigger refdata failover: `./scripts/failover-refdata.sh`
- Watch it fail over (should now show `refdata.datacenter=dc2`): `curl -fsS http://127.0.0.1:8080/api/refdata/demo`
- Restore: `./scripts/restore-refdata.sh`

Or run the scripted flow: `./scripts/smoke-test.sh`

### App ports and local upstream ports (same as the POC)

Your apps call local upstream listeners on the VM (stable per environment):

- `webservice` -> `refdata`: `http://127.0.0.1:18082`
- `webservice` -> `ordermanager`: `http://127.0.0.1:18083`
- `ordermanager` -> `refdata`: `http://127.0.0.1:18182`
- `itch-consumer` -> `itch-feed`: `127.0.0.1:19100` (TCP)

Where to change these mappings:

- Service registration templates + check URLs: `docker/consul/services-vmhost/dc1/*.json`, `docker/consul/services-vmhost/dc2/*.json`
- Host-published upstream/admin/sidecar ports: `docker-compose.prod.app.yml` (and `docker-compose.prod.app.dc1.yml`)

### Port mapping cheat sheet (Consul ↔ Envoy ↔ host apps)

In this repo, **Consul is the source of truth** for proxy ports and upstreams. Envoy binds to whatever Consul tells it to bind to (via `consul connect envoy ... -bootstrap`).

For each service registration (`docker/consul/services-vmhost/<dc>/*.json`):

- `service.port`: the **app’s inbound port** on the VM (e.g. `webservice` `8080`, `ordermanager` `8081`, `refdata` `8082`, `itch-feed` `9000`).
- `connect.sidecar_service.port`: the **Envoy sidecar inbound port** (reachable by the mesh). In this repo: `21000+`.
- `connect.sidecar_service.proxy.upstreams[].local_bind_port`: the **local “upstream” listener** the app calls (loopback on the VM). In this repo:
  - `webservice` uses `18082` (refdata) and `18083` (ordermanager)
  - `ordermanager` uses `18182` (refdata) to avoid clashing with webservice on the same VM
  - `itch-consumer` uses `19100` (itch-feed, TCP)

For the prod-shaped “apps on VM” mode, the Podman sidecar containers must publish those ports back onto the host:

- `scripts/prod/podman-up-app.sh` publishes:
  - upstream ports to `127.0.0.1:<port>` (so host apps can connect)
  - sidecar inbound ports to `0.0.0.0:<port>` (so other services/mesh gateways can reach the sidecar)
  - admin ports to `127.0.0.1:29000+` (debug only)

If you change any `local_bind_port` / sidecar `port` in Consul registration, you must also update:

- your app env vars (e.g. `REFDATA_BASE_URL`, `ORDERMANAGER_BASE_URL`)
- the Podman pod port mappings (`scripts/prod/podman-up-app.sh`)

## Single-VM POC (apps on VM, mesh in containers)

If you cannot run dedicated Consul server VMs yet, you can use the **single-VM POC mesh stack** on each app VM:

- `docker-compose.poc.single-vm.yml` (+ optional `docker-compose.poc.single-vm.dc1.yml`)

In this mode, the Consul process runs in **server mode** and also acts as the **local agent** that runs health checks for the VM-hosted apps.

This mode also uses `${ENVOY_IMAGE}` + one-shot `*-bootstrap` containers (Consul CLI) to generate the Envoy bootstrap config.

Example:

- dc1 VM: `CONSUL_DATACENTER=dc1 HOST_IP=10.0.0.10 CONSUL_RETRY_JOIN_WAN=10.0.1.10 podman compose -f docker-compose.poc.single-vm.yml -f docker-compose.poc.single-vm.dc1.yml up -d`
- dc2 VM: `CONSUL_DATACENTER=dc2 HOST_IP=10.0.1.10 CONSUL_RETRY_JOIN_WAN=10.0.0.10 podman compose -f docker-compose.poc.single-vm.yml up -d`

## Podman Desktop notes (Windows/macOS/Linux)

- This repo includes multiple Compose files:
  - `docker-compose.yml` (everything containerised)
  - `docker-compose.poc.single-vm.yml` (+ optional `docker-compose.poc.single-vm.dc1.yml`) for a **single-VM POC** where apps run on the VM and Consul+Envoy run in containers on the same VM.
  - `docker-compose.prod.server.yml` + `docker-compose.prod.app.yml` for a **production-shaped** topology with dedicated Consul server VM(s) and separate app VM(s).
- All Compose files in this repo avoid host networking (published ports) so they work with Podman without root privileges.
- Podman supports the Compose spec; these files work with `podman compose` or `podman-compose`.
- Ensure Podman is running:
  - Windows/macOS typically require a VM: `podman machine start`
- Ensure Compose is available:
  - Some Podman installs require an external compose provider. If you see `looking up compose provider failed`, install `podman-compose`.
  - Quick check: `podman-compose version`
- If you don’t want Compose at all, the production-shaped stacks have Podman-only wrappers:
  - `./scripts/prod/podman-up-server.sh`, `./scripts/prod/podman-up-app.sh`
- Podman Desktop UI: you can typically run `docker-compose.yml` from the Compose section; the scripts are just thin wrappers around the CLI.

## Where failover is configured

Failover is **not** an app setting. It’s mesh configuration:

- Service definitions + upstream listener ports:
  - `docker/consul/services/dc1/*.json`
  - `docker/consul/services/dc2/*.json`
  - `docker/consul/services-vmhost/dc1/*.json` (apps on VM; Consul/Envoy in containers)
  - `docker/consul/services-vmhost/dc2/*.json` (apps on VM; Consul/Envoy in containers)
- Failover policy:
  - `docker/consul/config-entries/refdata-resolver-dc1.hcl`
  - `docker/consul/config-entries/refdata-resolver-dc2.hcl`
  - `docker/consul/config-entries/ordermanager-resolver-dc1.hcl`
  - `docker/consul/config-entries/ordermanager-resolver-dc2.hcl`
  - `docker/consul/config-entries/itch-feed-resolver-dc1.hcl`
  - `docker/consul/config-entries/itch-feed-resolver-dc2.hcl`
- Mesh gateway routing (cross-DC traffic via gateways):
  - `docker/consul/config-entries/proxy-defaults.hcl`
- Intentions (allow rules):
  - `docker/consul/config-entries/intentions.hcl`

The key idea is: **apps always call `localhost:<upstreamPort>`**, and Consul decides which datacenter/instance is healthy and routable.

DR note: this repo configures failover **from `dc1` → `dc2`**. For `refdata` and `itch-feed`, the `dc2` resolver entries are local-only (no “reach back” into `dc1`). For `ordermanager`, `dc2` is configured to **prefer `dc1` when available** (so `webservice (dc2)` can still use the primary `ordermanager`), and falls back to `dc2` when `dc1` is unavailable.

## Failover vs failback (when dc1 recovers)

This POC’s cross-datacenter failover is **health-based**:

- If a caller is in `dc1` and there is a healthy `dc1` instance for the upstream service, traffic goes to `dc1`.
- Only when there are **no healthy `dc1` instances**, Consul fails over to `dc2`.

So for **east-west** traffic from `dc1`, “failback” is typically automatic: once the recovered `dc1` instance is healthy again, traffic naturally returns to `dc1`.

If you want a **controlled/manual failback** (avoid flapping, do warm-up checks, migrate gradually), common patterns are:

- Put the recovered `dc1` instances into **maintenance mode** until you’re ready, then disable maintenance to re-introduce them.
- Use a `service-resolver` + `service-splitter` (subsets like `primary`/`secondary`) and adjust weights during cutover/failback.

North-south note: this repo does not model public ingress failover for `webservice` (that’s typically handled by an edge LB like F5, DNS/GTM, or a Consul ingress gateway). Your ingress strategy determines how client traffic fails over and fails back between sites.

### Avoiding flapping (auto failover, stable behavior)

If you want auto failover but want to avoid “bounce between dc1 and dc2”, the usual levers are:

- **Choose the right health signal**: Actuator `/actuator/health` can include downstream dependencies; consider separating “process up” vs “ready to serve” (liveness vs readiness) to prevent transient dependency blips from triggering failover.
- **Tune check intervals/timeouts**: longer intervals and slightly higher timeouts reduce false negatives at the cost of slower detection.
- **Add a hold-down mechanism**: after a failover, keep `dc1` instances out of rotation until you confirm stability, then re-enable and optionally ramp traffic back gradually.

Practical implementation guidance (what is “Consul config” vs “automation”):

1. **Hysteresis (recommended, mostly Consul config)**
   - Goal: require _N consecutive failures_ before marking an instance unhealthy and _M consecutive successes_ before marking it healthy again.
   - This reduces “false failovers” and also creates an automatic “up delay” after a restart (a form of hold-down).
   - In Consul, these are configured on the **health check definition**:
     - `failures_before_critical`: number of consecutive failed check runs required before the check transitions to `critical`.
     - `success_before_passing`: number of consecutive successful check runs required before the check transitions back to `passing`.
   - In this repo, every service check is set to:
     - `failures_before_critical = 3`
     - `success_before_passing = 3`
     - with `interval = 5s` and `timeout = 1s` (so detection/recovery is roughly ~15s of consistent failure/success).
   - Files:
     - `docker/consul/services/dc1/*.json`
     - `docker/consul/services/dc2/*.json`

2. **Maintenance mode hold-down (operator/automation, uses Consul API)**
   - Goal: even if the process is healthy again, keep it _intentionally_ excluded from routing until you’re ready.
   - Mechanism: put the service instance into **maintenance mode** on the _local agent_ for that instance.
   - Typical API shape (called against the node’s local agent, often `http://127.0.0.1:8500`):
     - Enable: `PUT /v1/agent/service/maintenance/<service-id>?enable=true&reason=<text>`
     - Disable: `PUT /v1/agent/service/maintenance/<service-id>?enable=false`
   - This is usually driven by an Ansible task or a small “failback” runbook script, not by the application.

3. **Controlled failback (automation/process, sometimes Consul config)**
   - If you rely purely on health-based failover, **failback is immediate** once a `dc1` instance becomes healthy.
   - To make failback controlled:
     - Keep `dc1` in maintenance while you warm caches/run smoke tests, then disable maintenance at a controlled time.
     - Optionally, use traffic shaping (e.g., weighted routing / subsets) to ramp back gradually (advanced; depends on your Consul version and how you model “primary/secondary”).

4. **Edge (F5) hold-down is separate from mesh**
   - For GUI → `webservice`, the “don’t flap” logic typically lives in the F5 monitor config (interval/timeout, up-delay/hold-down), independent of Consul.

## Hot/hot-warm/hot-cold in this MVP

- `refdata` and `itch-feed` are modeled as **hot-warm / active-passive**: both `dc1` and `dc2` instances are running, but `dc2` only receives traffic when `dc1` becomes unhealthy.
- `webservice` is modeled as **hot-warm / active-passive at ingress**: both `dc1` and `dc2` are running, and your F5 selects the active site based on health.
- `ordermanager` is modeled as **hot-warm / active-passive for east–west calls**: callers prefer `dc1` and fail over to `dc2` when `dc1` has no healthy instances (via `service-resolver`).

## Assumptions

- **Consul OSS + Connect mTLS** are acceptable for the POC.
- Failover is based on **health checks** (service is removed from selection when unhealthy).
- WebSockets are **HTTP/1.1 upgrade** (Envoy proxies them as normal HTTP traffic).
- ITCH in this POC is modeled as **TCP**. In your environment you mentioned **Parity Trading Nassau (SoupBinTCP)**; this POC keeps the same L4 (TCP) characteristics, but does not implement the SoupBinTCP framing/sequence logic.
- External ingress/DNS cutover is out-of-scope here; internal failover happens at the mesh layer.

## Mapping this to Parity Trading Nassau (SoupBinTCP)

If your production ITCH connectivity uses Nassau SoupBinTCP, the mesh part stays the same because Envoy proxies it as **generic TCP**:

- Register `itch-feed` as `Protocol = "tcp"` (already done).
- Consumers connect to the **local upstream bind port** (e.g. `127.0.0.1:19000`) and implement **reconnect** + any SoupBinTCP session/sequence handling.
- This demo consumer sends a placeholder **LOGIN** and **SUBSCRIBE** message on connect, then treats everything else as publisher→client data.
- Failover will happen on **new connections** after a disconnect (a long-lived TCP stream can’t be transparently “moved” mid-flight).

## How this maps to VMs + Ansible

For each VM (node) running an app:

1. Run a local Consul client agent (joins dc1 or dc2).
2. Register the service with:
   - `connect { sidecar_service { ... } }`
   - health checks
   - upstream local bind ports
3. Run the Envoy sidecar:
   - If Envoy is installed on the VM: `consul connect envoy -sidecar-for <service-id>`
   - If Envoy runs in a container: generate bootstrap with `consul connect envoy -sidecar-for <service-id> -bootstrap > bootstrap.json`, then run `envoy -c bootstrap.json`
4. Apply config entries (`service-defaults`, `service-resolver`, `service-intentions`) per environment (Ansible templates work well here).

Your application config becomes simple and environment-stable:

- `REFDATA_BASE_URL=http://127.0.0.1:18082`

## Next iteration decisions

Already decided for this POC direction:

- Failover can be **automatic**, but you want to **avoid flapping** (use a stable health signal and a hold-down / controlled failback approach).
- ITCH is **Parity Trading Nassau (SoupBinTCP)**: client sends **login + subscription**, then receives publisher data.
- You want **cross-datacenter east–west failover** (services in `dc1` can fail over their upstreams to `dc2` when needed). This repo demonstrates that model via Consul WAN federation + `service-resolver` failover.
- GUI → `webservice` ingress will be handled by an **F5** (north–south).
- F5 will health-check `webservice` in **dc1 and dc2** and **automatically fail over to dc2** when needed.

Still to decide:

- Do you want the F5 setup to be **active/standby** only, or **active/active** (serve both sites) with geo/latency rules?

### F5 integration notes (guidance)

This repo does not include F5 config, but the usual production pattern is:

- F5 VIP → `webservice` instances (pool) in the active site
- Health monitor → `GET /actuator/health` on `webservice`
- With cross-site failover enabled, expect long-lived connections (WebSockets, SoupBinTCP) to drop during a site switch and reconnect (which is typically acceptable/expected).
- To reduce “flap” at the edge, configure sensible monitor intervals/timeouts and an “up delay”/hold-down (vendor naming varies).

# Disclaimer

This MVP was created with the help of Codex from OpenAI.
