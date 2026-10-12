#!/usr/bin/env bash
# Checks the synapse-operator chart's proxy-controller support. The repo has no
# unit-test harness (CI runs helm lint and helm template), so this renders the
# chart and asserts on the output with yq.
#
#   1. disabled (the default): renders what the base chart rendered
#   2. enabled: the flag, the CRD (kept on uninstall) and a ClusterRole whose
#      rules are exactly the operator's own
#   3. crds.install=false: no CRD, the role is still rendered
#   4. enabled together with ingressMode: the render fails
#
# Needs helm, yq (mikefarah, v4) and git. Run from anywhere.
#
#   BASE   commit whose chart is the reference for check 1. Needs the history
#          (fetch-depth: 0 in CI).
set -euo pipefail

BASE="${BASE:-0243668}"
root="$(cd "$(dirname "$0")/.." && pwd)"
chart="$root/charts/synapse-operator"
vendored="$root/hack/operator-proxy-controller-rbac.yaml"
release="check"
fullname="$release-synapse-operator"

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

# doc FILE KIND NAME prints one document of a rendered manifest.
doc() {
  yq "select(.kind == \"$2\" and .metadata.name == \"$3\")" "$1"
}

# Chart.yaml's version and appVersion legitimately differ from the base's, and
# land in the labels and the image tag; take those out before comparing.
normalise() {
  sed -E \
    -e 's#^( *helm\.sh/chart: ).*#\1CHART#' \
    -e 's#^( *app\.kubernetes\.io/version: ).*#\1VERSION#' "$1"
}

# --- 1. disabled renders what the base rendered ------------------------------
echo "==> disabled"
mkdir -p "$work/base"
git -C "$root" archive "$BASE" charts/synapse-operator | tar -x -C "$work/base"
base_tag="$(yq '.appVersion' "$work/base/charts/synapse-operator/Chart.yaml")"
helm template "$release" "$work/base/charts/synapse-operator" >"$work/base.yaml"
render --set "operator.image.tag=$base_tag" >"$work/disabled.yaml"
if diff -u <(normalise "$work/base.yaml") <(normalise "$work/disabled.yaml") >"$work/disabled.diff"; then
  pass "defaults render what $BASE rendered"
else
  fail "defaults differ from $BASE:"
  head -n 40 "$work/disabled.diff" >&2
fi

# --- 2. enabled --------------------------------------------------------------
echo "==> enabled"
if render --set operator.proxyController.enabled=true >"$work/enabled.yaml" 2>"$work/enabled.err"; then
  if yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[] | select(. == "--proxy-controller")' \
    "$work/enabled.yaml" >/dev/null 2>&1; then
    pass "--proxy-controller is in the args"
  else
    fail "--proxy-controller is not in the Deployment's args"
  fi

  crd="$(doc "$work/enabled.yaml" CustomResourceDefinition synapseproxies.synapse.gen0sec.com)"
  if [ -n "$crd" ]; then
    pass "the SynapseProxy CRD is rendered"
    keep="$(echo "$crd" | yq '.metadata.annotations["helm.sh/resource-policy"]')"
    if [ "$keep" = keep ]; then
      pass "the CRD is kept on uninstall"
    else
      fail "CRD resource-policy is '$keep', not keep"
    fi
  else
    fail "the SynapseProxy CRD is not rendered"
  fi

  role="$(doc "$work/enabled.yaml" ClusterRole "$fullname-proxy-controller")"
  if [ -n "$role" ]; then
    if diff -u <(yq -o=json -I2 'select(.kind == "ClusterRole") | .rules' "$vendored") <(echo "$role" | yq -o=json -I2 '.rules') >"$work/rules.diff"; then
      pass "ClusterRole rules equal the operator's"
    else
      fail "ClusterRole rules differ from $vendored:"
      head -n 40 "$work/rules.diff" >&2
    fi
    subject="$(doc "$work/enabled.yaml" ClusterRoleBinding "$fullname-proxy-controller" |
      yq '.roleRef.name + " " + .subjects[0].name')"
    if [ "$subject" = "$fullname-proxy-controller $fullname" ]; then
      pass "the binding ties the role to the chart's ServiceAccount"
    else
      fail "ClusterRoleBinding is '$subject'"
    fi
  else
    fail "ClusterRole $fullname-proxy-controller is not rendered"
  fi
else
  fail "enabled render failed: $(cat "$work/enabled.err")"
fi

# --- 3. crds.install=false ---------------------------------------------------
echo "==> crds.install=false"
if render --set operator.proxyController.enabled=true \
  --set operator.proxyController.crds.install=false >"$work/nocrd.yaml" 2>"$work/nocrd.err"; then
  if [ -z "$(yq 'select(.kind == "CustomResourceDefinition")' "$work/nocrd.yaml")" ]; then
    pass "no CRD"
  else
    fail "a CRD is rendered"
  fi
  if [ -n "$(doc "$work/nocrd.yaml" ClusterRole "$fullname-proxy-controller")" ]; then
    pass "the role is still rendered"
  else
    fail "the role is not rendered"
  fi
else
  fail "render failed: $(cat "$work/nocrd.err")"
fi

# --- 4. enabled with ingressMode --------------------------------------------
echo "==> proxyController with ingressMode"
if render --set operator.proxyController.enabled=true --set operator.ingressMode=true \
  >/dev/null 2>"$work/both.err"; then
  fail "the render succeeded; the operator refuses this pair"
elif grep -q "proxyController.*ingressMode\|ingressMode.*proxyController" "$work/both.err"; then
  pass "the render fails and names both values"
else
  fail "the render failed, but not with the expected message: $(cat "$work/both.err")"
fi

exit "$failed"
