<p align="center">
  <img src="./images/logo.png" alt="Gen0Sec" width="320">
</p>

<p align="center">
  <a href="https://github.com/gen0sec/helm-charts"><img src="https://img.shields.io/badge/License-Apache_2.0-green" alt="License - Apache 2.0"></a> &nbsp;
  <a href="https://github.com/gen0sec/helm-charts/actions?query=branch%3Amain"><img src="https://github.com/gen0sec/helm-charts/actions/workflows/release-synapse-stack.yaml/badge.svg" alt="Release Synapse Stack"></a> &nbsp;
  <a href="https://github.com/gen0sec/helm-charts/releases"><img src="https://img.shields.io/github/release/gen0sec/helm-charts.svg?label=Release" alt="Release"></a> &nbsp;
  <a href="https://docs.gen0sec.com/"><img alt="Documentation" src="https://img.shields.io/badge/gen0sec-documentation-page?style=flat&link=https%3A%2F%2Fdocs.gen0sec.com%2F"></a> &nbsp;
  <a href="https://discord.gg/jzsW5Q6s9q"><img src="https://img.shields.io/discord/1377189913849757726?label=Discord" alt="Discord"></a> &nbsp;
  <a href="https://x.com/gen0sec"><img src="https://img.shields.io/twitter/follow/gen0sec?style=flat" alt="X (formerly Twitter) Follow" /></a>
</p>

<p align="center">
  <a href="https://discord.gg/jzsW5Q6s9q"><img src="https://img.shields.io/badge/Join%20Us%20on-Discord-5865F2?logo=discord&logoColor=white" alt="Join us on Discord"></a>
  <a href="https://gen0sec.substack.com/"><img src="https://img.shields.io/badge/Substack-FF6719?logo=substack&logoColor=fff" alt="Substack"></a>
</p>

---

## Gen0Sec Helm Charts

Helm charts for deploying the **Synapse** dataplane and its **Kubernetes operator**.

> Requires **Helm 3** and a conformant **Kubernetes** cluster. Published to `https://helm.gen0sec.com`.

---

## Charts

| Chart | Version | App | Purpose |
|---|---|---|---|
| [`synapse-stack`](charts/synapse-stack) | 0.5.2 | 0.7.0 | **Umbrella** — two `synapse` workloads from one release, aliased `proxy` and `agent` |
| [`synapse`](charts/synapse) | 0.4.1 | 0.7.0 | Synapse reverse proxy / dataplane. Depends on `valkey`; optional `clamav` (`clamavIntegration.enabled`) |
| [`synapse-operator`](charts/synapse-operator) | 1.4.2 | 0.1.8 | The Synapse Kubernetes operator (config-sync controller) |

`synapse-stack` deploys the **dataplane twice** from the same subchart, each alias getting its
own values tree and identity:

| Alias | Workload | Role | Condition |
|---|---|---|---|
| `proxy` | `synapse-proxy` | TLS passthrough / L7 / Tier-2 terminate | `proxy.enabled` |
| `agent` | `synapse-agent` | XDP transparent observe (edge only) | `agent.enabled` |

It does **not** include the operator — install `synapse-operator` separately if you want it.

---

## Quick start

```bash
helm repo add gen0sec https://helm.gen0sec.com
helm repo update
helm search repo gen0sec        # list available charts + versions
```

**A single dataplane:**

```bash
helm install synapse gen0sec/synapse -n synapse --create-namespace
```

**Proxy and edge agent together, from the umbrella:**

```bash
helm install synapse-stack gen0sec/synapse-stack -n synapse --create-namespace
```

Both aliases default to enabled. Turn one off with `--set agent.enabled=false`, and set
per-alias values under the alias key — `--set proxy.service.type=LoadBalancer`, not
`--set service.type=...`.

**The operator (separate release):**

```bash
helm install synapse-operator gen0sec/synapse-operator -n synapse-os --create-namespace
```

---

## What the operator does

