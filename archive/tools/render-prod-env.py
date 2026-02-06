#!/usr/bin/env python3
import argparse
import json
import subprocess
from pathlib import Path


def run_inventory(inventory_path: str) -> dict:
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
            "ansible-inventory not found in PATH. Either install Ansible on the control machine, "
            "or run `ansible-inventory -i <inventory.yml> --list > inventory.json` and use "
            "`--inventory-json inventory.json`."
        ) from e

    proc = subprocess.run(
        ["ansible-inventory", "-i", inventory_path, "--list"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return json.loads(proc.stdout)


def get_var(hostvars: dict, key: str, default=None):
    if key in hostvars and hostvars[key] is not None and hostvars[key] != "":
        return hostvars[key]
    return default


def write_env(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    content = "\n".join(lines).rstrip() + "\n"
    path.write_text(content, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="Render scripts/prod env files from an Ansible YAML inventory.")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--inventory", "-i", help="Path to YAML inventory (used with ansible-inventory).")
    g.add_argument(
        "--inventory-json",
        help="Path to ansible-inventory JSON output (from: ansible-inventory -i <inventory.yml> --list).",
    )
    ap.add_argument("--out-dir", "-o", default="run/ansible", help="Output root (default: run/ansible).")
    args = ap.parse_args()

    if args.inventory_json:
        inv = json.loads(Path(args.inventory_json).read_text(encoding="utf-8"))
    else:
        try:
            inv = run_inventory(args.inventory)
        except RuntimeError as e:
            ap.error(str(e))
            return 2
    hostvars = inv.get("_meta", {}).get("hostvars", {})
    out_root = Path(args.out_dir)

    consul_servers = set(inv.get("consul_servers", {}).get("hosts", []))
    app_hosts = set(inv.get("app_hosts", {}).get("hosts", []))
    common_config_entries_dir = out_root / "common" / "config-entries"

    for host, hv in hostvars.items():
        dc = get_var(hv, "dc")
        host_ip = get_var(hv, "host_ip")
        if not dc or not host_ip:
            continue

        common = {
            "CONSUL_IMAGE": get_var(hv, "consul_image", get_var(inv.get("all", {}).get("vars", {}), "consul_image")),
            "ENVOY_IMAGE": get_var(hv, "envoy_image", get_var(inv.get("all", {}).get("vars", {}), "envoy_image")),
            "ENABLED_SERVICES": get_var(hv, "enabled_services", get_var(inv.get("all", {}).get("vars", {}), "enabled_services", "")),
            "ENABLE_ITCH_CONSUMER": get_var(hv, "enable_itch_consumer", get_var(inv.get("all", {}).get("vars", {}), "enable_itch_consumer", "0")),
            "MGMT_BIND_ADDR": get_var(hv, "mgmt_bind_addr", get_var(inv.get("all", {}).get("vars", {}), "mgmt_bind_addr", "127.0.0.1")),
        }

        if host in consul_servers:
            env_path = out_root / host / "server.env"
            lines = [
                f"CONSUL_DATACENTER={dc}",
                f"HOST_IP={host_ip}",
                f"CONSUL_BOOTSTRAP_EXPECT={get_var(hv, 'consul_bootstrap_expect', '1')}",
                f"CONSUL_RETRY_JOIN={get_var(hv, 'consul_retry_join', '')}",
                f"CONSUL_RETRY_JOIN_WAN={get_var(hv, 'consul_retry_join_wan', '')}",
                f"CONSUL_ENABLE_UI={get_var(hv, 'consul_enable_ui', '1')}",
                f"CONSUL_IMAGE={common['CONSUL_IMAGE']}",
                f"ENVOY_IMAGE={common['ENVOY_IMAGE']}",
                f"ENVOY_EXTRA_ARGS={get_var(hv, 'envoy_extra_args', '')}",
                f"MGMT_BIND_ADDR={common['MGMT_BIND_ADDR']}",
                f"CONSUL_CONFIG_ENTRIES_DIR={common_config_entries_dir.as_posix()}",
            ]
            write_env(env_path, lines)

        if host in app_hosts:
            env_path = out_root / host / "app.env"
            templates_dir = (out_root / host / "services").as_posix()
            lines = [
                f"CONSUL_DATACENTER={dc}",
                f"HOST_IP={host_ip}",
                f"CONSUL_RETRY_JOIN={get_var(hv, 'consul_retry_join', '')}",
                f"CONSUL_IMAGE={common['CONSUL_IMAGE']}",
                f"ENVOY_IMAGE={common['ENVOY_IMAGE']}",
                f"ENVOY_EXTRA_ARGS={get_var(hv, 'envoy_extra_args', '')}",
                f"ENABLED_SERVICES={common['ENABLED_SERVICES']}",
                f"ENABLE_ITCH_CONSUMER={common['ENABLE_ITCH_CONSUMER']}",
                f"CONSUL_SERVICE_TEMPLATES_DIR={templates_dir}",
            ]
            write_env(env_path, lines)

    print(f"Wrote env files under: {out_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
