#!/usr/bin/env bash
# Checks the synapse-operator chart's flat values layout. The repo has no
# unit-test harness (CI runs helm lint and helm template), so this renders the
# chart and asserts on the output with yq.
#
#   1. defaults render what the chart at BASE rendered; runs only when BASE is
#      set (CI sets it to the pull request's base)
#   2. an overlay of the old operator.* keys, moved to the top level, renders
#      what BASE rendered with the old keys; same BASE gate
#   3. enabled=false renders nothing
#   4. a leftover operator: block fails with the migration message
#
# Needs helm, yq (mikefarah, v4) and git. Run from anywhere.
#
#   BASE   commit whose chart is the reference for checks 1 and 2, e.g.
#          BASE=origin/main. Unset, they are skipped.
set -euo pipefail

BASE="${BASE:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
chart="$root/charts/synapse-operator"
release="check"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failed=0
fail() {
  echo "FAIL: $*" >&2
  failed=1
}
pass() { echo "ok:   $*"; }

render() {
  helm template "$release" "$chart" "$@"
}

# Chart.yaml's version legitimately differs from the base's and lands in the
# labels; take it out before comparing. appVersion is the same on both sides,
# so the image tag needs no pin, but its label is normalised with the version.
normalise() {
  sed -E \
    -e 's#^( *helm\.sh/chart: ).*#\1CHART#' \
    -e 's#^( *app\.kubernetes\.io/version: ).*#\1VERSION#' "$1"
}

# A rich overlay in the OLD layout (everything under operator:), as BASE reads
# it. Check 2 derives the new layout from it by lifting operator: to the top,
# so the two cannot disagree about which key maps to which.
cat >"$work/old.yaml" <<'YAML'
global:
  namespaces:
    operator: ns-ops
operator:
  fullnameOverride: ops
  createNamespace: false
  image:
    repository: example.test/op
    tag: v9.9.9
    pullPolicy: Always
  imagePullSecrets:
    - name: pull
  priorityClassName: high
  replicaCount: 2
  leaderElectionNamespace: lease-ns
  watchNamespace: watched
  labelSelector: "app in (a,b)"
  configHashAnnotation: example.test/hash
  ignoreConfigMapKeys: "x.yaml"
  ignoreSecretKeys: "tls.key"
  ingressMode: true
  ingressClass: edge
  upstreamsOutConfigMap: ns/upstreams
  gatewayAPI: true
  resolveBackendClusterIPs: true
  resolveBackendEndpoints: false
  upstreamsResolver: true
  netvarsResolver: true
  idsHotReloadHashExclude: true
  perWorkloadConfigHash: true
  extraArgs: ["--zap-log-level=debug"]
  env:
    - name: FOO
      value: bar
  extraVolumes:
    - name: ca
      emptyDir: {}
  extraVolumeMounts:
    - name: ca
      mountPath: /ca
  serviceAccount:
    name: custom-sa
    annotations:
      example.test/role: r
  resources:
    requests: {cpu: 10m, memory: 64Mi}
    limits: {cpu: 500m, memory: 256Mi}
  annotations: {a: b}
  podAnnotations: {c: d}
  podLabels: {e: f}
  nodeSelector: {disk: ssd}
  tolerations:
    - key: k
      operator: Exists
  service:
    port: 9090
    annotations: {g: h}
  serviceMonitor:
    enabled: true
    namespace: monitoring
    labels: {release: prom}
  pdb:
    create: true
    maxUnavailable: 1
  networkPolicy:
    enabled: true
    metricsIngress:
      from:
        - namespaceSelector:
            matchLabels: {name: monitoring}
YAML
cat >"$work/old-name.yaml" <<'YAML'
global:
  namespaces:
    operator: synapse-os
operator:
  nameOverride: nm
  rbac:
    create: false
YAML

# lift FILE prints the same overlay in the new layout: operator: moved to the top.
lift() {
  yq '(.operator // {}) * {"global": .global}' "$1"
}

# --- 1 and 2. the same objects as the base --------------------------------------
echo "==> same objects as BASE"
if [ -z "$BASE" ]; then
  echo "skip: BASE is not set"
else
  mkdir -p "$work/base"
  git -C "$root" archive "$BASE" charts/synapse-operator | tar -x -C "$work/base"
  base_chart="$work/base/charts/synapse-operator"
  base_app="$(yq '.appVersion' "$base_chart/Chart.yaml")"
  head_app="$(yq '.appVersion' "$chart/Chart.yaml")"
  if [ "$base_app" != "$head_app" ]; then
    fail "appVersion is $head_app, BASE has $base_app; this check expects it unchanged"
  fi

  # compare NAME BASE_VALUES_FILE|- HEAD_VALUES_FILE|-
  compare() {
    local name="$1" bv="$2" hv="$3"
    local bargs=() hargs=()
    [ "$bv" = - ] || bargs=(-f "$bv")
    [ "$hv" = - ] || hargs=(-f "$hv")
    helm template "$release" "$base_chart" "${bargs[@]}" >"$work/$name.base.yaml"
    if ! render "${hargs[@]}" >"$work/$name.head.yaml" 2>"$work/$name.err"; then
      fail "$name: head render failed: $(cat "$work/$name.err")"
      return
    fi
    if diff -u <(normalise "$work/$name.base.yaml") <(normalise "$work/$name.head.yaml") >"$work/$name.diff"; then
      pass "$name renders what $BASE rendered"
    else
      fail "$name differs from $BASE:"
      head -n 40 "$work/$name.diff" >&2
    fi
  }

  compare defaults - -
  lift "$work/old.yaml" >"$work/new.yaml"
  compare overlay "$work/old.yaml" "$work/new.yaml"
  lift "$work/old-name.yaml" >"$work/new-name.yaml"
  compare overlay-name "$work/old-name.yaml" "$work/new-name.yaml"

  # The overlay must reach every template; a comparison of two renders that
  # both ignored it would pass.
  for kind in Deployment Service ServiceMonitor PodDisruptionBudget NetworkPolicy ClusterRole; do
    if ! yq -e "select(.kind == \"$kind\")" "$work/overlay.head.yaml" >/dev/null 2>&1; then
      fail "overlay: no $kind rendered, the overlay does not exercise it"
    fi
  done
  if ! grep -q 'image: "example.test/op:v9.9.9"' "$work/overlay.head.yaml"; then
    fail "overlay: image.tag was not applied"
  fi
fi

# --- 3. enabled=false renders nothing ------------------------------------------
echo "==> enabled=false"
if render --set enabled=false >"$work/disabled.yaml" 2>"$work/disabled.err"; then
  if [ -z "$(yq 'select(. != null)' "$work/disabled.yaml")" ]; then
    pass "nothing is rendered"
  else
    fail "enabled=false still renders objects"
  fi
else
  fail "render failed: $(cat "$work/disabled.err")"
fi

# --- 4. the legacy operator: block fails -----------------------------------------
echo "==> legacy operator: block"
if render --set operator.image.tag=x >/dev/null 2>"$work/legacy.err"; then
  fail "the render succeeded with operator.image.tag set"
elif grep -q "moved from operator" "$work/legacy.err" && grep -q "2.0.0" "$work/legacy.err"; then
  pass "the render fails with the migration message"
else
  fail "the render failed, but not with the migration message: $(cat "$work/legacy.err")"
fi

exit "$failed"
