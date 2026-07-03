#!/bin/bash
#
# Fix AKS Flex Node Kubelet CA Certificate Initialization
#
# This script is a workaround for the CA certificate not being initialized
# in the nspawn container at /etc/kubernetes/pki/apiserver-client-ca.crt
#
# It performs the following steps:
# 1. Extracts caCertData from the agent config.json
# 2. Decodes the base64-encoded PEM certificate
# 3. Enters the nspawn container using nsenter
# 4. Creates the required directory structure
# 5. Writes the decoded certificate with proper permissions
# 6. Restarts kubelet to pick up the new certificate
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
FLEX_HOST="${FLEX_HOST:-20.112.90.136}"
FLEX_USER="${FLEX_USER:-azureoperator}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
CONFIG_PATH="/etc/aks-flex-node/config.json"
CONTAINER_CERT_PATH="/etc/kubernetes/pki/apiserver-client-ca.crt"
CERT_DIR="/etc/kubernetes/pki"

# Helper functions
log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
  log_info "Checking prerequisites..."

  # Check for required commands
  for cmd in ssh jq base64 openssl; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command not found: $cmd"
      exit 1
    fi
  done

  # Check SSH key
  if [[ ! -f "$SSH_KEY" ]]; then
    log_error "SSH key not found: $SSH_KEY"
    exit 1
  fi

  log_success "All prerequisites met"
}

# Extract and decode caCertData
extract_ca_cert() {
  log_info "Extracting caCertData from ${FLEX_HOST}:${CONFIG_PATH}"

  # Get the base64-encoded certificate
  CA_CERT_B64=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${FLEX_USER}@${FLEX_HOST}" "sudo cat ${CONFIG_PATH}" |
    jq -r '.node.kubelet.caCertData')

  if [[ -z "$CA_CERT_B64" ]]; then
    log_error "Failed to extract caCertData from config.json"
    exit 1
  fi

  log_info "Extracted ${#CA_CERT_B64} characters of base64-encoded certificate"

  # Decode and validate the certificate
  CA_CERT_PEM=$(echo "$CA_CERT_B64" | base64 -d)

  if ! echo "$CA_CERT_PEM" | openssl x509 -text -noout >/dev/null 2>&1; then
    log_error "Failed to validate decoded certificate - not a valid X.509 certificate"
    exit 1
  fi

  log_success "Certificate is valid"

  # Show cert info
  SUBJECT=$(echo "$CA_CERT_PEM" | openssl x509 -subject -noout 2>/dev/null | sed 's/subject=//')
  ISSUER=$(echo "$CA_CERT_PEM" | openssl x509 -issuer -noout 2>/dev/null | sed 's/issuer=//')
  NOTAFTER=$(echo "$CA_CERT_PEM" | openssl x509 -noout -dates 2>/dev/null | grep notAfter | sed 's/notAfter=//')

  log_info "Certificate Subject: $SUBJECT"
  log_info "Certificate Issuer:  $ISSUER"
  log_info "Certificate Expiry:  $NOTAFTER"

  echo "$CA_CERT_PEM"
}

# Initialize certificate in nspawn container
init_container_cert() {
  local ca_cert_pem="$1"

  log_info "Initializing certificate in nspawn container..."

  # Step 1: Get the PID of the nspawn container (kube1)
  log_info "Locating nspawn container 'kube1'..."

  CONTAINER_PID=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${FLEX_USER}@${FLEX_HOST}" \
    "sudo machinectl show kube1 -p Leader --value" 2>/dev/null)

  if [[ -z "$CONTAINER_PID" ]]; then
    log_error "Could not find nspawn container 'kube1' - is the agent running?"
    log_info "Run: aks-flex-node-agent start --config ${CONFIG_PATH}"
    exit 1
  fi

  log_success "Found container PID: $CONTAINER_PID"

  # Step 2: Write certificate into the container
  log_info "Writing certificate to ${CONTAINER_CERT_PATH} in container..."

  # Use nsenter to enter container namespace and write the certificate
  # This runs on the flex host via SSH
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${FLEX_USER}@${FLEX_HOST}" bash <<'REMOTE_SCRIPT'
        set -euo pipefail

        CONTAINER_PID="$1"
        CERT_DIR="$2"
        CONTAINER_CERT_PATH="$3"
        CA_CERT_PEM="$4"

        # Create directory inside container
        sudo nsenter -t "$CONTAINER_PID" --all mkdir -p "$CERT_DIR"

        # Write certificate to file inside container
        # We write via tee to handle permission restrictions
        echo "$CA_CERT_PEM" | sudo nsenter -t "$CONTAINER_PID" --all tee "$CONTAINER_CERT_PATH" > /dev/null

        # Set permissions (600 for root-readable only, per kubelet security practices)
        sudo nsenter -t "$CONTAINER_PID" --all chmod 600 "$CONTAINER_CERT_PATH"

        # Verify the file exists and is readable
        sudo nsenter -t "$CONTAINER_PID" --all test -r "$CONTAINER_CERT_PATH" && \
            echo "✓ Certificate successfully written to container"

        # Show certificate info in container
        sudo nsenter -t "$CONTAINER_PID" --all openssl x509 -in "$CONTAINER_CERT_PATH" -subject -issuer -noout
REMOTE_SCRIPT
  "$CONTAINER_PID" "$CERT_DIR" "$CONTAINER_CERT_PATH" "$ca_cert_pem" || {
    log_error "Failed to write certificate in container"
    exit 1
  }

  log_success "Certificate written successfully"
}

