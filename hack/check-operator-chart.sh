#!/usr/bin/env bash
# Checks the synapse-operator chart's proxy-controller support. The repo has no
# unit-test harness (CI runs helm lint and helm template), so this renders the
# chart and asserts on the output with yq.
#
#   1. disabled (the default): renders what the chart at BASE rendered; runs
#      only when BASE is set, as a one-off proof for a change meant to leave
#      the defaults alone (CI does not set it, so default changes stay free)
#   2. enabled: the flag, the CRD (kept on uninstall) and a ClusterRole whose
#      rules are exactly the operator's own
#   3. crds.install=false: no CRD, the role is still rendered
#   4. enabled together with ingressMode: the render fails
#
# Needs helm, yq (mikefarah, v4) and git. Run from anywhere.
#
#   BASE   commit whose chart is the reference for check 1, e.g.
#          BASE=origin/main. Unset, check 1 is skipped.
set -euo pipefail

BASE="${BASE:-}"
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

# check_binding FILE FULLNAME SA@NAMESPACE asserts the proxy-controller binding
# ties FULLNAME-proxy-controller to that ServiceAccount, and that the
# Deployment runs as it.
check_binding() {
  local got sa
  got="$(doc "$1" ClusterRoleBinding "$2-proxy-controller" |
    yq '.roleRef.kind + "/" + .roleRef.name + " -> " + .subjects[0].kind + "/" + .subjects[0].name + "@" + .subjects[0].namespace')"
  if [ "$got" = "ClusterRole/$2-proxy-controller -> ServiceAccount/$3" ]; then
    pass "the binding ties the role to ServiceAccount $3"
  else
    fail "ClusterRoleBinding is '$got', want ServiceAccount/$3"
  fi
  sa="$(yq 'select(.kind == "Deployment") | .spec.template.spec.serviceAccountName + "@" + .metadata.namespace' "$1")"
  if [ "$sa" != "$3" ]; then
    fail "the Deployment runs as '$sa', not $3"
  fi
}

# --- 1. disabled renders what the base rendered ------------------------------
echo "==> disabled"
if [ -z "$BASE" ]; then
  echo "skip: BASE is not set"
else
  mkdir -p "$work/base"
  git -C "$root" archive "$BASE" charts/synapse-operator | tar -x -C "$work/base"
  base_tag="$(yq '.appVersion' "$work/base/charts/synapse-operator/Chart.yaml")"
  helm template "$release" "$work/base/charts/synapse-operator" >"$work/base.yaml"
  # The image tag is pinned to the base's, so this does not show that the
  # default image follows appVersion.
  render --set "operator.image.tag=$base_tag" >"$work/disabled.yaml"
  if diff -u <(normalise "$work/base.yaml") <(normalise "$work/disabled.yaml") >"$work/disabled.diff"; then
    pass "defaults render what $BASE rendered"
  else
    fail "defaults differ from $BASE:"
    head -n 40 "$work/disabled.diff" >&2
  fi
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
    check_binding "$work/enabled.yaml" "$fullname" "$fullname@synapse-os"
  else
    fail "ClusterRole $fullname-proxy-controller is not rendered"
  fi
else
  fail "enabled render failed: $(cat "$work/enabled.err")"
fi

# The binding must name the ServiceAccount the Deployment runs as, in the
# operator's namespace, however the names are overridden.
echo "==> binding under overridden names"
if render --set operator.proxyController.enabled=true --set operator.fullnameOverride=foo \
  --set operator.serviceAccount.name=bar --set global.namespaces.operator=ns1 \
  >"$work/names.yaml" 2>"$work/names.err"; then
  check_binding "$work/names.yaml" foo "bar@ns1"
else
  fail "render failed: $(cat "$work/names.err")"
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
