# AWS infrastructure and operations

## AWS Load Balancer Controller IAM

`load_balancer_controller.tf` adds a dedicated IAM policy, IRSA role, and policy attachment. It reuses the existing EKS OIDC provider and permits only the subject `system:serviceaccount:kube-system:aws-load-balancer-controller`, with audience `sts.amazonaws.com`.

The policy is vendored unchanged from the [official controller v3.6.2 policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.2/docs/install/iam_policy.json) at `policies/aws-load-balancer-controller-v3.6.2.json`. Review and update the pinned policy deliberately when changing controller versions. No HTTP provider or download during planning is required.

After a separately approved apply, `terraform output -raw load_balancer_controller_role_arn` gives the ARN for the controller ServiceAccount annotation `eks.amazonaws.com/role-arn`. This configuration does not create a ServiceAccount, install Helm charts, or create a load balancer. Existing EKS, VPC, and node-group resources are unchanged.

This configuration creates a VPC (`10.42.0.0/16`), two public `/24` subnets in separate standard availability zones, an Internet Gateway and route table, private ECR, and a standard EKS cluster with one On-Demand `c7i-flex.large` managed worker by default. This is a short-lived experiment, not a highly available application platform.

The verified lab also has a public NLB, created by AWS Load Balancer Controller from `kubernetes/app/service-public.yaml`, not by a Terraform load-balancer resource. There are no NAT Gateways, databases or application persistent volumes. The worker still needs a 20 GiB root EBS disk, which EKS deletes with the instance. Default EKS networking, DNS, and kube-proxy components provide basic cluster operation; Terraform manages the VPC CNI add-on to give it a separate IAM role.

## Prerequisites and authentication

Install Terraform >= 1.6 and < 2, AWS CLI v2, and kubectl compatible with the selected EKS version. Use an AWS account with EC2 capacity and EKS/IAM quotas available in the chosen region. The verified cluster `cloud-deployment` runs in **us-west-2** with one **c7i-flex.large** worker. Terraform’s region default and starter tfvars example still say `us-east-1`, and the starter instance example says `t3.medium`; override these in private inputs rather than treating them as the live configuration. The configured Kubernetes version default is `1.35`; check the live version before upgrades. Check the [EKS version support calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) before deployment. `STANDARD` support avoids opting into extended-support pricing; AWS can automatically upgrade the cluster when standard support ends.

Reuse the existing lab AWS profile. If it uses IAM Identity Center, refresh it with `aws sso login --profile "$AWS_PROFILE"`; do not create a replacement profile for teardown:

```sh
: "${AWS_PROFILE:?Set AWS_PROFILE to the existing lab AWS profile}"
export AWS_PROFILE
export AWS_REGION=us-west-2
export AWS_DEFAULT_REGION="$AWS_REGION"
aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

Terraform uses the AWS credential chain. Do not put access keys in Terraform files. The provisioning identity needs permission to create/read/update/delete the declared VPC, EC2 networking, ECR, EKS, IAM roles, OIDC provider and policy attachments, pass the cluster/node roles to their services, and create EKS service-linked roles on first use. Use an account-approved provisioning role; this project does not grant the application or worker administrative IAM permissions.

Supply an existing IAM user or role ARN for `admin_principal_arn` (including its path, if any). Root and STS session ARNs are rejected. For a role, use its IAM `role/...` ARN rather than the `assumed-role/...` ARN returned for a session. The configuration grants the principal cluster administration through a STANDARD EKS access entry and the existing `AmazonEKSClusterAdminPolicy`, not additional AWS account permissions. The identity used by kubectl also needs `eks:DescribeCluster` for this cluster.

Rename `admin_role_arn` to `admin_principal_arn` in existing private variable files or `TF_VAR_` environment variables. Keeping the same ARN preserves the access entry's resource address and identity.

Cluster-creator bootstrap administration is explicitly disabled, and there is only one explicit administrator access entry in this configuration. Thus using the creator's IAM user or role as `admin_principal_arn` does not create a second creator entry in a new cluster. For a pre-existing cluster, check before applying:

```sh
aws eks list-access-entries --region YOUR_REGION --cluster-name YOUR_CLUSTER
aws eks describe-access-entry --region YOUR_REGION --cluster-name YOUR_CLUSTER \
  --principal-arn YOUR_IAM_USER_OR_ROLE_ARN