# Restart kubelet
restart_kubelet() {
  log_info "Restarting kubelet service in container..."

  # Get container PID again
  CONTAINER_PID=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${FLEX_USER}@${FLEX_HOST}" \
    "sudo machinectl show kube1 -p Leader --value" 2>/dev/null)

  # Restart kubelet inside container
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${FLEX_USER}@${FLEX_HOST}" \
    "sudo nsenter -t '$CONTAINER_PID' --all systemctl restart kubelet.service"

  log_info "Kubelet restart command sent - waiting for service to start..."
  sleep 5

  # Check kubelet status
  log_info "Checking kubelet status in container..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${FLEX_USER}@${FLEX_HOST}" \
    "sudo nsenter -t '$CONTAINER_PID' --all systemctl status kubelet.service" ||
    log_warn "Kubelet status check may have non-zero exit (normal for active services)"

  log_success "Kubelet restart initiated"
}

# Wait for node to join
wait_for_node_ready() {
  log_info "Waiting for Flex node to register and become Ready..."
  log_info "This may take 1-3 minutes..."

  local max_attempts=30
  local attempt=0
  local wait_seconds=10

  while [[ $attempt -lt $max_attempts ]]; do
    attempt=$((attempt + 1))

    # Get node name from config
    NODE_NAME=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${FLEX_USER}@${FLEX_HOST}" \
      "sudo cat ${CONFIG_PATH}" | jq -r '.node.name // "flex-node"')

    # Check if node is in cluster (requires kubeconfig access locally)
    if kubectl get node "$NODE_NAME" 2>/dev/null | grep -q "Ready"; then
      log_success "Node $NODE_NAME is Ready!"
      return 0
    fi

    echo -ne "\r[Attempt $attempt/$max_attempts] Waiting ${wait_seconds}s for node to register..."
    sleep $wait_seconds
  done

  log_warn "Timeout waiting for node to become Ready"
  log_info "The node may still be starting. Check logs with:"
  log_info "  ssh ${FLEX_USER}@${FLEX_HOST} 'sudo aks-flex-node-agent logs -f'"
  return 1
}

# Main function
main() {
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║       AKS Flex Node Kubelet CA Certificate Initialization       ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
  echo

  check_prerequisites

  log_info "Configuration:"
  echo "  Flex Host:            $FLEX_HOST"
  echo "  Config Path:          $CONFIG_PATH"
  echo "  Container Cert Path:  $CONTAINER_CERT_PATH"
  echo

  # Extract and validate cert
  CA_CERT_PEM=$(extract_ca_cert)

  # Initialize cert in container
  init_container_cert "$CA_CERT_PEM"

  # Restart kubelet
  restart_kubelet

  echo
  log_info "Workaround execution completed!"
  echo
  log_info "Next steps:"
  echo "  1. Monitor kubelet logs in container:"
  echo "     ssh ${FLEX_USER}@${FLEX_HOST} 'sudo aks-flex-node-agent logs -f kubelet'"
  echo ""
  echo "  2. Check if node joined:"
  echo "     kubectl get nodes -L kubernetes.io/hostname"
  echo ""
  echo "  3. Verify node is Ready:"
  echo "     kubectl get node <flex-node-name> -o wide"
  echo ""
}

# Run main function
main "$@"
