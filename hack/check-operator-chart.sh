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
#   6. the identity/edge producers (args, SYNAPSE_API_KEY, RBAC) are rendered
#      as documented and only when switched on; then, if the synapse-stack
#      renders (its dependencies built), the same settings in the stack's
#      operator: block give the same producer args, env and RBAC rules
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

# --- 6. producers -------------------------------------------------------------------
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

exit "$failed"
