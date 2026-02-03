data_dir = "/consul/data"
client_addr = "0.0.0.0"

connect {
  enabled = true
}

ports {
  grpc = 8502
}

enable_central_service_config = true
