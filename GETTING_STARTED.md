# Getting Started (recommended paths)

This repo contains a few different ways to run the MVP. If you're new to it, use **one** of these two paths and ignore the rest.

## Path 1 (laptop demo): everything in containers

Use this if you want the fastest way to see **cross-DC failover** on a single machine.

- Follow: `quickstart/README.md` → **Option A**
- Requires: Podman + a Compose frontend (`podman compose` plugin or `podman-compose`)

## Path 2 (production-shaped): legacy apps on host, mesh in containers (recommended)

Use this if you want the closest match to your production model:

- Apps run as **host processes** (your real Spring Boot / Java processes).
- Consul/Envoy run in **Podman containers** alongside them.
- Start/stop is **scriptable** (Autosys-friendly) and does **not** require Compose.

Recommended variant: **one bundle JSON per host** (single runtime input).

1) Define the system in one inventory-style YAML:
   - Start from: `config/mesh.example.yml` (copy to `config/mesh.yml` and edit)

2) Deploy-time: render per-host bundles (control machine):
   - Requires `ansible-inventory` on the control machine (or a pre-generated `inventory.json`)
   - `ansible-inventory -i config/mesh.yml --list > inventory.json`
   - `python tools/render-mesh-bundles.py --inventory-json inventory.json -o run/mesh/bundles`

3) Runtime: start/stop (on each VM)
   - Server VM (Consul server + mesh gateway):
     - `./scripts/prod/meshctl-up-server.sh --bundle run/mesh/bundles/<this-host>.bundle.json`
   - App VM (Consul agent + Envoy sidecars):
     - `./scripts/prod/meshctl-up-app.sh --bundle run/mesh/bundles/<this-host>.bundle.json`

4) Verify (optional)
   - `python tools/meshctl.py verify --bundle run/mesh/bundles/<this-host>.bundle.json`

For details and troubleshooting, see:
- `quickstart/README.md` → **Option C**
- `README.md` → **Option 2: single bundle per host**
- `docs/production-runbook.md`
