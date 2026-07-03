#!/bin/bash
# Quick Reference: Kubelet CA Certificate Initialization Workaround
# For Module 3: Flex Node Integration

cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                    Kubelet CA Certificate Fix - Quick Start                   ║
╚═══════════════════════════════════════════════════════════════════════════════╝

SITUATION:
  Flex node agent is running and CSR was created, but kubelet won't start inside
  the nspawn container because CA certificate file is missing.

  Error: "unable to load client CA file /etc/kubernetes/pki/apiserver-client-ca.crt"

═══════════════════════════════════════════════════════════════════════════════

OPTION 1: AUTOMATED WORKAROUND (Recommended)
═════════════════════════════════════════════

  Run the automated fix script (handles all steps automatically):

    ./scripts/fix-kubelet-ca-cert.sh

  Prerequisites:
    ✓ SSH key configured in .env (SSH_PRIVATE_KEY_PATH)
    ✓ Flex host IP in FLEX_HOST variable (.env)
    ✓ Local kubeconfig configured (for final node validation)

  What it does:
    1. Validates SSH access to Flex host
    2. Extracts caCertData from config.json
    3. Decodes and validates the certificate
    4. Enters nspawn container using nsenter
    5. Writes certificate to /etc/kubernetes/pki/apiserver-client-ca.crt
    6. Sets proper file permissions (600)
    7. Restarts kubelet service
    8. Waits for node to register as Ready

═══════════════════════════════════════════════════════════════════════════════

OPTION 2: MANUAL WORKAROUND (Step-by-step)
═════════════════════════════════════════════

Step 1: SSH into Flex Host
───────────────────────────
  FLEX_HOST="20.112.90.136"
  ssh -i ~/.ssh/id_ed25519 azureoperator@$FLEX_HOST

Step 2: Extract CA Certificate from Config
────────────────────────────────────────────
  CA_CERT_B64=$(sudo jq -r '.node.kubelet.caCertData' /etc/aks-flex-node/config.json)

  # Decode to PEM format
  echo "$CA_CERT_B64" | base64 -d > /tmp/ca-cert.pem

  # Verify it's valid
  openssl x509 -in /tmp/ca-cert.pem -text -noout | head -10

Step 3: Get Container PID
──────────────────────────
  CONTAINER_PID=$(sudo machinectl show kube1 -p Leader --value)
  echo "Container PID: $CONTAINER_PID"

Step 4: Create Directory in Container
──────────────────────────────────────
  sudo nsenter -t $CONTAINER_PID --all mkdir -p /etc/kubernetes/pki

Step 5: Write Certificate into Container
──────────────────────────────────────────
  cat /tmp/ca-cert.pem | \
    sudo nsenter -t $CONTAINER_PID --all tee /etc/kubernetes/pki/apiserver-client-ca.crt > /dev/null

  # Verify it was written
  sudo nsenter -t $CONTAINER_PID --all ls -la /etc/kubernetes/pki/

Step 6: Set Permissions (600 = root-readable only)
────────────────────────────────────────────────────
  sudo nsenter -t $CONTAINER_PID --all chmod 600 /etc/kubernetes/pki/apiserver-client-ca.crt

Step 7: Verify Certificate in Container
─────────────────────────────────────────
  sudo nsenter -t $CONTAINER_PID --all openssl x509 \
    -in /etc/kubernetes/pki/apiserver-client-ca.crt -subject -issuer -noout

Step 8: Restart Kubelet Service
─────────────────────────────────
  sudo nsenter -t $CONTAINER_PID --all systemctl restart kubelet.service

  # Wait a few seconds for service to start
  sleep 5

  # Check status
  sudo nsenter -t $CONTAINER_PID --all systemctl status kubelet.service

Step 9: Check Kubelet Logs (from another terminal)
────────────────────────────────────────────────────
  sudo aks-flex-node-agent logs -f kubelet

Step 10: Back on local machine - Wait for Node to Join
───────────────────────────────────────────────────────
  # Wait 1-3 minutes for kubelet to start and node to register
  kubectl get nodes -w

  # Or check specific node
  kubectl get node <flex-node-name> -o wide

═══════════════════════════════════════════════════════════════════════════════

VERIFICATION CHECKLIST
══════════════════════

