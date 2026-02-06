#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import urlopen
from urllib.error import URLError, HTTPError


REPO_ROOT = Path(__file__).resolve().parents[1]
CLIENT_HCL = REPO_ROOT / "docker" / "consul" / "client.hcl"


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(2)


def run_proc(cmd: list[str], *, check: bool = True, capture: bool = False, cwd: Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        check=check,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )


def run(cmd: list[str], *, check: bool = True, capture: bool = False, cwd: Path | None = None) -> str:
    proc = run_proc(cmd, check=check, capture=capture, cwd=cwd)
    if capture:
        return (proc.stdout or "").strip()
    return ""


def http_get(url: str, timeout_s: float = 2.0) -> tuple[int, str]:
    try:
        with urlopen(url, timeout=timeout_s) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        return e.code, body
    except URLError as e:
        return 0, str(e)


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def write_env(path: Path, env: dict[str, str]) -> None:
    lines = []
    for k in sorted(env.keys()):
        v = env[k]
        if v is None:
            continue
        lines.append(f"{k}={v}")
    write_text(path, "\n".join(lines))


def load_bundle(bundle_path: Path) -> dict:
    bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
    host = bundle.get("host") or "unknown-host"
    role = bundle.get("role")
    if role not in ("server", "app"):
        die(f"{bundle_path}: bundle.role must be 'server' or 'app'")
    bundle["host"] = host
    return bundle


def expand_bundle(bundle: dict, *, bundle_path: Path) -> tuple[dict, Path, dict]:
    host = bundle["host"]
    role = bundle["role"]

    out_root = REPO_ROOT / "run" / "mesh" / "expanded" / host / role
    files = bundle.get("files", {}) or {}
    env = bundle.get("env", {}) or {}

    if role == "server":
        config_entries = files.get("config_entries") or {}
        config_dir = out_root / "config-entries"
        for name, content in config_entries.items():
            write_text(config_dir / name, content)
        env["CONSUL_CONFIG_ENTRIES_DIR"] = str(config_dir.as_posix())

    if role == "app":
        templates = files.get("service_templates") or {}
        templates_dir = out_root / "services"
        for name, content in templates.items():
            write_text(templates_dir / name, content)
        env["CONSUL_SERVICE_TEMPLATES_DIR"] = str(templates_dir.as_posix())

    env_path = out_root / "runtime.env"
    write_env(env_path, {k: str(v) for k, v in env.items()})

    return bundle, out_root, {k: str(v) for k, v in env.items()}


def wait_for_consul(url_base: str, timeout_s: int) -> None:
    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        code, body = http_get(f"{url_base}/v1/status/leader", timeout_s=2.0)
        if code == 200 and body.strip().strip('"'):
            return
        last = f"{code}: {body[:200]}"
        time.sleep(1)
    die(f"Timed out waiting for Consul leader at {url_base} ({last})")


def podman(args: list[str], *, capture: bool = False, check: bool = True) -> str:
    return run(["podman", *args], capture=capture, check=check)


def podman_exists(kind: str, name: str) -> bool:
    if kind == "pod":
        return run_proc(["podman", "pod", "exists", name], check=False).returncode == 0
    if kind == "container":
        return run_proc(["podman", "container", "exists", name], check=False).returncode == 0
    if kind == "volume":
        return run_proc(["podman", "volume", "exists", name], check=False).returncode == 0
    die(f"Unknown podman kind: {kind}")


def ensure_volume(name: str) -> None:
    if podman_exists("volume", name):
        return
    podman(["volume", "create", name], capture=False)


def ensure_pod(name: str, port_args: list[str]) -> None:
    if podman_exists("pod", name):
        return
    podman(["pod", "create", "--name", name, *port_args], capture=False)


def rm_container(name: str) -> None:
    podman(["rm", "-f", name], check=False)


def rm_pod(name: str) -> None:
    podman(["pod", "rm", "-f", name], check=False)


def parse_csv(value: str) -> list[str]:
    if not value:
        return []
    return [p.strip() for p in value.split(",") if p.strip()]


def require_file(path: Path) -> None:
    if not path.is_file():
        die(f"Missing required file: {path}")


