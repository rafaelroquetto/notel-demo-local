# Local "notel" OpenTelemetry demo on kind, instrumented by an in-cluster OBI
# DaemonSet built from your local OBI working tree, shipping to otel-lgtm.
#
# Quick start:
#   make up            # cluster + lgtm + demo + obi (builds & loads your OBI)
#   make grafana       # open http://localhost:3000
#   make logs-obi      # tail the agent
#   make redeploy-obi  # after editing OBI source: recompile + load + restart
#   make down          # delete the cluster

CLUSTER            ?= notel-demo-local
KIND_NODE_IMAGE    ?= kindest/node:v1.32.0     # mirrors prod EKS 1.32
DEMO_NS            ?= opentelemetry-demo
DEMO_CHART_VERSION ?= 0.40.9

OBI_REPO  ?= $(HOME)/dev/opentelemetry-ebpf-instrumentation
OBI_IMAGE ?= obi:dev

# Keep this cluster's kubeconfig local to the directory (does not touch your
# default ~/.kube/config). Every kubectl/helm below inherits it.
KUBECONFIG_FILE ?= $(CURDIR)/kubeconfig.yaml
export KUBECONFIG = $(KUBECONFIG_FILE)

.PHONY: up deploy-all down create-cluster delete-cluster deploy-lgtm deploy-demo \
        build-obi-image load-obi-image deploy-obi redeploy-obi \
        logs-obi grafana shop status

## ---- meta ----------------------------------------------------------------
up: create-cluster deploy-lgtm deploy-demo deploy-obi
	@echo
	@echo "Stack is up."
	@echo "  Grafana:     make grafana   (http://localhost:3000)"
	@echo "  Agent logs:  make logs-obi"
	@echo "  Shop UI:     make shop       (http://localhost:8080)"

# (Re)deploy the workloads onto an already-running cluster.
deploy-all: deploy-lgtm deploy-demo deploy-obi

down: delete-cluster

## ---- cluster -------------------------------------------------------------
create-cluster:
	kind create cluster --name $(CLUSTER) --image $(KIND_NODE_IMAGE) \
		--config kind-config.yaml --kubeconfig $(KUBECONFIG_FILE)

delete-cluster:
	-kind delete cluster --name $(CLUSTER)
	-rm -f $(KUBECONFIG_FILE)

## ---- backend (otel-lgtm) -------------------------------------------------
deploy-lgtm:
	kubectl apply -f otel-lgtm.yaml
	kubectl -n observability rollout status deploy/otel-lgtm --timeout=180s

## ---- demo ----------------------------------------------------------------
deploy-demo:
	helm repo add opentelemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
	helm repo update opentelemetry >/dev/null
	helm upgrade --install opentelemetry-demo opentelemetry/opentelemetry-demo \
		--version $(DEMO_CHART_VERSION) \
		--namespace $(DEMO_NS) --create-namespace \
		-f otel-demo.values.yaml \
		--timeout 600s

## ---- OBI agent -----------------------------------------------------------
# Build your local OBI tree into a dev image. `make compile` produces bin/obi
# (linux/amd64, static); Dockerfile.fast wraps it in a scratch image. If compile
# fails on missing generated eBPF files, run `make generate` (or `make build`)
# in $(OBI_REPO) once.
build-obi-image:
	$(MAKE) -C $(OBI_REPO) compile
	docker build -f $(OBI_REPO)/Dockerfile.fast -t $(OBI_IMAGE) $(OBI_REPO)

load-obi-image:
	kind load docker-image $(OBI_IMAGE) --name $(CLUSTER)

deploy-obi: build-obi-image load-obi-image
	kubectl apply -f obi/rbac.yaml
	kubectl apply -f obi/configmap.yaml
	kubectl apply -f obi/daemonset.yaml
	kubectl -n obi rollout status ds/obi --timeout=180s

# The inner-loop target: rebuild your OBI changes and roll the DaemonSet.
redeploy-obi: build-obi-image load-obi-image
	kubectl apply -f obi/configmap.yaml
	kubectl -n obi rollout restart ds/obi
	kubectl -n obi rollout status ds/obi --timeout=180s

## ---- helpers -------------------------------------------------------------
logs-obi:
	kubectl -n obi logs -f ds/obi

grafana:
	@echo "Grafana: http://localhost:3000 (anonymous admin)"
	@command -v xdg-open >/dev/null 2>&1 && xdg-open http://localhost:3000 >/dev/null 2>&1 || true

# Astronomy shop UI on demand (blocks; Ctrl-C to stop).
shop:
	@echo "Astronomy shop: http://localhost:8080  (Ctrl-C to stop)"
	kubectl -n $(DEMO_NS) port-forward svc/frontend-proxy 8080:8080

status:
	kubectl get pods -A
