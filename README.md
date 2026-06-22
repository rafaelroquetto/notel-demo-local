# notel-demo-local

A minimal, prod-faithful local copy of the `notel-demo` environment for
debugging **OBI** (OpenTelemetry eBPF Instrumentation) / Beyla against the
OpenTelemetry demo on a **kind** cluster.

"notel" = the OTel demo runs with its **own SDK instrumentation on**, and OBI
instruments the same workloads via eBPF in parallel. Both pipelines ship to one
`otel-lgtm` stack, so you can watch OBI's eBPF spans **collide** with the apps'
SDK spans (duplicate spans, `traceparent` context-propagation interplay).

## What this is (and isn't)

Faithful to the upstream `notel-demo-us` env in the ways that matter for the
agent, minus the Grafana-Cloud plumbing:

| Layer | Here | Upstream prod |
|---|---|---|
| Workload | All 23 demo microservices, **SDK on** | same |
| Demo backends (Jaeger/Prom/Grafana/OpenSearch) | **disabled** | enabled |
| Demo otel-collector | kept, **repointed → otel-lgtm** | kept → cloud |
| Telemetry sink | in-cluster `otel-lgtm` | Grafana Cloud |
| eBPF agent | **OBI DaemonSet**, your local build | Beyla/alloy-beyla DaemonSet |
| Agent discovery | K8s-based, `namespace="."` + excludes | same |
| Context propagation | `all` | `all` |
| k8s metadata cache | none (single agent, internal informers) | `beyla-k8s-cache` |

## Prerequisites

- `kind`, `kubectl`, `helm`, `docker`, `go`
- A local OBI checkout (default `~/dev/opentelemetry-ebpf-instrumentation`);
  override with `OBI_REPO=...`
- Linux host (the kind node shares your kernel, so eBPF works natively). ~8 GiB
  RAM free for the full demo + lgtm.

## Layout

```
kind-config.yaml      # 1 node; debugfs/bpffs extraMounts; Grafana :3000 mapping
otel-demo.values.yaml # demo overrides: backends off, collector -> lgtm, SDK on
otel-lgtm.yaml        # otel-lgtm Deployment + NodePort Service (ns: observability)
obi/rbac.yaml         # ServiceAccount + ClusterRole for k8s discovery (ns: obi)
obi/configmap.yaml    # OBI native config (the beyla.ebpf equivalent)
obi/daemonset.yaml    # privileged OBI DaemonSet, image obi:dev
sdk-off.values.yaml   # OTEL_SDK_DISABLED overlay (makes OBI the sole tracer)
test-obi-trace.py     # deterministic OBI trace test (make test)
Makefile              # see `make` targets below
```

## Quick start

```sh
cd ~/dev/notel-demo-local
make up            # create cluster + deploy lgtm + demo + build/load/deploy OBI
make grafana       # http://localhost:3000  (anonymous admin)
make logs-obi      # tail the agent
```

`make up` writes an isolated `kubeconfig.yaml` in this directory and exports
`KUBECONFIG` for every target — it never touches your `~/.kube/config`.

### The OBI inner loop

After editing OBI source:

```sh
make redeploy-obi  # recompile bin/obi -> rebuild image -> kind load -> rollout restart
make logs-obi
```

## Validate in this order (and where the risk is)

1. **Demo up & generating traffic**
   `make status` — `opentelemetry-demo` pods Ready, including `load-generator`.
2. **Backend reachable**
   `make grafana` → Explore → Tempo: SDK traces from the demo should appear
   (apps → otel-collector → otel-lgtm).
3. **debugfs landed in the node** *(the known kind wrinkle)*
   `docker exec notel-demo-local-control-plane mount | grep debugfs`
   should show `/sys/kernel/debug`. If empty, see Troubleshooting.
4. **OBI running & correlating** *(the make-or-break for in-cluster k8s metadata)*
   `make logs-obi` — it should discover demo pods, and emitted spans should
   carry `k8s.namespace.name` / `k8s.pod.name`. If those attributes are missing,
   the pod→PID cgroup correlation isn't resolving (check RBAC and that the agent
   sees the node's cgroups).
5. **The collision, side by side**
   In Tempo, the same operation (e.g. `frontend → cart`) should show up from
   **both** producers — the SDK span and OBI's eBPF span. Compare trace IDs and
   span structure: that's the interference you're investigating.

## Test OBI's traces

Deterministic and non-interactive: fire one checkout with a trace ID we choose
(injected via `traceparent`, which OBI adopts), fetch that exact trace from
Tempo by ID, and assert OBI rebuilt checkout's call graph.

```sh
make obi-only   # SDK off, OBI on -> OBI is the sole tracer (helm rolls the demo; ~1-2 min)
make test       # PASS/FAIL
```

`make test` self-manages its port-forwards (frontend + Tempo). It checks the
trace's spans are actually OBI's (warns if the SDK is still on), prints each
expected edge `OK`/`MISS` plus any async Kafka edges as a bonus, and exits
non-zero on failure. Edit the `EXPECT` set in `test-obi-trace.py` to change what
"correct" means.

OBI is *expected* to miss the SDK's internal in-process spans (no network →
invisible to eBPF); the interesting open question is the cross-language **Kafka**
edges (`checkout → accounting`/`fraud-detection`).

Revert to the normal demo (SDK + OBI both tracing) with `make sdk-on`.

## Debugging OBI

- **Logs first.** `log_level: DEBUG` is on. Toggle `ebpf.bpf_debug: true` in
  `obi/configmap.yaml` then `make redeploy-obi` for verbose probe logs.
- **Step-debugging (dlv), ready when logs aren't enough.** OBI ships a
  `debug.Dockerfile` and a debug compile path (`-gcflags "-N -l"`). Build that
  image instead of the fast one, set `OBI_IMAGE` to it, run dlv headless in the
  pod, then `kubectl -n obi port-forward ds/obi <dlvPort>` and attach your
  client. Confirm the dlv port in `$(OBI_REPO)/debug.Dockerfile`.

## Knobs

- **Network observability (prod-faithful, deferred).** Uncomment the `network:`
  + `filter.network:` blocks in `obi/configmap.yaml` and add `network` to
  `otel_metrics_export.features`, then `make redeploy-obi`. hostNetwork is
  already set on the DaemonSet.
- **Narrow discovery.** Change `discovery.services[0].k8s_namespace` from `"."`
  to `opentelemetry-demo` to instrument only the demo and cut kube-system noise.
- **Run Beyla instead of OBI.** Point `OBI_IMAGE` at a `grafana/beyla` image and
  adapt `obi/daemonset.yaml`. The config schema is shared; the env-var prefix
  differs (`BEYLA_` vs `OTEL_EBPF_`).

## Troubleshooting

- **`kind create` fails on `/sys/fs/bpf` mount.** If your host has no bpffs,
  drop that `extraMounts` entry in `kind-config.yaml` (kprobes need
  `/sys/kernel/debug`, which is the important one).
- **OBI eBPF programs fail to load.** Swap the explicit `capabilities` block in
  `obi/daemonset.yaml` for `privileged: true` (keep `runAsUser: 0`). Faithful
  prod uses the cap set, but `privileged` is the robust fallback on kind.
- **`make build-obi-image` fails on missing generated files.** Run
  `make generate` (or `make build`) once in `$(OBI_REPO)`.
- **No traces in Tempo at all.** Check the demo collector:
  `kubectl -n opentelemetry-demo logs deploy/otel-collector` — it should export
  to `otel-lgtm.observability.svc.cluster.local:4317` without connection errors.

## Teardown

```sh
make down          # deletes the kind cluster and the local kubeconfig
```
