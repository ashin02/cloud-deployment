# Deployment counter · M1

A deliberately small React + TypeScript + Vite SPA for a DevOps portfolio. The counter has increment and reset controls; state lives in memory and resets on refresh. The production image builds with Node.js and serves static files with Nginx.

This milestone provides only the application, tests, and container. AWS EKS, Terraform, Kubernetes, GitHub Actions, and Argo CD are future work.

## Layout

```text
app/
  src/             # Counter UI and component tests
  Dockerfile       # Node.js build → Nginx production
  nginx.conf       # Static serving, SPA fallback, health endpoint
  package.json
Makefile
README.md
```

The repository root is available for future `terraform/`, `kubernetes/`, `scripts/`, and `.github/` directories.

## Local development

Use Node.js 22.12+ (Node.js 22 is used in Docker), npm, and optionally Make. Docker commands require a running Docker daemon.

```sh
cd app
npm install
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

## M1 validation in the implementation environment

- Passed: all 3 component tests, TypeScript checking, and the production build.
- Dependencies needed for tests and build were installed from the local npm cache. A full installation and lint remain unverified because registry DNS is unavailable and ESLint packages are not cached.
- Docker build was attempted but blocked by permission denied on the Docker socket. Container startup, Nginx SPA fallback, and `/healthz` remain unverified.
- Vite preview was attempted but the environment denied binding to `127.0.0.1:4173` (`EPERM`), so HTTP serving and a browser smoke test remain unverified. Component behavior was verified in jsdom.

Run `make install` on a network-enabled machine to install all dependencies and generate `app/package-lock.json`, then commit that lockfile. A complete lockfile could not be generated here; install commands currently use `npm install`. Once generated, switch the Dockerfile and install commands to `npm ci` for reproducible installs, then run `make check` and the Docker checks above.
