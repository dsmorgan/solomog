# Product / stack recipes for scripts/explain.sh. Sourced, not executed.
# Chart coordinates mirror helmfiles/environments/enterprise.yaml and
# community.yaml.gotmpl — a static table, not a helmfile parse.

explain_gateway_api() {
  [ "${EXPLAIN_GWAPI_DONE}" = 1 ] && return 0
  EXPLAIN_GWAPI_DONE=1
  local ver="${GATEWAY_API_VERSION:-1.5.1}"
  echo "# Gateway API CRDs (applied before the product charts)"
  echo "kubectl apply --server-side -f \\"
  echo "  https://github.com/kubernetes-sigs/gateway-api/releases/download/v${ver}/standard-install.yaml"
  echo
}

explain_helm_oci() {
  local release="$1" chart_url="$2" version="$3" ns="$4"
  shift 4
  echo "helm install ${release} \\"
  echo "  ${chart_url} \\"
  echo "  --version ${version} \\"
  echo "  --namespace ${ns} --create-namespace \\"
  if [ $# -gt 0 ]; then
    local i=0
    for a in "$@"; do
      i=$((i + 1))
      if [ "$i" -eq $# ]; then
        echo "  ${a}"
      else
        echo "  ${a} \\"
      fi
    done
  else
    echo "  --wait"
  fi
  echo
}

explain_helm_repo() {
  local repo_name="$1" repo_url="$2" release="$3" chart="$4" version="$5" ns="$6"
  shift 6
  echo "helm repo add ${repo_name} ${repo_url}"
  echo "helm repo update ${repo_name}"
  echo "helm install ${release} ${chart} \\"
  echo "  --version ${version} \\"
  echo "  --namespace ${ns} --create-namespace \\"
  if [ $# -gt 0 ]; then
    local i=0
    for a in "$@"; do
      i=$((i + 1))
      if [ "$i" -eq $# ]; then
        echo "  ${a}"
      else
        echo "  ${a} \\"
      fi
    done
  else
    echo "  --wait"
  fi
  echo
}

explain_product_istio() {
  local mode="${ISTIO_MODE:-ambient}"
  local ver="${ISTIO_VERSION:-1.30.1}"
  local dp="Ambient"
  [ "$mode" = "sidecar" ] && dp="Sidecar"
  explain_gateway_api
  if [ "$EDITION" = "community" ]; then
    echo "# Docs: https://istio.io/latest/docs/setup/install/helm/"
    echo "# Dataplane: ${mode}"
    explain_helm_repo istio https://istio-release.storage.googleapis.com/charts \
      istio-base istio/base "$ver" istio-system --wait
    explain_helm_repo istio https://istio-release.storage.googleapis.com/charts \
      istiod istio/istiod "$ver" istio-system --wait
    if [ "$mode" = "ambient" ]; then
      explain_helm_repo istio https://istio-release.storage.googleapis.com/charts \
        istio-cni istio/cni "$ver" kube-system \
        --set profile=ambient --wait
      explain_helm_repo istio https://istio-release.storage.googleapis.com/charts \
        ztunnel istio/ztunnel "$ver" istio-system --wait
    fi
  else
    echo "# Docs: https://docs.solo.io/istio/1.30.x/quickstart/multi/"
    echo "# Enterprise Istio is the Gloo Operator plus a ServiceMeshController, not upstream istiod."
    echo "# Create a cacerts secret in istio-system (shared root CA) before the mesh comes up."
    explain_helm_oci gloo-operator \
      oci://us-docker.pkg.dev/solo-public/gloo-operator-helm/gloo-operator \
      "${GLOO_OPERATOR_VERSION:-0.5.2}" gloo-mesh \
      '--set manager.env.SOLO_ISTIO_LICENSE_KEY="$SOLO_ISTIO_LICENSE_KEY"' \
      --wait
    echo "# If the operator hangs on Gateway API safe-upgrades admission, delete those"
    echo "# ValidatingAdmissionPolicy objects (Gateway API 1.5+ vs older Solo CRDs)."
    cat <<EOF
kubectl apply -f - <<'SMC'
apiVersion: operator.gloo.solo.io/v1
kind: ServiceMeshController
metadata:
  name: managed-istio
  namespace: gloo-mesh
spec:
  cluster: ${CLUSTER}
  network: ${CLUSTER}
  dataplaneMode: ${dp}
  installNamespace: istio-system
  version: "${ver}"
SMC
EOF
    echo
  fi
}

explain_product_agentgateway() {
  explain_gateway_api
  if [ "$EDITION" = "community" ]; then
    echo "# Docs: https://agentgateway.dev/docs/kubernetes/latest/install/helm/"
    explain_helm_oci agentgateway-crds \
      oci://cr.agentgateway.dev/charts/agentgateway-crds \
      "${AGENTGATEWAY_COMMUNITY_VERSION:-v1.4.1}" agentgateway-system --wait
    explain_helm_oci agentgateway \
      oci://cr.agentgateway.dev/charts/agentgateway \
      "${AGENTGATEWAY_COMMUNITY_VERSION:-v1.4.1}" agentgateway-system --wait
  else
    echo "# Docs: https://docs.solo.io/agentgateway/2.3.x/install/helm/"
    explain_helm_oci agentgateway-crds \
      oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
      "${AGENTGATEWAY_VERSION}" agentgateway-system --wait
    explain_helm_oci agentgateway \
      oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
      "${AGENTGATEWAY_VERSION}" agentgateway-system \
      '--set licensing.licenseKey="$AGENTGATEWAY_LICENSE_KEY"' \
      --wait
    if [ "${TOKEN_EXCHANGE:-false}" = "true" ]; then
      echo "# TOKEN_EXCHANGE=true — enable the OBO STS on the controller, then restart the dataplane."
      echo "# helm upgrade --set tokenExchange.enabled=true \\"
      echo "#   --set tokenExchange.subjectValidator.validatorType=remote \\"
      echo "#   --set tokenExchange.subjectValidator.remoteConfig.url=<IdP JWKS URL>"
      echo "# kubectl rollout restart deployment -n agentgateway-system \\"
      echo "#   -l gateway.networking.k8s.io/gateway-name=agw"
      echo
    fi
  fi
}

explain_product_kgateway() {
  explain_gateway_api
  if [ "$EDITION" = "community" ]; then
    echo "# Docs: https://kgateway.dev/docs/envoy/latest/quickstart/"
    explain_helm_oci kgateway-crds \
      oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
      "${KGATEWAY_COMMUNITY_VERSION:-v2.3.1}" kgateway-system --wait
    explain_helm_oci kgateway \
      oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
      "${KGATEWAY_COMMUNITY_VERSION:-v2.3.1}" kgateway-system --wait
  else
    echo "# Docs: https://docs.solo.io/kgateway/2.2.x/install/helm/"
    [ "${KGATEWAY_ELS_CRD:-false}" = "true" ] && \
      echo "# KGATEWAY_ELS_CRD=true — also set installEnterpriseListenerSetCRD=true on the CRDs chart."
    [ "${KGATEWAY_SKIP_SHARED_CRDS:-false}" = "true" ] && \
      echo "# KGATEWAY_SKIP_SHARED_CRDS=true — skip ext-auth / rate-limit / WAF CRDs (agentgateway already owns them)."
    explain_helm_oci kgateway-crds \
      oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds \
      "${KGATEWAY_VERSION}" kgateway-system --wait
    explain_helm_oci kgateway \
      oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway \
      "${KGATEWAY_VERSION}" kgateway-system \
      '--set licensing.licenseKey="$KGATEWAY_LICENSE_KEY"' \
      --wait
  fi
}

explain_product_gloo_gateway() {
  explain_gateway_api
  echo "# Docs: https://docs.solo.io/gateway/1.21.x/quickstart/"
  echo "# Distinct product from kgateway — different chart, namespace, and license path."
  if [ "$EDITION" = "community" ]; then
    explain_helm_repo gloo https://storage.googleapis.com/solo-public-helm \
      gloo-gateway gloo/gloo "${GLOO_GATEWAY_VERSION}" gloo-system --wait
  else
    explain_helm_repo glooe https://storage.googleapis.com/gloo-ee-helm \
      gloo-gateway glooe/gloo-ee "${GLOO_GATEWAY_VERSION}" gloo-system \
      '--set license_key="$GLOO_GATEWAY_LICENSE_KEY"' \
      --wait
  fi
}

explain_product_gloo_mesh() {
  if [ "$EDITION" != "enterprise" ]; then
    echo "# gloo-mesh is enterprise-only; community edition installs nothing."
    echo
    return 0
  fi
  echo "# Docs: https://docs.solo.io/gloo-mesh-enterprise/latest/setup/installation/"
  echo "# Assumes Istio is already on the cluster."
  explain_helm_repo gloo-mesh-enterprise \
    https://storage.googleapis.com/gloo-mesh-enterprise/gloo-mesh-enterprise \
    gloo-mesh-enterprise gloo-mesh-enterprise/gloo-mesh-enterprise \
    "${GLOO_MESH_VERSION}" gloo-mesh \
    '--set licenseKey="$GLOO_MESH_LICENSE_KEY"' \
    --wait
  explain_helm_repo gloo-mesh-enterprise \
    https://storage.googleapis.com/gloo-mesh-enterprise/gloo-mesh-enterprise \
    gloo-mesh-agent gloo-mesh-enterprise/gloo-mesh-agent \
    "${GLOO_MESH_VERSION}" gloo-mesh --wait
}

explain_product_kagent() {
  if [ "$EDITION" = "community" ]; then
    echo "# Docs: https://kagent.dev/docs/kagent/introduction/installation"
    explain_helm_oci kagent-crds \
      oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
      "${KAGENT_COMMUNITY_VERSION}" kagent --wait
    explain_helm_oci kagent \
      oci://ghcr.io/kagent-dev/kagent/helm/kagent \
      "${KAGENT_COMMUNITY_VERSION}" kagent --wait
  else
    echo "# Docs: https://docs.solo.io/kagent/latest/quickstart/"
    echo "# Enterprise kagent is an evaluation path; confirm the Istio / agentgateway matrix."
    echo "# JWT signing key (generate once; preserve across upgrades):"
    echo "kubectl create namespace kagent --dry-run=client -o yaml | kubectl apply -f -"
    echo "openssl genrsa -out /tmp/kagent-jwt.pem 2048"
    echo "kubectl create secret generic jwt -n kagent --from-file=jwt=/tmp/kagent-jwt.pem \\"
    echo "  --dry-run=client -o yaml | kubectl apply -f -"
    echo "kubectl create secret generic kagent-enterprise-oidc-secret -n kagent \\"
    echo "  --from-literal=clientSecret=\"\$KAGENT_OIDC_CLIENT_SECRET\" \\"
    echo "  --dry-run=client -o yaml | kubectl apply -f -"
    echo
    explain_product_management kagent
    explain_helm_oci kagent-crds \
      oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds \
      "${KAGENT_VERSION}" kagent --wait
    explain_helm_oci kagent \
      oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise \
      "${KAGENT_VERSION}" kagent \
      '--set licensing.licenseKey="$KAGENT_LICENSE_KEY"' \
      --wait
  fi
}

explain_product_management() {
  local product="${1:-agentgateway}"
  echo "# Solo UI (management chart) — one release per cluster, in agentgateway-system."
  echo "# Docs: https://docs.solo.io/agentgateway/2.3.x/install/ui/setup/"
  echo "# Enable the product you want; reuseValues keeps a second product on the same release."
  explain_helm_oci management \
    oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
    "${MANAGEMENT_VERSION}" agentgateway-system \
    "--set products.${product}.enabled=true" \
    '--set licensing.licenseKey="$KAGENT_LICENSE_KEY"' \
    --wait
}

explain_emit_products() {
  local p
  for p in "$@"; do
    explain_section "$p"
    explain_cluster_note
    case "$p" in
      istio)        explain_product_istio ;;
      agentgateway) explain_product_agentgateway ;;
      kgateway)     explain_product_kgateway ;;
      gloo-gateway) explain_product_gloo_gateway ;;
      gloo-mesh)    explain_product_gloo_mesh ;;
      kagent)       explain_product_kagent ;;
      *)            echo "# Unknown product '${p}'." ;;
    esac
  done
}

