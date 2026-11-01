# M4A: counter SPA with Argo CD

The `app/` Kustomization owns only the `cloud-deployment` namespace, one counter Deployment and a ClusterIP Service. Argo CD watches that directory on `main`. The separate `argocd/bootstrap/` Kustomization contains the Application and a restricted AppProject; `argocd/install/` pins the upstream **v3.5.6** non-HA installation. Argo CD does not manage itself in this milestone.

## Before bootstrap

**Do not execute apply, repository registration, password changes, or the reconciliation test below until live-cluster changes are explicitly approved.** Creating the Application enables automated deployment immediately. Merge/push the reviewed manifests to `main` and configure read-only repository access before creating it.

The Deployment references the verified published image `011951224228.dkr.ecr.us-west-2.amazonaws.com/cloud-deployment:sha-45348c8edbba5b414a9ded0fba909bd4396ebb85-41363422813-1`. The immutable tag is preserved; no `latest` tag is used. Image changes are manual Git changes for M4A; automatic promotion belongs to M4B.

Use the existing `cloud-deployment` EKS cluster in `us-west-2` and its current single `c7i-flex.large` worker. Terraform, CI, and the image are unchanged. Install kubectl compatible with the cluster version (within one minor version), and Argo CD CLI v3.5.6. Use an AWS profile with the configured EKS administrator access. Your public IP must match the cluster's API CIDR restriction.

```sh
aws sts get-caller-identity
aws eks update-kubeconfig --region us-west-2 --name cloud-deployment
kubectl config current-context
kubectl get nodes -o wide
kubectl describe nodes
kubectl get pods -A
```

These are read-only cluster checks (update-kubeconfig only writes local configuration). Check the account and context explicitly. If assuming the configured admin role is necessary, add its IAM role ARN with `--role-arn`; never use that option for an IAM user.

The worker role must already have ECR pull permissions for the target repository/account. EKS's kubelet obtains ECR credentials; no expiring Docker-login imagePullSecret is needed for the same-account repository. Argo CD's Git credential does not grant ECR access.

## Render and review

Run from the repository root on a machine with access to GitHub:

```sh
kubectl kustomize kubernetes/app > /tmp/counter-app.yaml
kubectl kustomize kubernetes/argocd/bootstrap > /tmp/counter-bootstrap.yaml
kubectl kustomize kubernetes/argocd/install > /tmp/argocd-install.yaml
```

