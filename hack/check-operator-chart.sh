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
#   6. serviceAccount.create=false without serviceAccount.name fails naming
#      serviceAccount.name, instead of binding RBAC to the default account
#   7. the identity/edge producers (args, SYNAPSE_API_KEY, RBAC) are rendered
#      as documented and only when switched on; then, if the synapse-stack
#      renders (its dependencies built), the same settings in the stack's
#      operator: block give the same producer args, env and RBAC rules
#   8. instanceLabelInSelector: each of the five selectors (Deployment,
#      Service, PDB, NetworkPolicy, ServiceMonitor) equals exactly
#      {name, component} when false, and {name, component, instance=release}
#      when true or when left unset (the default). Pod and Deployment labels
#      keep instance in every mode, and each selector is a subset of the pod
#      labels
#   9. ingress.*: the ingress-mode companion Deployment (<fullname>-ingress).
#      Off by default; name, selectors (both modes), args, ServiceAccount, image
#      fallback, security context and /tmp mount, enabled=false, Gateway RBAC
#      gating, the two refusals, and a comparison with the synapse-stack's
#      operator.ingress (needs `helm dependency build charts/synapse-stack`;
#      skipped only when that is missing and CI is unset)
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

# --- 6. no ServiceAccount to use fails ----------------------------------------
echo "==> serviceAccount.create=false without a name"
if render --set serviceAccount.create=false >"$work/sa.out" 2>"$work/sa.err"; then
  fail "the render succeeded with serviceAccount.create=false and no serviceAccount.name (binds to: $(yq 'select(.kind == "ClusterRoleBinding") | .subjects[].name' "$work/sa.out" | sort -u | tr '\n' ' '))"
elif grep -q "serviceAccount.name" "$work/sa.err"; then
  pass "the render fails naming serviceAccount.name"
else
  fail "the render failed, but not naming serviceAccount.name: $(cat "$work/sa.err")"
fi
# sa_uses OUT NAME: the pod runs as NAME, both bindings name only NAME, and no
# ServiceAccount object is rendered.
sa_uses() {
  [ "$(yq 'select(.kind == "Deployment") | .spec.template.spec.serviceAccountName' "$1")" = "$2" ] &&
    [ "$(yq 'select(.kind == "ClusterRoleBinding") | .subjects[].name' "$1" | sort -u)" = "$2" ] &&
    [ "$(yq 'select(.kind == "RoleBinding") | .subjects[].name' "$1" | sort -u)" = "$2" ] &&
    [ "$(yq 'select(.kind == "ServiceAccount") | .kind' "$1" | wc -l)" = 0 ]
}
for sa in pre-made default; do
  if render --set serviceAccount.create=false --set "serviceAccount.name=$sa" >"$work/sa2.out" 2>"$work/sa2.err" &&
    sa_uses "$work/sa2.out" "$sa"; then
    pass "serviceAccount.create=false with name=$sa runs and binds as $sa, creating none"
  else
    fail "serviceAccount.create=false with name=$sa did not run and bind as $sa: $(cat "$work/sa2.err")"
  fi
done
if render --set enabled=false --set serviceAccount.create=false >/dev/null 2>"$work/sa3.err"; then
  pass "a disabled operator is not validated for its ServiceAccount"
else
  fail "enabled=false fails on the ServiceAccount check: $(cat "$work/sa3.err")"
fi

# --- 7. producers -------------------------------------------------------------------
echo "==> producers"
ARGS='select(.kind == "Deployment") | .spec.template.spec.containers[0].args[]'
KEYENV='select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "SYNAPSE_API_KEY")'
# The rules a producer adds; printed as compact JSON, one per line, in template order.
PRULES='select(.kind == "ClusterRole") | .rules[] | [.apiGroups, .resources, .verbs] | select(.[1] | map(test("^(pods|namespaces|networkpolicies)$")) | any)'

