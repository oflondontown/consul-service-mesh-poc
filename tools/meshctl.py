#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError


REPO_ROOT = Path(__file__).resolve().parents[1]


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(2)


def run(cmd: list[str], *, check: bool = True, capture: bool = False, cwd: Path | None = None) -> str:
    proc = subprocess.run(
        cmd,
        check=check,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )
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


def expand_bundle(bundle_path: Path) -> tuple[dict, Path]:
    bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
    host = bundle.get("host") or "unknown-host"
    role = bundle.get("role")
    if role not in ("server", "app"):
        die(f"{bundle_path}: bundle.role must be 'server' or 'app'")

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

    return bundle, out_root


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


def cmd_up_server(args) -> int:
    bundle, out_root = expand_bundle(Path(args.bundle))
    env_file = out_root / "runtime.env"

    script = REPO_ROOT / "scripts" / "prod" / "podman-up-server.sh"
    run([str(script), "--env-file", str(env_file)])

    mgmt_bind = (bundle.get("env", {}) or {}).get("MGMT_BIND_ADDR", "127.0.0.1")
    wait_for_consul(f"http://{mgmt_bind}:8500", timeout_s=180)
    print(f"Up(server): {bundle.get('host')} ({bundle.get('dc')})")
    return 0


def cmd_down_server(args) -> int:
    bundle, out_root = expand_bundle(Path(args.bundle))
    env_file = out_root / "runtime.env"

    script = REPO_ROOT / "scripts" / "prod" / "podman-down-server.sh"
    run([str(script), "--env-file", str(env_file)])
    print(f"Down(server): {bundle.get('host')} ({bundle.get('dc')})")
    return 0


def cmd_up_app(args) -> int:
    bundle, out_root = expand_bundle(Path(args.bundle))
    env_file = out_root / "runtime.env"

    script = REPO_ROOT / "scripts" / "prod" / "podman-up-app.sh"
    run([str(script), "--env-file", str(env_file)])

    # agent API is published to localhost on the app host by the pod
    wait_for_consul("http://127.0.0.1:8500", timeout_s=120)
    print(f"Up(app): {bundle.get('host')} ({bundle.get('dc')})")
    return 0


def cmd_down_app(args) -> int:
    bundle, out_root = expand_bundle(Path(args.bundle))
    env_file = out_root / "runtime.env"

    script = REPO_ROOT / "scripts" / "prod" / "podman-down-app.sh"
    run([str(script), "--env-file", str(env_file)])
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

    p = sub.add_parser("up-server", help="Expand bundle, then start server+mesh-gateway pod using scripts/prod/podman-up-server.sh")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.set_defaults(func=cmd_up_server)

    p = sub.add_parser("down-server", help="Expand bundle, then stop server pod using scripts/prod/podman-down-server.sh")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.set_defaults(func=cmd_down_server)

    p = sub.add_parser("up-app", help="Expand bundle, then start agent+sidecars pod using scripts/prod/podman-up-app.sh")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.set_defaults(func=cmd_up_app)

    p = sub.add_parser("down-app", help="Expand bundle, then stop app pod using scripts/prod/podman-down-app.sh")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.set_defaults(func=cmd_down_app)

    p = sub.add_parser("verify", help="Basic readiness check (server leader / app agent reachable)")
    p.add_argument("--bundle", required=True, help="Path to <host>.bundle.json")
    p.set_defaults(func=cmd_verify)

    args = ap.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
