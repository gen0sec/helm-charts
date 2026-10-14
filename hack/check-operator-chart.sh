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
#   6. instanceLabelInSelector: each of the five selectors (Deployment,
#      Service, PDB, NetworkPolicy, ServiceMonitor) equals exactly
#      {name, component} when false, and {name, component, instance=release}
#      when true or when left unset (the default). Pod and Deployment labels
#      keep instance in every mode, and each selector is a subset of the pod
#      labels
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
# One JSON object per selector in the render: the Deployment's matchLabels, the
# Service's selector, and the PDB, ServiceMonitor and NetworkPolicy ones.
selectors='select(.kind == "Deployment") | .spec.selector.matchLabels,
  select(.kind == "Service") | .spec.selector,
  select(.kind == "PodDisruptionBudget" or .kind == "ServiceMonitor") | .spec.selector.matchLabels,
  select(.kind == "NetworkPolicy") | .spec.podSelector.matchLabels'
sel_base='{"app.kubernetes.io/component":"controller","app.kubernetes.io/name":"synapse-operator"}'
sel_with="{\"app.kubernetes.io/component\":\"controller\",\"$inst\":\"$release\",\"app.kubernetes.io/name\":\"synapse-operator\"}"
# default sets nothing: it must behave as true.
for mode in true false default; do
  set_args=()
  [ "$mode" = default ] || set_args=(--set "instanceLabelInSelector=$mode")
  want="$sel_with"
  [ "$mode" = false ] && want="$sel_base"
  if ! render -f "$work/flat.yaml" "${set_args[@]}" >"$work/sel-$mode.yaml" 2>"$work/sel-$mode.err"; then
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
    got="$(printf '%s' "$sel" | yq -p=json -o=json -I=0 'sort_keys(.)')"
    if [ "$got" != "$want" ]; then
      fail "instanceLabelInSelector=$mode: selector is $got, want $want"
    fi
    # the selector must also select the pod: a subset of the pod labels
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
  pass "instanceLabelInSelector: selectors are {name, component} when false and add instance when true or unset"
fi

# --- 7. the ingress-mode Deployment ---------------------------------------------
# The synapse-stack's operator.ingress.* as flat ingress.*: a second Deployment
# running --ingress-mode next to the config-hash operator, on the same
# ServiceAccount. Off by default.
echo "==> ingress-mode Deployment"
ing_dep='select(.kind == "Deployment" and .metadata.name == "synapse-operator-ingress")'
ing_set=(--set fullnameOverride=synapse-operator --set image.tag=0.1.11
  --set ingress.enabled=true --set ingress.upstreamsOutConfigMap=ns/up)

# 7a. off by default: one Deployment and nothing of the ingress-mode companion
if render >"$work/ing-off.yaml" 2>"$work/ing-off.err"; then
  if [ "$(yq 'select(.kind == "Deployment") | .metadata.name' "$work/ing-off.yaml" | wc -l)" = 1 ] &&
    ! grep -q 'ingress-controller' "$work/ing-off.yaml"; then
    pass "ingress.enabled is off by default and renders no second Deployment"
  else
    fail "ingress-mode objects are rendered by default"
  fi
else
  fail "default render failed: $(cat "$work/ing-off.err")"
fi

# 7b. on: name, selector, labels, SA, args
for mode in true false; do
  if ! render "${ing_set[@]}" --set "instanceLabelInSelector=$mode" >"$work/ing-$mode.yaml" 2>"$work/ing-$mode.err"; then
    fail "ingress on, instanceLabelInSelector=$mode: render failed: $(cat "$work/ing-$mode.err")"
    continue
  fi
  f="$work/ing-$mode.yaml"
  if [ "$(yq "$ing_dep | .metadata.name" "$f")" != synapse-operator-ingress ]; then
    fail "ingress on: no Deployment named synapse-operator-ingress"
    continue
  fi
  want='{"app.kubernetes.io/component":"ingress-controller","app.kubernetes.io/name":"synapse-operator-ingress"}'
  [ "$mode" = true ] && want="{\"app.kubernetes.io/component\":\"ingress-controller\",\"$inst\":\"$release\",\"app.kubernetes.io/name\":\"synapse-operator-ingress\"}"
  got="$(yq -o=json -I=0 "$ing_dep | .spec.selector.matchLabels | sort_keys(.)" "$f")"
  if [ "$got" = "$want" ]; then
    pass "ingress selector (instanceLabelInSelector=$mode) is $got"
  else
    fail "ingress selector (instanceLabelInSelector=$mode) is $got, want $want"
  fi
  # the selector selects its own pods: a subset of the pod labels
  pod="$(yq -o=json -I=0 "$ing_dep | .spec.template.metadata.labels" "$f")"
  if ! yq -n -e "($want) as \$s | ($pod) as \$p | \$s | to_entries | all_c(\$p[.key] == .value)" >/dev/null 2>&1; then
    fail "ingress selector ($mode) is not a subset of pod labels $pod"
  fi
  if [ "$(printf '%s' "$pod" | yq -p=json ".\"$inst\"")" != "$release" ]; then
    fail "ingress pod labels lost $inst ($mode)"
  fi
  if [ "$(yq "$ing_dep | .spec.template.spec.serviceAccountName" "$f")" != synapse-operator ]; then
    fail "ingress Deployment ($mode) does not use the operator's ServiceAccount"
  fi
