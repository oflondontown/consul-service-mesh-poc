# Quickstart (copy/paste)

This folder is a **copy/paste** guide for running and testing the MVP from **Git Bash on Windows**.

## Prereqs (Windows + Git Bash)

- Podman installed (Podman Desktop is fine)
- Start the Podman VM (Windows/macOS):
  - First time only: `podman machine init`
  - Every time: `podman machine start`
- Java 17 available (for the host-process mock services)
- Gradle available (`./scripts/mock/build-jars.sh` uses `./gradlew` if present, otherwise `gradle`)

## Option A (recommended): 1-laptop demo (2 DCs + apps in containers)

This is the fastest way to **see cross-datacenter failover** on one machine.

Requires a Compose frontend:
- `podman compose` (plugin) **or**
- `podman-compose`

Commands (from repo root):

- Start everything: `./scripts/start.sh`
- Open UIs:
  - dc1 UI: `http://localhost:8500/ui`
  - dc2 UI: `http://localhost:8501/ui`
- Run the failover demo: `./scripts/smoke-test.sh`
- Stop: `./scripts/stop.sh`

## Option B: production-shaped (apps as host processes, mesh in containers)

This is the closest to your target topology:

- Per DC:
  - **1x Consul server VM** running `consul-server + mesh-gateway` containers
  - **1x application VM** running `consul-agent + envoy sidecars` containers
  - Apps (`webservice`, `ordermanager`, `refdata`, `itch-feed`) run as **host processes** on the application VM

This option does **not** require Compose (it uses Podman pods via wrapper scripts).

### 1) Edit env files (per VM)

These files are templates. Update the `HOST_IP` and the peer IPs to match your environment:

- dc1 Consul server VM: `quickstart/env/prod/server.dc1.env`
- dc2 Consul server VM: `quickstart/env/prod/server.dc2.env`
- dc1 application VM: `quickstart/env/prod/app.dc1.env`
- dc2 application VM: `quickstart/env/prod/app.dc2.env`

### 2) Start the mesh containers

Run on the **Consul server VMs**:

- dc1 server VM: `./scripts/prod/podman-up-server.sh --env-file quickstart/env/prod/server.dc1.env`
- dc2 server VM: `./scripts/prod/podman-up-server.sh --env-file quickstart/env/prod/server.dc2.env`

Run on the **application VMs**:

- dc1 app VM: `./scripts/prod/podman-up-app.sh --env-file quickstart/env/prod/app.dc1.env`
- dc2 app VM: `./scripts/prod/podman-up-app.sh --env-file quickstart/env/prod/app.dc2.env`

### 3) Start mock apps as host processes (application VMs)

Run on **each** application VM:

- Build jars: `./scripts/mock/build-jars.sh`
- Start mocks:
  - dc1 app VM: `./scripts/mock/start-mocks.sh --dc dc1`
  - dc2 app VM: `./scripts/mock/start-mocks.sh --dc dc2`

### 4) View the Consul UI (server VMs)

On each server VM, Consul UI is published to `127.0.0.1:8500` on that VM.

- Local on the VM: `http://127.0.0.1:8500/ui`
- From your laptop (SSH tunnel example):
  - dc1: `ssh -L 8500:127.0.0.1:8500 <user>@<dc1-consul-server>`
  - dc2: `ssh -L 8501:127.0.0.1:8500 <user>@<dc2-consul-server>` then open `http://localhost:8501/ui`

### 5) Test failover (run on dc1 application VM)

- Baseline: `curl -fsS http://127.0.0.1:8080/api/refdata/demo`
- Trigger failover: `./scripts/failover-refdata.sh`
- Verify traffic is using dc2 refdata: `curl -fsS http://127.0.0.1:8080/api/refdata/demo`
- Restore: `./scripts/restore-refdata.sh`

Or run the scripted flow: `./scripts/smoke-test.sh`

### 6) Tear down

Stop mocks (on each app VM):

- dc1: `./scripts/mock/stop-mocks.sh --dc dc1`
- dc2: `./scripts/mock/stop-mocks.sh --dc dc2`

Stop containers:

- dc1 app VM: `./scripts/prod/podman-down-app.sh --env-file quickstart/env/prod/app.dc1.env`
- dc2 app VM: `./scripts/prod/podman-down-app.sh --env-file quickstart/env/prod/app.dc2.env`
- dc1 server VM: `./scripts/prod/podman-down-server.sh --env-file quickstart/env/prod/server.dc1.env`
- dc2 server VM: `./scripts/prod/podman-down-server.sh --env-file quickstart/env/prod/server.dc2.env`

