# Example Consul client agent config (non-root friendly).
# The scripts start the agent with:
# - client address (usually 127.0.0.1)
# - bind address (the VM's IP)

# data_dir and client_addr are set by the start script via `-data-dir` and `-client`.

connect {
  enabled = true
}

ports {
  grpc = 8502
}

enable_central_service_config = true
