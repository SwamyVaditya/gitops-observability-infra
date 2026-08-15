# Bootstraps the local GitOps observability lab: k3d cluster -> Argo CD
$ErrorActionPreference = "Stop"

Write-Host "==> [1/2] Provisioning k3d cluster" -ForegroundColor Cyan
Push-Location "$PSScriptRoot/../terraform/01-cluster"
terraform init -upgrade
terraform apply -auto-approve
Pop-Location

Write-Host "==> [2/2] Installing Argo CD" -ForegroundColor Cyan
Push-Location "$PSScriptRoot/../terraform/02-argocd-bootstrap"
terraform init -upgrade
terraform apply -auto-approve
Pop-Location

Write-Host "`n==> Done. Fetch the Argo CD admin password with:" -ForegroundColor Green
Write-Host '  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"'
Write-Host '  ... then base64-decode it, e.g.:'
Write-Host '  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("<value>"))'