After running the workaround:

  ☐ Certificate file exists in container:
    sudo nsenter -t $CONTAINER_PID --all test -r /etc/kubernetes/pki/apiserver-client-ca.crt && echo "✓ File readable"

  ☐ Kubelet service is active (not crashing):
    sudo nsenter -t $CONTAINER_PID --all systemctl is-active kubelet.service

  ☐ No kubelet errors in logs:
    sudo aks-flex-node-agent logs kubelet | grep -i "unable to load"

  ☐ Node registered in Kubernetes:
    kubectl get nodes | grep flex

  ☐ Node status is Ready:
    kubectl get node <flex-node-name> --no-headers | grep -i ready

═══════════════════════════════════════════════════════════════════════════════

TROUBLESHOOTING
═════════════════

Problem: "Container not found" or "Cannot find machine kube1"
────────────────────────────────────────────────────────────────
  Solution: Agent may not be running yet. Start it:
    ssh azureoperator@20.112.90.136 'sudo aks-flex-node-agent start'

  Or check agent status:
    ssh azureoperator@20.112.90.136 'sudo systemctl status aks-flex-node-agent'

Problem: "Permission denied" when writing certificate
──────────────────────────────────────────────────────
  Solution: Use sudo nsenter (not just nsenter)
    WRONG:  nsenter -t $CONTAINER_PID --all tee /etc/kubernetes/pki/...
    RIGHT: sudo nsenter -t $CONTAINER_PID --all tee /etc/kubernetes/pki/...

Problem: Certificate still looks wrong or invalid
───────────────────────────────────────────────────
  Solution: Verify the decode:
    # Should start with "-----BEGIN CERTIFICATE-----"
    echo "$CA_CERT_B64" | base64 -d | head -1

    # Should show certificate validity info
    echo "$CA_CERT_B64" | base64 -d | openssl x509 -text -noout

Problem: Kubelet still crashing after cert is written
──────────────────────────────────────────────────────
  Solution: Check file permissions and ownership:
    sudo nsenter -t $CONTAINER_PID --all ls -la /etc/kubernetes/pki/apiserver-client-ca.crt

  Should show: -rw------- (600 permission)
  Should be owned by root:root

  If not, fix with:
    sudo nsenter -t $CONTAINER_PID --all chmod 600 /etc/kubernetes/pki/apiserver-client-ca.crt

Problem: Timeout waiting for node to become Ready
───────────────────────────────────────────────────
  Solution: Check kubelet logs to see what's blocking:
    ssh azureoperator@20.112.90.136 'sudo aks-flex-node-agent logs -f kubelet | head -50'

  Common issues:
    - RBAC permission denied → ensure bootstrap token has auth-extra-groups
    - Network connectivity → verify API server reachable from flex host
    - CSR pending → check `kubectl get csr` and approve if needed

═══════════════════════════════════════════════════════════════════════════════

CA CERTIFICATE DETAILS (From Your Config)
═════════════════════════════════════════

  Base64 Length: 2348 characters
  Certificate Type: X.509 v3 (RSA 4096-bit)
  Subject: CN=ca
  Issuer: CN=ca
  Valid From: 2026-07-03 01:36:16 UTC
  Valid Until: 2056-07-03 01:46:16 UTC ✓ (30 years)

  Status: ✅ VALID - Certificate is legitimate and properly encoded

═══════════════════════════════════════════════════════════════════════════════

WHAT THIS FIXES
════════════════

✅ Initializes the CA certificate file inside the nspawn container
✅ Allows kubelet to start successfully
✅ Enables node to complete bootstrap and join the Kubernetes cluster
✅ Unblocks completion of Module 3: Flex Node Integration
✅ Allows progression to Modules 4-7

═══════════════════════════════════════════════════════════════════════════════

NEXT STEPS AFTER FIXING
═════════════════════════

1. Verify node is Ready and can run pods:
   kubectl run test-pod --image=nginx:latest -n default
   kubectl get pod -n default

2. Continue to Module 4 (Anyscale Operator Deployment):
   Set TF_VAR_anyscale_enabled=true in .env
   Run: terraform apply

3. Document what worked:
   Update your local run log with the workaround that fixed the issue

═══════════════════════════════════════════════════════════════════════════════
EOF
