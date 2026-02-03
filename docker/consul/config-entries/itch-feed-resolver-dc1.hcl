Kind = "service-resolver"
Name = "itch-feed"

Failover = {
  "*" = {
    Datacenters = ["dc2"]
  }
}