# expect NAME GOT WANT: passes when the two values are equal.
expect() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass "$name"
  else
    fail "$name: got '$got', want '$want'"
  fi
}
# producer_case NAME HELM_ARGS... : renders with the helm args and leaves the
# output in $work/NAME.yaml; prints nothing, fails (after reporting) when the
# render fails.
producer_case() {
  local name="$1"
  shift
  if ! render "$@" >"$work/$name.yaml" 2>"$work/$name.err"; then
    fail "$name: render failed: $(cat "$work/$name.err")"
    return 1
  fi
}
pargs() { yq -N "$ARGS | select(test(\"producer|download-api|cluster-id\"))" "$1" | paste -sd' ' -; }
penv() { yq -N -o=json -I=0 "$KEYENV" "$1"; }
prules() { yq -N -o=json -I=0 "$PRULES" "$1" | paste -sd' ' -; }

POD='[[""],["pods"],["get","list","watch"]]'
NS='[[""],["namespaces"],["get","list","watch"]]'
NP='[["networking.k8s.io"],["networkpolicies"],["get","list","watch"]]'
KEY='{"name":"SYNAPSE_API_KEY","valueFrom":{"secretKeyRef":{"name":"synapse-operator-api-key","key":"SYNAPSE_API_KEY"}}}'
URL='--download-api-url=https://api.gen0sec.com/v1'

if producer_case producers-off; then
  expect "producers off: no producer args" "$(pargs "$work/producers-off.yaml")" ""
  expect "producers off: no SYNAPSE_API_KEY" "$(penv "$work/producers-off.yaml")" ""
  expect "producers off: no producer rules" "$(prules "$work/producers-off.yaml")" ""
fi
if producer_case identity --set identityProducer.enabled=true; then
  expect "identityProducer: args" "$(pargs "$work/identity.yaml")" "$URL --identity-producer"
  expect "identityProducer: key from the secret" "$(penv "$work/identity.yaml")" "$KEY"
  expect "identityProducer: pods rule only" "$(prules "$work/identity.yaml")" "$POD"
fi
if producer_case edge --set edgeProducer.enabled=true; then
  expect "edgeProducer: args" "$(pargs "$work/edge.yaml")" "$URL --edge-producer"
  expect "edgeProducer: key from the secret" "$(penv "$work/edge.yaml")" "$KEY"
  expect "edgeProducer: pods, namespaces, networkpolicies" "$(prules "$work/edge.yaml")" "$POD $NS $NP"
fi
if producer_case both --set identityProducer.enabled=true --set edgeProducer.enabled=true \
  --set identityProducer.interval=60s --set edgeProducer.interval=2m \
  --set downloadAPIURL=https://dl.example.test/v1 --set clusterId=c1 \
  --set apiKeySecret.name=my-key --set apiKeySecret.key=K; then
  expect "both producers: args, in order" "$(pargs "$work/both.yaml")" \
    "--download-api-url=https://dl.example.test/v1 --identity-producer --identity-producer-interval=60s --edge-producer --edge-producer-interval=2m --cluster-id=c1"
  expect "both producers: apiKeySecret name and key" "$(penv "$work/both.yaml")" \
    '{"name":"SYNAPSE_API_KEY","valueFrom":{"secretKeyRef":{"name":"my-key","key":"K"}}}'
  expect "both producers: each rule once" "$(prules "$work/both.yaml")" "$POD $NS $NP"
fi
if producer_case cluster-id --set clusterId=c1; then
  expect "clusterId alone: only --cluster-id, no key, no rules" \
    "$(pargs "$work/cluster-id.yaml") |$(penv "$work/cluster-id.yaml")|$(prules "$work/cluster-id.yaml")" "--cluster-id=c1 ||"
fi
if producer_case rbac-off --set edgeProducer.enabled=true --set rbac.create=false; then
  expect "rbac.create=false: no producer rules" "$(prules "$work/rbac-off.yaml")" ""
fi
# Position: the producer and cluster args come before extraArgs, which stay last
# so a user can still override them. The tail is unfiltered on purpose.
if producer_case args-order --set identityProducer.enabled=true --set clusterId=c1 \
  --set 'extraArgs[0]=--zap-log-level=debug'; then
  expect "extraArgs stay last, after the producer args" \
    "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[]' "$work/args-order.yaml" | tail -n 4 | paste -sd' ' -)" \
    "$URL --identity-producer --cluster-id=c1 --zap-log-level=debug"
