Kind = "service-resolver"
Name = "ordermanager"

# -----------------------------------------------------------------------------
# How to read this file (Consul Service Resolver)
#
# Keywords (schema fields for Kind="service-resolver"):
# - Kind, Name, DefaultSubset, Subsets, Failover, Filter, Targets, Datacenter, ServiceSubset
#
# Lookups / user-defined keys (labels you choose):
# - "primary" / "secondary" are *subset names* (map keys). They must match anywhere
#   they are referenced (DefaultSubset and ServiceSubset).
#
# How the filter works:
# - Filter is a Consul service filter expression evaluated against discovered
#   instances. Service.Meta.* comes from the service registration "meta" map
#   (see vm/config/services/dc1/ordermanager.json and vm/config/services/dc2/ordermanager.json).
#
# How failover works:
# - Failover["primary"].Targets defines the ordered targets to try when routing to
#   the "primary" subset and there are no healthy instances for that subset in the
#   caller's datacenter:
#     1) prefer dc1 + subset "primary"
#     2) fall back to dc2 + subset "secondary"
#
# Result:
# - Callers *in dc2* that resolve "ordermanager" will prefer the dc1 primary when
#   it is healthy; otherwise they will use the dc2 secondary.
# -----------------------------------------------------------------------------

# In dc2 (DR site), prefer the primary dc1 ordermanager when it exists.
# If dc1 is unavailable/unhealthy, fall back to the local dc2 ordermanager.
DefaultSubset = "primary"

Subsets = {
  "primary" = {
    Filter = "Service.Meta.instanceRole == \"primary\""
  }
  "secondary" = {
    Filter = "Service.Meta.instanceRole == \"secondary\""
  }
}

Failover = {
  "primary" = {
    Targets = [
      {
        Datacenter    = "dc1"
        ServiceSubset = "primary"
      },
      {
        Datacenter    = "dc2"
        ServiceSubset = "secondary"
      }
    ]
  }
}
