# Implementation roadmap and engineering record

This roadmap records the implemented M1–M4 delivery path and organizes public
access/reliability work as M5 and operational documentation/hardening as M6.
Milestone labels describe repository scope, not a claim that every future task is complete.

## Evidence and status

- **Implemented** means the configuration or code is present in the repository.
- **Owner-verified** means the running-lab result was reported by the project owner.
- **Locally checked** means an implementation-session check completed successfully.
- **Remaining** means unimplemented work or validation that lacks recorded evidence.

The verified lab is `cloud-deployment` in us-west-2 with one c7i-flex.large worker.
Historical sandbox restrictions prevented some checks; those failures do not mean
the owner’s running deployment failed. Conversely, a working deployment does not
prove every provider, schema or failure path has been validated.

| Milestone | Scope | Status |
| --- | --- | --- |
| M1 | Minimal app and container | Implemented; component tests/type checking/build passed in an earlier session |
| M2A | CI | Implemented; YAML and structural checks passed |
| M2B | ECR publishing | Implemented; published immutable image verified by owner |
| M3 | AWS infrastructure | Implemented; running EKS lab verified by owner |
| M4A | Kubernetes and Argo CD | Implemented; GitOps recovery verified by owner |
| M4B | Automatic image promotion | Implemented; local promotion guards and rendering checks passed |
| M5 | Public access and reliability | Implemented; four manual scenarios owner-verified |
| M6 | Portfolio documentation and operational hardening | Documentation consolidated; hardening/evidence tasks remain |

## M1 — application and production image

**Implementation:** React + TypeScript + Vite under `app/`; a dark counter UI with
increment/reset controls; Vitest/React Testing Library, ESLint and TypeScript checks.
A multi-stage Dockerfile builds with Node.js 22 and serves static assets with Nginx.
The SPA has `/healthz`, route fallback and no backend or database. Make targets
cover local development, validation and Docker operations.

**Decisions:** Keep the deployment target small. Counter state is intentionally
in-memory. `/healthz` checks Nginx HTTP serving, not JavaScript execution.

**Validation:** Three component tests, type checking and a production build passed
in an earlier session. Later dependency installation/lint/build attempts encountered
registry DNS restrictions or missing local dependencies. Docker daemon permissions
blocked local container verification. Do not turn historical passes into a claim
that every current check was rerun successfully.

**Remaining:** Retain CI run evidence for the current revision; browser and container
smoke-test evidence can be recorded without adding product complexity.

## M2 — CI and immutable image publishing

**M2A:** CI runs on PRs and `main` pushes with Node.js 22, npm lockfile caching,
lint, tests, type checking, production build and Docker build. Any failed step fails CI.

**M2B:** Publishing is gated on successful CI for a same-repository `main` push.
The exact validated commit is built and published to private ECR in us-west-2.
Tags use `sha-<commit>-<run-id>-<attempt>`. Terraform supplies an OIDC provider and
ECR-scoped role; the exact branch subject supports immutable owner/repository IDs.

**Decisions:** No long-lived AWS keys, no `latest`, no publishing from PR artifacts.
Repository rules and IAM trust remain independent enforcement boundaries.

**Validation:** Workflow YAML, structural and shell checks passed locally. The owner
supplied a verified published ECR URI. Live AWS authentication and push tests were
not performed by the documentation/implementation sessions.

**Remaining:** Keep links to representative successful CI and publish runs. Verify
role assumptions after repository renames/transfers; do not widen trust to fix them.

## M3 — reproducible AWS infrastructure

**Implementation:** VPC, two public subnets in different availability zones, Internet
Gateway, routing, private ECR, standard EKS managed nodes and IAM. The live lab uses
us-west-2 and one c7i-flex.large. API access requires an explicit administrator CIDR;
private endpoint access is enabled. Administrator access supports an existing IAM
user or role; root/STS sessions are rejected and creator bootstrap access is disabled.
CNI and load-balancer-controller roles use the existing cluster OIDC provider.

**Decisions:** Avoid NAT Gateway cost for a short-lived lab. Keep node count at one
and acknowledge the availability tradeoff. Keep local state secure and preserve it
through destruction. Use the existing account-wide GitHub provider carefully.

**Validation:** Terraform formatting and vendored controller-policy JSON comparison
passed. Terraform init was blocked by registry access; validate encountered a provider
plugin startup/handshake failure. The owner confirmed the live EKS deployment.

**Remaining:** Record a successful full validate/plan on an authorized machine.
Reconcile private inputs with live settings before recreation: the starter tfvars
file still has old defaults. The integrated publishing data source requires an
existing west-region ECR repository; clean-account bootstrapping needs that prerequisite
resolved before a full-stack plan. No one-step empty-account recreation is claimed.

## M4 — Kubernetes GitOps and image promotion

**M4A:** Kustomize defines a namespace, one-replica Deployment, ClusterIP Service and
Argo CD Application/AppProject. Probes use `/healthz`. Requests are 25m CPU / 32 MiB,
limits 250m / 128 MiB. RollingUpdate allows one surge pod with zero unavailable pods.
Argo CD v3.5.6 is pinned in a non-HA install overlay with resource budgets.
Automated sync, prune and self-heal are enabled; private Git uses a read-only deploy key.

**M4B:** A separate promotion job receives the exact published URI, checks latest
`main` against the source SHA, changes only the image manifest and renders Kustomize.
Only promotion has `contents: write`; it uses GITHUB_TOKEN. Job concurrency, a second
branch check and a non-forced push prevent stale overwrite. No AWS credentials,
PAT, kubectl apply or Argo CD deployment command is used by promotion.

