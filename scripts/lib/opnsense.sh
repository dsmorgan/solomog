#!/usr/bin/env bash
# OPNsense Dnsmasq DNS automation for `expose DNS=real` — upsert one exact-name
# host override per (cluster, gateway), so no manual router edits per cluster.
# Flat DNS=real hostnames (agw-s1.<domain>) made this possible: exact-name host
# overrides are all we need (no subtree address=/ records), and host overrides are
# what the OPNsense API manages cleanly.
#
# API contract (OPNsense Dnsmasq MVC; David's opns1 runs Dnsmasq — confirmed):
#   POST /api/dnsmasq/settings/search_host        → {"rows":[{uuid,host,domain,ip,…}]}
#   POST /api/dnsmasq/settings/add_host           {"host":{host,domain,ip,descr}}
#   POST /api/dnsmasq/settings/set_host/<uuid>    same payload (update)
#   POST /api/dnsmasq/service/reconfigure         apply
# Auth: HTTP basic <key>:<secret> over HTTPS (opns1 serves a real LE cert).
# ⚠ Endpoint/field names follow the standard OPNsense MVC grid pattern but are
# validated LIVE on first use — if the dnsmasq model differs, adjust here; expose
# falls back to printed manual instructions on any failure, so nothing breaks.
#
# Env (all from .env; solomog_opnsense_ready gates on them):
#   OPNSENSE_URL           e.g. https://opns1.apex.district11.net
#   OPNSENSE_API_KEY       from a dedicated low-privilege user's API key pair
#   OPNSENSE_API_SECRET    (System → Access → Users → API keys)

_opnsense_curl() {
  curl -sSf --max-time 15 -u "${OPNSENSE_API_KEY}:${OPNSENSE_API_SECRET}" \
    -H 'Content-Type: application/json' "$@"
}

# True when the API credentials are configured (expose then automates the record).
solomog_opnsense_ready() {
  [ -n "${OPNSENSE_URL:-}" ] && [ -n "${OPNSENSE_API_KEY:-}" ] && [ -n "${OPNSENSE_API_SECRET:-}" ]
}

# Upsert the A record <label>.<domain> → <ip> as a Dnsmasq host override + apply.
# Idempotent: absent → add; present with a different ip → update; same → no-op.
# Returns non-zero on any API failure (caller falls back to manual instructions).
solomog_opnsense_dns_upsert() {   # args: <label> <domain> <ip> [<descr>]
  local label="$1" domain="$2" ip="$3" descr="${4:-managed by solomog (DNS=real)}"
  command -v jq >/dev/null 2>&1 || { echo "    (jq not found — cannot drive the OPNsense API)" >&2; return 1; }
  local rows uuid cur payload
  rows="$(_opnsense_curl -X POST "${OPNSENSE_URL}/api/dnsmasq/settings/search_host" \
           -d '{"current":1,"rowCount":-1}')" || return 1
  uuid="$(printf '%s' "$rows" | jq -r --arg h "$label" --arg d "$domain" \
           '.rows[]? | select(.host==$h and .domain==$d) | .uuid' | head -1)"
  cur="$(printf '%s' "$rows" | jq -r --arg h "$label" --arg d "$domain" \
           '.rows[]? | select(.host==$h and .domain==$d) | .ip' | head -1)"
  payload="$(jq -nc --arg h "$label" --arg d "$domain" --arg ip "$ip" --arg descr "$descr" \
           '{host:{host:$h,domain:$d,ip:$ip,descr:$descr}}')"
  if [ -z "$uuid" ]; then
    _opnsense_curl -X POST "${OPNSENSE_URL}/api/dnsmasq/settings/add_host" -d "$payload" \
      | jq -e '.result=="saved"' >/dev/null || return 1
    echo "    OPNsense: added ${label}.${domain} → ${ip}"
  elif [ "$cur" != "$ip" ]; then
    _opnsense_curl -X POST "${OPNSENSE_URL}/api/dnsmasq/settings/set_host/${uuid}" -d "$payload" \
      | jq -e '.result=="saved"' >/dev/null || return 1
    echo "    OPNsense: updated ${label}.${domain} ${cur} → ${ip}"
  else
    echo "    OPNsense: ${label}.${domain} → ${ip} already in place"
    return 0   # no reconfigure needed
  fi
  _opnsense_curl -X POST "${OPNSENSE_URL}/api/dnsmasq/service/reconfigure" -d '{}' >/dev/null || true
  return 0
}