def render_templates(templates_dir: Path, *, host_ip: str, out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    rendered = []
    for p in sorted(templates_dir.glob("*.json")):
        content = p.read_text(encoding="utf-8")
        content = content.replace("__HOST_IP__", host_ip)
        out = out_dir / p.name
        out.write_text(content, encoding="utf-8")
        rendered.append(out)
    return rendered


def parse_service_template(path: Path) -> tuple[str, str, int | None, list[int]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    svc = data.get("service", data)
    name = str(svc.get("name") or "")
    service_id = str(svc.get("id") or "")
    connect = svc.get("connect", {}) or {}
    sidecar = connect.get("sidecar_service", {}) or {}
    sidecar_port = sidecar.get("port")
    proxy = sidecar.get("proxy", {}) or {}
    upstreams = proxy.get("upstreams", []) or []
    upstream_ports: list[int] = []
    for u in upstreams:
        try:
            upstream_ports.append(int(u.get("local_bind_port")))
        except Exception:
            pass
    if not name or not service_id:
        die(f"Invalid service template (missing name/id): {path}")
    if sidecar_port is None:
        return name, service_id, None, upstream_ports
    return name, service_id, int(sidecar_port), upstream_ports


def wait_http_ok(url: str, timeout_s: int) -> None:
    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        code, body = http_get(url, timeout_s=2.0)
        if code == 200:
            return
        last = f"{code}: {body[:200]}"
        time.sleep(1)
    die(f"Timed out waiting for HTTP 200: {url} ({last})")


def up_server(bundle: dict, env: dict, out_root: Path) -> None:
    require_file(CLIENT_HCL)

    dc = env.get("CONSUL_DATACENTER") or bundle.get("dc")
    host_ip = env.get("HOST_IP") or bundle.get("host_ip")
    if not dc or not host_ip:
        die("Missing CONSUL_DATACENTER/HOST_IP in bundle")

    consul_image = env.get("CONSUL_IMAGE") or (bundle.get("images") or {}).get("consul") or "docker.io/hashicorp/consul:1.17"
    envoy_image = env.get("ENVOY_IMAGE") or (bundle.get("images") or {}).get("envoy") or "docker.io/envoyproxy/envoy:v1.29-latest"

    mgmt_bind = env.get("MGMT_BIND_ADDR", "127.0.0.1")
    config_entries_dir = Path(env.get("CONSUL_CONFIG_ENTRIES_DIR", ""))
    if not config_entries_dir.is_dir():
        die(f"Missing CONSUL_CONFIG_ENTRIES_DIR: {config_entries_dir}")

    pod_name = f"mesh-server-{dc}"
    consul_container = f"consul-server-{dc}"
    gw_container = f"mesh-gateway-{dc}"

    consul_data_vol = f"consul-server-data-{dc}"
    gw_bootstrap_vol = f"mesh-gateway-bootstrap-{dc}"
    ensure_volume(consul_data_vol)
    ensure_volume(gw_bootstrap_vol)

    port_args = [
        "-p",
        f"{mgmt_bind}:8500:8500/tcp",
        "-p",
        f"{mgmt_bind}:8502:8502/tcp",
        "-p",
        "8300:8300/tcp",
        "-p",
        "8301:8301/tcp",
        "-p",
        "8301:8301/udp",
        "-p",
        "8302:8302/tcp",
        "-p",
        "8302:8302/udp",
        "-p",
        "8443:8443/tcp",
        "-p",
        f"{mgmt_bind}:29100:29100/tcp",
    ]
    ensure_pod(pod_name, port_args)

    bootstrap_expect = env.get("CONSUL_BOOTSTRAP_EXPECT", "1")
    node = env.get("CONSUL_NODE_NAME", f"consul-server-{dc}-{host_ip.replace('.', '-')}" )
    advertise = env.get("CONSUL_ADVERTISE_ADDR", host_ip)
    advertise_wan = env.get("CONSUL_ADVERTISE_WAN_ADDR", host_ip)

    args = [
        "agent",
        "-config-file=/consul/config/client.hcl",
        "-data-dir=/consul/data",
        "-server",
        f"-bootstrap-expect={bootstrap_expect}",
        f"-node={node}",
        f"-datacenter={dc}",
        "-client=0.0.0.0",
        f"-bind={env.get('CONSUL_BIND_ADDR','0.0.0.0')}",
        f"-advertise={advertise}",
        f"-advertise-wan={advertise_wan}",
    ]
    if env.get("CONSUL_ENABLE_UI", "1") == "1":
        args.append("-ui")
    if env.get("CONSUL_ENCRYPT"):
        args.append(f"-encrypt={env['CONSUL_ENCRYPT']}")

    for addr in parse_csv(env.get("CONSUL_RETRY_JOIN", "")):
        args.append(f"-retry-join={addr}")
    for addr in parse_csv(env.get("CONSUL_RETRY_JOIN_WAN", "")):
        args.append(f"-retry-join-wan={addr}")

    rm_container(consul_container)
    podman(
        [
            "run",
            "-d",
            "--name",
            consul_container,
            "--pod",
            pod_name,
            "--restart",
            "unless-stopped",
            "-v",
            f"{CLIENT_HCL.as_posix()}:/consul/config/client.hcl:ro",
            "-v",
            f"{consul_data_vol}:/consul/data",
            consul_image,
            *args,
        ]
    )

    wait_for_consul(f"http://{mgmt_bind}:8500", timeout_s=180)

    # Apply config entries (idempotent)
    podman(
        [
            "run",
            "--rm",
            "--pod",
            pod_name,
            "-e",
            "CONSUL_HTTP_ADDR=http://127.0.0.1:8500",
            "-v",
            f"{config_entries_dir.as_posix()}:/config-entries:ro",
            consul_image,
            "sh",
            "-ec",
            (
                f"consul config write -datacenter='{dc}' /config-entries/proxy-defaults.hcl\n"
                f"for f in /config-entries/service-defaults-*.hcl; do consul config write -datacenter='{dc}' \"$f\"; done\n"
                f"for f in /config-entries/intentions-*.hcl; do consul config write -datacenter='{dc}' \"$f\"; done\n"
                f"for f in /config-entries/*-resolver-{dc}.hcl; do consul config write -datacenter='{dc}' \"$f\"; done\n"
            ),
        ]
    )

    # Generate mesh gateway bootstrap
    mesh_gateway_address = env.get("MESH_GATEWAY_ADDRESS", f"{host_ip}:8443")
    mesh_gateway_wan_address = env.get("MESH_GATEWAY_WAN_ADDRESS", mesh_gateway_address)
    mesh_gateway_bind_address = env.get("MESH_GATEWAY_BIND_ADDRESS", "0.0.0.0:8443")
    expose_servers = env.get("EXPOSE_SERVERS", "0")

    rm_container(gw_container)
    podman(
        [
            "run",
            "--rm",
            "--pod",
            pod_name,
            "-e",
            "CONSUL_HTTP_ADDR=http://127.0.0.1:8500",
            "-e",
            "CONSUL_GRPC_ADDR=http://127.0.0.1:8502",
            "-e",
            f"CONSUL_DATACENTER={dc}",
            "-e",
            "ENVOY_ADMIN_BIND=0.0.0.0:29100",
            "-e",
            f"MESH_GATEWAY_ADDRESS={mesh_gateway_address}",
            "-e",
            f"MESH_GATEWAY_WAN_ADDRESS={mesh_gateway_wan_address}",
            "-e",
            f"MESH_GATEWAY_BIND_ADDRESS={mesh_gateway_bind_address}",
            "-e",
            f"EXPOSE_SERVERS={expose_servers}",
            "-v",
            f"{gw_bootstrap_vol}:/bootstrap",
            consul_image,
            "sh",
            "-ec",
            (
                "if [ \"${EXPOSE_SERVERS:-0}\" = \"1\" ]; then\n"
                "  consul connect envoy -gateway=mesh -register -service \"mesh-gateway\" "
                "-address \"${MESH_GATEWAY_ADDRESS}\" -wan-address \"${MESH_GATEWAY_WAN_ADDRESS}\" "
                "-bind-address \"default=${MESH_GATEWAY_BIND_ADDRESS}\" -admin-bind \"${ENVOY_ADMIN_BIND}\" "
                "-bootstrap -expose-servers >/bootstrap/bootstrap.json\n"
                "else\n"
                "  consul connect envoy -gateway=mesh -register -service \"mesh-gateway\" "
                "-address \"${MESH_GATEWAY_ADDRESS}\" -wan-address \"${MESH_GATEWAY_WAN_ADDRESS}\" "
                "-bind-address \"default=${MESH_GATEWAY_BIND_ADDRESS}\" -admin-bind \"${ENVOY_ADMIN_BIND}\" "
                "-bootstrap >/bootstrap/bootstrap.json\n"
                "fi\n"
            ),
        ]
    )

    envoy_extra = env.get("ENVOY_EXTRA_ARGS", "")
    podman(
        [
            "run",
            "-d",
            "--name",
            gw_container,
            "--pod",
            pod_name,
            "--restart",
            "unless-stopped",
            "-e",
            f"ENVOY_EXTRA_ARGS={envoy_extra}",
            "-v",
            f"{gw_bootstrap_vol}:/bootstrap:ro",
            envoy_image,
            "sh",
            "-ec",
            "test -s /bootstrap/bootstrap.json; exec envoy -c /bootstrap/bootstrap.json ${ENVOY_EXTRA_ARGS:-}",
        ]
    )


def up_app(bundle: dict, env: dict, out_root: Path) -> None:
    require_file(CLIENT_HCL)

    dc = env.get("CONSUL_DATACENTER") or bundle.get("dc")
    host_ip = env.get("HOST_IP") or bundle.get("host_ip")
    if not dc or not host_ip:
        die("Missing CONSUL_DATACENTER/HOST_IP in bundle")

    consul_image = env.get("CONSUL_IMAGE") or (bundle.get("images") or {}).get("consul") or "docker.io/hashicorp/consul:1.17"
    envoy_image = env.get("ENVOY_IMAGE") or (bundle.get("images") or {}).get("envoy") or "docker.io/envoyproxy/envoy:v1.29-latest"

    templates_dir = Path(env.get("CONSUL_SERVICE_TEMPLATES_DIR", ""))
    if not templates_dir.is_dir():
        die(f"Missing CONSUL_SERVICE_TEMPLATES_DIR: {templates_dir}")

    rendered_dir = out_root / "rendered"
    rendered_paths = render_templates(templates_dir, host_ip=host_ip, out_dir=rendered_dir)

    envoy_admin_offset = int(env.get("ENVOY_ADMIN_PORT_OFFSET", "8000"))

    port_args = [
        "-p",
        "127.0.0.1:8500:8500/tcp",
        "-p",
        "127.0.0.1:8502:8502/tcp",
        "-p",
        "8301:8301/tcp",
        "-p",
        "8301:8301/udp",
    ]

    sidecars: list[tuple[str, str, int, int]] = []  # name,id,sidecar_port,admin_port
    for p in rendered_paths:
        name, service_id, sidecar_port, upstream_ports = parse_service_template(p)
        if sidecar_port is None:
            continue
        admin_port = sidecar_port + envoy_admin_offset
        sidecars.append((name, service_id, sidecar_port, admin_port))
        port_args += ["-p", f"{sidecar_port}:{sidecar_port}/tcp"]
        port_args += ["-p", f"127.0.0.1:{admin_port}:{admin_port}/tcp"]
        for up in upstream_ports:
            port_args += ["-p", f"127.0.0.1:{up}:{up}/tcp"]

    pod_name = f"mesh-app-{dc}"
    agent_container = f"consul-agent-{dc}"
    ensure_pod(pod_name, port_args)

    agent_data_vol = f"consul-agent-data-{dc}"
    ensure_volume(agent_data_vol)

    node = env.get("CONSUL_NODE_NAME", f"app-{dc}-{host_ip.replace('.', '-')}")

    args = [
        "agent",
        "-config-file=/consul/config/client.hcl",
        "-data-dir=/consul/data",
        f"-node={node}",
        f"-datacenter={dc}",
        "-client=0.0.0.0",
        "-config-dir=/consul/config/rendered",
        f"-bind={env.get('CONSUL_BIND_ADDR','0.0.0.0')}",
        f"-advertise={env.get('CONSUL_ADVERTISE_ADDR', host_ip)}",
    ]
    if env.get("CONSUL_ENCRYPT"):
        args.append(f"-encrypt={env['CONSUL_ENCRYPT']}")
    for addr in parse_csv(env.get("CONSUL_RETRY_JOIN", "")):
        args.append(f"-retry-join={addr}")

    rm_container(agent_container)
    podman(
        [
            "run",
            "-d",
            "--name",
            agent_container,
            "--pod",
            pod_name,
            "--restart",
            "unless-stopped",
            "-v",
            f"{CLIENT_HCL.as_posix()}:/consul/config/client.hcl:ro",
            "-v",
            f"{rendered_dir.as_posix()}:/consul/config/rendered:ro",
            "-v",
            f"{agent_data_vol}:/consul/data",
            consul_image,
            *args,
        ]
    )

    wait_http_ok("http://127.0.0.1:8500/v1/agent/self", timeout_s=120)

    envoy_extra = env.get("ENVOY_EXTRA_ARGS", "")
    for name, service_id, sidecar_port, admin_port in sidecars:
        bootstrap_vol = f"{name}-envoy-bootstrap-{dc}"
        ensure_volume(bootstrap_vol)
        rm_container(f"{name}-envoy-{dc}")

        podman(
            [
                "run",
                "--rm",
                "--pod",
                pod_name,
                "-e",
                "CONSUL_HTTP_ADDR=http://127.0.0.1:8500",
                "-e",
                "CONSUL_GRPC_ADDR=http://127.0.0.1:8502",
                "-e",
                f"SERVICE_ID={service_id}",
                "-e",
                f"ENVOY_ADMIN_BIND=0.0.0.0:{admin_port}",
                "-v",
                f"{bootstrap_vol}:/bootstrap",
                consul_image,
                "sh",
                "-ec",
                (
                    "for i in $(seq 1 240); do "
                    "wget -qO- \"http://127.0.0.1:8500/v1/agent/service/${SERVICE_ID}\" >/dev/null 2>&1 && break; "
                    "sleep 1; "
                    "done\n"
                    "wget -qO- \"http://127.0.0.1:8500/v1/agent/service/${SERVICE_ID}\" >/dev/null\n"
                    "consul connect envoy -sidecar-for \"${SERVICE_ID}\" -admin-bind \"${ENVOY_ADMIN_BIND}\" -bootstrap >/bootstrap/bootstrap.json\n"
                ),
            ]
        )

        podman(
            [
                "run",
                "-d",
                "--name",
                f"{name}-envoy-{dc}",
                "--pod",
                pod_name,
                "--restart",
                "unless-stopped",
                "-e",
                f"ENVOY_EXTRA_ARGS={envoy_extra}",
                "-v",
                f"{bootstrap_vol}:/bootstrap:ro",
                envoy_image,
                "sh",
                "-ec",
                "test -s /bootstrap/bootstrap.json; exec envoy -c /bootstrap/bootstrap.json ${ENVOY_EXTRA_ARGS:-}",
            ]
        )


def down_stack(*, dc: str, pod_name: str, volumes: list[str], remove_volumes: bool) -> None:
    rm_pod(pod_name)
    if remove_volumes:
        for v in volumes:
            podman(["volume", "rm", "-f", v], check=False)


def cmd_up_server(args) -> int:
    bundle_path = Path(args.bundle)
    bundle = load_bundle(bundle_path)
    bundle, out_root, env = expand_bundle(bundle, bundle_path=bundle_path)
    up_server(bundle, env, out_root)
    print(f"Up(server): {bundle.get('host')} ({bundle.get('dc')})")
    return 0


def cmd_down_server(args) -> int:
    bundle_path = Path(args.bundle)
    bundle = load_bundle(bundle_path)
    _, _, env = expand_bundle(bundle, bundle_path=bundle_path)
    dc = env.get("CONSUL_DATACENTER") or bundle.get("dc") or ""
    down_stack(
        dc=dc,
        pod_name=f"mesh-server-{dc}",
        volumes=[f"consul-server-data-{dc}", f"mesh-gateway-bootstrap-{dc}"],
        remove_volumes=args.remove_volumes,
    )
    print(f"Down(server): {bundle.get('host')} ({bundle.get('dc')})")
    return 0


def cmd_up_app(args) -> int:
    bundle_path = Path(args.bundle)
    bundle = load_bundle(bundle_path)
    bundle, out_root, env = expand_bundle(bundle, bundle_path=bundle_path)
    up_app(bundle, env, out_root)
    print(f"Up(app): {bundle.get('host')} ({bundle.get('dc')})")
    return 0


def cmd_down_app(args) -> int:
    bundle_path = Path(args.bundle)
    bundle = load_bundle(bundle_path)
    _, out_root, env = expand_bundle(bundle, bundle_path=bundle_path)
    dc = env.get("CONSUL_DATACENTER") or bundle.get("dc") or ""
    # remove volumes for sidecar bootstraps + agent data if asked
    vols = [f"consul-agent-data-{dc}"]
    templates_dir = Path(env.get("CONSUL_SERVICE_TEMPLATES_DIR", ""))
    rendered_dir = out_root / "rendered"
    # If templates exist, derive sidecar bootstrap volume names
    if templates_dir.is_dir():
        for p in sorted(templates_dir.glob("*.json")):
            name, _, sidecar_port, _ = parse_service_template(Path(p))
            if sidecar_port is None:
                continue
            vols.append(f"{name}-envoy-bootstrap-{dc}")
    down_stack(dc=dc, pod_name=f"mesh-app-{dc}", volumes=vols, remove_volumes=args.remove_volumes)
    if rendered_dir.is_dir():
        # best-effort cleanup
        for f in rendered_dir.glob("*.json"):
            f.unlink(missing_ok=True)
    print(f"Down(app): {bundle.get('host')} ({bundle.get('dc')})")
    return 0


def cmd_verify(args) -> int:
    bundle = json.loads(Path(args.bundle).read_text(encoding="utf-8"))
    role = bundle.get("role")
    if role == "server":
        mgmt_bind = (bundle.get("env", {}) or {}).get("MGMT_BIND_ADDR", "127.0.0.1")
        base = f"http://{mgmt_bind}:8500"
        code, body = http_get(f"{base}/v1/status/leader", timeout_s=2.0)
        if code != 200 or not body.strip().strip('"'):
            die(f"Consul not ready at {base} (code={code})")

        # Spot-check key config entries
        checks = [
            ("/v1/config/proxy-defaults/global", "proxy-defaults/global"),
        ]
        # If we have expanded config entries locally, add a few more expected kinds/names.
        host = bundle.get("host") or "unknown-host"
        dc = bundle.get("dc") or ""
        expanded = REPO_ROOT / "run" / "mesh" / "expanded" / host / "server" / "config-entries"
        if expanded.is_dir():
            for p in sorted(expanded.glob("*-resolver-*.hcl"))[:2]:
                # kind/name derived from filename is fragile; keep it as informational only.
                checks.append(("/v1/config/service-resolver/refdata", "service-resolver/refdata"))
                break

        for path, label in checks:
            c, _ = http_get(f"{base}{path}", timeout_s=2.0)
            if c != 200:
                die(f"Missing/invalid config entry: {label} (GET {path} -> {c})")

        print(f"OK: leader={body.strip()}")
        return 0

    if role == "app":
        base = "http://127.0.0.1:8500"
        code, body = http_get(f"{base}/v1/agent/self", timeout_s=2.0)
        if code != 200:
            die(f"Consul agent not ready at {base} (code={code})")

        # Spot-check that expected services are registered (by ID)
        code, body = http_get(f"{base}/v1/agent/services", timeout_s=2.0)
        if code != 200:
            die(f"Failed to read agent services (code={code})")
        try:
            services = json.loads(body)
        except json.JSONDecodeError:
            die("Failed to parse /v1/agent/services response")

        dc = bundle.get("dc")
        templates = ((bundle.get("files") or {}).get("service_templates") or {}).keys()
        expected_ids = {f"{Path(n).stem}-{dc}" for n in templates}
        actual_ids = set(services.keys())
        missing = sorted(expected_ids - actual_ids)
        if missing:
            die(f"Missing registered services: {', '.join(missing)}")

        print("OK: agent reachable; services registered")
        return 0

    die("Unknown role in bundle")


def main() -> int:
    ap = argparse.ArgumentParser(description="Start/stop the Podman-based Consul mesh using a single per-host bundle JSON.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("up-server", help="Expand bundle, then start server+mesh-gateway using podman")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.set_defaults(func=cmd_up_server)

    p = sub.add_parser("down-server", help="Stop server pod (optionally remove volumes)")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.add_argument("--remove-volumes", action="store_true", help="Also delete Podman volumes (data + bootstraps)")
    p.set_defaults(func=cmd_down_server)

    p = sub.add_parser("up-app", help="Expand bundle, then start agent+sidecars using podman")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.set_defaults(func=cmd_up_app)

    p = sub.add_parser("down-app", help="Stop app pod (optionally remove volumes)")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.add_argument("--remove-volumes", action="store_true", help="Also delete Podman volumes (data + bootstraps)")
    p.set_defaults(func=cmd_down_app)

    p = sub.add_parser("verify", help="Basic readiness check (server leader / app agent reachable)")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.set_defaults(func=cmd_verify)

    args = ap.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
