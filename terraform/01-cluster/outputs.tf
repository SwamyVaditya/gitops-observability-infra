output "cluster_name" {
  value = var.cluster_name
}

output "kubeconfig_path" {
  description = "Absolute path to this cluster's kubeconfig; consumed by 02-argocd-bootstrap"
  value       = local.kubeconfig_path
  depends_on  = [null_resource.write_kubeconfig]
}

output "http_url" {
  value = "http://localhost:${var.http_host_port}"
}
