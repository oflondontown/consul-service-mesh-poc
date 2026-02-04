# Non-root VM deployment (RHEL 8.10)

This folder provides **non-root** (user-level) scripts and example configs to run the same Consul + Envoy service-mesh pattern as the Docker/Podman MVP, but on **VMs**.

Assumptions:

- You can run long-lived processes under a non-root service account.
- You can open the required network ports between nodes (or you will add mesh gateways; see note below).
- You have `bash` and `curl` available on RHEL 8.10.

What “non-root” means here:

- No `systemctl` root services required.
- No privileged ports (<1024).
- No iptables-based transparent proxying.
- Apps call upstreams via explicit `localhost:<port>` listeners provided by the Envoy sidecar.

## Terminology (quick glossary)

- **VM**: a machine (in your case, a RHEL 8.10 VM).
- **Consul agent**: the `consul agent ...` **process** that runs on a node/VM.
- **Consul server**: a Consul agent running with `-server` enabled (participates in Raft and stores the catalog/state).
- **Consul client agent**: a Consul agent **not** running in server mode (registers services, runs checks, talks to servers).
- **Server VM / server node** (in this doc): a VM that runs a **Consul server** process.
- **App VM / service node** (in this doc): a VM that runs application workloads (often with a local Consul client agent + Envoy sidecars).
- **Mesh gateway**: an Envoy process started as `consul connect envoy -gateway=mesh ...` and registered as a gateway service.

## Directory layout

- `vm/config/consul/`
  - Example Consul server/client configs for VM deployments.
- `vm/config/nodes/`
  - Example per-VM "node" config (for running multiple services on one VM), e.g. sidecar admin port allocations.
- `vm/config/services/`
  - Example service registration files (one per service instance per DC).
- `vm/scripts/`
  - Start/stop scripts for Consul server/agent and Envoy sidecars (run as a normal user).

## Install binaries (example)

Install the binaries somewhere user-writable (Ansible can do this), e.g.:

- `/opt/mesh/bin/consul`
- `/opt/mesh/bin/envoy`

Or in the service account home:

- `~/bin/consul`
- `~/bin/envoy`

The scripts default to `consul` on `PATH`. Override with `CONSUL_BIN=/path/to/consul`.

## Running multiple services on one VM (your 2-VM / 2-DC layout)

If you run **many services on the same VM** (all primaries on one VM in `dc1`, all secondaries on one VM in `dc2`),
you typically run:

- **one** Consul process on the VM (**server** or **client agent**)
- one mesh gateway process (recommended for cross-DC traffic)
- one Envoy sidecar process **per service**

Production note: running **only one Consul server per datacenter** (and co-locating it with workloads) is a trade-off.
It works for a PoC, but you lose control-plane HA in that datacenter. Typical production guidance is **3+ Consul servers per DC**,
separate from application workloads if possible.

Important gotchas when co-locating services:

- **Envoy admin ports must be unique** per sidecar on the VM.
- **Upstream listener ports must be unique** per sidecar on the VM.
  - In this repo’s VM service defs:
    - `webservice` uses `localhost:18082` (refdata) and `localhost:18083` (ordermanager)
    - `ordermanager` uses `localhost:18182` (refdata) to avoid clashing with webservice’s `18082`
    - `itch-consumer` uses `localhost:19100` (itch-feed) to avoid clashing with common Envoy admin ports

This repo includes a convenience wrapper that starts the “host runtime” (Consul + mesh gateway + all sidecars):

- Start: `vm/scripts/start-host.sh`
- Stop: `vm/scripts/stop-host.sh`

It uses example inputs:

- Service definitions: `vm/config/services/<dc>/*.json` (loaded by the Consul process)
- Sidecar admin ports: `vm/config/nodes/<dc>/sidecars.txt`

## 1) Start Consul servers (dc1 and dc2)

You need at least one Consul server per datacenter for the POC (prod should be 3+ per DC).

Make scripts executable:

```bash
chmod +x vm/scripts/*.sh
```

### Single-VM-per-DC quickstart (runs everything on the same VM)

On your **dc1 VM** (primaries):

