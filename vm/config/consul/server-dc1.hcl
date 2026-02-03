# Example Consul server config for dc1 (non-root friendly).
# For production, run 3+ servers per datacenter and set bootstrap-expect accordingly.

datacenter = "dc1"
# data_dir is set by the start script via `-data-dir`.

ui_config {
  enabled = true
}

connect {
  enabled = true
}

ports {
  grpc = 8502
}

enable_central_service_config = true

# Optional: configure WAN federation via retry_join_wan, e.g.:
# retry_join_wan = ["<dc2-server-ip>"]

# Optional: use encryption for gossip (same key across the datacenter)
# encrypt = "<gossip_key>"
