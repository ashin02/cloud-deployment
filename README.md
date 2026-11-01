# Deployment counter · M3

[![CI](https://github.com/ashin02/cloud-deployment/actions/workflows/ci.yml/badge.svg)](https://github.com/ashin02/cloud-deployment/actions/workflows/ci.yml)

A deliberately small React + TypeScript + Vite SPA for a DevOps portfolio. The counter has increment and reset controls; state lives in memory and resets on refresh. The production image builds with Node.js and serves static files with Nginx.

The M2A GitHub Actions workflow runs on pull requests and pushes to `main`. It installs the app dependencies with npm caching, then runs lint, tests, TypeScript checking, the production build, and a Docker image build. The workflow needs only read access to repository contents.

M3 adds [Terraform-managed AWS infrastructure](terraform/README.md): a public-subnet VPC, private ECR repository, and a minimal EKS managed node group. See the guide for authentication, costs, validation, deployment verification, and teardown. Infrastructure apply and destroy require explicit approval.

## Layout

```text
app/
  src/             # Counter UI and component tests
  Dockerfile       # Node.js build → Nginx production
  nginx.conf       # Static serving, SPA fallback, health endpoint
  package.json
terraform/         # VPC, ECR, EKS, IAM, and deployment/teardown guide
Makefile
README.md
```

The repository root is available for future `kubernetes/` and `scripts/` directories.

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

## GitHub Actions CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every pull request and pushes to `main`. One job uses Node.js 22 and caches npm downloads using `app/package-lock.json`. It runs `npm ci`, ESLint, Vitest, TypeScript checks, and the production build from `app/`, then builds the production Docker image with `app/Dockerfile` and the `app/` build context.

Any failed step fails the job. The workflow grants only `contents: read` and does not publish the image. The badge above links to workflow runs. To reproduce the checks locally, run `cd app && npm ci`, then the validation commands above and the Docker build from the repository root.

## ECR image publishing (M2B)

After successful CI for a push to `main`, [Publish image](.github/workflows/publish.yml) builds the validated commit and pushes a unique immutable tag to the existing `cloud-deployment` ECR repository in `us-west-2`. Authentication uses a Terraform-managed GitHub OIDC role, with no static AWS credentials. See the [publishing setup and troubleshooting guide](terraform/PUBLISHING.md) for repository IDs, role configuration, approval requirements, and verification.

## Kubernetes and Argo CD (M4A)

[Kubernetes deployment and bootstrap guide](kubernetes/README.md) documents the one-replica counter SPA, a pinned non-HA Argo CD installation, private repository access, and localhost port-forwarding. Kustomize manifests live under `kubernetes/`. Bootstrap and live-cluster changes require explicit approval; image promotion remains manual until M4B.
