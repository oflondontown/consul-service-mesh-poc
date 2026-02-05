#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
from pathlib import Path


PROXY_DEFAULTS_HCL = """Kind = "proxy-defaults"
Name = "global"

MeshGateway = {
  Mode = "local"
}
"""


def run_inventory(inventory_path: str) -> dict:
    proc = subprocess.run(
        ["ansible-inventory", "-i", inventory_path, "--list"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return json.loads(proc.stdout)


def load_inventory(args) -> dict:
    if args.inventory_json:
        return json.loads(Path(args.inventory_json).read_text(encoding="utf-8"))
    if not args.inventory:
        raise RuntimeError("Missing --inventory or --inventory-json")
    try:
        subprocess.run(
            ["ansible-inventory", "--version"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except FileNotFoundError as e:
        raise RuntimeError(
            "ansible-inventory not found in PATH. Use --inventory-json instead "
            "(generate with: ansible-inventory -i <inventory.yml> --list > inventory.json)."
        ) from e
    return run_inventory(args.inventory)


def get_var(hostvars: dict, key: str, default=None):
    if key in hostvars and hostvars[key] is not None and hostvars[key] != "":
        return hostvars[key]
    return default


def normalize_csv(value: str) -> list[str]:
    if not value:
        return []
    parts = []
    for p in value.split(","):
        p = p.strip()
        if p:
            parts.append(p)
    return parts


def default_instance_role(dc: str) -> str:
    return "primary" if dc == "dc1" else "secondary"


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def write_json(path: Path, data: dict) -> None:
    ensure_dir(path.parent)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def service_template_json(
    *,
    dc: str,
    host_ip_placeholder: str,
    instance_role: str,
    service: dict,
) -> str:
    name = service["name"]
    port = int(service["port"])
    protocol = service.get("protocol", "http")
    tags = service.get("tags", []) or []
    meta = service.get("meta", {}) or {}
    if not isinstance(tags, list):
        raise ValueError(f"service.tags must be a list for {name}")
    if not isinstance(meta, dict):
        raise ValueError(f"service.meta must be a dict for {name}")

    check = service.get("check", {})
    check_type = check.get("type", "http" if protocol in ("http", "grpc", "http2") else "tcp")
    interval = check.get("interval", "5s")
    timeout = check.get("timeout", "1s")
    failures_before_critical = int(check.get("failures_before_critical", 3))
    success_before_passing = int(check.get("success_before_passing", 3))

    svc = {
        "service": {
            "name": name,
            "id": f"{name}-{dc}",
            "address": host_ip_placeholder,
            "port": port,
            "tags": tags,
            "meta": {**meta, "datacenter": dc, "instanceRole": instance_role},
            "check": {
                "id": f"{name}-health",
                "interval": interval,
                "timeout": timeout,
                "failures_before_critical": failures_before_critical,
                "success_before_passing": success_before_passing,
            },
        }
    }

    if check_type == "http":
        path = check.get("path", "/actuator/health")
        svc["service"]["check"]["http"] = f"http://{host_ip_placeholder}:{port}{path}"
    elif check_type == "tcp":
        svc["service"]["check"]["tcp"] = f"{host_ip_placeholder}:{port}"
        svc["service"]["check"]["id"] = f"{name}-tcp"
    else:
        raise ValueError(f"Unsupported check.type for service {name}: {check_type}")

    sidecar_port = service.get("sidecar_port")
    if sidecar_port is not None:
        connect = {"sidecar_service": {"port": int(sidecar_port)}}
        upstreams = service.get("upstreams", [])
        if upstreams:
            connect["sidecar_service"]["proxy"] = {
                "upstreams": [
                    {
                        "destination_name": u["destination_name"],
                        "local_bind_address": u.get("local_bind_address", "0.0.0.0"),
                        "local_bind_port": int(u["local_bind_port"]),
                    }
                    for u in upstreams
                ]
            }
        svc["service"]["connect"] = connect

    return json.dumps(svc, indent=2)


def hcl_service_defaults(name: str, protocol: str) -> str:
    if protocol not in ("http", "tcp"):
        protocol = "http"
    return f'Kind = "service-defaults"\nName = "{name}"\nProtocol = "{protocol}"\n'


def hcl_intentions(dest: str, sources: list[str]) -> str:
    sources_hcl = ",\n".join([f'  {{\n    Name   = "{s}"\n    Action = "allow"\n  }}' for s in sources])
    return f'Kind = "service-intentions"\nName = "{dest}"\nSources = [\n{sources_hcl}\n]\n'


def hcl_resolver_dc1(name: str) -> str:
    return f'Kind = "service-resolver"\nName = "{name}"\n\nFailover = {{\n  "*" = {{\n    Datacenters = ["dc2"]\n  }}\n}}\n'


def hcl_resolver_dc2_prefer_dc1(name: str) -> str:
    return f"""Kind = "service-resolver"
Name = "{name}"

DefaultSubset = "primary"

Subsets = {{
  "primary" = {{
    Filter = "Service.Meta.instanceRole == \\"primary\\""
  }}
  "secondary" = {{
    Filter = "Service.Meta.instanceRole == \\"secondary\\""
  }}
}}

Failover = {{
  "primary" = {{
    Targets = [
      {{
        Datacenter    = "dc1"
        ServiceSubset = "primary"
      }},
      {{
        Datacenter    = "dc2"
        ServiceSubset = "secondary"
      }}
    ]
  }}
}}
"""


def main() -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Render per-host mesh bundle JSONs from an Ansible inventory. "
            "Bundles are the single runtime input for starting/stopping the mesh with tools/meshctl.py."
        )
    )
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--inventory", "-i", help="Path to YAML inventory (used with ansible-inventory).")
    g.add_argument("--inventory-json", help="Path to ansible-inventory JSON output.")
    ap.add_argument("--out-dir", "-o", default="run/mesh/bundles", help="Output directory (default: run/mesh/bundles).")
    args = ap.parse_args()

    inv = load_inventory(args)
    all_vars = inv.get("all", {}).get("vars", {})
    hostvars = inv.get("_meta", {}).get("hostvars", {})
    out_dir = Path(args.out_dir)

    consul_servers = set(inv.get("consul_servers", {}).get("hosts", []))
    app_hosts = set(inv.get("app_hosts", {}).get("hosts", []))

    service_catalog = all_vars.get("service_catalog") or []
    if not isinstance(service_catalog, list) or not service_catalog:
        raise SystemExit("Inventory is missing all:vars.service_catalog (list of services).")

    services_by_name: dict[str, dict] = {}
    for s in service_catalog:
        if not isinstance(s, dict) or "name" not in s or "port" not in s:
            raise SystemExit("Invalid service_catalog entry (need at least name, port).")
        name = s["name"]
        if not re.match(r"^[a-z0-9][a-z0-9\\-]*$", name):
            raise SystemExit(f"Invalid service name: {name}")
        services_by_name[name] = s

    # Derive intentions from upstream relationships
    dest_sources: dict[str, set[str]] = {}
    for s in service_catalog:
        src = s["name"]
        for u in s.get("upstreams", []) or []:
            dest = u["destination_name"]
            dest_sources.setdefault(dest, set()).add(src)

    # Common config entries content (strings), used by server bundles
    common_config_entries: dict[str, str] = {"proxy-defaults.hcl": PROXY_DEFAULTS_HCL}
    for name, s in services_by_name.items():
        common_config_entries[f"service-defaults-{name}.hcl"] = hcl_service_defaults(name, s.get("protocol", "http"))
    for dest, sources in sorted(dest_sources.items()):
        common_config_entries[f"intentions-{dest}.hcl"] = hcl_intentions(dest, sorted(sources))
    for name in services_by_name.keys():
        common_config_entries[f"{name}-resolver-dc1.hcl"] = hcl_resolver_dc1(name)
    prefer_primary = set(all_vars.get("dc2_prefer_dc1_services") or [])
    for name in prefer_primary:
        if name in services_by_name:
            common_config_entries[f"{name}-resolver-dc2.hcl"] = hcl_resolver_dc2_prefer_dc1(name)

    # Bundles per host
    for host, hv in hostvars.items():
        dc = get_var(hv, "dc")
        host_ip = get_var(hv, "host_ip")
        if not dc or not host_ip:
            continue

        consul_image = get_var(hv, "consul_image", get_var(all_vars, "consul_image", "docker.io/hashicorp/consul:1.17"))
        envoy_image = get_var(hv, "envoy_image", get_var(all_vars, "envoy_image", "docker.io/envoyproxy/envoy:v1.29-latest"))

        enabled_services = normalize_csv(get_var(hv, "enabled_services", get_var(all_vars, "enabled_services", "")))
        enable_itch_consumer = str(get_var(hv, "enable_itch_consumer", get_var(all_vars, "enable_itch_consumer", "0")))
        mgmt_bind_addr = get_var(hv, "mgmt_bind_addr", get_var(all_vars, "mgmt_bind_addr", "127.0.0.1"))

        instance_role = str(get_var(hv, "instance_role", default_instance_role(dc)))

        bundle: dict = {
            "version": 1,
            "host": host,
            "dc": dc,
            "host_ip": host_ip,
            "images": {"consul": consul_image, "envoy": envoy_image},
            "env": {
                "CONSUL_DATACENTER": dc,
                "HOST_IP": host_ip,
                "CONSUL_IMAGE": consul_image,
                "ENVOY_IMAGE": envoy_image,
            },
            "files": {},
        }

        if host in consul_servers:
            bundle["role"] = "server"
            bundle["env"].update(
                {
                    "CONSUL_BOOTSTRAP_EXPECT": str(get_var(hv, "consul_bootstrap_expect", "1")),
                    "CONSUL_RETRY_JOIN": str(get_var(hv, "consul_retry_join", "")),
                    "CONSUL_RETRY_JOIN_WAN": str(get_var(hv, "consul_retry_join_wan", "")),
                    "CONSUL_ENABLE_UI": str(get_var(hv, "consul_enable_ui", "1")),
                    "ENVOY_EXTRA_ARGS": str(get_var(hv, "envoy_extra_args", "")),
                    "MGMT_BIND_ADDR": str(mgmt_bind_addr),
                }
            )
            bundle["files"]["config_entries"] = common_config_entries

        if host in app_hosts:
            bundle["role"] = "app"
            bundle["env"].update(
                {
                    "CONSUL_RETRY_JOIN": str(get_var(hv, "consul_retry_join", "")),
                    "ENVOY_EXTRA_ARGS": str(get_var(hv, "envoy_extra_args", "")),
                    "ENABLED_SERVICES": ",".join(enabled_services),
                    "ENABLE_ITCH_CONSUMER": enable_itch_consumer,
                }
            )

            if not enabled_services:
                enabled_services = list(services_by_name.keys())

            templates: dict[str, str] = {}
            for name in enabled_services:
                if name == "itch-consumer" and enable_itch_consumer != "1":
                    continue
                svc = services_by_name.get(name)
                if not svc:
                    raise SystemExit(f"{host}: enabled service not found in service_catalog: {name}")
                templates[f"{name}.json"] = service_template_json(
                    dc=dc,
                    host_ip_placeholder="__HOST_IP__",
                    instance_role=instance_role,
                    service=svc,
                )
            bundle["files"]["service_templates"] = templates

        if "role" not in bundle:
            continue

        write_json(out_dir / f"{host}.bundle.json", bundle)

    print(f"Wrote bundles under: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

