Kind = "service-intentions"
Name = "refdata"
Sources = [
  {
    Name   = "webservice"
    Action = "allow"
  },
  {
    Name   = "ordermanager"
    Action = "allow"
  }
]

---
Kind = "service-intentions"
Name = "ordermanager"
Sources = [
  {
    Name   = "webservice"
    Action = "allow"
  }
]

---
Kind = "service-intentions"
Name = "itch-feed"
Sources = [
  {
    Name   = "itch-consumer"
    Action = "allow"
  }
]
