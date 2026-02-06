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
- `docker/consul/client.hcl` (baseline Consul config that enables Connect)

**Generated at deploy-time / runtime**
- `run/mesh/bundles/*.bundle.json` (deploy-time)
- `run/mesh/expanded/<host>/...` (runtime expansion; safe to delete)

## Laptop demo (everything containerised)

The prior Compose-based laptop demo has been archived:

- `archive/compose/`
- `archive/compose/scripts/`

## Reference / legacy config directories

These exist mainly to support the containerised demo and/or as examples. If you are using the **bundle-per-host** approach, you do **not** need to edit these by hand:

- `archive/docker/consul/services/**` and `archive/docker/consul/services-vmhost/**` (service registration templates)
- `archive/docker/consul/config-entries/**` (service-defaults/intentions/resolvers)
- `archive/compose/*.yml` (Compose-based launches)

The bundle-per-host approach generates the equivalents into `run/mesh/expanded/...` and uses those generated directories at runtime.

## Archive

If you see a file path mentioned in an older doc but it’s not listed above, check `archive/` (deprecated run modes and reference configs live there).
