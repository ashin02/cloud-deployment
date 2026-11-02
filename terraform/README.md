# M3: temporary EKS infrastructure

## AWS Load Balancer Controller IAM

`load_balancer_controller.tf` adds a dedicated IAM policy, IRSA role, and policy attachment. It reuses the existing EKS OIDC provider and permits only the subject `system:serviceaccount:kube-system:aws-load-balancer-controller`, with audience `sts.amazonaws.com`.

The policy is vendored unchanged from the [official controller v3.6.2 policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.2/docs/install/iam_policy.json) at `policies/aws-load-balancer-controller-v3.6.2.json`. Review and update the pinned policy deliberately when changing controller versions. No HTTP provider or download during planning is required.

After a separately approved apply, `terraform output -raw load_balancer_controller_role_arn` gives the ARN for the future ServiceAccount annotation `eks.amazonaws.com/role-arn`. This configuration does not create a ServiceAccount, install Helm charts, or create a load balancer. Existing EKS, VPC, and node-group resources are unchanged.

This configuration creates a VPC (`10.42.0.0/16`), two public `/24` subnets in separate standard availability zones, an Internet Gateway and route table, private ECR, and a standard EKS cluster with one On-Demand `t3.medium` managed worker by default. This is a short-lived experiment, not a highly available application platform.

There are no NAT Gateways, load balancers, databases, application manifests, or persistent volumes. The worker still needs a 20 GiB root EBS disk, which EKS deletes with the instance. Default EKS networking, DNS, and kube-proxy components provide basic cluster operation; Terraform manages the VPC CNI add-on to give it a separate IAM role.

## Prerequisites and authentication

Install Terraform >= 1.6 and < 2, AWS CLI v2, and kubectl compatible with the selected EKS version. Use an AWS account with EC2 capacity and EKS/IAM quotas available in the chosen region. The default region is `us-east-1`; the default Kubernetes version is `1.35`. Check the [EKS version support calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) before deployment. `STANDARD` support avoids opting into extended-support pricing; AWS can automatically upgrade the cluster when standard support ends.

Use temporary credentials, preferably IAM Identity Center:

```sh
aws configure sso --profile portfolio
aws sso login --profile portfolio
export AWS_PROFILE=portfolio
aws sts get-caller-identity
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
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set your actual public IPv4/32 and existing IAM user or role ARN.
terraform fmt -recursive
terraform init
terraform validate
terraform plan -out=m3.tfplan
```

`admin_cidr` has no default and accepts IPv4 `/24` through `/32` only; prefer `/32`. Use your VPN egress IP if applicable. Choose a project name unique within the account/region (IAM role names are account-wide). Two standard availability zones must be available; an unsupported instance type or EKS version will fail planning or provisioning. No existing VPC or ECR repository is required.

Review the plan and account/region before deployment. **Apply only after explicit approval**:

```sh
terraform apply m3.tfplan
terraform output
```

Commit the generated `.terraform.lock.hcl` after successful initialization to pin provider selection and checksums. The AWS provider is constrained to major version 6. No lockfile is fabricated here: initialization has not run successfully. Keep the same committed lockfile when recreating infrastructure; update deliberately with `terraform init -upgrade`. EKS selects compatible default add-on and node AMI releases at creation, so later recreations may receive newer patches.

State is local to keep this single-user experiment minimal. `.terraform/`, state and backups, `*.tfvars`, `*.tfvars.json`, and saved `*.tfplan` files are ignored by Git. Plans and state can contain sensitive data: store them securely, retain state until teardown succeeds, and do not share the working directory. Do not use multiple concurrent operators against local state. Keep credentials in the normal AWS credential store outside the repository.

## Network and IAM choices

Workers get public IPv4 addresses and outbound internet access through the Internet Gateway. EKS's automatically created cluster security group is attached to the managed workers: inbound traffic is allowed only from members of that security group. No SSH, public HTTP, or NodePort ingress is enabled. Its outbound access is retained for image pulls, AWS APIs, DNS and cluster communication. The public Kubernetes API is separately restricted to `admin_cidr`; the private API is enabled so nodes can join without allowing their public IPs through that CIDR restriction. Public IP assignment does not itself permit inbound connections.

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
terraform plan
```

For an IAM user, use that user’s AWS profile and omit `--role-arn`. For a role you need to assume, append `--role-arn YOUR_IAM_ROLE_ARN` to `update-kubeconfig`; your current credentials must be permitted to assume it. If already authenticated as the configured role, omit that option. Never pass a user ARN to `--role-arn`. Expect one Ready node and healthy system pods. A timeout accessing the API usually warrants checking your current public IP against `admin_cidr`; an authorization failure warrants checking the IAM principal/access entry. The final plan should show no unexpected changes. No application is deployed in M3.

## Cost and complete teardown

Budget for the control plane even when no pods are running. [EKS standard support](https://aws.amazon.com/eks/pricing/) costs $0.10/cluster-hour ($2.40/day, about $73 per 730 hours); [public IPv4](https://aws.amazon.com/vpc/pricing/) costs $0.005/address-hour (about $3.65 per 730 hours for one worker address). Add region-specific `t3.medium` On-Demand compute, its 20 GiB EBS root disk, ECR storage, and data transfer. A rough planning allowance is $4–5/day or $110–150/month for this small experiment, not a quote; verify with the [AWS Pricing Calculator](https://calculator.aws/) for the chosen region. T3 surplus CPU credits and temporary extra nodes during updates can add charges. There is no NAT Gateway charge. A single worker saves money but provides no workload redundancy.

Destroy promptly after the experiment. Scaling the worker down or stopping an instance does not remove control-plane charges. If later experiments create services, volumes, or external resources, remove those through Kubernetes while the cluster is still reachable before teardown.

From the same `terraform/` directory, with the same state, inputs, region and AWS account:

```sh
terraform plan -destroy -out=destroy.tfplan
# Review the deletion plan. Execute ONLY after explicit approval:
terraform apply destroy.tfplan
terraform state list
aws eks list-clusters --region "$REGION"
aws ecr describe-repositories --region "$REGION" --repository-names "$CLUSTER"
aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Project,Values=$CLUSTER"
```

Expect an empty Terraform state, the cluster absent, ECR `RepositoryNotFoundException`, and no matching VPC. ECR uses `force_delete = true`: approved destruction removes all images in this repository. IAM roles, OIDC provider, add-on, access entries, worker instances/root disks, and network resources are included in teardown. If deletion fails, keep state, resolve the reported dependency and retry the destroy plan; do not discard state or manually recreate conflicting resources. Confirm billing/resource inventories after deletion. Remove stale kubeconfig entries locally if desired.

To recreate, retain the configuration and provider lockfile, refresh temporary AWS credentials, confirm your current public IP and supported EKS version, then repeat init, validate, plan, and approved apply. Never delete state to simulate a fresh deployment while resources still exist.

## Implementation validation

`terraform fmt -recursive` completed successfully after the administrator-principal update. `terraform validate` was attempted but could not load the installed AWS provider schema because the provider plugin failed to start/complete its handshake. Provider validation remains unverified. The configuration disables automatic creator administration and declares one explicit STANDARD administrator entry; live access entries have not been inspected. No infrastructure was applied or destroyed.

## GitHub image publishing

[M2B publishing configuration](PUBLISHING.md) adds an exact-branch GitHub OIDC trust and a repository-scoped ECR publishing role. Supply the new GitHub ID inputs before planning. The existing west-region publishing target is read through a separate provider alias; the main infrastructure region is unchanged.
