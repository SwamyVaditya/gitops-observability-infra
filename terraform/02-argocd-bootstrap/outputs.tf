output "argocd_namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "get_admin_password_cmd" {
  description = "Run this to retrieve the initial Argo CD admin password"
  value       = "kubectl -n ${kubernetes_namespace.argocd.metadata[0].name} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\""
}