terraform state show aws_eks_access_entry.admin
```

If the principal already has an entry outside this Terraform state, import it instead of trying to create a duplicate: `terraform import aws_eks_access_entry.admin 'CLUSTER_NAME:PRINCIPAL_ARN'`. Inspect existing policy associations with `aws eks list-associated-access-policies` using the same cluster and principal arguments; reconcile/import existing associations before applying. Do not delete a working administrator entry blindly or change bootstrap settings on an existing cluster to fix duplicates. Live entries cannot be checked without AWS credentials and a deployed cluster.


## Configure and validate

From the repository root:

```sh
cd terraform
# For a NEW checkout only, copy the example without overwriting existing inputs.
test -e terraform.tfvars || cp terraform.tfvars.example terraform.tfvars
# Populate terraform.tfvars with the real lab values described below.
TF_INPUT_FILE="$PWD/terraform.tfvars"
test -f "$TF_INPUT_FILE"
terraform fmt -recursive
terraform init
terraform validate
terraform plan -input=false -var-file="$TF_INPUT_FILE" -var="region=$AWS_REGION" -out=m3.tfplan
```

`admin_cidr` has no default and accepts IPv4 `/24` through `/32` only; prefer `/32`. Use your VPN egress IP if applicable. Choose a project name unique within the account/region (IAM role names are account-wide). Two standard availability zones must be available; an unsupported instance type or EKS version will fail planning or provisioning. Supply `region = "us-west-2"`, `node_instance_type = "c7i-flex.large"`, the existing project/version/node-count settings, and all required inputs: `admin_cidr`, `admin_principal_arn`, `github_owner_id`, and `github_repository_id`. Preserve `github_immutable_subject`. The integrated publishing configuration reads an **existing** `cloud-deployment` repository in us-west-2. For a genuinely empty account, that data-source prerequisite must be resolved before planning the full stack; do not claim the integrated configuration can create everything in one step from an empty account.

Review the plan and account/region before deployment. **Apply only after explicit approval**:

```sh
terraform apply m3.tfplan
terraform output
```

Commit the generated `.terraform.lock.hcl` after successful initialization to pin provider selection and checksums. The AWS provider is constrained to major version 6. Keep the same committed lockfile when recreating infrastructure; update deliberately with `terraform init -upgrade`. EKS selects compatible default add-on and node AMI releases at creation, so later recreations may receive newer patches.

State is local to keep this single-user experiment minimal. `.terraform/`, state and backups, `*.tfvars`, `*.tfvars.json`, and saved `*.tfplan` files are ignored by Git. Plans and state can contain sensitive data: store them securely, retain state until teardown succeeds, and do not share the working directory. Do not use multiple concurrent operators against local state. Keep credentials in the normal AWS credential store outside the repository.

## Network and IAM choices

Workers get public IPv4 addresses and outbound internet access through the Internet Gateway. EKS's automatically created cluster security group is attached to the managed workers: inbound traffic is allowed only from members of that security group. The base Terraform network configuration does not open SSH or NodePort ingress. The controller manages the NLB and the security-group rules needed for the public HTTP Service; inspect those controller-owned resources separately from Terraform’s base rules. Its outbound access is retained for image pulls, AWS APIs, DNS and cluster communication. The public Kubernetes API is separately restricted to `admin_cidr`; the private API is enabled so nodes can join without allowing their public IPs through that CIDR restriction. Public IP assignment does not itself permit inbound connections.

The control plane uses `AmazonEKSClusterPolicy`; workers use `AmazonEKSWorkerNodePolicy` and `AmazonEC2ContainerRegistryPullOnly`. AWS-managed policies include discovery actions and broader ECR pull permissions needed by EKS system images. `AmazonEKS_CNI_Policy` is isolated using IRSA, with trust restricted to `kube-system:aws-node` and the STS audience. No worker ECR push permission is granted. The only cluster-admin access entry is the explicitly supplied administrator principal. Resources that support provider default tags receive Project, ManagedBy, and Purpose tags; EKS controls its generated EC2/ASG resources and their system tags.

## Verify deployment

From `terraform/`, authenticate as the configured IAM user or role:

```sh
REGION=$(terraform output -raw region)
CLUSTER=$(terraform output -raw cluster_name)
aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.status'
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
kubectl get nodes -o wide
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get pods -n kube-system
aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" \
  --nodegroup-name "${CLUSTER}-workers" --query 'nodegroup.{status:status,health:health.issues}'
