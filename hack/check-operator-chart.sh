#!/usr/bin/env bash
# Checks the synapse-operator chart's flat values layout. The repo has no
# unit-test harness (CI runs helm lint and helm template), so this renders the
# chart and asserts on the output with yq.
#
#   1. defaults render what the chart at BASE rendered; runs only when BASE is
#      set (CI sets it to the pull request's base)
#   2. a rich overlay renders what BASE rendered with the same settings; same
#      BASE gate. The fixture is written in the current (flat) layout; for a
#      BASE that still reads the old operator: layout it is wrapped back into
#      operator: first, so the script works before and after the flattening.
#   3. enabled=false renders nothing
#   4. (any BASE) the default image is <image.repository>:<appVersion>, with no
#      pin; checks 1 and 2 pin image.tag, so they cannot see that fallback
#   5. a leftover operator: block fails with the migration message
#   6. instanceLabelInSelector=false drops app.kubernetes.io/instance from
#      every selector (Deployment, Service, PDB, NetworkPolicy, ServiceMonitor)
#      while the pod labels keep it and still satisfy each selector; the
#      default keeps it
#
# Only chart/version labels are normalised. The head render is pinned to the
# base chart's appVersion (image.tag), so the image is NOT compared by the
# defaults and overlay-name cases; an appVersion bump is not a default change.
#
# An INTENDED change of the render is declared, not waived: commit
# hack/operator-chart-expected/<case>.diff (defaults, overlay, overlay-name)
# holding the exact `diff -u --label base --label head` of that case's
# normalised base and head renders. Each file is honoured only when it differs
# between BASE and HEAD, so the PR that changes the render carries (and
# reviewers see) the diffs, and the next PR is held to "no change" again
# without touching them. Otherwise the expected diff of a case is empty.
# A file counts only once it is committed: the comparison with BASE is made
# against HEAD, not the working tree. Regenerate with REGEN=1 (needs BASE),
# which writes the actual diff of every case to that case's file; review it,
# then commit it.
#
# Needs helm, yq (mikefarah, v4) and git. Run from anywhere.
#
#   BASE   commit whose chart is the reference for checks 1 and 2, e.g.
#          BASE=origin/main. Unset, they are skipped. BASE=HEAD must always
#          pass: it proves the script is compatible with the chart it ships in.
set -euo pipefail

for t in helm yq git; do
  command -v "$t" >/dev/null || {
    echo "missing $t" >&2
    exit 2
  }
done

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

# The monitoring API is declared so the ServiceMonitor template is exercised.
render() {
  helm template "$release" "$chart" --api-versions monitoring.coreos.com/v1 "$@"
}

# Chart.yaml's version legitimately differs from the base's and lands in the
# labels; take it out before comparing. The version label follows appVersion,
# so it is normalised too.
normalise() {
  sed -E \
    -e 's#^( *helm\.sh/chart: ).*#\1CHART#' \
    -e 's#^( *app\.kubernetes\.io/version: ).*#\1VERSION#' "$1"
}

# A rich overlay in the current flat layout. The base side is derived from it
# (see to_base), so the two cannot disagree about which key maps to which.
cat >"$work/flat.yaml" <<'YAML'
global:
  namespaces:
    operator: ns-ops
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
cat >"$work/flat-name.yaml" <<'YAML'
global:
  namespaces:
    operator: synapse-os
nameOverride: nm
rbac:
  create: false
YAML

