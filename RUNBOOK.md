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
pod, and one `fluent-bit-collector-*` pod per node are all `Running`, and
`argocd app list` shows all 4 Applications `Synced`/`Healthy`. This exact
sequence (including hitting and fixing the `machine-id` mount issue below)
has been run end to end on Windows 11 + Docker Desktop — see "Known
friction points" if `fluent-bit-collector` doesn't reach `Healthy` on the
first try.

---

## 4. Build and deploy the sample checkout app

The `sampleapp` Application manifest is already in place in the config
repo (`apps/sampleapp/sampleapp.yaml` — discovered automatically by
`root-app`, same as the observability Applications were). What's missing
is the images: there's no registry in this lab, so build locally and
import straight into k3d.

From your `gitops-observability-sampleapp` clone:

```powershell
docker build -t sampleapp/frontend-gateway:local ./services/frontend-gateway
docker build -t sampleapp/order-service:local ./services/order-service
docker build -t sampleapp/inventory-service:local ./services/inventory-service
docker build -t sampleapp/load-generator:local ./services/load-generator

k3d image import `
  sampleapp/frontend-gateway:local `
  sampleapp/order-service:local `
  sampleapp/inventory-service:local `
  sampleapp/load-generator:local `
  -c gitops-observability-lab
```

Then, if you haven't already, push the config repo changes
(`base/sampleapp/`, `environments/local/sampleapp/`,
`apps/sampleapp/sampleapp.yaml`) — no new `kubectl apply` needed, Argo CD
picks up the new `sampleapp` Application on its next poll (or force it:
`argocd app sync sampleapp`).

**Checkpoint:**

```powershell
kubectl get pods -n sampleapp
argocd app get sampleapp
```

Expect `frontend-gateway`, `order-service`, `inventory-service`, and
`load-generator` all `Running`, Application `Synced`/`Healthy`. Then watch
real traffic land in OpenSearch — port-forward Dashboards and check the
`fluent-bit`-created index for a growing document count:

```powershell
kubectl -n observability port-forward svc/opensearch-dashboards 5601:5601
```

Open `http://localhost:5601`, create an index pattern matching the index
name set in `fluent-bit-collector`'s output config (`app-logs`), and
confirm documents are arriving with `service`, `level`, and `error.type`
fields populated — that's the whole pipeline working end to end, from a
Python/Node checkout flow through to a searchable log store.

**If images aren't found / `ErrImagePull` / `ImagePullBackOff`.** Confirm
the import actually landed on every node, not just the server:

```powershell
docker exec k3d-gitops-observability-lab-agent-0 crictl images | Select-String sampleapp
```

If missing, re-run `k3d image import` — it's safe to re-run, and
occasionally needs a retry right after a fresh `docker build`.

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

**`fluent-bit-collector` Application stays `Synced`/`Progressing` and never
goes `Healthy`; pods stuck in `ContainerCreating`.** Confirmed on a real
run. `kubectl describe pod/<fluent-bit-collector-pod> -n observability`
shows:

```
Warning  FailedMount  ...  MountVolume.SetUp failed for volume "machine-id" : hostPath type check failed: /etc/machine-id is not a file
```

The chart's default `hostVolumes` mounts `/etc/machine-id` as a hostPath of
`type: File`. k3d nodes are themselves Docker containers, not real
VMs/bare metal, and don't reliably expose a real `/etc/machine-id` file at
that path — the kubelet's existence check fails and the pod never leaves
`ContainerCreating`. Fix: override `hostVolumes` in
`environments/local/observability/fluent-bit-collector/values.yaml` to keep
only the `/var/log` mount (Helm replaces list values wholesale, so this
drops `machine-id` entirely — it's optional host metadata, not required
for container log tailing):

```yaml
hostVolumes:
  - name: logs
    mountPath: /var/log
    hostPath:
      path: /var/log
      type: Directory
```

Commit, push, and either wait for Argo CD's next poll or force it with
`argocd app sync fluent-bit-collector`. The DaemonSet's existing pods
terminate and recreate automatically once the pod template changes — no
manual pod deletion needed.

**Windows/WSL2 disk usage climbing continuously, seemingly without bound.**
Confirmed on a real run — WSL2's `.vhdx` grew ~30GB+ and kept climbing
with the cluster just sitting idle (no sample app running yet). Root
cause: `fluent-bit-collector` originally matched `kube.*` — every
namespace's logs, including Argo CD's own reconciliation noise and k3s
system components — into a single static `app-logs` index with no
retention policy. `local-path-provisioner` (the default k3s
StorageClass) does **not** actually enforce a PVC's declared size as a
disk quota, so nothing capped growth.

Fixed as of `gitops-observability-config` commit `6d56d91` — see that
repo's README "Disk usage / log retention" section for the full fix
(namespace-scoped collection, daily indices, an ISM policy deleting
indices after 3 days). If you hit this before pulling that fix:

```powershell
wsl --shutdown
diskpart
```
then inside `diskpart` (adjust the path to match your actual Docker
Desktop WSL disk location — check Settings → Resources → Advanced first):
```
select vdisk file="C:\Users\<you>\AppData\Local\Docker\wsl\disk\docker_data.vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
exit
```
This reclaims space already consumed but doesn't fix the underlying
unbounded growth on its own — pull the config repo fix too, or it'll
climb again.

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
