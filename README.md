# taipei-devopsdays-2021

## setup GKE and setup credential for kubectl

Get [gcloud cli](https://cloud.google.com/sdk/docs/install),[kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-macos/#install-with-homebrew-on-macos),[helms](https://helm.sh/docs/intro/install/)  and [gcp projects](https://developers.google.com/workspace/marketplace/create-gcp-project) ready, then:

```bash
terraform init
terraform apply
gcloud container clusters get-credentials playground --region=australia-southeast1
```

## deploy the default app (optional)

```bash
kubectl apply -f k8s-default/
```
After this you can see that k8s secrets can be decoded by base64, configMap contains secrets and yaml files contains secrets.

## Create namespace 'vault' and deploy vault

```bash
cd hashicups-demo
kubectl create namespace vault
helm install vault hashicorp/vault --version 0.17.1 -f helm/vault-values.yaml -n vault
```

Get the public ip address of Vault:

```
kubectl get svc -n vault
```
Once you get the external IP, visit the EXTERNAL-IP:8200 and initialise Vault on the GUI and download a copy of the unseal key and root token for later use. Unseal vault.

### Setup k8s authmethod from the vault pod, so that all k8s pods can authentiate with vault using their k8s token

```bash
kubectl exec --stdin=true --tty=true vault-0 -n vault -- /bin/sh

vault login

vault secrets enable -path=secrets kv

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

exit

```

## deploy cert manager

```bash
kubectl create namespace cert-manager

helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.6.0 \
  --set installCRDs=true
```

find cert-manager k8s token:

```
kubectl get secrets -n cert-manager|grep cert-manager-token
```

update the k8s-vault-cert-mgr/vault-issuer.yaml file with the kubernetes tokens from the above step. This token is used by cert-manager to login to Vault using k8s authentication method.

deploy vault-issuer and letsencrypt-issuer:

```
kubectl apply -f k8s-vault-cert-mgr/vault-issuer.yaml
kubectl apply -f k8s-vault-cert-mgr/letsencrypt-issuer.yaml
```

Validate that the issuers are ready:
```
kubectl get Clusterissuer --all-namespaces -o wide
```

## Config Vault

### define role and policy for product-api pod, so it can read both static and dynamic secrets

```bash
kubectl exec --stdin=true --tty=true vault-0 -n vault -- /bin/sh

vault login

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
    bound_service_account_namespaces=hashicups \
    policies=products-api \
    ttl=24h
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
    bound_service_account_namespaces=hashicups \
    policies=postgres \
    ttl=24h


vault kv get secrets/taipeidevopsday

exit

```

### Dynamic database secret engine for postgres, note the initial password is clear text

```bash

kubectl create namespace hashicups

kubectl apply -f k8s-vault-cert-mgr/products-db.yaml

kubectl exec --stdin=true --tty=true vault-0 -n vault -- /bin/sh

vault login

vault secrets enable database

vault write database/config/products \
    plugin_name=postgresql-database-plugin \
    allowed_roles="products-api" \
    connection_url="postgresql://{{username}}:{{password}}@postgres.hashicups.svc.cluster.local:5432/?sslmode=disable" \
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

exit

```

<!-- ## setup cert manager

```bash
kubectl apply -f k8s-vault-cert-mgr/cert-manager.yaml

kubectl get clusterissuers -o wide
``` -->

## deploy nginx ingress controller

```bash
kubectl create namespace nginx    

helm install nginx-ingress ingress-nginx/ingress-nginx -n nginx
```

## setup ingress controller to use cert manager

```bash
gcloud iam service-accounts create dns01-solver --display-name "dns01-solver"

gcloud projects add-iam-policy-binding yulei-playground \
   --member serviceAccount:dns01-solver@yulei-playground.iam.gserviceaccount.com \
   --role roles/dns.admin

gcloud iam service-accounts keys create key.json \
   --iam-account dns01-solver@yulei-playground.iam.gserviceaccount.com

kubectl create secret generic clouddns-dns01-solver-svc-acct \
   --from-file=key.json -n cert-manager

kubectl apply -f k8s-vault-cert-mgr/public-ssl-hashicups.yaml
```

## setup ingress controller to use cert manager for Vault as well

```bash
kubectl apply -f k8s-vault-cert-mgr/ssl-hashicups.yaml
```

## validate that both certificates are ready

```bash
kubectl get certificate --all-namespaces -o wide
```

## setup the rest of deployments

```bash
kubectl apply -f k8s-vault-cert-mgr/products-api.yaml
kubectl apply -f k8s-vault-cert-mgr/payments.yaml
kubectl apply -f k8s-vault-cert-mgr/public-api.yaml
kubectl apply -f k8s-vault-cert-mgr/frontend.yaml
```

## update dns record 

Get ip address of nginx ingress controller:

```bash
kubectl get svc -n nginx     
```

In Google Cloud DNS, add two records to point to the external IP address of Nginx ingress controller

hashicups.yulei.gcp.hashidemos.io
vault.yulei.gcp.hashidemos.io

## get Vault pki_root CA

```bash
kubectl get svc -n vault
```

hit below URL to download the CA in PEM format:
http://34.87.217.159:8200/v1/pki_root/ca/pem

open the .pem file and import into operating system trust store.

## trouble shooting commands

```
kubectl get svc --all-namespaces
kubectl get clusterissuer --all-namespaces
kubectl get order --all-namespaces
kubectl get certificaterequest --all-namespaces
kubectl describe certificate/issuer/clusterissuer/order/certificaterequest/challendge/ingress --all-namespaces
```
