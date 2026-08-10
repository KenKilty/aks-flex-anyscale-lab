locals {
  managed_istio_gateway_api_managed_cluster_api_type = "Microsoft.ContainerService/managedClusters@2026-03-02-preview"
}

resource "terraform_data" "managed_cni_ready" {
  triggers_replace = [
    module.aks.aks_provisioning_validation,
    var.cilium_pod_cidr,
  ]

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]

    environment = {
      AKS_CLUSTER_NAME   = module.aks.cluster_name
      AKS_RESOURCE_GROUP = azurerm_resource_group.this.name
      AKS_POD_CIDR       = var.cilium_pod_cidr
    }

    command = <<-EOT
      set -euo pipefail

      NETWORK_PROFILE="$(az aks show \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --query networkProfile \
        -o json)"
      NETWORK_PLUGIN="$(jq -r '.networkPlugin // empty' <<<"$NETWORK_PROFILE")"
      NETWORK_PLUGIN_MODE="$(jq -r '.networkPluginMode // empty' <<<"$NETWORK_PROFILE")"
      NETWORK_DATA_PLANE="$(jq -r '.networkDataplane // .networkDataPlane // empty' <<<"$NETWORK_PROFILE")"
      POD_CIDR="$(jq -r '.podCidr // empty' <<<"$NETWORK_PROFILE")"
      if [[ "$NETWORK_PLUGIN" != "azure" || "$NETWORK_PLUGIN_MODE" != "overlay" || "$NETWORK_DATA_PLANE" != "cilium" || "$POD_CIDR" != "$AKS_POD_CIDR" ]]; then
        printf 'error: AKS must report Azure CNI Overlay powered by Cilium with podCidr=%s; observed plugin=%s mode=%s dataplane=%s podCidr=%s\n' \
          "$AKS_POD_CIDR" "$NETWORK_PLUGIN" "$NETWORK_PLUGIN_MODE" "$NETWORK_DATA_PLANE" "$POD_CIDR" >&2
        exit 1
      fi

      az aks get-credentials \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --overwrite-existing \
        --only-show-errors >/dev/null
      kubelogin convert-kubeconfig -l azurecli >/dev/null

      kubectl -n kube-system rollout status daemonset/cilium --timeout=10m
    EOT
  }

  depends_on = [module.aks]
}

resource "azapi_update_resource" "managed_istio_gateway_api" {
  type        = local.managed_istio_gateway_api_managed_cluster_api_type
  resource_id = module.aks.cluster_id

  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          enabled = true
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "1h"
    update = "1h"
  }

  depends_on = [terraform_data.managed_cni_ready]
}

resource "terraform_data" "managed_istio_ready" {
  triggers_replace = [azapi_update_resource.managed_istio_gateway_api.id]

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]

    environment = {
      AKS_CLUSTER_NAME   = module.aks.cluster_name
      AKS_RESOURCE_GROUP = azurerm_resource_group.this.name
    }

    command = <<-EOT
      set -euo pipefail

      az aks get-credentials \
        --resource-group "$AKS_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --overwrite-existing \
        --only-show-errors >/dev/null
      kubelogin convert-kubeconfig -l azurecli >/dev/null

      CONSECUTIVE_SUCCESSES=0
      for ATTEMPT in $(seq 1 120); do
        CLASS_ACCEPTED="$(kubectl get gatewayclass approuting-istio -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' --request-timeout=10s 2>/dev/null || true)"
        if [[ "$CLASS_ACCEPTED" == "True" ]] && kubectl get --raw=/readyz --request-timeout=10s >/dev/null 2>&1; then
          CONSECUTIVE_SUCCESSES=$((CONSECUTIVE_SUCCESSES + 1))
          if [[ "$CONSECUTIVE_SUCCESSES" -ge 5 ]]; then
            printf 'AKS App Routing Istio is ready and authenticated API access is stable.\n'
            exit 0
          fi
        else
          CONSECUTIVE_SUCCESSES=0
        fi
        sleep 5
      done

      kubectl get gatewayclass -o wide || true
      printf 'error: AKS App Routing Istio did not become ready with stable API access within 10 minutes\n' >&2
      exit 1
    EOT
  }

  depends_on = [azapi_update_resource.managed_istio_gateway_api]
}
