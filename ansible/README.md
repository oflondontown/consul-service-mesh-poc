# Ansible integration (optional)

This repo already includes runnable Podman scripts under `scripts/prod/`. If you deploy with Ansible, you can drive those scripts from a YAML inventory so you don’t have to hand-edit `*.env` files per host.

## What this gives you

- A single YAML inventory that defines:
  - target hosts (dc1/dc2)
  - host IPs and Consul peer addresses
  - which legacy services exist on each app host (`ENABLED_SERVICES`)
- A small renderer that converts inventory vars into env files compatible with:
  - `./scripts/prod/podman-up-server.sh --env-file ...`
  - `./scripts/prod/podman-up-app.sh --env-file ...`

## Files

- Inventory template: `ansible/inventory.example.yml`
- Env renderer: `tools/render-prod-env.py`
- Output (generated): `run/ansible/<host>/{server.env,app.env}`

## Prereqs (control machine)

- `python3`
- Either:
  - `ansible-inventory` available in `$PATH`, or
  - a pre-generated inventory JSON file (see below)

## Render env files

From repo root:

```bash
python3 tools/render-prod-env.py -i ansible/inventory.example.yml -o run/ansible
```

If your control machine doesn’t have `ansible-inventory` available, you can render from a pre-generated JSON:

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