fi
# The key must come before extra env, after the operator's own POD_* variables.
if producer_case env-order --set identityProducer.enabled=true --set 'env[0].name=FOO' --set 'env[0].value=bar'; then
  expect "env order" "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[].name' "$work/env-order.yaml" | paste -sd' ' -)" \
    "POD_NAMESPACE POD_NAME SYNAPSE_API_KEY FOO"
fi

# The stack renders the same producer settings under operator:. Skipped when its
# dependencies are not built.
echo "==> producers: same as the synapse-stack"
stack="$root/charts/synapse-stack"
cat >"$work/producers-flat.yaml" <<'YAML'
identityProducer: {enabled: true, interval: 90s}
edgeProducer: {enabled: true, interval: 3m}
downloadAPIURL: https://dl.example.test/v1
apiKeySecret: {name: my-key, key: K}
YAML
yq '{"operator": .}' "$work/producers-flat.yaml" >"$work/producers-stack.yaml"
# Only the stack's own operator objects.
SOBJ='select((.kind == "Deployment" or .kind == "ClusterRole") and .metadata.name == "synapse-operator")'
if ! helm template stk "$stack" -f "$work/producers-stack.yaml" >"$work/stack.yaml" 2>"$work/stack.err"; then
  # Only an unbuilt dependency skips, and never in CI: a stack that cannot
  # render must not make the comparison quietly disappear.
  if [ -z "${CI:-}" ] && grep -q 'missing in charts/ directory' "$work/stack.err"; then
    echo "skip: the stack's dependencies are not built: $(head -n 1 "$work/stack.err")"
  else
    fail "the stack does not render, so the producers cannot be compared with it: $(head -n 3 "$work/stack.err")"
  fi
