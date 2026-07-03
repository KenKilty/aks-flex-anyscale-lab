#!/bin/bash
# Simplified CA Certificate Fix for AKS Flex Node Kubelet
# Direct approach without complex variable passing

set -euo pipefail

FLEX_HOST="${FLEX_HOST:-20.112.90.136}"
FLEX_USER="${FLEX_USER:-azureoperator}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
CONFIG_PATH="/etc/aks-flex-node/config.json"

echo "════════════════════════════════════════════════════════════════"
echo "  Kubelet CA Certificate Fix - Simplified Workaround"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Step 1: Extract and validate CA cert locally
echo "[1/6] Extracting CA certificate from flex host..."
CA_CERT_B64=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${FLEX_USER}@${FLEX_HOST}" "sudo jq -r '.node.kubelet.caCertData' ${CONFIG_PATH}")

if [[ -z "$CA_CERT_B64" ]]; then
  echo "❌ ERROR: Failed to extract caCertData from config"
  exit 1
fi

echo "✓ Extracted ${#CA_CERT_B64} characters"

# Decode locally
CA_CERT_PEM=$(echo "$CA_CERT_B64" | base64 -d)

# Validate
if ! echo "$CA_CERT_PEM" | openssl x509 -noout >/dev/null 2>&1; then
  echo "❌ ERROR: Invalid certificate"
  exit 1
fi

SUBJECT=$(echo "$CA_CERT_PEM" | openssl x509 -subject -noout | sed 's/subject=//')
echo "✓ Certificate valid: $SUBJECT"
echo ""

# Step 2: Get container PID on flex host
echo "[2/6] Finding nspawn container PID..."
CONTAINER_PID=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${FLEX_USER}@${FLEX_HOST}" "sudo machinectl show kube1 -p Leader --value")

if [[ -z "$CONTAINER_PID" ]]; then
  echo "❌ ERROR: Cannot find container 'kube1'"
  exit 1
fi

echo "✓ Container PID: $CONTAINER_PID"
echo ""

# Step 3: Create temp file with cert and transfer
echo "[3/6] Preparing certificate for transfer..."
TEMP_CERT_FILE="/tmp/ca-cert-fix-$$.pem"
echo "$CA_CERT_PEM" >"$TEMP_CERT_FILE"
echo "✓ Temp file: $TEMP_CERT_FILE"
echo ""

# Step 4: Transfer to flex host
echo "[4/6] Transferring certificate to flex host..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$TEMP_CERT_FILE" "${FLEX_USER}@${FLEX_HOST}:/tmp/ca-cert-transfer.pem"
echo "✓ Transferred"
echo ""

# Step 5: Write into container and restart kubelet
echo "[5/6] Initializing certificate in container and restarting kubelet..."
# shellcheck disable=SC2087  # $CONTAINER_PID is intentionally expanded client-side; \$CONTAINER_PID runs on the server
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${FLEX_USER}@${FLEX_HOST}" bash -s <<REMOTE_SCRIPT
    set -euo pipefail
    CONTAINER_PID="$CONTAINER_PID"

    # Create directory
    sudo nsenter -t \$CONTAINER_PID --all mkdir -p /etc/kubernetes/pki

    # Copy certificate into container
    cat /tmp/ca-cert-transfer.pem | \
        sudo nsenter -t \$CONTAINER_PID --all tee /etc/kubernetes/pki/apiserver-client-ca.crt > /dev/null

    # Set permissions
    sudo nsenter -t \$CONTAINER_PID --all chmod 600 /etc/kubernetes/pki/apiserver-client-ca.crt

    # Verify
    sudo nsenter -t \$CONTAINER_PID --all test -r /etc/kubernetes/pki/apiserver-client-ca.crt && echo "✓ File written and readable"

    # Restart kubelet
    sudo nsenter -t \$CONTAINER_PID --all systemctl restart kubelet.service
    echo "✓ Kubelet restart initiated"

    # Cleanup
    rm /tmp/ca-cert-transfer.pem
REMOTE_SCRIPT

echo ""

# Step 6: Monitor progress
echo "[6/6] Monitoring kubelet startup..."
sleep 3

# Quick status check
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${FLEX_USER}@${FLEX_HOST}" \
  "sudo nsenter -t $CONTAINER_PID --all systemctl is-active kubelet.service 2>&1" || true

# Cleanup local temp file
rm "$TEMP_CERT_FILE"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ CA Certificate Fix Complete!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "NEXT STEPS:"
echo "  1. Wait 1-3 minutes for kubelet to start and node to register"
echo "  2. Check node status:"
echo "     kubectl get nodes -L kubernetes.io/hostname"
echo "  3. Monitor kubelet logs (from flex host):"
echo "     ssh azureoperator@20.112.90.136 'sudo aks-flex-node-agent logs -f kubelet | head -50'"
echo ""
