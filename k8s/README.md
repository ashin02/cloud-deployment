# Kubernetes deployment and operations

The `app/` Kustomization owns only the `cloud-deployment` namespace, one counter Deployment, a ClusterIP Service and a public NLB Service. Argo CD watches that directory on `main`. The separate `argocd/bootstrap/` Kustomization contains the Application and a restricted AppProject; `argocd/install/` pins the upstream **v3.5.6** non-HA installation. Argo CD does not manage itself in this milestone.

## Before bootstrap

**Do not execute apply, repository registration, password changes, or the reconciliation test below until live-cluster changes are explicitly approved.** Creating the Application enables automated deployment immediately. Merge/push the reviewed manifests to `main` and configure read-only repository access before creating it.

The Deployment pins an immutable ECR tag. The publishing workflow now promotes the exact image after successful CI, provided `main` still matches the validated source commit. Argo CD reconciles that Git change. Inspect `app/deployment.yaml` for the current URI rather than copying a historical tag from documentation. See [publishing and promotion](../terraform/PUBLISHING.md).

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
kubectl kustomize k8s/app > /tmp/counter-app.yaml
kubectl kustomize k8s/argocd/bootstrap > /tmp/counter-bootstrap.yaml
kubectl kustomize k8s/argocd/install > /tmp/argocd-install.yaml
```

Inspect the rendered files before applying. The remote install URL is pinned to [v3.5.6](https://github.com/argoproj/argo-cd/releases/tag/v3.5.6), not `stable`. The app includes `counter-public`, an internet-facing NLB Service on port 80 with IP targets. `counter` and the Argo CD UI Service remain internal. No Ingress is configured. Standard Argo CD installation includes CRDs and cluster-wide controller RBAC, so review it as an administrator. The restricted AppProject only permits this source, destination namespace, and the three app resource kinds. It is an operational guardrail, not isolation against cluster administrators.

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

The Application points only at `k8s/app`, so it cannot sync its own bootstrap files or credentials. The namespace is synced first via a negative sync wave. Automated sync, prune and self-heal are enabled. No deletion finalizer is set on the Application: deleting that object does not unexpectedly cascade-delete workloads. `allowEmpty: false` blocks automatically pruning the entire app when the source is empty; individual removed resources can still be pruned. Treat Git edits as deployment changes.

## Application readiness and reconciliation

```sh
kubectl -n argocd wait application/cloud-deployment --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s
kubectl -n argocd wait application/cloud-deployment --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s
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
kubectl -n argocd get application cloud-deployment
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

