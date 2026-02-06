datacenter = "dc2"
data_dir = "/consul/data"
client_addr = "0.0.0.0"

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

retry_join_wan = ["consul-dc1"]
