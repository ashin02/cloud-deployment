IMAGE ?= deployment-counter:local
PORT ?= 8080

.PHONY: install dev lint test typecheck build preview check docker-build docker-run

install:
	npm --prefix app ci
dev:
	npm --prefix app run dev
lint:
	npm --prefix app run lint
test:
	npm --prefix app test
typecheck:
	npm --prefix app run typecheck
build:
	npm --prefix app run build
preview:
	npm --prefix app run preview
check: lint test build
docker-build:
	docker build -t $(IMAGE) app
docker-run:
	docker run --rm -p 127.0.0.1:$(PORT):80 $(IMAGE)
