# taipei-devopsdays-2021

## setup GKE

```bash
cd terraform-standing-up-gke
terraform init
terraform apply
```

Note that you need to have google credential and projects ready.

## deploy the default app

```bash
kubectl apply -f k8s-default/
```
After this you can see that k8s secrets can be decoded by base64, configMap contains secrets and yaml files contains secrets.

## deploy vault

Note that you should have helm3 installed.

```bash
helm install vault hashicorp/vault --version 0.17.1 -f helm/vault-values.yaml
```

### Setup k8s authmethod from the vault pod, so that all k8s pods can authentiate with vault using their k8s token

```bash
kubectl exec --stdin=true --tty=true vault-0 -- /bin/sh

vault login

vault auth enable kubernetes

vault write auth/kubernetes/config \
        token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
        disable_iss_validation=true \
        kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

### Vault pki_root

```bash
vault secrets enable --path=pki_root pki

vault secrets tune -max-lease-ttl=8760h pki_root

vault write pki_root/root/generate/internal \
    common_name=devopsdays \
    ttl=87600h

vault write pki_root/roles/devopsdays \
    allowed_domains=hashidemos.io \
    allow_subdomains=true \
    max_ttl=2260h

vault write auth/kubernetes/role/cert-manager \
    bound_service_account_names=cert-manager \
    bound_service_account_namespaces=cert-manager \
    policies=cert-manager \
    ttl=24h

vault policy write cert-manager - <<EOF
path "pki_root/sign/devopsdays" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF
```

## deploy cert manager

```bash
helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.6.0 \
  --set installCRDs=true
```

find cert-manager k8s token:

```
kubectl get secrets -n cert-manager|grep cert-manager-token
```

deploy the cert-manager pods:

```
kubectl apply -f k8s-vault-cert-mgr/cert-manager.yaml
```

Validate that the issuer is ready:
```
kubectl get Clusterissuer --all-namespaces
```

## deploy nginx ingress controller

```bash
helm install nginx-ingress ingress-nginx/ingress-nginx
```

## Config Vault




### define role and policy for product-api pod, so it can read both static and dynamic secrets

```bash
vault policy write products-api - <<EOF
path "secrets/data/taipeidevopsday" {
  capabilities = ["read"]
}
path "database/creds/products-api" {
  capabilities = ["read"]
}
EOF

vault write auth/kubernetes/role/products-api \
    bound_service_account_names=products-api \
    bound_service_account_namespaces=default \
    policies=products-api \
    ttl=12h
```

### define role nd policy for postgres admin so he can save the initial postgres password

```bash
vault policy write postgres - <<EOF
path "secrets/data/taipeidevopsday" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

vault write auth/kubernetes/role/postgres \
    bound_service_account_names=postgres \
    bound_service_account_namespaces=default \
    policies=postgres \
    ttl=1h


 vault kv get secrets/taipeidevopsday
```

### Dynamic database secret engine for postgres, note the initial password is clear text

```bash
vault secrets enable database

vault write database/config/products \
    plugin_name=postgresql-database-plugin \
    allowed_roles="products-api" \
    connection_url="postgresql://{{username}}:{{password}}@postgres.default.svc.cluster.local:5432/?sslmode=disable" \
    username="postgres" \
    password="Taipei-is-nice"
```

### Rotate the initial postgres password so that only vault knows about it.

```bash
vault write -force database/rotate-root/products
```

### Create a role for products-api to use

```bash
vault write database/roles/products-api \
    db_name=products \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' SUPERUSER;GRANT ALL ON ALL TABLES IN schema public TO \"{{name}}\";" \
    default_ttl="2h" \
    max_ttl="24h"
```

### test database credential

```bash
vault read database/creds/products-api
```


```

## setup cert manager

```bash
kubectl apply -f k8s-vault-cert-mgr/cert-manager.yaml

kubectl get issuers vault-issuer -o wide
```

## setup ingress controller to use cert manager

```bash
kubectl apply -f k8s-vault-cert-mgr/ssl-ingress.yaml
```

## setup the rest of deployments

```bash
kubectl apply -f k8s-vault-cert-mgr/products-db.yaml
kubectl apply -f k8s-vault-cert-mgr/products-api.yaml
kubectl apply -f k8s-vault-cert-mgr/payments.yaml
kubectl apply -f k8s-vault-cert-mgr/public-api.yaml
kubectl apply -f k8s-vault-cert-mgr/frontend.yaml
```
