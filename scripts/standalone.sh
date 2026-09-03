#!/usr/bin/env bash
set -euo pipefail
#
# standalone.sh — run enterprise agentgateway in STANDALONE mode: one self-contained
# binary in a Docker container, no Kubernetes, no control plane, no CRDs.
#
# This is deliberately NOT a cluster path. The standalone gateway reads a single local
# config file (the `LocalConfig` schema) and serves its own UI in-process, so putting it
# in vind would add a vcluster, a LoadBalancer, /etc/hosts and mkcert for no benefit.
# Note the UI here is the gateway's OWN built-in UI — a different thing from the Solo
# Enterprise UI management chart that `solomog agentgateway:ui` installs onto a cluster.
#
# Usage: standalone.sh <action>
#   run       start (or restart) the instance named by NAME
#   stop      stop and remove the instance's container
#   list      show solomog standalone containers and their URLs
#   logs      tail the instance's logs
#   validate  --validate-only the config; no container, no cluster, no license needed
#   import    convert a foreign gateway config (LiteLLM) into a standalone config
#
# Env:
#   NAME          config directory under standalone/            REQUIRED (no default)
#   BIND          host address to publish ports on              default 127.0.0.1
#   UI_PORT       first host port tried for the admin/UI        default 15000
#   GW_PORT       first host port tried for gateway ports       default the config's own port
#   PORT_TRIES    how many ports to probe before giving up      default 25
#   IMAGE         full image ref override                       default from versions.env
#   FOLLOW        true to tail logs after a successful start    default false
#   TAIL_LINES    log lines to show (logs only)                 default 60
#   FROM          import source format (import only)            default litellm
#   FILE          source file to import (import only)
#
# Licensing: standalone requires ENTERPRISE_AGENTGATEWAY_LICENSE_KEY and refuses to start
# without it — there is no grace period on a fresh install. We source it from
# AGENTGATEWAY_LICENSE_KEY and deliberately do NOT fall back to SOLO_LICENSE_KEY: the
# standalone verifier needs a `product` claim, and the generic key has none, so a fallback
# would turn a missing-key mistake into a confusing "malformed claims" crash.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/ui.sh"

ACTION="${1:-run}"

NAME="${NAME:-}"
BIND="${BIND:-127.0.0.1}"
UI_PORT="${UI_PORT:-15000}"
GW_PORT="${GW_PORT:-}"
PORT_TRIES="${PORT_TRIES:-25}"
FOLLOW="${FOLLOW:-false}"
FROM="${FROM:-litellm}"
FILE="${FILE:-}"

STANDALONE_DIR="$REPO_DIR/standalone"
IMAGE_REPO="us-docker.pkg.dev/solo-public/enterprise-agentgateway/agentgateway-enterprise"
# No "v" prefix: this is the image line. See versions.env.
IMAGE="${IMAGE:-${IMAGE_REPO}:${AGENTGATEWAY_STANDALONE_VERSION:-2026.8.2}}"

# In-container admin address. MUST be 0.0.0.0 — the default binds the container's own
# loopback, which is not the host's, so `-p` would publish a port nothing listens on. The
# image is distroless (no shell), so there is no in-container workaround. ADMIN_ADDR takes
# precedence over config.adminAddr, which lets us do this without editing your config.
CONTAINER_ADMIN_PORT=15000

die() { echo "ERROR: $*" >&2; exit 1; }

# ── helpers ──────────────────────────────────────────────────────────────────

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found — see: solomog setup"
  docker info >/dev/null 2>&1 || die "Docker is not running — start Docker Desktop"
}

require_name() {
  [ -n "$NAME" ] || die "NAME is required. Available configs:
$(list_configs_indented)
  e.g. solomog standalone NAME=minimal"
}

config_dir() { printf '%s/%s' "$STANDALONE_DIR" "$1"; }
config_file() { printf '%s/%s/config.yaml' "$STANDALONE_DIR" "$1"; }
container_name() { printf 'solomog-standalone-%s' "$1"; }

