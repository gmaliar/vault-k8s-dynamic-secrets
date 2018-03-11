path "database/creds/postgres-role" {
  capabilities = ["read"]
}

path "sys/leases/renew" {
  capabilities = ["create"]
}

path "sys/leases/revoke" {
  capabilities = ["update"]
}
