# What to use (and what to ignore)

This repo contains both **demo** and **production-shaped** ways to run the MVP. Use the table below to avoid mixing modes.

## Recommended for production-shaped VMs (legacy apps on host)

Use this if:
- apps run as host processes (Spring Boot/Java running on the VM)
- Consul/Envoy run in containers
- start/stop is driven by Autosys/scripts

**Primary entrypoints**
- `config/mesh.example.yml` (copy to `config/mesh.yml`): single source of truth (hosts + service catalog)
- `tools/render-mesh-bundles.py`: deploy-time bundle renderer (one JSON per host)
- `tools/meshctl.py`: expands bundle + runs start/stop + verifies
- `scripts/prod/meshctl-up-*.sh`, `scripts/prod/meshctl-down-*.sh`: Autosys-friendly wrappers

**Still required from the existing repo**
- `scripts/prod/podman-up-server.sh`, `scripts/prod/podman-down-server.sh`
- `scripts/prod/podman-up-app.sh`, `scripts/prod/podman-down-app.sh`
- `scripts/prod/lib-podman.sh`
- `docker/consul/client.hcl` (the Consul agent/server baseline config that enables Connect)

**Generated at deploy-time / runtime**
- `run/mesh/bundles/*.bundle.json` (deploy-time)
- `run/mesh/expanded/<host>/...` (runtime expansion; safe to delete)

## Laptop demo (everything containerised)

Use this if you want a quick demo on one machine.

- `quickstart/README.md` → Option A
- Uses the Compose files (`docker-compose.yml`, etc.)

## Reference / legacy config directories

These exist mainly to support the containerised demo and/or as examples. If you are using the **bundle-per-host** approach, you do **not** need to edit these by hand:

- `docker/consul/services/**` and `docker/consul/services-vmhost/**` (service registration templates)
- `docker/consul/config-entries/**` (service-defaults/intentions/resolvers)
- `docker-compose*.yml` (Compose-based launches)

The bundle-per-host approach generates the equivalents into `run/mesh/expanded/...` and points the runtime scripts at those generated directories.