**Validation:** App/bootstrap rendering, selectors, probes and GitOps settings passed
local checks. The promotion script passed one-field-update, invalid-image and stale-source
guard checks in temporary files. Full install rendering/schema checks were blocked
by GitHub/cluster endpoint access. Owner-verified GitOps recovery demonstrates the live
reconciliation path; live workflow concurrency/race results are not recorded here.

**Remaining:** Capture successful and skipped promotion run evidence; validate the
full pinned install against the actual server schemas on an authorized machine.
During rollback, coordinate promotion so a later source push cannot supersede recovery.

## M5 — public access and failure recovery

**Implementation:** `counter-public` is a LoadBalancer Service with class
`service.k8s.aws/nlb`, internet-facing scheme, IP targets and port 80. The internal
ClusterIP Service remains available. Terraform tags the public subnets for ELB discovery
and vendors the official controller v3.6.2 IAM policy with a ServiceAccount-specific IRSA role.
Controller installation is a separate operational prerequisite, not a managed Helm release.

**Decisions:** Expose the SPA publicly while keeping Argo CD behind local port-forwarding.
Public HTTP is implemented; TLS, a custom domain and multi-node availability are not.
The controller must remain alive during Service deletion to clean up AWS resources.

## Reliability validation

The following manual scenarios were reported as verified by the project owner in the running lab. They are operational exercises, not automated test-suite results; this repository does not attach timestamps, recovery-time measurements or captured logs for them.

| Scenario | Verified behavior | What it demonstrates |
| --- | --- | --- |
| Pod self-healing | The workload recovered after a pod was removed | Kubernetes restores the Deployment’s desired replica count |
| Failed image deployment | An invalid image reference produced `ErrImagePull` | A bad image cannot become a Ready replacement; a failed rollout is observable |
| GitOps rollback and recovery | Restoring the known-good image in Git recovered the deployment through reconciliation | Git is the recovery source of truth; rollback requires an operator’s Git change |
| Public NLB HTTP validation | The public NLB endpoint returned HTTP 200 | The public request path reached the application |

Argo CD self-heal restores drift to the state declared in Git. It does **not** automatically choose an earlier healthy image when Git declares a bad image. Recovery is a deliberate manifest change or Git revert, followed by reconciliation. No zero-downtime or automatic-rollback guarantee is claimed.

To observe a recovery, check pod events, the deployed image and Argo CD status:

```sh
kubectl -n cloud-deployment get pods
kubectl -n cloud-deployment get events --sort-by=.metadata.creationTimestamp
kubectl -n cloud-deployment get deployment counter \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n argocd get application cloud-deployment \
  -o jsonpath='{.status.sync.status}{" "}{.status.health.status}{"\n"}'
```

Failure-injection exercises change the live workload and should be performed only with approval. During a rollback exercise, coordinate or pause image promotion so a concurrent application change does not supersede the recovery commit.


**Remaining:** Store dated test evidence and exact revisions if publishing a formal
validation report. No recovery-time, throughput or uptime benchmarks exist. Repeat
failure injection only with approval and available resource headroom.

## M6 — documentation and operational hardening

**Implemented:** A concise portfolio overview, this engineering record, dedicated
Terraform/publishing/Kubernetes runbooks, complete NLB-before-infrastructure teardown,
explicit existing-profile/region/input handling and kubectl-based verification.
Local app and Docker instructions are retained in the Kubernetes guide.

**Validation:** Documentation links, shell syntax, code fences and change scope are
checked locally. The four owner-verified manual reliability results are preserved;
no live resource changes are part of documentation maintenance.

**Remaining / optional future work (not implemented):**

- Capture CI, promotion, Argo CD and reliability evidence tied to a Git revision.
- Exercise and record a complete approved teardown/recreation with current inputs.
- Resolve the clean-account ECR data-source prerequisite and stale starter examples
  through a separately reviewed code change.
- Consider remote state/locking before collaborating with multiple operators.
- Consider HTTPS/custom DNS, monitoring/alerts and more than one worker only if
  the lab’s scope and budget expand. None is represented as available today.
- Review pinned controller/Argo CD releases and policy compatibility before upgrades.

## Technical decisions and security practices

- **Small application, visible delivery mechanics.** The counter needs no backend or database. Docker builds static assets once and Nginx serves them.
- **Immutable image identity.** ECR tags and Git manifest commits make the deployed build traceable. Recovery restores an explicit image reference.
- **Short-lived AWS authentication.** Publishing uses OIDC with an exact audience and repository/branch subject, not stored access keys. Its IAM permissions are scoped to ECR publishing.
- **Separated permissions.** Promotion has Git write access but no AWS credential step. Cluster workloads use dedicated IRSA roles where required; the SPA does not mount a ServiceAccount token.
- **Private control plane access boundaries.** The EKS public API is CIDR-restricted. Argo CD reads Git with a repository-scoped read-only deploy key and checks SSH host keys.
- **Explicit secret handling.** State, saved plans and sensitive Terraform inputs are ignored by Git. Private keys and repository Secrets remain outside source control. Local state must be retained securely through teardown.
- **Resource and cost discipline.** One node, one application replica, non-HA Argo CD and no NAT Gateway reduce lab overhead. The NLB, EKS control plane, compute, public IPv4, EBS and ECR storage still incur charges.


## Runbooks

- [Portfolio overview](../README.md)
- [Infrastructure and complete cleanup](../terraform/README.md)
- [Publishing and promotion](../terraform/PUBLISHING.md)
- [Kubernetes bootstrap, verification and local development](../kubernetes/README.md)