```bash
export CONSUL_DATACENTER=dc1
export CONSUL_NODE_NAME=dc1-host
export CONSUL_BIND_ADDR=<dc1-vm-ip>
export CONSUL_CLIENT_ADDR=127.0.0.1
export CONSUL_DATA_DIR=~/run/consul
./vm/scripts/start-host.sh
```

On your **dc2 VM** (secondaries):

```bash
export CONSUL_DATACENTER=dc2
export CONSUL_NODE_NAME=dc2-host
export CONSUL_BIND_ADDR=<dc2-vm-ip>
export CONSUL_CLIENT_ADDR=127.0.0.1
export CONSUL_DATA_DIR=~/run/consul
./vm/scripts/start-host.sh
```

This starts:

- a Consul **server** process on the VM (default `CONSUL_MODE=server`)
- a mesh gateway (default `START_MESH_GATEWAY=1`, binds `:8443` on `CONSUL_BIND_ADDR`)
- Envoy sidecars for each service listed in `vm/config/nodes/<dc>/sidecars.txt`

Stop:

```bash
export CONSUL_DATACENTER=dc1
./vm/scripts/stop-host.sh
```

If you decide to run Consul servers on separate boxes later, set `CONSUL_MODE=agent` and `CONSUL_RETRY_JOIN` and the same wrapper still works.

After both VMs are up, continue with:

- **WAN federation** (section 2) so `dc1` can discover `dc2`
- **Apply central config entries** (section 3) so resolvers/intentions are installed in both DCs

On a server node in **dc1**:

```bash
export CONSUL_DATACENTER=dc1
export CONSUL_NODE_NAME=consul-dc1-1
export CONSUL_BIND_ADDR=<dc1-server-ip>
export CONSUL_CLIENT_ADDR=0.0.0.0
export CONSUL_DATA_DIR=~/run/consul-server
export CONSUL_CONFIG_FILE=vm/config/consul/server-dc1.hcl
export CONSUL_BOOTSTRAP_EXPECT=1
export PID_FILE=~/run/pids/consul-server.pid
./vm/scripts/start-consul-server.sh
```

On a server node in **dc2**:

```bash
export CONSUL_DATACENTER=dc2
export CONSUL_NODE_NAME=consul-dc2-1
export CONSUL_BIND_ADDR=<dc2-server-ip>
export CONSUL_CLIENT_ADDR=0.0.0.0
export CONSUL_DATA_DIR=~/run/consul-server
export CONSUL_CONFIG_FILE=vm/config/consul/server-dc2.hcl
export CONSUL_BOOTSTRAP_EXPECT=1
export PID_FILE=~/run/pids/consul-server.pid
./vm/scripts/start-consul-server.sh
```

## 2) WAN federation (enable cross-DC discovery)

To allow `dc1` to discover `dc2` services (needed for cross-DC failover), join the WAN:

```bash
export CONSUL_HTTP_ADDR=http://127.0.0.1:8500
consul join -wan <dc2-server-ip>
```

Run the symmetric join from dc2 to dc1 as well (or set `retry_join_wan` in server config).

## 2b) Mesh gateways (recommended for real multi-DC)

Mesh gateways reduce the network blast radius for cross-DC service traffic. Instead of allowing every node in `dc1` to connect to every node in `dc2`, you allow:

- `dc1` nodes → `dc1` mesh gateway (local)
- `dc1` mesh gateway ↔ `dc2` mesh gateway (cross-DC)
- `dc2` mesh gateway → `dc2` destination services (local)

Start one mesh gateway in each datacenter (often on dedicated VMs).

On the mesh gateway host in **dc1**:

```bash
export CONSUL_HTTP_ADDR=http://127.0.0.1:8500
export GATEWAY_SERVICE_NAME=mesh-gateway-dc1
export GATEWAY_ADDRESS=<dc1-gateway-private-ip>:8443
export GATEWAY_WAN_ADDRESS=<dc1-gateway-wan-ip-or-same>:8443
export PID_FILE=~/run/pids/mesh-gateway.pid
./vm/scripts/start-mesh-gateway.sh
```

On the mesh gateway host in **dc2**:

