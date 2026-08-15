locals {
  kubeconfig_path = abspath("${path.module}/${var.kubeconfig_output_path}")
}

# --- k3d cluster lifecycle -------------------------------------------------
resource "null_resource" "k3d_cluster" {
  triggers = {
    cluster_name = var.cluster_name
    k3s_version  = var.k3s_version
    servers      = var.server_count
    agents       = var.agent_count
    http_port    = var.http_host_port
    https_port   = var.https_host_port
    api_port     = var.api_host_port
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    command     = <<-EOT
      $existing = k3d cluster list --no-headers 2>$null | Select-String -Pattern "^${var.cluster_name}\s"
      if ($existing) {
        Write-Host "k3d cluster '${var.cluster_name}' already exists, skipping create."
      } else {
        k3d cluster create ${var.cluster_name} `
          --servers ${var.server_count} `
          --agents ${var.agent_count} `
          --image "rancher/k3s:${var.k3s_version}" `
          --port "${var.http_host_port}:80@loadbalancer" `
          --port "${var.https_host_port}:443@loadbalancer" `
          --api-port ${var.api_host_port} `
          --wait
        if ($LASTEXITCODE -ne 0) { throw "k3d cluster create failed" }
      }
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    command     = "k3d cluster delete ${self.triggers.cluster_name}"
  }
}

# --- Write a dedicated kubeconfig for this cluster --------------------------
# Kept separate from the user's default kubeconfig so it can be safely handed
# to the 02-argocd-bootstrap stage without merge/context-switching surprises.
resource "null_resource" "write_kubeconfig" {
  depends_on = [null_resource.k3d_cluster]

  triggers = {
    cluster_name = var.cluster_name
    run_always   = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    command     = <<-EOT
      New-Item -ItemType Directory -Force -Path "${dirname(local.kubeconfig_path)}" | Out-Null
      k3d kubeconfig write ${var.cluster_name} --output "${local.kubeconfig_path}"
    EOT
  }
}
