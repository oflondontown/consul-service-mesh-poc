# Quickstart (supported path)

This quickstart focuses on the **supported** production-shaped mode:

- apps run as host processes on app VMs
- Consul/Envoy run as Podman containers
- runtime start/stop uses `meshctl` (no Compose)

Deprecated demos and old env templates have been moved to `archive/`.

## Prereqs

- Podman 4.9+
- Python 3
- Java 17 (only if you want to run the mock apps)
- Deploy-time only: `ansible-inventory` (or a pre-generated `inventory.json`)

## 1) Create your mesh config

- Copy `config/mesh.example.yml` to `config/mesh.yml` and edit hostnames/IPs and the `service_catalog`.

## 2) Render bundles (deploy/control machine)

```bash
ansible-inventory -i config/mesh.yml --list > inventory.json
python tools/render-mesh-bundles.py --inventory-json inventory.json -o run/mesh/bundles
```

Copy `run/mesh/bundles/<host>.bundle.json` to each matching VM.

## 3) Start the mesh (runtime)

Before first start on each VM (deploy-time):

```bash
python tools/meshctl.py expand --bundle run/mesh/bundles/<this-host>.bundle.json
```

On each server VM:

```bash
./scripts/prod/meshctl-up-server.sh --bundle run/mesh/bundles/<this-host>.bundle.json
python tools/meshctl.py verify --bundle run/mesh/bundles/<this-host>.bundle.json
```

On each app VM:

```bash
./scripts/prod/meshctl-up-app.sh --bundle run/mesh/bundles/<this-host>.bundle.json
python tools/meshctl.py verify --bundle run/mesh/bundles/<this-host>.bundle.json
```

## 4) Start the mock apps (optional)

On each app VM:

```bash
./scripts/mock/build-jars.sh
./scripts/mock/start-mocks.sh --dc dc1   # on dc1 app VM
./scripts/mock/start-mocks.sh --dc dc2   # on dc2 app VM
```

## 5) Run the smoke test

On dc1 app VM:

```bash
./scripts/smoke-test.sh
```

Override endpoints if needed:

```bash
WEBSERVICE_URL=http://127.0.0.1:8080 CONSUL_HTTP_ADDR=http://127.0.0.1:8500 ./scripts/smoke-test.sh
```

## 6) Tear down

Stop mocks:

```bash
./scripts/mock/stop-mocks.sh --dc dc1
./scripts/mock/stop-mocks.sh --dc dc2
```

Stop mesh:

```bash
./scripts/prod/meshctl-down-app.sh --bundle run/mesh/bundles/<this-host>.bundle.json
./scripts/prod/meshctl-down-server.sh --bundle run/mesh/bundles/<this-host>.bundle.json
```

For more detail and troubleshooting, see `docs/production-runbook.md`.