The `synapse-operator` chart deploys the operator as a config-sync controller (its default mode, [source](https://github.com/gen0sec/synapse-operator)):

- Watches **ConfigMaps and Secrets** matching a label selector (default `app.kubernetes.io/name=synapse`).
- Hashes their combined data and stamps the hash onto the Synapse workload under the `synapse.gen0sec.com/config-hash` annotation.
- A changed hash bumps the pod template, so Kubernetes **rolls the pods to pick up new config** — no manual restarts.

The chart wires these operator flags from `values.yaml`:

| Value | Operator flag | Default |
|---|---|---|
| `operator.leaderElect` | `--leader-elect` | `true` |
| `operator.labelSelector` | `--label-selector` | `app.kubernetes.io/name in (synapse,synapse-proxy,synapse-agent)` |
| `operator.configHashAnnotation` | `--config-hash-annotation` | `synapse.gen0sec.com/config-hash` |
| `operator.ignoreConfigMapKeys` | `--ignore-configmap-keys` | `upstreams.yaml` |
| `operator.ignoreSecretKeys` | `--ignore-secret-keys` | _(empty)_ |

> The operator binary also supports an Ingress + Gateway API mode (`--ingress-mode`); this chart does **not** enable it (config-sync mode only).

---

## Configuration highlights

| Value | Chart | Notes |
|---|---|---|
| `service.type` | synapse | `ClusterIP` by default. Every Service port becomes a load balancer listener on `LoadBalancer` |
| `service.exposeHealth` | synapse | `false`. The health endpoint binds loopback in the container, so publishing its port routes nowhere — see below |
| `clamavIntegration.enabled` | synapse | Pulls in the `clamav` subchart for content scanning |
| `operator.image.repository` / `tag` | synapse-operator | `ghcr.io/gen0sec/synapse-operator`; an empty `tag` falls back to the chart's `appVersion` |

### Configuring the dataplane

`synapse.config` is a **block scalar** — the literal `config.yaml` the container reads, rendered
into a ConfigMap. It is not a structured values tree, so its contents cannot be reached with
`--set synapse.something`. To change the platform endpoint or key, edit that block:

```yaml
synapse:
  config: |
    platform:
      api_key: ""
      base_url: "https://api.gen0sec.com/v1"
```

The chart does not template an API-key Secret. Supply the key through the config block, or
override it at runtime with the container's `AX_`-prefixed environment variables.

### A note on the health port

`service.healthPort` (8080) names a **container** port. The health endpoint listens on loopback
inside the container, so nothing answers on the Pod IP there — which is why the default probes,
pointing at that port, have to be repointed at `httpPort` in practice.

Publishing it on the Service is therefore off by default. Enabling it on a `LoadBalancer`
service is the case to avoid: the cloud controller creates a listener for it and opens the load
balancer's security group to `0.0.0.0/0`, giving you an internet-facing port that accepts
nothing.

See each chart's `values.yaml` for the full set:
[`synapse`](charts/synapse/values.yaml) ·
[`synapse-operator`](charts/synapse-operator/values.yaml) ·
[`synapse-stack`](charts/synapse-stack/values.yaml)

---

## Releases

Charts are published to GitHub Pages (`https://helm.gen0sec.com`) by per-chart GitHub Actions workflows ([chart-releaser](https://github.com/helm/chart-releaser-action), config in `.cr.yaml`). A workflow runs when its chart directory changes on `main`, or via manual `workflow_dispatch`:

| Workflow | Triggers on |
|---|---|
| `release-synapse.yaml` | `charts/synapse/**` |
| `release-synapse-operator.yaml` | `charts/synapse-operator/**` |
| `release-synapse-stack.yaml` | `charts/synapse-stack/**` |

To cut a release, bump the chart's `version` in its `Chart.yaml` and merge to `main`.

---

## Documentation

| | |
|---|---|
| [Gen0Sec Docs](https://docs.gen0sec.com/) | Product documentation and guides |
| [synapse](https://github.com/gen0sec/synapse) | The Synapse dataplane this chart deploys |
| [synapse-operator](https://github.com/gen0sec/synapse-operator) | The operator source and full flag reference |

---

## License

These charts are distributed under the **Apache-2.0** license — see [`LICENSE`](LICENSE).
