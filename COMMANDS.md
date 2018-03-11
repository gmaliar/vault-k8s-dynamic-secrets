```sh
brew install kubernetes-helm vault consul kubectl
brew cask install virtualbox
brew cask install minikube

minikube --vm-driver=virualbox start
helm init

helm install --name consul stable/consul --set Replicas=1

helm repo add incubator http://storage.googleapis.com/kubernetes-charts-incubator
helm install incubator/vault --set vault.dev=true --set vault.config.storage.consul.address="consul-consul:8500",vault.config.storage.consul.path="vault"

helm install stable/postgresql --set postgresUser=root,postgresPassword=root,postgresDatabase=rails_development


VAULT_POD=$(kubectl get pods --namespace default -l "app=vault" -o jsonpath="{.items[0].metadata.name}")

kubectl port-forward $VAULT_POD 8200
kubectl logs $VAULT_POD

export VAULT_TOKEN=$(kubectl logs $VAULT_POD | grep 'Root Token' | cut -d' ' -f3)
export VAULT_ADDR=http://127.0.0.1:8200

echo $VAULT_TOKEN | vault login -
vault status

vault secrets enable database
vault write database/config/postgres \
    plugin_name=postgresql-database-plugin \
    allowed_roles="postgres-role" \
    connection_url="postgresql://root:root@intended-moth-postgresql.default.svc.cluster.local:5432/rails_development?sslmode=disable"

vault write database/roles/postgres-role \
    db_name=postgres \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

vault read -format json database/creds/postgres-role
vault lease renew
vault lease revoke


cat > postgres-policy.hcl <<EOF
path "database/creds/postgres-role" {
  capabilities = ["read"]
}

path "sys/leases/renew" {
  capabilities = ["create"]
}

path "sys/leases/revoke" {
  capabilities = ["update"]
}
EOF

vault policy write postgres-policy postgres-policy.hcl

cat > postgres-serviceaccount.yml <<EOF
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: role-tokenreview-binding
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: postgres-vault
  namespace: default
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: postgres-vault
EOF

kubectl apply -f postgres-serviceaccount.yml

export VAULT_SA_NAME=$(kubectl get sa postgres-vault -o jsonpath="{.secrets[*]['name']}")
export SA_JWT_TOKEN=$(kubectl get secret $VAULT_SA_NAME -o jsonpath="{.data.token}" | base64 --decode; echo)
export SA_CA_CRT=$(kubectl get secret $VAULT_SA_NAME -o jsonpath="{.data['ca\.crt']}" | base64 --decode; echo)
export K8S_HOST=$(kubectl exec consul-consul-0 -- sh -c 'echo $KUBERNETES_SERVICE_HOST')

vault auth enable kubernetes

vault write auth/kubernetes/config \
  token_reviewer_jwt="$SA_JWT_TOKEN" \
  kubernetes_host="https://$K8S_HOST:443" \
  kubernetes_ca_cert="$SA_CA_CRT"

vault write auth/kubernetes/role/postgres \
    bound_service_account_names=postgres-vault \
    bound_service_account_namespaces=default \
    policies=postgres-policy \
    ttl=24h

kubectl run tmp --rm -i --tty --serviceaccount=postgres-vault --image alpine
KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

apk update
apk add curl postgresql-client jq

VAULT_K8S_LOGIN=$(curl --request POST --data '{"jwt": "'"$KUBE_TOKEN"'", "role": "postgres"}' http://errant-mandrill-vault:8200/v1/auth/kubernetes/login)
echo $VAULT_K8S_LOGIN | jq

```json
{
  "request_id": "e870619d-84a4-6fa0-cb1c-af1cf5f9f6f8",
  "lease_id": "",
  "renewable": false,
  "lease_duration": 0,
  "data": null,
  "wrap_info": null,
  "warnings": null,
  "auth": {
    "client_token": "5cff094f-09c2-cf0f-a66a-187d8bb06199",
    "accessor": "e38de6c2-d704-4569-a81f-58765b77c741",
    "policies": [
      "default",
      "postgres-policy"
    ],
    "metadata": {
      "role": "postgres",
      "service_account_name": "postgres-vault",
      "service_account_namespace": "default",
      "service_account_secret_name": "postgres-vault-token-tb6x4",
      "service_account_uid": "8231b01a-1f26-11e8-96b2-080027de9cbb"
    },
    "lease_duration": 86400,
    "renewable": true,
    "entity_id": "38a5a726-16c6-87cb-c9c4-cc038db2faa3"
  }
}
```

X_VAULT_TOKEN=$(echo $VAULT_K8S_LOGIN | jq -r '.auth.client_token')
POSTGRES_CREDS=$(curl --header "X-Vault-Token: $X_VAULT_TOKEN" http://errant-mandrill-vault:8200/v1/database/creds/postgres-role)

echo $POSTGRES_CREDS | jq

```json
{
  "request_id": "8d412c32-8154-506b-ff86-84054bcb1c45",
  "lease_id": "database/creds/postgres-role/51fc4eb0-8eb7-122c-d3eb-ce68b18bad35",
  "renewable": true,
  "lease_duration": 3600,
  "data": {
    "password": "A1a-rzs3px81vy08su8t",
    "username": "v-kubernet-postgres-62734t4ssxqww66s3023-1520676436"
  },
  "wrap_info": null,
  "warnings": null,
  "auth": null
}
```

PGUSER=$(echo $POSTGRES_CREDS | jq -r '.data.username')
export PGPASSWORD=$(echo $POSTGRES_CREDS | jq -r '.data.password')
psql -h intended-moth-postgresql -U $PGUSER rails_development -c 'SELECT * FROM pg_catalog.pg_tables;'

VAULT_LEASE_ID=$(echo $POSTGRES_CREDS | jq -j '.lease_id')

curl --request PUT --header "X-Vault-Token: $X_VAULT_TOKEN" --data '{"lease_id": "'"$VAULT_LEASE_ID"'", "increment": 3600}' http://errant-mandrill-vault:8200/v1/sys/leases/renew

curl --request PUT --header "X-Vault-Token: $X_VAULT_TOKEN" --data '{"lease_id": "'"$VAULT_LEASE_ID"'"}' http://errant-mandrill-vault:8200/v1/sys/leases/revoke
```