done
wantargs='["--ingress-mode","--ingress-class=synapse","--upstreams-out-configmap=ns/up","--cluster-domain=cluster.local","--resolve-backend-endpoints","--metrics-bind-address=:8080","--health-probe-bind-address=:8081"]'
got="$(yq -o=json -I=0 "$ing_dep | .spec.template.spec.containers[0].args" "$work/ing-true.yaml")"
if [ "$got" = "$wantargs" ]; then pass "ingress args at their defaults"; else fail "ingress args are $got, want $wantargs"; fi
if render "${ing_set[@]}" --set ingress.gatewayAPI=true --set ingress.resolveBackendClusterIPs=true \
  --set ingress.ingressClass=edge --set ingress.clusterDomain=c.local \
  --set 'ingress.extraArgs={--zap-log-level=debug}' --set ingress.replicaCount=2 >"$work/ing-all.yaml" 2>"$work/ing-all.err"; then
  wantargs='["--ingress-mode","--ingress-class=edge","--upstreams-out-configmap=ns/up","--cluster-domain=c.local","--resolve-backend-cluster-ips","--resolve-backend-endpoints","--gateway-api","--metrics-bind-address=:8080","--health-probe-bind-address=:8081","--zap-log-level=debug"]'
  got="$(yq -o=json -I=0 "$ing_dep | .spec.template.spec.containers[0].args" "$work/ing-all.yaml")"
  if [ "$got" = "$wantargs" ]; then pass "ingress args with every option set"; else fail "ingress args are $got, want $wantargs"; fi
  if [ "$(yq "$ing_dep | .spec.replicas" "$work/ing-all.yaml")" != 2 ]; then fail "ingress.replicaCount was not applied"; fi
  gw='select(.kind == "ClusterRole") | .rules[] | select(.apiGroups[0] == "gateway.networking.k8s.io") | .resources[]'
  if [ "$(yq "$gw" "$work/ing-all.yaml" | wc -l)" = 6 ]; then
    pass "ingress.gatewayAPI adds the Gateway API rules"
  else
    fail "ingress.gatewayAPI did not add the Gateway API rules"
  fi
else
  fail "ingress with every option: render failed: $(cat "$work/ing-all.err")"
fi
# without ingress.gatewayAPI (and without the main gatewayAPI) no Gateway rule
if grep -q 'gateway.networking.k8s.io' "$work/ing-true.yaml"; then
  fail "Gateway API RBAC is rendered although ingress.gatewayAPI is off"
else
  pass "no Gateway API RBAC without ingress.gatewayAPI"
fi

# 7c. the two refusals
if render --set ingress.enabled=true >/dev/null 2>"$work/ing-nocm.err"; then
  fail "ingress.enabled without ingress.upstreamsOutConfigMap rendered"
elif grep -q 'ingress.upstreamsOutConfigMap' "$work/ing-nocm.err"; then
  pass "ingress.enabled without ingress.upstreamsOutConfigMap fails, naming the key"
else
  fail "failed, but without naming ingress.upstreamsOutConfigMap: $(cat "$work/ing-nocm.err")"
fi
if render "${ing_set[@]}" --set ingressMode=true >/dev/null 2>"$work/ing-both.err"; then
  fail "ingress.enabled together with ingressMode rendered"
elif grep -q 'ingress.enabled' "$work/ing-both.err" && grep -q 'ingressMode' "$work/ing-both.err"; then
  pass "ingress.enabled with ingressMode fails, naming both keys"
else
  fail "failed, but without naming ingress.enabled and ingressMode: $(cat "$work/ing-both.err")"
fi

