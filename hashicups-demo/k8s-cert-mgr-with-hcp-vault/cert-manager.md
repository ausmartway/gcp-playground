#steps for installing cert-manager on gke

## Prerequisites
- GKE cluster
- kubectl
- helm

## Steps

### install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager CRDs
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.0/cert-manager.crds.yaml

# Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.17.0
```

### verify installation

```bash
kubectl get pods --namespace cert-manager
```

### setup hcp vault

```bash
VAULT_ADDR=https://vault-cluster-public-vault-bb7b95a8.c950b5f7.z1.hashicorp.cloud:8200
VAULT_NAMESPACE=admin
vault login
vault token lookup
vault auth enable kubernetes

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
  namespace: default
EOF

# Get GKE API server details
K8S_HOST=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
K8S_CA_CERT=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)
# Configure Vault
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(kubectl get secret $(kubectl get serviceaccount vault-auth -o jsonpath='{.secrets[0].name}') -o jsonpath='{.data.token}' | base64 -d)" \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$K8S_CA_CERT"

#read the kubernetes auth config
vault read auth/kubernetes/config
```

### config vault for cert-manager

```bash
# Create policy allowing cert-manager to issue certificates
vault policy write cert-manager - <<EOF
path "pki/issue/*" {
  capabilities = ["create", "update"]
}
EOF

# Link policy to Kubernetes service account
vault write auth/kubernetes/role/cert-manager \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager \
  ttl=1h
  ```

### setup pki secrets engine so that cert-manager can issue certificates

```bash
vault secrets enable pki

# Generate root CA (or import your own)
vault write pki/root/generate/internal \
  common_name=example.com \
  ttl=8760h
  