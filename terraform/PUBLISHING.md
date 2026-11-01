# M2B: publish images after CI

`.github/workflows/publish.yml` runs when `CI` completes on `main`, and its job proceeds only for successful **push** runs from this repository. PR runs, forks, failures and other branches do not publish. The workflow file must be present on the default branch. `main` is the default branch used by the existing CI configuration; update both workflows and the exact Terraform trust subject together if it changes.

The workflow checks out `workflow_run.head_sha`, builds `app/Dockerfile` with `app/` as context, obtains short-lived AWS credentials using GitHub OIDC, logs into ECR and pushes one tag:

```text
sha-<full validated commit SHA>-<publish run ID>-<publish run attempt>
```

Retries get a different tag. There is no `latest` tag. The image reference appears in the workflow summary; the push log includes its digest. CI checks and the EKS infrastructure are unchanged. No application deployment is performed.

## AWS and GitHub configuration

1. Confirm the existing private `cloud-deployment` ECR repository is in **us-west-2**, in the same AWS account as the Terraform credentials. It must have `IMMUTABLE` tag mutability. The new provider alias only reads this repository and does not create, move, or import it. The original ECR resource remains managed under the original provider; `publishing_ecr_url` explicitly identifies the publishing target even if the original `ecr_url` is in another region. Do not change `region` to move an existing EKS cluster.
2. Get the real repository IDs, creation date and default branch with an authenticated GitHub CLI:

   ```sh
   gh api repos/ashin02/cloud-deployment \
     --jq '{owner_id: .owner.id, repository_id: .id, created_at: .created_at, default_branch: .default_branch}'
   ```

   Set `github_owner_id` and `github_repository_id` in your ignored Terraform variable file. Do not use the example IDs. Set `github_immutable_subject = true` for the immutable default format.
3. The exact trusted subject is:

   ```text
   repo:ashin02@OWNER_ID/cloud-deployment@REPOSITORY_ID:ref:refs/heads/main
   ```

   [GitHub's immutable OIDC format](https://docs.github.com/en/actions/reference/security/oidc) applies to repositories created after July 15, 2026, and repositories renamed/transferred under the new format. The separator is `@`, not a hyphen. Only if you verify this repository still uses the legacy default format, set `github_immutable_subject = false`; this trusts exactly `repo:ashin02/cloud-deployment:ref:refs/heads/main`. The configuration never trusts both formats at once and uses no wildcard subjects. Custom subject templates require a deliberate matching policy update. Do not add a GitHub environment to the publishing job: that changes the default subject from a branch to an environment.
4. Check whether this account already has the GitHub OIDC provider (`https://token.actions.githubusercontent.com`). AWS permits only one provider for that URL per account. If it exists and is not managed by another Terraform stack, import it before planning:

   ```sh
   cd terraform
   terraform import aws_iam_openid_connect_provider.github \
     arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com
   ```

   If another stack owns it, reference it from that stack instead of attempting duplicate ownership. An imported shared provider must not be deleted during this experiment's teardown while other roles still use it.
5. Run `terraform fmt -check`, `terraform init`, `terraform validate`, and `terraform plan`. Review that no existing EKS, networking, or ECR resources are being replaced. The provisioning identity additionally needs IAM OIDC-provider/role/inline-policy management and `ecr:DescribeRepositories` for the west-region lookup. Apply requires separate explicit approval; no apply or destroy was performed for this implementation.
6. After an approved apply, set repository **Settings → Secrets and variables → Actions → Variables** → `AWS_PUBLISH_ROLE_ARN` to `terraform output -raw github_publish_role_arn`. This is a non-secret ARN. No static AWS keys or GitHub environment are needed. `terraform output -raw github_oidc_subject` shows the expected subject. Do not push a test change until the role and variable are configured.

The role allows `ecr:GetAuthorizationToken` on `*` because AWS does not support repository scoping for that action. Layer-upload, manifest-read and image-publish actions are scoped to the single resolved repository ARN. It has no repository-creation, deletion, EKS, IAM, or deployment permissions. GitHub permissions are `contents: read` and, only for the publish job, `id-token: write`. Any push workflow on the trusted branch can request this role, so protect default-branch changes and review workflow edits. The workflow does not download or execute PR artifacts.

## Verification

After approval and a push to `main`, confirm CI succeeds, then confirm the `Publish image` run references the same commit. Using a local AWS profile with read permissions:

```sh
aws sts get-caller-identity
aws ecr describe-repositories --region us-west-2 --repository-names cloud-deployment \
  --query 'repositories[0].{url:repositoryUri,mutability:imageTagMutability}'
aws ecr describe-images --region us-west-2 --repository-name cloud-deployment \
  --image-ids imageTag=sha-COMMIT_SHA-RUN_ID-RUN_ATTEMPT \
  --query 'imageDetails[0].{digest:imageDigest,pushed:imagePushedAt,tags:imageTags}'
```

Use the exact tag from the workflow summary. AWS CloudTrail's `AssumeRoleWithWebIdentity` events can verify the publishing session. PRs and unsuccessful CI runs should have no publishing job execution.

## Troubleshooting and cleanup

- **No workflow run:** ensure the publish file is on `main`, CI is named `CI`, Actions are enabled, and the source run is a push on `main`.
- **OIDC AccessDenied:** check the role ARN, account, audience `sts.amazonaws.com`, exact `sub` format and numeric IDs. Renames, transfers and environments can change the subject. Check GitHub OIDC settings or securely inspect only the decoded `sub` and `aud` claims; never print or share a raw token. Do not fix this by allowing `repo:*` or all branches.
- **Repository not found:** verify account and `us-west-2`; the Terraform data source intentionally requires the existing repository. Do not change the primary provider region to resolve this.
- **Push denied:** check the resolved ECR ARN and inline role policy. Login alone proves authentication, not repository write authorization.
- **Tag already exists:** immutable tags cannot be overwritten. Re-run the publishing workflow to get a new attempt suffix; do not disable immutability.
- **Terraform provider handshake failure:** validation in this environment could not start the installed AWS plugin. Run validation on a host that can execute Terraform provider plugins before applying.

Images incur ECR storage costs and are retained until deliberately removed. The publishing role cannot delete them. Destroying this Terraform stack removes its publishing role and GitHub provider; it does not delete a repository that is only referenced by the data source. If the target is also the original managed `aws_ecr_repository.app`, that original resource's documented force-delete behavior still applies. Teardown requires explicit approval, including checking whether the account-wide OIDC provider is shared.