# 7d. the same objects as the synapse-stack's operator.ingress. Needs the stack's
# dependencies built (helm dependency build charts/synapse-stack); skipped only
# when they are missing and CI is unset.
cat >"$work/stack-ing.yaml" <<'YAML'
operator:
  ingress:
    enabled: true
    upstreamsOutConfigMap: ns/up
    ingressClass: edge
    clusterDomain: c.local
    resolveBackendClusterIPs: true
    gatewayAPI: true
    replicaCount: 2
    extraArgs: ["--zap-log-level=debug"]
    resources:
      requests: {cpu: 10m, memory: 64Mi}
      limits: {cpu: 300m, memory: 256Mi}
YAML
cat >"$work/flat-ing.yaml" <<'YAML'
fullnameOverride: synapse-operator
image:
  tag: "0.1.11"
instanceLabelInSelector: false
ingress:
  enabled: true
  upstreamsOutConfigMap: ns/up
  ingressClass: edge
  clusterDomain: c.local
  resolveBackendClusterIPs: true
  gatewayAPI: true
  replicaCount: 2
  extraArgs: ["--zap-log-level=debug"]
  resources:
    requests: {cpu: 10m, memory: 64Mi}
    limits: {cpu: 300m, memory: 256Mi}
YAML
echo "==> ingress-mode Deployment against the synapse-stack"
if ! helm template stack "$root/charts/synapse-stack" -f "$work/stack-ing.yaml" >"$work/stack-ing.out.yaml" 2>"$work/stack-ing.err"; then
  if grep -q 'missing in charts/ directory' "$work/stack-ing.err" && [ -z "${CI:-}" ]; then
    echo "skip: synapse-stack dependencies are not built (helm dependency build charts/synapse-stack)"
  else
    fail "synapse-stack render failed: $(cat "$work/stack-ing.err")"
  fi
elif ! render -f "$work/flat-ing.yaml" >"$work/flat-ing.out.yaml" 2>"$work/flat-ing.err"; then
  fail "flat ingress render failed: $(cat "$work/flat-ing.err")"
else
  s="$work/stack-ing.out.yaml"
  h="$work/flat-ing.out.yaml"
  if [ "$(yq "$ing_dep | .metadata.name" "$s")" != synapse-operator-ingress ]; then
    fail "stack render has no synapse-operator-ingress Deployment: the comparison is vacuous"
  fi
  for q in \
    '.metadata.name' \
    '.metadata.namespace' \
    '.spec.replicas' \
    '.spec.selector.matchLabels | sort_keys(.)' \
    '.spec.template.spec.serviceAccountName' \
    '.spec.template.spec.containers[0].image' \
    '.spec.template.spec.containers[0].args' \
    '.spec.template.spec.containers[0].resources'; do
    a="$(yq -o=json -I=0 "$ing_dep | $q" "$s")"
    b="$(yq -o=json -I=0 "$ing_dep | $q" "$h")"
    if [ -n "$a" ] && [ "$a" != null ] && [ "$a" = "$b" ]; then
      pass "stack and chart agree on ingress $q: $a"
    else
      fail "ingress $q differs: stack $a, chart $b"
    fi
  done
  # the ServiceAccount the Deployment names is rendered
  sa="$(yq "$ing_dep | .spec.template.spec.serviceAccountName" "$h")"
  if [ "$(yq "select(.kind == \"ServiceAccount\") | .metadata.name" "$h")" != "$sa" ]; then
    fail "the chart renders no ServiceAccount named $sa"
  fi
  # RBAC: every rule outside the core group is the stack's; core-group rules
  # of this chart may grant more verbs (it also serves the resolver paths) but
  # never fewer.
  nc='select(.kind == "ClusterRole") | .rules | map(select(.apiGroups[0] != "")) | sort_by(.apiGroups[0] + .resources[0])'
  a="$(yq -o=json -I=0 "$nc" "$s")"
  b="$(yq -o=json -I=0 "$nc" "$h")"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then
    pass "stack and chart agree on the non-core ClusterRole rules"
  else
    fail "non-core ClusterRole rules differ: stack $a, chart $b"
  fi
  for r in configmaps secrets services nodes events; do
    vq="select(.kind == \"ClusterRole\") | .rules | map(select(.resources[0] == \"$r\") | .verbs) | flatten | sort | unique"
    a="$(yq -o=json -I=0 "$vq" "$s")"
    b="$(yq -o=json -I=0 "$vq" "$h")"
    if [ "$a" != '[]' ] && [ "$(yq -n -o=json -I=0 "($a - $b) | length")" = 0 ]; then
      pass "chart grants at least the stack's verbs on $r"
    else
      fail "chart grants fewer verbs on $r than the stack: stack $a, chart $b"
    fi
  done
fi

exit "$failed"
