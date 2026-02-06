# Getting Started (supported path)

This repo’s supported (maintained) path is the **production-shaped** model:

- your apps run as **host processes** on app VMs
- Consul/Envoy run as **Podman containers** alongside them
- start/stop is **scriptable** (Autosys-friendly) and does not require Compose

Deprecated run modes (Compose demos, reference configs) have been moved to `archive/`.

## Steps

1) Create your mesh config:
   - Copy `config/mesh.example.yml` to `config/mesh.yml` and edit hostnames/IPs and the service catalog.

2) Deploy-time: render one bundle JSON per host (control machine):

```bash
ansible-inventory -i config/mesh.yml --list > inventory.json
python tools/render-mesh-bundles.py --inventory-json inventory.json -o run/mesh/bundles
```

If you don’t have `ansible-inventory`, start from the included example JSON and edit it:

```bash
python tools/render-mesh-bundles.py --inventory-json config/inventory.example.json -o run/mesh/bundles
```

3) Deploy-time: expand the bundle on each VM (minimises runtime file writes):

```bash
python tools/meshctl.py expand --bundle run/mesh/bundles/<this-host>.bundle.json
```

4) Runtime: start (on each VM):

- Server VM (Consul server + mesh gateway):
  - `./scripts/prod/meshctl-up-server.sh --bundle run/mesh/bundles/<this-host>.bundle.json`
- App VM (Consul agent + Envoy sidecars):
  - `./scripts/prod/meshctl-up-app.sh --bundle run/mesh/bundles/<this-host>.bundle.json`

Verify:

- `python tools/meshctl.py verify --bundle run/mesh/bundles/<this-host>.bundle.json`

Next:

- Follow `docs/production-runbook.md` for runtime order, verification, and failover drills.
