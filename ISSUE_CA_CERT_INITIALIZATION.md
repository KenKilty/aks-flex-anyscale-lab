# CA Certificate Not Auto-Initialized During Bootstrap

## Problem Summary

The CA certificate file at `/etc/kubernetes/pki/apiserver-client-ca.crt` is not automatically created inside the nspawn container during bootstrap, even though `caCertData` is present and valid in the node configuration. This occurs reliably with aks-flex-node-agent v0.1.4.alpha-3 when using bootstrap-token authentication, with all bootstrap phases completing successfully but the certificate file remaining missing.

## Setup Details

Using aks-flex-node-agent v0.1.4.alpha-3 with bootstrap-token authentication on AKS v1.34.6 (westus2 region). The node configuration includes `caCertData` as a base64-encoded X.509 PEM certificate.

## Reproduction Steps

Based on the [official aks-flex-node documentation](https://github.com/Azure/AKSFlexNode), we followed these steps:

Setting up RBAC and bootstrap token:

```bash
aks-flex-config setup-node-rbac \
  --resource-group rg-flexany-dev-wus2 \
  --cluster-name aks-flexany-dev-wus2 \
  --subscription <sub-id>
```

Generating node configuration:

```bash
aks-flex-config generate-node-config --bootstrap-token \
  --resource-group rg-flexany-dev-wus2 \
  --cluster-name aks-flexany-dev-wus2 \
  --subscription <sub-id> \
  --output config.json
```

Deploying to the flex host and starting the agent:

```bash
scp config.json azureoperator@<flex-host>:/tmp/config.json
ssh azureoperator@<flex-host> "sudo cp /tmp/config.json /etc/aks-flex-node/config.json && \
  sudo systemctl start aks-flex-node-agent"
```

## Observed Behavior

The bootstrap process completes all phases successfully:

- setup-nvidia: complete
- configure-kubelet: complete
- start-nspawn-machine: complete
- start-kubelet: complete
- wait-for-kubelet: reached

However, `/etc/kubernetes/pki/apiserver-client-ca.crt` is not created inside the nspawn container, despite `caCertData` being present and valid in the config file. No error messages appear in bootstrap logs indicating initialization failure.

## Questions

Is the CA certificate initialization during bootstrap expected to be automatic? If so, is there a configuration step documented that we are missing?

We tested this with both manually created configs and official aks-flex-config generated configs. Both show the same behavior when using bootstrap-token authentication, so it does not appear to be configuration-related.

See [unbounded library nodestartphases](https://github.com/Azure/unbounded/blob/main/pkg/agent/phases/nodestart/kubelet.go) for expected bootstrap flow.
