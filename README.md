![Arxignis logo](./images/logo.png)

<p align="center">
  <a href="https://github.com/arxignis/helm-charts/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-Apache 2-green" alt="License - Apache 2"></a> &nbsp;
  <a href="https://github.com/arxignis/helm-charts/actions?query=branch%3Amain"><img src="https://github.com/arxignis/helm-charts/actions/workflows/release-synapse.yaml/badge.svg" alt="Release Synapse"></a> &nbsp;
  <a href="https://github.com/arxignis/helm-charts/actions?query=branch%3Amain"><img src="https://github.com/arxignis/helm-charts/actions/workflows/release-synapse-operator.yaml/badge.svg" alt="Release Synapse Operator"></a> &nbsp;
  <a href="https://github.com/arxignis/helm-charts/actions?query=branch%3Amain"><img src="https://github.com/arxignis/helm-charts/actions/workflows/release-synapse-stack.yaml/badge.svg" alt="Release Synapse Stack"></a> &nbsp;
  <a href="https://github.com/arxignis/helm-charts/releases"><img src="https://img.shields.io/github/release/arxignis/helm-charts.svg?label=Release" alt="Release"></a> &nbsp;
  <img alt="GitHub Downloads (all assets, all releases)" src="https://img.shields.io/github/downloads/arxignis/helm-charts/total"> &nbsp;
  <a href="https://docs.arxignis.com/"><img alt="Static Badge" src="https://img.shields.io/badge/arxignis-documentation-page?style=flat&link=https%3A%2F%2Fdocs.arxignis.com%2F"></a> &nbsp;
  <a href="https://discord.gg/jzsW5Q6s9q"><img src="https://img.shields.io/discord/1377189913849757726?label=Discord" alt="Discord"></a> &nbsp;
  <a href="https://x.com/arxignis"><img src="https://img.shields.io/twitter/follow/arxignis?style=flat" alt="X (formerly Twitter) Follow" /> </a>
</p>

# Community
[![Join us on Discord](https://img.shields.io/badge/Join%20Us%20on-Discord-5865F2?logo=discord&logoColor=white)](https://discord.gg/jzsW5Q6s9q)
[![Substack](https://img.shields.io/badge/Substack-FF6719?logo=substack&logoColor=fff)](https://arxignis.substack.com/)


# Helm Charts

This repository contains Helm charts for deploying Synapse and related components.

## Charts

### synapse

A Helm chart for Synapse reverse proxy with security features.

**Dependencies:**
- `valkey` - Redis-compatible in-memory data store
- `clamav` - Antivirus engine

### synapse-operator

A Helm chart for the Synapse Kubernetes operator.

### synapse-stack

Umbrella chart that installs both the Synapse dataplane and the Synapse Kubernetes operator together.

**Dependencies:**
- `synapse` - Synapse reverse proxy chart

### ssl-storage

Helm chart for deploying the SSL Storage ACME/Let's Encrypt certificate management service.

## Installation

### Add the Helm repository

```bash
helm repo add arxignis https://helm.arxignis.com
helm repo update
```

### Install synapse-stack (recommended)

Install both the Synapse dataplane and operator together:

```bash
helm install synapse-stack arxignis/synapse-stack --version 0.1.0
```

### Install synapse only

Install just the Synapse reverse proxy:

```bash
helm install synapse arxignis/synapse --version 0.1.0
```

### Install synapse-operator only

Install just the Synapse Kubernetes operator:

```bash
helm install synapse-operator arxignis/synapse-operator --version 1.0.6
```

## Usage

See the individual chart directories for detailed configuration options:

- [synapse chart values](charts/synapse/values.yaml)
- [synapse-operator chart values](charts/synapse-operator/values.yaml)
- [synapse-stack chart values](charts/synapse-stack/values.yaml)

## Repository

Charts are automatically published to:
- **Repository URL**: `https://helm.arxignis.com`
- **GitHub Repository**: `https://github.com/arxignis/helm-charts`

## Development

### Releasing Charts

Charts are automatically released via separate GitHub Actions workflows when changes are pushed to the `main` branch:

- **Synapse Chart**: Changes to `charts/synapse/**` trigger the `release-synapse.yaml` workflow
- **Synapse Operator Chart**: Changes to `charts/synapse-operator/**` trigger the `release-synapse-operator.yaml` workflow
- **Synapse Stack Chart**: Changes to `charts/synapse-stack/**` trigger the `release-synapse-stack.yaml` workflow
- **SSL Storage Chart**: Changes to `charts/ssl-storage/**` trigger the `release-ssl-storage.yaml` workflow

Each workflow can also be triggered manually via workflow_dispatch. The workflows use [chart-releaser-action](https://github.com/helm/chart-releaser-action) to package and publish charts to the GitHub Pages repository.

### Manual Release

You can also use the Makefile for manual releases:

```bash
make release VERSION=x.y.z
```

## License

See the LICENSE file in the root of this repository.