terraform plan -input=false -var-file="$TF_INPUT_FILE" -var="region=$AWS_REGION"
```

For an IAM user, use that user’s AWS profile and omit `--role-arn`. For a role you need to assume, append `--role-arn YOUR_IAM_ROLE_ARN` to `update-kubeconfig`; your current credentials must be permitted to assume it. If already authenticated as the configured role, omit that option. Never pass a user ARN to `--role-arn`. Expect one Ready node and healthy system pods. A timeout accessing the API usually warrants checking your current public IP against `admin_cidr`; an authorization failure warrants checking the IAM principal/access entry. The final plan should show no unexpected changes. Application and public NLB operations are documented in [the Kubernetes guide](../kubernetes/README.md).

## Cost considerations

Budget for EKS control-plane hours, c7i-flex.large On-Demand compute, the worker’s 20 GiB EBS root disk, public IPv4 addresses, ECR storage, NLB hours/capacity usage and data transfer. No NAT Gateway is provisioned. Use the [AWS Pricing Calculator](https://calculator.aws/) with us-west-2 and the actual deployment; this project records no measured monthly bill or cost benchmark. Temporary extra nodes/pods during updates can increase resource use. Stopping application traffic does not stop these charges.

## Cost and complete teardown

Closing a browser, stopping port-forwarding or deleting the app pod does not stop infrastructure billing. Teardown requires explicit approval. Use the same AWS account, region, Terraform state and inputs that created the resources.

1. Pause the publish workflow in GitHub Actions and stop other changes to `main` during cleanup.
2. Remove the Argo CD Application first so it cannot recreate the public Service. This Application has no cascading deletion finalizer. Then remove the NLB Service **while AWS Load Balancer Controller is still running and its IAM role still exists**:

   ```sh
   kubectl -n argocd delete application cloud-deployment
   kubectl -n cloud-deployment delete service counter-public --wait=true --timeout=10m
   ```

3. Verify in AWS that the lab’s NLB, target groups and controller-managed security groups have been removed. If deletion stalls, inspect controller logs and Service finalizers; do not remove the controller or strip finalizers to bypass cleanup.
4. Delete the application namespace. Remove the dedicated Argo CD/controller installations only after checking that nothing else uses them, and revoke the GitHub read-only deploy key. Preserve any resources shared with other projects.
5. Use the existing AWS profile and the **same private variable file, state/backend and workspace used to provision this lab**. Run the following from the repository root. The example assumes that file is `terraform/terraform.tfvars`; change `TF_INPUT_FILE` to its actual path if different. Do not copy the example variable file over working inputs during teardown.

   The private inputs must include all required variables: `admin_cidr`, `admin_principal_arn`, `github_owner_id`, and `github_repository_id`. Preserve the existing values of `project`, `kubernetes_version`, `node_instance_type`, `node_count`, and `github_immutable_subject` as well. If provisioning supplied values via `TF_VAR_*` instead, retain those exports and omit `-var-file` only when all inputs are supplied that way. `-input=false` makes missing required inputs fail instead of prompting for guessed values. An AWS region environment variable alone does not override Terraform's `var.region`, so the plan explicitly supplies the lab region.

   ```sh
   : "${AWS_PROFILE:?Set AWS_PROFILE to the existing lab AWS profile}"
   export AWS_PROFILE
   export AWS_REGION=us-west-2
   export AWS_DEFAULT_REGION="$AWS_REGION"
   aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION"
   cd terraform
   TF_INPUT_FILE="$PWD/terraform.tfvars"
   test -f "$TF_INPUT_FILE"
   terraform workspace show
   terraform state list
   terraform plan -destroy -input=false \
     -var-file="$TF_INPUT_FILE" \
     -var="region=$AWS_REGION" \
     -out=destroy.tfplan
   terraform show destroy.tfplan
   # Only after reviewing and approving the plan:
   terraform apply -input=false destroy.tfplan
   terraform state list
   ```

   Stop if the account, region, workspace or state is not the existing lab's. Stop on any failed command; do not apply an older plan file after a failed plan. The saved plan already contains the selected variables, so do not add `-var` or `-var-file` to the apply command. Keep the same AWS profile/session for plan and apply, and refresh that profile's credentials if needed. No new profile, backend or workspace should be created to perform teardown.

6. Confirm the cluster, worker instances/root disks and VPC are gone. Check ECR, load balancers, target groups, public IPs and billing/resource inventories for anything remaining. Terraform’s ECR resource uses `force_delete = true`, so its images are deleted during approved destruction. A repository referenced only through a data source is not deleted by that lookup. The account-wide GitHub OIDC provider may be shared; resolve ownership before destroying it.

Retain state until deletion completes. If teardown fails, fix the reported dependency and retry with the same state rather than deleting state files. See the [recreation notes below](#recreation) for resource verification and recreation notes.

## Recreation

Retain the configuration and provider lockfile, refresh the existing AWS profile, confirm the public API CIDR and supported Kubernetes version, and reuse the correct private inputs. Resolve the existing-ECR data-source prerequisite before a clean-account plan. Repeat init, validate, plan and separately approved apply; then bootstrap controllers/Argo CD using the Kubernetes guide. Never discard state while resources still exist.

After teardown, use AWS CLI or the console with the same profile and region to verify the cluster and project-tagged VPC are absent, and review ECR/NLB resources separately. Remove stale local kubeconfig entries if desired.

For this lab's `cloud-deployment` project, these read-only checks complement `terraform state list` (use the actual project name if it differs):

```sh
aws eks list-clusters --profile "$AWS_PROFILE" --region "$AWS_REGION"
aws ecr describe-repositories --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --repository-names cloud-deployment
aws ec2 describe-vpcs --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --filters Name=tag:Project,Values=cloud-deployment
aws elbv2 describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION"
aws elbv2 describe-target-groups --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

Expect the lab cluster and VPC to be absent. Expect `RepositoryNotFoundException` only if this state owned and destroyed the ECR repository; a data-source-only repository requires separate cleanup approval. Compare load balancers and target groups with the lab's pre-deletion inventory, and leave unrelated resources untouched. An empty Terraform state alone does not prove controller-created AWS resources were removed.

## Implementation validation

`terraform fmt -recursive` completed successfully after the administrator-principal update. `terraform validate` was attempted but could not load the installed AWS provider schema because the provider plugin failed to start/complete its handshake. Provider validation remains unverified. The configuration disables automatic creator administration and declares one explicit STANDARD administrator entry; live access entries have not been inspected. Those historical local checks did not apply or destroy infrastructure. The owner subsequently verified the running us-west-2 cluster and public NLB; this is not evidence that every local Terraform validation issue has been resolved.

## GitHub image publishing

[M2B publishing configuration](PUBLISHING.md) adds an exact-branch GitHub OIDC trust and a repository-scoped ECR publishing role. Supply the new GitHub ID inputs before planning. The existing west-region publishing target is read through a separate provider alias; the main infrastructure region is unchanged.
