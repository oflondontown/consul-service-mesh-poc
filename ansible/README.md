# Ansible integration (optional)

This repo already includes runnable Podman scripts under `scripts/prod/`. If you deploy with Ansible, you can drive **both**:

- the runtime env files (`scripts/prod/*.env` compatible), and
- the per-service Consul registration templates + mesh config entries (including service `port`, `protocol`, and health check settings)

from a YAML inventory on your control machine.

## What this gives you

- A single YAML inventory that defines:
  - target hosts (dc1/dc2)
  - host IPs and Consul peer addresses
  - which legacy services exist on each app host (`ENABLED_SERVICES`)
  - each service's `port`, `protocol`, health check, sidecar listener port, and upstream listeners (`service_catalog`)
- A small renderer that converts inventory vars into env files compatible with:
  - `./scripts/prod/podman-up-server.sh --env-file ...`
  - `./scripts/prod/podman-up-app.sh --env-file ...`

## Files

- Inventory template: `ansible/inventory.example.yml`
- Env renderer: `tools/render-prod-env.py` (optional)
- Full artifact renderer: `tools/render-ansible-artifacts.py` (recommended)
- Output (generated): `run/ansible/<host>/{server.env,app.env}`

## Prereqs (control machine)

- Python 3 (`python3` on most Linux distros; `python` on Windows)
- Either:
  - `ansible-inventory` available in `$PATH`, or
  - a pre-generated inventory JSON file (see below)

## Render env files

From repo root:

```bash
python3 tools/render-prod-env.py -i ansible/inventory.example.yml -o run/ansible
```

If your control machine doesn't have `ansible-inventory` available, you can render from a pre-generated JSON:

```bash
ansible-inventory -i ansible/inventory.example.yml --list > inventory.json
python3 tools/render-prod-env.py --inventory-json inventory.json -o run/ansible
```

Example outputs:

- `run/ansible/dc1-consul-01/server.env`
- `run/ansible/dc1-app-01/app.env`

## Use the rendered env files

On each target host (after the repo is deployed/checked out there):

```bash
./scripts/prod/podman-up-server.sh --env-file run/ansible/<this-host>/server.env
./scripts/prod/podman-up-app.sh --env-file run/ansible/<this-host>/app.env
```

## Render full artifacts (services + config entries)

This generates:

- Common Consul config entries (applied by server VMs):
  - `run/ansible/common/config-entries/*`
- Per-host service registration templates (mounted by app VMs):
  - `run/ansible/<host>/services/*.json`

From repo root:

```bash
python3 tools/render-ansible-artifacts.py -i ansible/inventory.example.yml -o run/ansible
```

Then set these env vars (either in your rendered env files, or as inventory vars if you also render env):

- On server VMs: `CONSUL_CONFIG_ENTRIES_DIR=run/ansible/common/config-entries`
- On app VMs: `CONSUL_SERVICE_TEMPLATES_DIR=run/ansible/<host>/services`

If you render env files with `tools/render-prod-env.py` to the same output directory (`-o run/ansible`), these variables are included automatically.

## Inventory variables

Required per host:

- `dc`: `dc1` or `dc2`
- `host_ip`: the host’s reachable IP

Server hosts (group `consul_servers`) should also set:

- `consul_bootstrap_expect`
- `consul_retry_join`
- `consul_retry_join_wan`
- `consul_enable_ui`

App hosts (group `app_hosts`) should also set:

- `consul_retry_join`

Optional (all or per-host):

- `consul_image`, `envoy_image`
- `envoy_extra_args`
- `mgmt_bind_addr` (host bind for Consul UI/API; default is localhost-only)
- `enabled_services` (comma-separated service names like `webservice,ordermanager,refdata`)
- `enable_itch_consumer` (`0`/`1`)
- `service_catalog` (list of service definitions: name/port/protocol/check/sidecar_port/upstreams)
- `dc2_prefer_dc1_services` (list; generates `*-resolver-dc2.hcl` that prefers `dc1` primary when healthy)