```bash
export CONSUL_HTTP_ADDR=http://127.0.0.1:8500
export GATEWAY_SERVICE_NAME=mesh-gateway-dc2
export GATEWAY_ADDRESS=<dc2-gateway-private-ip>:8443
export GATEWAY_WAN_ADDRESS=<dc2-gateway-wan-ip-or-same>:8443
export PID_FILE=~/run/pids/mesh-gateway.pid
./vm/scripts/start-mesh-gateway.sh
```

Note: this repo enables mesh gateways for cross-DC traffic via a `proxy-defaults` config entry (`MeshGateway.Mode = "local"`).

## 3) Apply central config entries (intentions, resolvers, defaults)

Run once (from anywhere that can reach the dc1 and dc2 Consul HTTP APIs):

```bash
export CONSUL_HTTP_ADDR=http://<dc1-server-ip>:8500
./vm/scripts/apply-consul-config.sh
```

This script writes the same config entries used by the container MVP (service-defaults, intentions, resolvers).

## 4) Start a service node (example: webservice dc1)

On the VM that runs `webservice` in dc1:

1. Start a local Consul **client agent** that registers the service:

```bash
export CONSUL_DATACENTER=dc1
export CONSUL_NODE_NAME=webservice-dc1
export CONSUL_BIND_ADDR=<this-vm-ip>
export CONSUL_CLIENT_ADDR=127.0.0.1
export CONSUL_DATA_DIR=~/run/consul-agent
export CONSUL_RETRY_JOIN="<dc1-server-ip>"
export CONSUL_SERVICE_DEF=vm/config/services/dc1/webservice.json
export PID_FILE=~/run/pids/consul-agent.pid
./vm/scripts/start-consul-agent.sh
```

2. Start the Envoy sidecar:

```bash
export CONSUL_HTTP_ADDR=http://127.0.0.1:8500
export SERVICE_ID=webservice-dc1
export PID_FILE=~/run/pids/envoy.pid
./vm/scripts/start-envoy-sidecar.sh
```

3. Start the application (from Nexus/Ansible artifact):

```bash
export PORT=8080
export REFDATA_BASE_URL=http://127.0.0.1:18082
export ORDERMANAGER_BASE_URL=http://127.0.0.1:18083
java -jar webservice.jar
```

Example (ordermanager dc1):

```bash
export PORT=8081
# Note: ordermanager uses a different upstream port to avoid clashing with webservice on the same VM.
export REFDATA_BASE_URL=http://127.0.0.1:18182
java -jar ordermanager.jar
```

Example (itch-consumer dc1):

```bash
export PORT=9100
export ITCH_HOST=127.0.0.1
export ITCH_PORT=19100
java -jar itch-consumer.jar
```

### Optional wrapper (one command to start agent + sidecar)

The start scripts in `vm/scripts/` run long-lived processes in the **background** by default and exit
`0`/non-zero based on whether startup checks succeeded.

If you prefer a single command to start (or re-start) both the Consul agent and Envoy sidecar,
use `vm/scripts/run-service-node.sh`. It runs the two start scripts and exits `0` only if both
processes started successfully.

Note: `run-service-node.sh` is intended for the **one-service-per-VM** pattern (one Consul agent per VM).
If you run **multiple services on the same VM**, use `vm/scripts/start-host.sh` instead.

Example (webservice dc1):

```bash
export CONSUL_DATACENTER=dc1
export CONSUL_NODE_NAME=webservice-dc1
export CONSUL_BIND_ADDR=<this-vm-ip>
export CONSUL_CLIENT_ADDR=127.0.0.1
export CONSUL_DATA_DIR=~/run/consul-agent
export CONSUL_RETRY_JOIN="<dc1-server-ip>"
export CONSUL_SERVICE_DEF=vm/config/services/dc1/webservice.json
export SERVICE_ID=webservice-dc1
./vm/scripts/run-service-node.sh
```

To stop the node using pidfiles (optional):

```bash
export SERVICE_ID=webservice-dc1
./vm/scripts/stop-service-node.sh
```

## Mesh gateway note (recommended for real multi-DC)

This repo includes mesh gateway scripts/config for the VM deployment (see section 2b above).

## Stopping processes (optional)

If you set `PID_FILE` when starting a process, you can stop it with:

```bash
./vm/scripts/stop-by-pidfile.sh ~/run/pids/envoy.pid
```