else
  helm template stk "$stack" >"$work/stack-off.yaml"
  render -f "$work/producers-flat.yaml" >"$work/op.yaml"
  for q in "args:$ARGS | select(test(\"producer|download-api\"))" "env:$KEYENV" "rules:$PRULES"; do
    what="${q%%:*}"
    q="${q#*:}"
    s="$(yq -N -o=json -I=0 "$SOBJ | $q" "$work/stack.yaml" 2>&1)"
    o="$(yq -N -o=json -I=0 "$q" "$work/op.yaml" 2>&1)"
    if [ -z "$s" ]; then
      fail "stack $what: the stack rendered no producer $what, the comparison is vacuous"
    elif [ "$s" = "$o" ]; then
      pass "producer $what match the stack"
    else
      fail "producer $what differ from the stack: stack '$s' vs chart '$o'"
    fi
  done
  if [ -n "$(yq -N "$SOBJ | $ARGS | select(test(\"producer|download-api\"))" "$work/stack-off.yaml")" ]; then
    fail "stack default renders producer args; the comparison baseline moved"
  fi
fi

# --- 8. instanceLabelInSelector -------------------------------------------------
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

# --- 9. the ingress-mode Deployment ---------------------------------------------
# The synapse-stack's operator.ingress.* as flat ingress.*: a second Deployment
# running --ingress-mode next to the config-hash operator, on the same
# ServiceAccount. Off by default.
echo "==> ingress-mode Deployment"
ing_dep='select(.kind == "Deployment" and .metadata.name == "synapse-operator-ingress")'
ing_set=(--set fullnameOverride=synapse-operator --set image.tag=0.1.11
  --set ingress.enabled=true --set ingress.upstreamsOutConfigMap=ns/up)

# 9a. off by default: one Deployment and nothing of the ingress-mode companion
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

# 9b. on: name, selector, labels, SA, args
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

# image falls back to appVersion; the SA follows the shared helper
if render --set ingress.enabled=true --set ingress.upstreamsOutConfigMap=a/b >"$work/ing-def.yaml" 2>"$work/ing-def.err"; then
  d='select(.kind == "Deployment" and .metadata.name == "check-synapse-operator-ingress")'
  want="$(yq '.image.repository' "$chart/values.yaml"):$(yq '.appVersion' "$chart/Chart.yaml")"
  got="$(yq "$d | .spec.template.spec.containers[0].image" "$work/ing-def.yaml")"
  if [ "$got" = "$want" ]; then pass "ingress image defaults to $want"; else fail "ingress image is '$got', want $want"; fi
  got="$(yq "$d | .spec.template.spec.serviceAccountName" "$work/ing-def.yaml")"
  if [ "$got" = check-synapse-operator ]; then
    pass "ingress ServiceAccount follows the helper ($got)"
  else
    fail "ingress ServiceAccount is '$got', want check-synapse-operator"
  fi
else
  fail "ingress with defaults: render failed: $(cat "$work/ing-def.err")"
fi
# the same hardening as the operator: read-only root filesystem plus /tmp
c="$ing_dep | .spec.template.spec"
if [ "$(yq "$c.containers[0].securityContext.readOnlyRootFilesystem" "$work/ing-true.yaml")" = true ] &&
  [ "$(yq "$c.containers[0].volumeMounts[0].mountPath" "$work/ing-true.yaml")" = /tmp ] &&
  [ "$(yq "$c.volumes[0] | has(\"emptyDir\")" "$work/ing-true.yaml")" = true ] &&
  [ "$(yq "$c.securityContext.runAsNonRoot" "$work/ing-true.yaml")" = true ]; then
  pass "ingress container is read-only with a /tmp emptyDir, pod runs non-root"
else
  fail "ingress container lacks readOnlyRootFilesystem, the /tmp emptyDir or the pod securityContext"
fi
# gates: gatewayAPI alone, and enabled=false, render nothing of it
if render --set ingress.gatewayAPI=true >"$work/ing-gwonly.yaml" 2>&1 && ! grep -q 'gateway.networking.k8s.io' "$work/ing-gwonly.yaml"; then
  pass "ingress.gatewayAPI without ingress.enabled renders no Gateway rule"
else
  fail "ingress.gatewayAPI without ingress.enabled renders (or fails to render) Gateway rules"
fi
if render --set enabled=false --set ingress.enabled=true --set ingress.upstreamsOutConfigMap=a/b >"$work/ing-dis.yaml" 2>&1 && ! grep -q '^kind:' "$work/ing-dis.yaml"; then
  pass "enabled=false renders no ingress Deployment either"
else
  fail "enabled=false with ingress.enabled still renders objects"
fi

# 9c. the two refusals
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

# 9d. the same objects as the synapse-stack's operator.ingress. Needs the stack's
# dependencies built (helm dependency build charts/synapse-stack); skipped only
# when they are missing and CI is unset.
cat >"$work/stack-ing.yaml" <<'YAML'
operator:
  nodeSelector: {disk: ssd}
  tolerations:
    - key: k
      operator: Exists
  imagePullSecrets:
    - name: pull
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
nodeSelector: {disk: ssd}
tolerations:
  - key: k
    operator: Exists
imagePullSecrets:
  - name: pull
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
    '.spec.template.spec.containers[0] | del(.securityContext, .volumeMounts)' \
    '.spec.template.spec | del(.securityContext, .volumes, .containers)'; do
    a="$(yq -o=json -I=0 "$ing_dep | $q | sort_keys(..)" "$s")"
    b="$(yq -o=json -I=0 "$ing_dep | $q | sort_keys(..)" "$h")"
    if [ -n "$a" ] && [ "$a" != null ] && [ "$a" = "$b" ]; then
      pass "stack and chart agree on ingress $q"
    else
      fail "ingress $q differs: stack $a, chart $b"
    fi
  done
  for k in nodeSelector tolerations imagePullSecrets; do
    if [ "$(yq "$ing_dep | .spec.template.spec | has(\"$k\")" "$h")" != true ]; then
      fail "ingress pod spec has no $k: the fixture does not exercise it"
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
