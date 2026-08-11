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

# POST an MVC endpoint and require .result==<want>. OPNsense returns HTTP 200 with
# {"result":"failed","validations":{...}} on model validation errors, so the body —
# the only clue for adjusting the payload — is printed on failure, never discarded.
_opnsense_post_expect() {   # args: <want-result> <url> <payload>
  local want="$1" url="$2" payload="$3" body
  body="$(_opnsense_curl -X POST "$url" -d "$payload")" || {
    echo "    OPNsense API call failed (${url##*/api/}) — see the curl error above." >&2
    return 1
  }
  printf '%s' "$body" | jq -e --arg w "$want" '.result==$w' >/dev/null 2>&1 || {
    echo "    OPNsense API error (${url##*/api/}): ${body}" >&2
    return 1
  }
}

# Apply saved dnsmasq changes. Records only take effect after this step — a swallowed
# failure here would report success for a record dnsmasq never actually serves.
_opnsense_reconfigure() {
  local body
  body="$(_opnsense_curl -X POST "${OPNSENSE_URL}/api/dnsmasq/service/reconfigure" -d '{}')" || {
    echo "    OPNsense reconfigure call failed — see the curl error above." >&2
    return 1
  }
  printf '%s' "$body" | jq -e '.status=="ok"' >/dev/null 2>&1 || {
    echo "    OPNsense reconfigure returned: ${body}" >&2
    return 1
  }
}

# True when the API credentials are configured (expose then automates the record).
solomog_opnsense_ready() {
  [ -n "${OPNSENSE_URL:-}" ] && [ -n "${OPNSENSE_API_KEY:-}" ] && [ -n "${OPNSENSE_API_SECRET:-}" ]
}

# Upsert the A record <label>.<domain> → <ip> as a Dnsmasq host override + apply.
# Idempotent: absent → add; present with a different ip → update; same → apply only.
# Returns 1 when nothing was saved (API failure — caller falls back to manual
# instructions) and 2 when the record SAVED but the dnsmasq apply failed (caller
# should say "press Apply / re-run", NOT "create the record").
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
    _opnsense_post_expect saved "${OPNSENSE_URL}/api/dnsmasq/settings/add_host" "$payload" || return 1
    echo "    OPNsense: added ${label}.${domain} → ${ip}"
  elif [ "$cur" != "$ip" ]; then
    _opnsense_post_expect saved "${OPNSENSE_URL}/api/dnsmasq/settings/set_host/${uuid}" "$payload" || return 1
    echo "    OPNsense: updated ${label}.${domain} ${cur} → ${ip}"
  else
    echo "    OPNsense: ${label}.${domain} → ${ip} already in place"
    # Fall through to the apply anyway: a previous run may have saved this exact
    # record and then failed the apply — search_host reads SAVED config, not what
    # dnsmasq is serving, so skipping here would make that state unrecoverable by
    # re-running. Reconfigure is idempotent and cheap; retrying it is what makes
    # "re-run expose" a genuine repair path.
  fi
  if ! _opnsense_reconfigure; then
    echo "    WARNING: record saved but the dnsmasq apply FAILED — ${label}.${domain} will not" >&2
    echo "             resolve until applied (OPNsense UI: Services → Dnsmasq DNS, Apply — or re-run expose)." >&2
    return 2   # distinct from 1: the record exists, only the apply is pending
  fi
  return 0
}

# Delete every DNS=real record expose created for <cluster> + apply. Matches the
# descr expose stamps ("solomog <cluster>/<gw> (DNS=real)"), so only solomog-managed
# records are touched — never hand-made ones. Returns non-zero on API failure
# (caller treats cleanup as best-effort).
solomog_opnsense_dns_delete_cluster() {   # args: <cluster>
  local cluster="$1" rows victims line uuid fqdn n=0 fails=0
  command -v jq >/dev/null 2>&1 || { echo "    (jq not found — cannot drive the OPNsense API)" >&2; return 1; }
  rows="$(_opnsense_curl -X POST "${OPNSENSE_URL}/api/dnsmasq/settings/search_host" \
           -d '{"current":1,"rowCount":-1}')" || return 1
  victims="$(printf '%s' "$rows" | jq -r --arg p "solomog ${cluster}/" \
           '.rows[]? | select((.descr // "") | startswith($p)) | "\(.uuid)\t\(.host).\(.domain)"')"
  [ -n "$victims" ] || return 0
  while IFS=$'\t' read -r uuid fqdn; do
    [ -n "$uuid" ] || continue
    if _opnsense_post_expect deleted "${OPNSENSE_URL}/api/dnsmasq/settings/del_host/${uuid}" '{}'; then
      echo "    OPNsense: deleted ${fqdn}"
      n=$((n + 1))
    else
      echo "    WARNING: failed to delete OPNsense record ${fqdn} (${uuid})" >&2
      fails=$((fails + 1))
    fi
  done <<EOF
$victims
EOF
  if [ "$n" -gt 0 ] && ! _opnsense_reconfigure; then
    echo "    WARNING: dnsmasq apply failed — deleted records may still be served until applied." >&2
    fails=$((fails + 1))
  fi
  # Non-zero when anything survived, so the caller's warning path fires rather than
  # this reading as a clean cleanup.
  [ "$fails" -eq 0 ]
}
