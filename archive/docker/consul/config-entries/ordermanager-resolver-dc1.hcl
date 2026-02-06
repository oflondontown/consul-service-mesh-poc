Kind = "service-resolver"
Name = "ordermanager"

Failover = {
  "*" = {
    Datacenters = ["dc2"]
  }
}
