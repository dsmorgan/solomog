#!/usr/bin/env bash
# Sourced by every hook, test and helper: the pins and the names derived from them.
#
# Knobs are KEF_* so nothing here collides with solomog's own pins in versions.env
# (KAGENT_VERSION, SUBSTRATE_VERSION). Any name that appears in .env or versions.env silently
# wins over a default written here.

# ── pins ─────────────────────────────────────────────────────────────────────
# Enterprise kagent 1.0.0-alpha11 is built on community kagent 1.0.0-alpha14 and substrate
# 0.5.0-alpha4. Swap all four together when a new release lands.
KEF_KAGENT_VERSION="${KEF_KAGENT_VERSION:-1.0.0-alpha11}"
# The substrate-enterprise chart built from the substrate line alpha11 pins. Chart versions carry
# no `v`; image tags do.
KEF_SUBSTRATE_VERSION="${KEF_SUBSTRATE_VERSION:-0.5.0-alpha4-da3c2e5}"
KEF_SUBSTRATE_TAG="v${KEF_SUBSTRATE_VERSION}"
# kubectl-ate mints the CA and JWT pools. substrate-enterprise publishes no binary, so this is the
# community release of the same line.
KEF_ATE_CLI_VERSION="${KEF_ATE_CLI_VERSION:-0.5.0-alpha4}"
# The Go agent runtime (golang-adk) from the community line alpha11 is built on. The Harness CRD
# accepts a digest only.
KEF_ADK_IMAGE="${KEF_ADK_IMAGE:-ghcr.io/kagent-dev/kagent/golang-adk@sha256:eb1b0c7f635f31d464cff7cf212275f2642057a629ed20b39661e9f644f71f21}"

# ── where things come from ───────────────────────────────────────────────────
# All public, all pulled anonymously.
KEF_KAGENT_CHARTS="oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts"
KEF_SUBSTRATE_CHARTS="oci://us-docker.pkg.dev/solo-public/enterprise-substrate-helm"
KEF_SUBSTRATE_IMAGES="us-docker.pkg.dev/solo-public/substrate-enterprise"
# chart REPO NAME VERSION → a local copy from .solomog/cache/charts when one is there, otherwise
# REPO/NAME. Pass `--version` either way; helm ignores it for a .tgz.
KEF_CHART_CACHE="${KEF_CHART_CACHE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/.solomog/cache/charts}"
chart() {
  if [ -f "${KEF_CHART_CACHE}/$2-$3.tgz" ]; then echo "${KEF_CHART_CACHE}/$2-$3.tgz"; else echo "$1/$2"; fi
}

# ── names ────────────────────────────────────────────────────────────────────
KAGENT_NS="${KEF_KAGENT_NS:-kagent}"           # the one kagent install
KAGENT_RELEASE=kagent
SUBSTRATE_NS=ate-system                        # the substrate chart's fullname helper assumes it
PODCERT_NS=podcertificate-controller-system    # where the certificate controller and its pools live
MOCK_NS="${KEF_MOCK_NS:-mock-system}"          # mock model
MODEL_URL="http://mock-llm.${MOCK_NS}.svc:8080/v1"
POOL=kagent-default                            # the chart's WorkerPool name
SANDBOX_CLASS=gvisor                           # microvm needs /dev/kvm, which vind doesn't have
PG_NS="${KEF_PG_NS:-postgres}"
PG_HOST="postgres.${PG_NS}.svc"
# The telemetry collector the chart renders when telemetry.enabled is true. Agents and the
# controller send OTLP traces here, and it writes them to ClickHouse.
COLLECTOR_URL="http://solo-enterprise-telemetry-collector.${KAGENT_NS}.svc:4317"

# ── licenses ─────────────────────────────────────────────────────────────────
# Two different products. kagent-enterprise validates a `kagent` product claim. The substrate
# chart writes its key to the Secret the agentgateway inside atenet-router reads, so that one
# wants an agentgateway key.
KEF_KAGENT_LICENSE="${KAGENT_LICENSE_KEY:-${SOLO_LICENSE_KEY:-}}"
KEF_SUBSTRATE_LICENSE="${AGENTGATEWAY_LICENSE_KEY:-}"

# clear_failed_install CONTEXT RELEASE NAMESPACE → remove a release whose only history is a failed
# first install, which helm otherwise refuses to retry ("has no deployed releases"). A release that
# ever reached `deployed` is left alone.
clear_failed_install() {
  helm --kube-context "$1" status "$2" -n "$3" >/dev/null 2>&1 || return 0
  helm --kube-context "$1" history "$2" -n "$3" -o json 2>/dev/null | grep -q '"status":"deployed"' && return 0
  printf '    · release %s never reached deployed — removing it so the install can retry\n' "$2"
  helm --kube-context "$1" uninstall "$2" -n "$3" --wait >/dev/null 2>&1 || true
}

# Anonymous registry access for helm. Docker Desktop's credential helper can wedge helm for
# minutes before its first request, and every chart here is public.
kef_anon_helm() {
  _KEF_ANON="$(mktemp -d)"
  echo '{}' > "$_KEF_ANON/config.json"
  export DOCKER_CONFIG="$_KEF_ANON"
}