Follow [the complete AWS cleanup sequence](../terraform/README.md#cost-and-complete-teardown). Stop promotion and remove the Application before deleting `counter-public`. Keep AWS Load Balancer Controller and its IAM role available until AWS has removed the NLB, target groups and associated controller-owned resources. Only then remove the application namespace, dedicated controllers, and Terraform infrastructure. Revoke the GitHub deploy key. Do not remove finalizers to bypass cloud cleanup.

## Local validation results

App and bootstrap Kustomizations render with kubectl's bundled Kustomize. The supplied, user-verified ECR image URI is pinned in the rendered Deployment, with no unresolved placeholders. The pinned Argo CD installation could not be fetched in the implementation environment because GitHub DNS/network access is blocked. These are historical implementation-environment limitations, not the current lab status. The owner subsequently verified pod recovery, ErrImagePull failure handling, GitOps recovery and public HTTP 200. No captured timings or exhaustive schema-validation report is included. This documentation refactor made no live changes.

## Access and operational verification

Use the existing AWS profile for this lab (set `AWS_PROFILE` to that profile's name if it is not already exported). These verification commands require AWS CLI and kubectl; the Argo CD CLI is optional.

```sh
: "${AWS_PROFILE:?Set AWS_PROFILE to the existing lab AWS profile}"
export AWS_PROFILE
export AWS_REGION=us-west-2
aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION"
aws eks update-kubeconfig --profile "$AWS_PROFILE" --region "$AWS_REGION" --name cloud-deployment
kubectl config current-context
kubectl -n cloud-deployment get pods,svc
kubectl -n cloud-deployment rollout status deployment/counter --timeout=300s
kubectl -n argocd wait application/cloud-deployment \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s
kubectl -n argocd wait application/cloud-deployment \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s
kubectl -n argocd get application cloud-deployment \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{" "}{.status.sync.revision}{"\n"}'
```

These commands observe Argo CD's normal reconciliation; they do not force a refresh or sync. Confirm the reported revision matches the intended manifest commit on `main`, since a previously reconciled revision can also report `Synced Healthy`. For errors, inspect `kubectl -n argocd describe application cloud-deployment`.

Discover the current public endpoint rather than keeping a temporary AWS hostname in documentation:

```sh
NLB_HOST=$(kubectl -n cloud-deployment get service counter-public \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
test -n "$NLB_HOST"
curl --fail -i "http://$NLB_HOST/healthz"
curl --fail -o /dev/null -w '%{http_code}\n' "http://$NLB_HOST/"
```

Open `http://<the returned hostname>` in a browser. The Service exposes plain HTTP on port 80; TLS termination and a custom domain are not configured. The temporary lab endpoint is not a permanent hosted demo.

For local tunnels, run each command in a separate terminal:

```sh
kubectl -n cloud-deployment port-forward --address 127.0.0.1 svc/counter 8080:80
kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server 8081:443
```

Visit <http://localhost:8080> for the SPA and <https://localhost:8081> for Argo CD. Argo CD uses a self-signed certificate by default; follow the bootstrap guide for initial login and password rotation. The Argo CD UI is not exposed through the public NLB.


## Local development

Use Node.js 22.12+ (Node.js 22 is used in Docker), npm, and optionally Make. Docker commands require a running Docker daemon.

```sh
cd app
npm ci
npm run dev
```

Open <http://localhost:5173>. From the repository root, `make install` and `make dev` do the same thing.

## Validation and production build

```sh
cd app
npm run lint
npm test
npm run typecheck
npm run build
npm run preview
```

Vitest and React Testing Library cover the initial count, repeated increments, reset, and keyboard interaction. `npm run test:watch` enables watch mode. The build includes TypeScript checking and writes to `app/dist/`; preview serves it at <http://localhost:4173>.

From the repository root, use `make lint`, `make test`, `make typecheck`, `make build`, or `make check` for lint, tests, and a type-checked production build.

## Docker

Run these commands from the repository root; **`app/` is the build context**:

```sh
docker build -t deployment-counter:local app
docker run --rm --name deployment-counter -p 127.0.0.1:8080:80 deployment-counter:local
```

Alternatively, use `make docker-build` and `make docker-run`. Override the defaults with `IMAGE=my-counter:local` or `PORT=8081`.

Open <http://localhost:8080>. In another terminal:

```sh
curl --fail http://localhost:8080/
curl --fail -i http://localhost:8080/healthz
curl --fail http://localhost:8080/example/deep/link
docker inspect --format '{{.State.Health.Status}}' deployment-counter
```

`GET /healthz` returns HTTP 200 with `ok` as plain text. It checks Nginx availability, not JavaScript execution. Nginx falls back to `index.html` for SPA paths; missing assets return 404. The health endpoint exists in the production Nginx container, not the Vite development or preview servers. Docker checks it every 30 seconds.

Stop the foreground container with Ctrl+C, or run `docker stop deployment-counter` in another terminal.


## Public NLB prerequisite

The running lab’s `counter-public` Service depends on an installed AWS Load Balancer Controller using the existing `kube-system/aws-load-balancer-controller` ServiceAccount with the Terraform IRSA role annotation. Terraform vendors the v3.6.2 IAM policy; it does not install the controller or pin a deployed Helm chart. Public subnets carry `kubernetes.io/role/elb = "1"`. Do not assume a clean cluster gets a working NLB from the Service alone. Verify the controller, its credentials, subnet discovery and security-group reconciliation before diagnosing the application.
