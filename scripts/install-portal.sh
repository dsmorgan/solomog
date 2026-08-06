#!/usr/bin/env bash
set -euo pipefail
#
# Installs Solo Portal (portal-crds + portal controller) into portal-system.
# Enterprise only — Portal is a Solo Enterprise for kgateway (SEFK) add-on today
# and needs its own license key (PORTAL_LICENSE_KEY / SOLO_LICENSE_KEY).
#
# Kept as a separate task from `kgateway` so Portal can later attach to other
# Solo products without reshaping the CLI. The preflight currently requires
# enterprise kgateway on the cluster (GatewayClass enterprise-kgateway).
#
# Usage: install-portal.sh
# Env:
#   CLUSTER    cluster name (required unless CONTEXT is set) — resolves context
#              via solomog_context (CONTEXT override → registry → vind default)
#   CONTEXT    kube context override (external / unregistered)
#   EDITION    enterprise (default). community is rejected (no community Portal).
#
# After sync, applies a starter PortalParameters (in-memory store) + Portal so a
# portal web server comes up. API products, frontend, and gateway routing are
# left to bundles / follow-up — see docs.solo.io/kgateway/.../portal/setup/.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

CLUSTER="${CLUSTER:-}"
solomog_require_cluster "$CLUSTER" portal
CONTEXT="$(solomog_context "$CLUSTER")"
# When CLUSTER was omitted but CONTEXT was set, derive a label for messages.
[[ -z "$CLUSTER" ]] && CLUSTER="${CONTEXT#vcluster-docker_}"
EDITION="${EDITION:-enterprise}"
NS=portal-system

if [[ "$EDITION" == "community" ]]; then
  echo "Error: Solo Portal is enterprise-only — no community edition." >&2
  echo "       Run 'solomog portal' with the default EDITION=enterprise." >&2
  exit 1
fi

# Preflight: Portal today requires Solo Enterprise for kgateway (SEFK).
# GatewayClass enterprise-kgateway is the same signal expose/monitoring use.
if ! kubectl --context "$CONTEXT" get gatewayclass enterprise-kgateway >/dev/null 2>&1; then
  echo "Error: enterprise kgateway (SEFK) not found on context '$CONTEXT'." >&2
  echo "       Portal currently requires Solo Enterprise for kgateway." >&2
  echo "       Install it first:  solomog kgateway CLUSTER=${CLUSTER}" >&2
  echo "       (or: solomog stack PRODUCTS=\"kgateway\" CLUSTER=${CLUSTER})" >&2
  exit 1
fi

if [[ -z "${PORTAL_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}" ]]; then
  echo "Warning: no PORTAL_LICENSE_KEY / SOLO_LICENSE_KEY set — helm sync will" >&2
  echo "         likely fail licensing. Set one in .env (see .env.example)." >&2
fi

echo "==> Installing Solo Portal (portal-crds + portal) into ${NS} on ${CONTEXT}"
SOLO_CONTEXT="$CONTEXT" helmfile sync \
  -f "$REPO_DIR/helmfiles/addons/portal.yaml.gotmpl" \
  -e "$EDITION" \
  --kube-context "$CONTEXT"

# Starter portal: in-memory store (ephemeral — fine for PoV/repro) + a public
# Portal with an empty API catalog. The controller spins up portal-<name>.
# Docs put these in `default`; keep them with the controller in portal-system.
echo "==> Applying starter PortalParameters + Portal in ${NS}"
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: portal.solo.io/v1alpha1
kind: PortalParameters
metadata:
  name: portal-params
  namespace: ${NS}
spec:
  store:
    memory: {}
---
apiVersion: portal.solo.io/v1alpha1
kind: Portal
metadata:
  name: my-portal
  namespace: ${NS}
spec:
  parametersRef:
    name: portal-params
  visibility:
    public: true
  apiProductRefs: []
EOF

echo ""
echo "==> Portal installed on ${CONTEXT}."
echo "    Controller:  kubectl --context ${CONTEXT} get pods -n ${NS}"
echo "    Web server:  kubectl --context ${CONTEXT} get deploy,svc portal-my-portal -n ${NS}"
echo "    Next: add ApiDoc/ApiProduct + frontend/routes — see"
echo "          https://docs.solo.io/kgateway/2.3.x/portal/setup/"
echo "          (or apply a bundle once you have one)."