# to_base FILE prints the fixture in the layout BASE reads: unchanged when BASE
# is flat, wrapped into operator: (global stays at the top) when it is not.
to_base() {
  if [ "$base_legacy" = 1 ]; then
    yq '{"global": .global, "operator": del(.global)}' "$1"
  else
    cat "$1"
  fi
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
  base_legacy=0
  [ "$(yq '.operator | tag' "$base_chart/values.yaml")" = '!!map' ] && base_legacy=1

  # compare NAME FLAT_VALUES_FILE|- [HEAD_ARGS...]; the head render is pinned
  # to the base's appVersion by the caller where the fixture sets no image.tag.
  compare() {
    local name="$1" fv="$2"
    shift 2
    local bargs=() hargs=()
    if [ "$fv" != - ]; then
      to_base "$fv" >"$work/$name.basevals.yaml"
      bargs=(-f "$work/$name.basevals.yaml")
      hargs=(-f "$fv")
    fi
    helm template "$release" "$base_chart" --api-versions monitoring.coreos.com/v1 "${bargs[@]}" >"$work/$name.base.yaml"
    if ! render "${hargs[@]}" "$@" >"$work/$name.head.yaml" 2>"$work/$name.err"; then
      fail "$name: head render failed: $(cat "$work/$name.err")"
      return
    fi
    diff -u --label base --label head <(normalise "$work/$name.base.yaml") <(normalise "$work/$name.head.yaml") >"$work/$name.diff" || true
    # The case's declared diff: empty unless its file changed between BASE and
    # HEAD.
    local want="$work/$name.expected.diff" file="hack/operator-chart-expected/$name.diff"
    : >"$want"
    if ! git -C "$root" diff --quiet "$BASE" HEAD -- "$file" && [ -f "$root/$file" ]; then
      cp "$root/$file" "$want"
    fi
    if [ "${REGEN:-}" = 1 ]; then
      cp "$work/$name.diff" "$root/$file"
      pass "$name: wrote $file"
    elif cmp -s "$work/$name.diff" "$want"; then
      pass "$name renders what $BASE rendered"
    else
      fail "$name differs from what $BASE rendered; actual diff (base -> head):"
      cat "$work/$name.diff" >&2
      if [ -s "$want" ]; then
        echo "--- expected ($file) against actual:" >&2
        diff -u "$want" "$work/$name.diff" >&2 || true
      fi
    fi
  }

  compare defaults - --set "image.tag=$base_app"
  compare overlay "$work/flat.yaml"
  compare overlay-name "$work/flat-name.yaml" --set "image.tag=$base_app"

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
  if ! grep -q '^kind:' "$work/disabled.yaml"; then
    pass "nothing is rendered"
  else
    fail "enabled=false still renders objects"
  fi
else
  fail "render failed: $(cat "$work/disabled.err")"
fi

# --- 4. the default image follows appVersion ----------------------------------
echo "==> default image"
want_image="$(yq '.image.repository' "$chart/values.yaml"):$(yq '.appVersion' "$chart/Chart.yaml")"
if render >"$work/default.yaml" 2>"$work/default.err"; then
  got_image="$(grep -E '^ +image: ' "$work/default.yaml" | head -n 1 | sed -E 's/^ +image: "?([^"]*)"?$/\1/')"
  if [ "$got_image" = "$want_image" ]; then
    pass "the default image is $want_image"
  else
    fail "the default image is '$got_image', want $want_image"
  fi
else
  fail "render failed: $(cat "$work/default.err")"
fi

# --- 5. the legacy operator: block fails -----------------------------------------
echo "==> legacy operator: block"
if render --set operator.image.tag=x >/dev/null 2>"$work/legacy.err"; then
  fail "the render succeeded with operator.image.tag set"
elif grep -q "moved from operator" "$work/legacy.err" && grep -q "2.0.0" "$work/legacy.err"; then
  pass "the render fails with the migration message"
else
  fail "the render failed, but not with the migration message: $(cat "$work/legacy.err")"
fi

# --- 6. instanceLabelInSelector -------------------------------------------------
# Selectors are immutable on a Deployment, so a release adopted from a chart
# whose selector has no instance label needs the same selector here.
echo "==> instanceLabelInSelector"
inst=app.kubernetes.io/instance
# selectors prints one JSON object per selector in the render: the Deployment's
# matchLabels, the Service's selector, and the PDB, NetworkPolicy and
# ServiceMonitor ones.
selectors='select(.kind == "Deployment") | .spec.selector.matchLabels,
  select(.kind == "Service") | .spec.selector,
  select(.kind == "PodDisruptionBudget" or .kind == "ServiceMonitor") | .spec.selector.matchLabels,
  select(.kind == "NetworkPolicy") | .spec.podSelector.matchLabels'
for mode in true false; do
  if ! render -f "$work/flat.yaml" --set "instanceLabelInSelector=$mode" >"$work/sel-$mode.yaml" 2>"$work/sel-$mode.err"; then
    fail "instanceLabelInSelector=$mode: render failed: $(cat "$work/sel-$mode.err")"
    continue
  fi
  n="$(yq -o=json -I=0 "$selectors" "$work/sel-$mode.yaml" | wc -l)"
  if [ "$n" -ne 5 ]; then
    fail "instanceLabelInSelector=$mode: found $n selectors, want 5 (Deployment, Service, PDB, NetworkPolicy, ServiceMonitor)"
    continue
  fi
  pod="$(yq -o=json -I=0 'select(.kind == "Deployment") | .spec.template.metadata.labels' "$work/sel-$mode.yaml")"
  while IFS= read -r sel; do
    has="$(printf '%s' "$sel" | yq -p=json ".\"$inst\" != null")"
    if [ "$mode" = false ] && [ "$has" = true ]; then
      fail "instanceLabelInSelector=false: selector $sel still has $inst"
    elif [ "$mode" = true ] && [ "$has" = false ]; then
      fail "instanceLabelInSelector=true: selector $sel lacks $inst"
    fi
    if [ "$(printf '%s' "$sel" | yq -p=json -o=json -I=0 'to_entries | map(select(.value != null)) | length')" -lt 2 ]; then
      fail "instanceLabelInSelector=$mode: selector $sel is too small to select anything"
    fi
    # selector is a subset of the pod labels
    if ! yq -n -e "($sel) as \$s | ($pod) as \$p | \$s | to_entries | all_c(\$p[.key] == .value)" >/dev/null 2>&1; then
      fail "instanceLabelInSelector=$mode: selector $sel is not a subset of pod labels $pod"
    fi
  done < <(yq -o=json -I=0 "$selectors" "$work/sel-$mode.yaml")
  if [ "$(printf '%s' "$pod" | yq -p=json ".\"$inst\" != null")" != true ]; then
    fail "instanceLabelInSelector=$mode: pod labels lost $inst"
  fi
  if [ "$(yq 'select(.kind == "Deployment") | .metadata.labels."'$inst'" != null' "$work/sel-$mode.yaml")" != true ]; then
    fail "instanceLabelInSelector=$mode: Deployment metadata labels lost $inst"
  fi
done
if [ "$failed" = 0 ]; then
  pass "instanceLabelInSelector toggles instance in all five selectors only"
fi

exit "$failed"