# Canonical install order — same as scripts/stack.sh.
explain_canonical_order() {
  local wanted="$1" p out=""
  for p in istio gloo-mesh kgateway gloo-gateway agentgateway kagent; do
    case " $wanted " in
      *" $p "*) out="${out}${out:+ }${p}" ;;
    esac
  done
  printf '%s' "$out"
}

explain_task_products() {
  local task="$1" products="" want ui=0
  case "$task" in
    stack)
      products="${PRODUCTS:-}"
      if [ -z "$products" ]; then
        explain_section "stack"
        echo "# stack requires PRODUCTS=\"istio kgateway agentgateway …\""
        echo "explain: stack needs PRODUCTS=" >&2
        return 0
      fi
      ;;
    agentgateway) products="agentgateway" ;;
    kgateway) products="kgateway" ;;
    kagent) products="kagent" ;;
    gloo-gateway) products="gloo-gateway" ;;
    gloo-mesh) products="gloo-mesh" ;;
    agentgateway:ui)
      products="agentgateway"
      ui=1
      ;;
    kgateway:with-istio) products="istio kgateway" ;;
    istio:ambient:single|istio:sidecar:single) products="istio" ;;
    *) products="$task" ;;
  esac

  want="$(explain_canonical_order "$products")"
  if [ -z "$want" ]; then
    explain_section "$task"
    echo "# No recognized products in: ${products}"
    return 0
  fi
  case "$products" in
    "$want") ;;
    *)
      echo "# PRODUCTS listed as '${products}'; install order is ${want}."
      ;;
  esac
  # shellcheck disable=SC2086
  explain_emit_products $want
  if [ "$ui" -eq 1 ]; then
    if [ "$EDITION" != "enterprise" ]; then
      explain_section "agentgateway:ui"
      echo "# The Solo UI is enterprise-only; community edition has no management chart."
      echo
      return 0
    fi
    explain_section "agentgateway:ui"
    explain_product_management agentgateway
  fi
}
