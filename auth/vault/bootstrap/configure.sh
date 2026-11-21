#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_ADDR:?Set the Vault HTTPS URL}"
: "${KUBE_API_URL:?Set the K3s HTTPS API URL reachable from Vault}"
: "${KUBE_CA_FILE:?Set the path to the K3s API CA PEM}"
: "${REVIEWER_JWT_FILE:?Set the path to the reviewer JWT file}"
: "${WORKER_IAM_ROLE_ARN:?Set the exact IAM role ARN used by the worker instance profile}"
: "${VAULT_IAM_SERVER_ID:?Set the AWS IAM auth server ID, normally the Vault DNS name}"

if [[ "$VAULT_ADDR" != https://* || "$KUBE_API_URL" != https://* ||
      "${VAULT_SKIP_VERIFY:-}" =~ ^([tT][rR][uU][eE]|[tT]|1)$ ||
      ! "$WORKER_IAM_ROLE_ARN" =~ ^arn:aws:iam::[0-9]{12}:role/[[:alnum:]_+=,.@/-]+$ ||
      ! -s "$KUBE_CA_FILE" || ! -r "$KUBE_CA_FILE" ||
      ! -s "$REVIEWER_JWT_FILE" || ! -r "$REVIEWER_JWT_FILE" ]]; then
  printf '%s\n' 'Check HTTPS/TLS, the exact worker IAM role ARN, and readable nonempty input files.' >&2
  exit 1
fi

vault_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

vault policy write tailscale-key-relay "$vault_dir/policies/tailscale-key-relay.hcl"
vault policy write k3s-worker-bootstrap "$vault_dir/policies/k3s-worker-bootstrap.hcl"

vault write auth/worker-kubernetes/config \
  kubernetes_host="$KUBE_API_URL" \
  kubernetes_ca_cert="@$KUBE_CA_FILE" \
  token_reviewer_jwt="@$REVIEWER_JWT_FILE" \
  disable_local_ca_jwt=true

vault write auth/worker-kubernetes/role/tailscale-key-relay \
  bound_service_account_names=tailscale-key-relay \
  bound_service_account_namespaces=worker-bootstrap \
  audience=vault-worker-bootstrap \
  token_policies=tailscale-key-relay \
  token_no_default_policy=true \
  token_type=service \
  token_ttl=5m \
  token_explicit_max_ttl=5m

vault write auth/worker-aws/config/client \
  iam_server_id_header_value="$VAULT_IAM_SERVER_ID"

vault write auth/worker-aws/role/k3s-worker-bootstrap \
  auth_type=iam \
  bound_iam_principal_arn="$WORKER_IAM_ROLE_ARN" \
  resolve_aws_unique_ids=true \
  token_policies=k3s-worker-bootstrap \
  token_no_default_policy=true \
  token_type=service \
  token_ttl=5m \
  token_explicit_max_ttl=5m