list_configs_indented() {
  local d found=0
  for d in "$STANDALONE_DIR"/*/; do
    [ -f "${d}config.yaml" ] || continue
    found=1
    echo "    $(basename "$d")"
  done
  # Explicit if + return 0, not `[ ] && echo`: as a function's last statement that idiom
  # leaks a non-zero status and kills the caller under `set -e`.
  if [ "$found" -eq 0 ]; then
    echo "    (none — add standalone/<name>/config.yaml)"
  fi
  return 0
}

require_config() {
  local f
  f="$(config_file "$NAME")"
  [ -f "$f" ] || die "no config at standalone/$NAME/config.yaml. Available configs:
$(list_configs_indented)"
}

# Resolve the license key. Explicit, single-source, no fallback (see header).
resolve_license() {
  local key="${AGENTGATEWAY_LICENSE_KEY:-}"
  # Trim any stray whitespace so we never hand docker a padded value.
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  if [ -z "$key" ]; then
    die "AGENTGATEWAY_LICENSE_KEY is not set in .env.

Standalone refuses to start unlicensed — there is no grace period on a fresh install.
Note it does NOT fall back to SOLO_LICENSE_KEY: the standalone license verifier requires
a 'product' claim and the generic key has none, so the fallback would fail confusingly.

Generate one from the licensing repo if you need to:
  cd ../licensing/tools && go run cmd/genlicense/main.go -product agentgateway -enterprise -days 365"
  fi
  export ENTERPRISE_AGENTGATEWAY_LICENSE_KEY="$key"
}

# Every port the config makes the gateway listen on. Two sources:
#
#  1. `gateways.*.port`. Listeners nested under a gateway share its port — they split on
#     hostname — so the gateway's own port is the whole story for that gateway.
#  2. Top-level `llm` / `mcp`, which are listeners in their own right when they are NOT
#     attached to a gateway. This mirrors apply_implicit_default_gateway() in
#     crates/agentgateway/src/types/local.rs: a bare `llm` (no `gateways`, no `port`, no
#     `tls`) auto-attaches to a gateway named `default` and needs no port of its own;
#     otherwise it listens on `llm.port`, defaulting to 4000 (mcp defaults to 3000).
#
# Getting (2) wrong is not cosmetic: the UI can add a top-level `llm.port`, and a port we
# never published is a listener you cannot reach from the host.
config_gateway_ports() {
  python3 - "$1" <<'PY'
import sys, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
except Exception as exc:
    sys.stderr.write(f"could not parse config: {exc}\n")
    sys.exit(1)

out = []
gws = cfg.get("gateways") or {}
if isinstance(gws, dict):
    for name, gw in gws.items():
        if isinstance(gw, dict) and isinstance(gw.get("port"), int):
            out.append((name, gw["port"]))

# Does a gateway named `default` exist that could absorb an unattached llm/mcp? The Rust
# side also requires it to carry HTTP routes; approximate that by excluding TCP/TLS.
default_gw = gws.get("default") if isinstance(gws, dict) else None
default_http = (
    isinstance(default_gw, dict)
    and str(default_gw.get("protocol") or "HTTP").upper() in ("HTTP", "HTTPS")
)

for section, default_port in (("llm", 4000), ("mcp", 3000)):
    sec = cfg.get(section)
    if not isinstance(sec, dict):
        continue
    if sec.get("gateways"):          # attached to a gateway → shares that port
        continue
    port = sec.get("port")
    if port is None:
        # Auto-attach applies only when no port and (for llm) no tls is set.
        if default_http and not (section == "llm" and sec.get("tls")):
            continue
        port = default_port
    if isinstance(port, int):
        out.append((section, port))

for name, port in out:
    print(f"{name}\t{port}")
PY
}

# Environment variables the config references as $VAR / ${VAR}.
#
# The binary runs shellexpand over the WHOLE config file before parsing, so any $IDENT is
# substituted — and an unset one aborts the entire config load with "environment variable
# not found", without naming the variable. We pre-flight that here so the error names it,
# and pass the resolved ones into the container.
config_env_refs() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
# Mirror the gateway's own preprocessing exactly (crates/agentgateway/src/config.rs):
# it replaces this one literal substring before expanding, which is why the editor schema
# hint is the ONLY $-bearing comment that is safe. Every other $IDENT in the file —
# comments included — is expanded and must exist.
text = text.replace("# yaml-language-server: $schema", "#")
# $NAME or ${NAME}; a bare or doubled $ (e.g. a regex anchor) has no identifier and is skipped.
names = set(re.findall(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)', text))
for braced, bare in sorted(names):
    print(braced or bare)
PY
}

# True when BIND:PORT can be bound right now. Probes the same address we will publish on,
# because a listener on 0.0.0.0:4000 also blocks 127.0.0.1:4000.
port_is_free() {
  python3 - "$1" "$2" <<'PY'
import socket, sys
addr, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind((addr, port))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

# First free port at or above START, skipping any already claimed in this run.
# Probing is advisory — a port can be taken between the probe and container start — so the
# caller also retries on Docker's own allocation failure, which is the check that counts.
_CLAIMED_PORTS=""
pick_port() {
  local start="$1" tries="$2" port n=0
  port="$start"
  while [ "$n" -lt "$tries" ]; do
    case " $_CLAIMED_PORTS " in
      *" $port "*) port=$((port+1)); n=$((n+1)); continue ;;
    esac
    if port_is_free "$BIND" "$port"; then
      _CLAIMED_PORTS="$_CLAIMED_PORTS $port"
      printf '%s' "$port"
      return 0
    fi
    port=$((port+1))
    n=$((n+1))
  done
  die "no free port on $BIND in $start..$((start+tries-1)) (probed $tries).
Free one up, or raise the search: PORT_TRIES=50, or move the start: GW_PORT=/UI_PORT="
}

# ── actions ──────────────────────────────────────────────────────────────────

do_validate() {
  require_docker
  require_name
  require_config
  local f cfg_in_container
  f="$(config_file "$NAME")"
  cfg_in_container="/config/config.yaml"

  # An unset $VAR fails the load; name it here rather than leaving the opaque runtime error.
  local refs missing=""
  refs="$(config_env_refs "$f")"
  local v
  for v in $refs; do
    eval "set +u; val=\${$v-__SOLOMOG_UNSET__}; set -u"
    [ "$val" = "__SOLOMOG_UNSET__" ] && missing="$missing $v"
  done
  if [ -n "$missing" ]; then
    echo "Config references environment variables that are not set:"
    for v in $missing; do echo "    \$$v"; done
    echo ""
    die "set these in .env (the gateway expands \$VAR over the whole config file and
aborts the load if one is missing — its own error does not name the variable)"
  fi

  # --validate-only needs no license and no cluster.
  local env_args=""
  for v in $refs; do env_args="$env_args -e $v"; done
  # shellcheck disable=SC2086
  docker run --rm $env_args \
    -v "$(config_dir "$NAME"):/config:ro" \
    "$IMAGE" -f "$cfg_in_container" --validate-only
}

do_run() {
  require_docker
  require_name
  require_config
  resolve_license

  local dir file cname
  dir="$(config_dir "$NAME")"
  file="$(config_file "$NAME")"
  cname="$(container_name "$NAME")"

  # Pre-flight the $VAR references and the config itself, so a bad config fails here with a
  # readable message instead of as a crash-looping container.
  do_validate >/dev/null

  local refs env_args=""
  refs="$(config_env_refs "$file")"
  local v
  for v in $refs; do env_args="$env_args -e $v"; done

  # Container gateway ports, from the config.
  local gw_lines
  gw_lines="$(config_gateway_ports "$file")"
  [ -n "$gw_lines" ] || die "config declares no gateways with a port — nothing to publish"

  docker rm -f "$cname" >/dev/null 2>&1 || true

  local attempt=0 max_attempts=5 rc=0 out
  local port_args gw_map ui_host_port bump=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt+1))
    _CLAIMED_PORTS=""
    port_args=""
    gw_map=""

    # Admin/UI port.
    ui_host_port="$(pick_port "$((UI_PORT + bump))" "$PORT_TRIES")"
    port_args="$port_args -p ${BIND}:${ui_host_port}:${CONTAINER_ADMIN_PORT}"

    # One published port per gateway. GW_PORT, when set, overrides the starting point for
    # the probe; without it each gateway starts from its own configured port.
    local gname cport hport
    while IFS=$'\t' read -r gname cport; do
      [ -n "$cport" ] || continue
      if [ -n "$GW_PORT" ]; then
        hport="$(pick_port "$((GW_PORT + bump))" "$PORT_TRIES")"
      else
        hport="$(pick_port "$((cport + bump))" "$PORT_TRIES")"
      fi
      port_args="$port_args -p ${BIND}:${hport}:${cport}"
      gw_map="${gw_map}${gname}"$'\t'"${hport}"$'\t'"${cport}"$'\n'
    done <<EOF
$gw_lines
EOF

    # The config dir is mounted READ-WRITE on purpose. In storage.mode file the UI writes
    # your edits back into config.yaml, and the binary keeps its SQLite state (data.db*)
    # beside it — so UI changes show up in `git diff`, which is what you want when you are
    # building a config. data.db* is gitignored.
    set +e
    # shellcheck disable=SC2086
    out=$(docker run -d --name "$cname" \
      --label solomog.standalone="$NAME" \
      -e ENTERPRISE_AGENTGATEWAY_LICENSE_KEY \
      -e "ADMIN_ADDR=0.0.0.0:${CONTAINER_ADMIN_PORT}" \
      $env_args \
      $port_args \
      -v "${dir}:/config" \
      "$IMAGE" -f /config/config.yaml 2>&1)
    rc=$?
    set -e

    [ "$rc" -eq 0 ] && break

    case "$out" in
      *"port is already allocated"*|*"address already in use"*|*"Bind for"*)
        docker rm -f "$cname" >/dev/null 2>&1 || true
        bump=$((bump+1))
        echo "  port raced (attempt $attempt/$max_attempts) — retrying one port higher"
        ;;
      *)
        echo "$out" >&2
        die "docker run failed"
        ;;
    esac
  done
  [ "$rc" -eq 0 ] || die "could not claim free host ports after $max_attempts attempts"

  # Wait for readiness, but report the real failure if it crashed instead.
  local waited=0 state
  while [ "$waited" -lt 40 ]; do
    state="$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo missing)"
    if [ "$state" != "running" ]; then
      echo ""
      docker logs "$cname" 2>&1 | grep -E '^Error|error' | tail -5 >&2 || true
      die "container exited — full logs: solomog standalone:logs NAME=$NAME"
    fi
    if docker logs "$cname" 2>&1 | grep -q 'marking server ready'; then
      break
    fi
    sleep 1
    waited=$((waited+1))
  done

  echo ""
  echo "  standalone instance : $NAME  ($cname)"
  echo "  image               : $IMAGE"
  echo "  config              : standalone/$NAME/config.yaml (mounted read-write)"
  if [ -n "$refs" ]; then
    # shellcheck disable=SC2086
    echo "  env passed through  : $(echo $refs | tr '\n' ' ')"
  fi
  echo ""
  echo "  UI    http://${BIND}:${ui_host_port}/ui/"
  local gname hport cport
  while IFS=$'\t' read -r gname hport cport; do
    [ -n "$gname" ] || continue
    if [ "$hport" = "$cport" ]; then
      echo "  gw    http://${BIND}:${hport}          (gateway '$gname')"
    else
      echo "  gw    http://${BIND}:${hport}          (gateway '$gname', container port $cport)"
    fi
  done <<EOF
$gw_map
EOF
  echo ""
  echo "  logs  solomog standalone:logs NAME=$NAME"
  echo "  stop  solomog standalone:stop NAME=$NAME"

  if [ "$FOLLOW" = "true" ]; then
    echo ""
    docker logs -f "$cname"
  fi
}

do_stop() {
  require_docker
  require_name
  local cname
  cname="$(container_name "$NAME")"
  if ! docker ps -aq --filter "name=^${cname}$" | grep -q .; then
    echo "  no container named $cname — nothing to stop"
    return 0
  fi
  docker rm -f "$cname" >/dev/null
  echo "  removed $cname"
}

do_logs() {
  require_docker
  require_name
  local cname
  cname="$(container_name "$NAME")"
  docker ps -aq --filter "name=^${cname}$" | grep -q . \
    || die "no container named $cname — start it with: solomog standalone NAME=$NAME"
  # TAIL_LINES, not LINES: bash sets LINES itself (terminal height) and an inherited value
  # would silently override the caller's intent. Same class of trap as GROUPS.
  docker logs "$cname" 2>&1 | tail -n "${TAIL_LINES:-60}"
}

do_list() {
  require_docker
  echo "  configs under standalone/:"
  list_configs_indented
  echo ""
  echo "  running instances:"
  local rows
  rows="$(docker ps -a --filter 'label=solomog.standalone' \
    --format '{{.Label "solomog.standalone"}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}')"
  if [ -z "$rows" ]; then
    echo "    (none)"
    return 0
  fi
  printf '%s\n' "$rows" | while IFS=$'\t' read -r n c s p; do
    echo "    $n  [$s]"
    echo "        $p"
  done
}

do_import() {
  require_docker
  [ -n "$FILE" ] || die "FILE is required — the foreign config to import.
  e.g. solomog standalone:import FROM=litellm FILE=~/litellm/config.yaml NAME=from-litellm"
  [ -f "$FILE" ] || die "no such file: $FILE"
  require_name
  local dest src_dir src_base
  dest="$(config_dir "$NAME")"
  src_dir="$(cd "$(dirname "$FILE")" && pwd)"
  src_base="$(basename "$FILE")"

  [ -e "$dest/config.yaml" ] && die "standalone/$NAME/config.yaml already exists — pick another NAME"
  mkdir -p "$dest"

  # Findings go to stderr, the config to stdout — keep them separate.
  docker run --rm -v "${src_dir}:/src:ro" --entrypoint /app/agentgateway "$IMAGE" \
    import --from "$FROM" -f "/src/${src_base}" > "$dest/config.yaml"

  # The importer emits a RELATIVE database path (sqlite://data.db). The container's working
  # directory is /, so that would put the SQLite state at /data.db — inside the container,
  # discarded on every `docker rm`, silently losing budget counters. Point it at the mounted
  # config dir instead, where it persists and is gitignored.
  python3 - "$dest/config.yaml" <<'PY'
import re, sys
p = sys.argv[1]
text = open(p).read()
fixed = re.sub(r'(?m)^(\s*url:\s*)sqlite://(?!/)(\S+)$', r'\1sqlite:///config/\2', text)
if fixed != text:
    open(p, 'w').write(fixed)
    print("  normalized config.database.url to sqlite:///config/data.db")
PY

  echo ""
  echo "  wrote standalone/$NAME/config.yaml"
  echo "  review the findings above: 'exact' translated cleanly, 'approximate' needs a look,"
  echo "  'unsupported' was dropped."
  echo ""
  echo "  next: solomog standalone:validate NAME=$NAME"
}

case "$ACTION" in
  run)      do_run ;;
  stop)     do_stop ;;
  list)     do_list ;;
  logs)     do_logs ;;
  validate) do_validate ;;
  import)   do_import ;;
  *)        die "unknown action '$ACTION' (run|stop|list|logs|validate|import)" ;;
esac
