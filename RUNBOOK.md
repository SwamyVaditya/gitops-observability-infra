# Runbook: Steps 1–3 (Infra → Argo CD → EFK-equivalent stack)

Run this from PowerShell on Windows 11, with Docker Desktop already running.

---

## 0. Prerequisites check

```powershell
docker version
k3d version
kubectl version --client
terraform version
helm version
argocd version --client
```

All should return without error. If Docker Desktop's WSL2 backend has less
than ~6GB RAM allocated, bump it now (Docker Desktop → Settings →
Resources) — a 3-node k3d cluster plus a JVM-backed OpenSearch node is
tight on the 2GB default.

**Port check** — Traefik inside k3d will bind host ports 80/443. If
anything else on your machine already uses those (IIS, another local dev
proxy), either stop it or change `http_host_port`/`https_host_port` in
`terraform/01-cluster/terraform.tfvars` before applying.

---

## 1. Provision the k3d cluster

```powershell
cd terraform/01-cluster
terraform init
terraform apply
```

Type `yes` when prompted. This takes 1–3 minutes.

**Checkpoint:**

```powershell
kubectl --kubeconfig .\outputs\kubeconfig.yaml get nodes
```

Expect 3 nodes (1 server, 2 agents), all `Ready`. Set the kubeconfig for the
rest of this session so you don't have to pass `--kubeconfig` every time:

```powershell
$env:KUBECONFIG = (Resolve-Path .\outputs\kubeconfig.yaml).Path
kubectl get nodes
```

**If this fails:** the most common cause is a stale k3d cluster from a
previous attempt. `k3d cluster list` to check, `k3d cluster delete
gitops-observability-lab` to clear it, then re-apply.

---

## 2. Install Argo CD

```powershell
cd ../02-argocd-bootstrap
terraform init
terraform apply
```

**Checkpoint:**

```powershell
kubectl -n argocd get pods
```

Expect all pods `Running`/`Completed` within ~2 minutes (argocd-server,
-repo-server, -application-controller, -dex-server, -redis, -applicationset-controller,
-notifications-controller).

Get the admin password and log in via the CLI (server is `insecure` mode —
HTTP internally, no port-forward TLS complaints):

```powershell
$pwBase64 = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$adminPw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pwBase64))
Write-Host $adminPw

kubectl -n argocd port-forward svc/argocd-server 8080:80
```

In a second terminal:

```powershell
argocd login localhost:8080 --username admin --password "<paste adminPw>" --plaintext
```

Open `http://localhost:8080` in a browser too — this is your first resume
screenshot opportunity (empty Argo CD UI, ready for apps).

---

## 3. Push the config repo and bootstrap App-of-Apps

If you haven't already: create an empty GitHub repo named
`gitops-observability-config`, then from that repo's local folder:

```powershell
git remote add origin https://github.com/<your-username>/gitops-observability-config.git
git push -u origin main
```

Now replace every `YOUR_GITHUB_ORG` placeholder with your real username/org
in these 4 files, then commit and push again:

- `apps/root/root-app.yaml`
- `apps/observability/opensearch.yaml`
- `apps/observability/opensearch-dashboards.yaml`
- `apps/observability/fluent-bit-collector.yaml`

```powershell
git add -A
git commit -m "chore: point Applications at real repo URL"
git push
```

Apply the one manifest you ever apply by hand:

```powershell
kubectl apply -f apps/root/root-app.yaml
```

**Checkpoint:**

```powershell
argocd app list
```

Expect 4 Applications: `root-app`, `opensearch`, `opensearch-dashboards`,
`fluent-bit-collector`. Give Argo CD a minute, then re-check — `root-app`
should go `Synced`/`Healthy` first, then the three children as it discovers
and applies them.

```powershell
kubectl get pods -n observability -w
```

Watch until `opensearch-cluster-master-0`, an `opensearch-dashboards-*`
pod, and one `fluent-bit-collector-*` pod per node are all `Running`.

---

## Known friction points (fix these when you hit them, not before)

**PVC stuck `Pending`.** Check the StorageClass name actually matches:

```powershell
kubectl get storageclass
```

If it's not exactly `local-path`, edit `storageClass:` in
`environments/local/observability/opensearch/values.yaml` in the config
repo, commit, push — Argo CD's `selfHeal` picks it up automatically. No
manual `kubectl apply` needed; that's the point of GitOps.

**OpenSearch Dashboards or Fluent Bit Collector can't reach OpenSearch.**
The values files assumed a Service name of `opensearch-cluster-master`.
Confirm:

```powershell
kubectl get svc -n observability
```

If the real name differs, correct `opensearchHosts` (Dashboards) and `Host`
(Fluent Bit Collector) in their respective `values.yaml`, commit, push.

**OpenSearch pod OOMKilled or CrashLoopBackOff.** Docker Desktop's overall
memory ceiling may be tighter than the 1Gi limit set in
`opensearch/values.yaml`. Either raise Docker Desktop's memory allocation,
or lower `opensearchJavaOpts` and `resources.limits.memory` together (heap
should stay at roughly half the container memory limit).

**`terraform apply` in `02-argocd-bootstrap` fails to connect to the
cluster.** Confirm `kubeconfig_path` in `terraform.tfvars` actually resolves
— it defaults to a relative path assuming you run `terraform apply` from
inside `02-argocd-bootstrap/`, not the repo root.

---

## What to capture along the way for your resume/portfolio

Since this project is going on a resume, treat this run as evidence
generation, not just a one-time bring-up:

1. **Screenshot the Argo CD UI** once all 4 Applications show
   `Synced`/`Healthy` — this is the single image that best proves the
   GitOps loop actually works (declarative source → reconciled cluster
   state), and pairs well with an architecture diagram in your top-level
   README.
2. **Screenshot OpenSearch Dashboards** once you've confirmed log ingestion
   (Step 3's sample app comes next — Dashboards showing real indexed
   documents is a stronger portfolio piece than an empty instance).
3. **Keep this RUNBOOK.md in the repo, updated with what actually happened
   on your machine** — interviewers reading a GitOps/SRE portfolio repo
   specifically look for a maintained runbook and a troubleshooting section
   grounded in real failures, not just a working demo. If you hit and fixed
   something not listed above, add it here.
4. **Write a short "Design Decisions" doc** (or fold it into the top-level
   README) covering the calls made during this build: multi-repo split
   (infra vs config), Helm multi-source over vendored charts, OpenSearch
   over Elasticsearch (frozen chart), and Helm over the ECK operator
   pattern for this stage. Being able to articulate *why*, with trade-offs,
   is exactly what gets probed in an SRE interview — more than the fact
   that the stack runs.