Inspect the rendered files before applying. The remote install URL is pinned to [v3.5.6](https://github.com/argoproj/argo-cd/releases/tag/v3.5.6), not `stable`. All Services remain internal; there are no Ingress or LoadBalancer resources. Standard Argo CD installation includes CRDs and cluster-wide controller RBAC, so review it as an administrator. The restricted AppProject only permits this source, destination namespace, and the three app resource kinds. It is an operational guardrail, not isolation against cluster administrators.

For schema validation, use kubeconform with Kubernetes schemas matching your actual server version for `/tmp/counter-app.yaml`. Validate Argo CD custom resources against the pinned CRDs, or use the server dry-run step below once CRDs are installed. Do not treat `-ignore-missing-schemas` as successful validation of Application/AppProject.

## Approved installation

The following commands change the live cluster and require approval first. Apply the **reviewed rendered file** from above:

```sh
kubectl apply --server-side -f /tmp/argocd-install.yaml
kubectl wait --for=condition=Established --timeout=120s \
  crd/applications.argoproj.io crd/appprojects.argoproj.io
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kubectl -n argocd get pods,svc
```

Do not add `--force-conflicts` to overwrite an existing Argo CD installation blindly. Stop if these names already belong to a different installation. The namespace transformer uses the expected `argocd` namespace throughout the pinned manifests.

In a separate terminal, open the UI only on loopback:

```sh
kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server 8081:443
```

Visit <https://localhost:8081>. The default server certificate is self-signed; verify you are using your own localhost tunnel before accepting it. Retrieve the initial admin password locally with `argocd admin initial-password -n argocd`. Do not copy it into Git, shared logs, or screenshots. Log in with `argocd login localhost:8081 --username admin --insecure` (interactive password; `--insecure` is only for this self-signed localhost TLS endpoint). Change it with `argocd account update-password`, then delete the initial password Secret with `kubectl -n argocd delete secret argocd-initial-admin-secret`. Keep anonymous access disabled.

## Private repository: read-only deploy key

Use a unique SSH deploy key scoped only to `ashin02/cloud-deployment`, following [Argo CD private repository authentication](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/). Generate the key **outside the checkout**:

```sh
ssh-keygen -t ed25519 -C argocd-cloud-deployment -f "$HOME/.ssh/argocd-cloud-deployment"
```

Argo CD needs a non-interactive key; leave its passphrase empty and protect the private file with mode 600. Add only the `.pub` contents in GitHub repository Settings → Deploy keys. Leave **Allow write access unchecked**. Never commit either a private key or a Kubernetes Secret containing it (base64 is not encryption).

The pinned installation supplies SSH known hosts. Confirm its GitHub host keys against [GitHub's published fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints) before trusting them. Do not use `--insecure-ignore-host-key` or trust an unverified `ssh-keyscan` result. Once logged into Argo CD through the local tunnel, register the repository:

```sh
argocd repo add git@github.com:ashin02/cloud-deployment.git \
  --ssh-private-key-path "$HOME/.ssh/argocd-cloud-deployment"
argocd repo list
```

This writes the credential as a Secret in `argocd`; it does not write credentials into this repository. Restrict access to Secrets and cluster-admin credentials. The deploy key only needs read access. Rotate/revoke it in GitHub when the lab ends. For HTTPS-only networks, a GitHub App limited to this repository with read-only Contents permission is an alternative; do not put a PAT in the repository URL or manifests.

## Approved application bootstrap

Verify `argocd repo list` reports a successful connection. Confirm the reviewed image URI is committed on `main` before proceeding. After the Argo CD CRDs exist:

```sh
kubectl apply --dry-run=server -f /tmp/counter-bootstrap.yaml
kubectl apply -f /tmp/counter-bootstrap.yaml
```

The Application points only at `kubernetes/app`, so it cannot sync its own bootstrap files or credentials. The namespace is synced first via a negative sync wave. Automated sync, prune and self-heal are enabled. No deletion finalizer is set on the Application: deleting that object does not unexpectedly cascade-delete workloads. `allowEmpty: false` blocks automatically pruning the entire app when the source is empty; individual removed resources can still be pruned. Treat Git edits as deployment changes.

## Verify readiness, health and reconciliation

```sh
argocd app get cloud-deployment --refresh
argocd app wait cloud-deployment --sync --health --timeout 300
kubectl -n argocd get application cloud-deployment \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{" "}{.status.sync.revision}{"\n"}'
kubectl -n cloud-deployment rollout status deployment/counter --timeout=300s
kubectl -n cloud-deployment wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=counter --timeout=300s
kubectl -n cloud-deployment get pods,svc
kubectl -n cloud-deployment get deployment counter \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expect `Synced Healthy`, the correct Git revision, one Ready pod and the pinned ECR image. To view the SPA, keep this running in another terminal:

```sh
kubectl -n cloud-deployment port-forward --address 127.0.0.1 svc/counter 8080:80
```

```sh
curl --fail -i http://127.0.0.1:8080/healthz
curl --fail http://127.0.0.1:8080/
curl --fail http://127.0.0.1:8080/example/deep/link
```

Expect HTTP 200 and `ok` from `/healthz`; open <http://localhost:8080> to test the counter. Forwarding is local to your machine; restart it if its selected pod is replaced.

For an **approved** low-impact self-heal test, temporarily change the managed revision-history setting:

```sh
kubectl -n cloud-deployment patch deployment counter --type merge \
  -p '{"spec":{"revisionHistoryLimit":3}}'
argocd app get cloud-deployment --refresh
kubectl -n cloud-deployment get deployment counter --watch \
  -o custom-columns=NAME:.metadata.name,HISTORY:.spec.revisionHistoryLimit
```

Within a reconciliation cycle it should return to the Git value `2`, without changing replicas or rolling the pods. Stop the watch with Ctrl+C. Also verify a reviewed Git-only change to the Deployment (for example a metadata annotation) appears after merge to `main`. No webhook or image updater is needed; Argo CD polls Git. Do not change the image through kubectl: self-heal would revert it.

## Single-node resource budget and troubleshooting

The SPA requests 25m CPU / 32 MiB and is limited to 250m / 128 MiB. RollingUpdate permits one extra pod and zero unavailable pods, so reserve at least another 25m / 32 MiB of **allocatable** resources and one pod slot for updates. A single worker still has no node-level redundancy.

The non-HA Argo CD controller requests 100m / 256 MiB and is limited to 1 CPU / 1 GiB. Each auxiliary Deployment requests 50m / 64 MiB and is capped at 500m / 512 MiB. These are small-lab starting values, not capacity guarantees. Retain headroom for kube-system pods, node overhead and rollout overlap. Use `kubectl describe node` for allocated resources; use `kubectl top` only if metrics-server is already installed. This milestone does not install a monitoring stack, persistent volumes, Redis HA or extra replicas.

- Pending pods: inspect events with `kubectl describe pod`, resource requests and node pod/IP capacity. Do not add replicas blindly.
- ImagePullBackOff: verify the exact region/account/tag, ECR existence, node-role pull permissions and outbound connectivity. Git repository credentials cannot fix image pulls.
- Repository errors: check read-only deploy-key registration, matching SSH URL, host-key verification and outbound GitHub access.
- OOMKilled/slow sync: inspect Argo CD pod events and logs, then review resource budgets before increasing limits. All Argo CD state caches here are ephemeral; durable app configuration is in Git and credentials must be re-registered after rebuilding the installation.
- Probes failing: check pod logs and port 80. The existing Nginx image needs its normal filesystem access; no incompatible non-root/read-only-root hardening is forced onto it.

## Teardown (requires separate approval)

Remove the Application first to stop reconciliation, then delete only the application namespace if you intend to remove the SPA. Revoke the GitHub deploy key. If this is the dedicated Argo CD lab installation, remove its reviewed install manifest and namespace only after checking no other applications use it. Do not delete Argo CD first and leave an untracked application running. No Terraform or EKS teardown is part of M4A.

## Local validation results

App and bootstrap Kustomizations render with kubectl's bundled Kustomize. The supplied, user-verified ECR image URI is pinned in the rendered Deployment, with no unresolved placeholders. The pinned Argo CD installation could not be fetched in the implementation environment because GitHub DNS/network access is blocked. Full Kubernetes schema and server-side validation, Git authentication, live image pulling, sync and readiness remain to be verified on an authorized connected machine. No live resources were applied or changed.
