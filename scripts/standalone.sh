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
# CONFIG vs INSTANCE. NAME picks the config directory under standalone/. INSTANCE names the
# running thing, and defaults to NAME. Give INSTANCE a different value to run the same config
# again alongside the first — the config is copied to .solomog/standalone/<INSTANCE>/ and
# mounted from there, so two instances never fight over one config.yaml or data.db, and a
# scratch instance's UI edits never touch your repo.
#
# The Taskfile aliases those two onto the repo-wide vocabulary — CONFIG → NAME and
# CLUSTER → INSTANCE — so an instance is addressed the way any other target is. This script
# keeps NAME/INSTANCE internally because "config" and "instance" are the accurate words for
# what they select; the aliasing is one env: line per task, not a second code path.
#
# Instances are registered in .solomog/standalone-instances (via lib/target.sh), which lets
# `solomog cluster:list` show them and `solomog teardown` destroy them like any other target.
#
# Usage: standalone.sh <action>
#   run       start (or restart) the instance named by INSTANCE, from config NAME
#   stop      stop and remove the container; config and state stay
#   delete    stop, then drop the runtime state and the registry entry
#   list      show every instance with its config, status, and URLs
#   logs      tail the instance's logs
#   validate  --validate-only the config; no container, no cluster, no license needed
#   import    convert a foreign gateway config (LiteLLM) into a standalone config
#
# Env:
#   NAME          config directory under standalone/            REQUIRED (task alias: CONFIG)
#   INSTANCE      name for the running instance                 default NAME (alias: CLUSTER)
#   BIND          host address to publish ports on              default 127.0.0.1
#   UI_PORT       first host port tried for the admin/UI        default 15000
#   GW_PORT       first host port tried for gateway ports       default the config's own port
#   PORT_TRIES    how many ports to probe before giving up      default 25
#   IMAGE         full image ref override                       default from versions.env
#   FOLLOW        true to tail logs after a successful start    default false
#   TAIL_LINES    log lines to show (logs only)                 default 60
#   FROM          import source format (import only)            default litellm
#   FILE          source file to import (import only)
#   FORCE         true skips delete's confirmation prompt
#
# Licensing: standalone requires ENTERPRISE_AGENTGATEWAY_LICENSE_KEY and refuses to start
# without it — there is no grace period on a fresh install. We source it from
# AGENTGATEWAY_LICENSE_KEY and deliberately do NOT fall back to SOLO_LICENSE_KEY: the
# standalone verifier needs a `product` claim, and the generic key has none, so a fallback
# would turn a missing-key mistake into a confusing "malformed claims" crash.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/scripts/lib/ui.sh"
# shellcheck source=lib/target.sh
source "$REPO_DIR/scripts/lib/target.sh"

ACTION="${1:-run}"

NAME="${NAME:-}"
INSTANCE="${INSTANCE:-}"
BIND="${BIND:-127.0.0.1}"
UI_PORT="${UI_PORT:-15000}"
GW_PORT="${GW_PORT:-}"
PORT_TRIES="${PORT_TRIES:-25}"
FOLLOW="${FOLLOW:-false}"
FROM="${FROM:-litellm}"
FILE="${FILE:-}"

STANDALONE_DIR="$REPO_DIR/standalone"
# Scratch runtime dirs for instances whose INSTANCE differs from NAME. Under .solomog/, which
# is gitignored, so a throwaway instance leaves no trace in the repo.
RUNTIME_DIR="$REPO_DIR/.solomog/standalone"
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
  [ -n "$NAME" ] || die "CONFIG is required — a config directory under standalone/. Existing:
$(list_configs_indented)
  e.g. solomog standalone CONFIG=minimal
  (NAME is accepted as an alias. To call the running instance something other than the
   config name, add CLUSTER=<name>.)"
}

# Actions that address a running instance take INSTANCE, falling back to NAME. Either is
# enough on its own, so `stop CLUSTER=scratch` needs no config name and `stop CONFIG=minimal`
# still works for the common case where the two are the same string.
require_instance() {
  [ -n "$INSTANCE" ] && return 0
  [ -n "$NAME" ] && { INSTANCE="$NAME"; return 0; }
  die "CLUSTER is required — which instance to act on. Registered:
$(list_instances_indented)
  e.g. solomog standalone:stop CLUSTER=minimal
  (aliases: INSTANCE, CONFIG, NAME)"
}

config_dir() { printf '%s/%s' "$STANDALONE_DIR" "$1"; }
config_file() { printf '%s/%s/config.yaml' "$STANDALONE_DIR" "$1"; }
container_name() { printf 'solomog-standalone-%s' "$1"; }
runtime_dir() { printf '%s/%s' "$RUNTIME_DIR" "$1"; }

# The directory actually mounted at /config. When INSTANCE is just NAME, that is the repo
# config dir, so UI edits land in git. When they differ, it is a scratch copy under
# .solomog/, so the second instance neither fights the first over config.yaml/data.db nor
# writes into the repo.
mount_dir() {   # args: <instance> <name>
  if [ "$1" = "$2" ]; then config_dir "$2"; else runtime_dir "$1"; fi
}

is_scratch() { [ "$INSTANCE" != "$NAME" ]; }

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

# Registered standalone instances, for the error hints.
list_instances_indented() {
  local n found=0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    found=1
    echo "    $n"
  done <<EOF
$(solomog_standalone_names)
EOF
  if [ "$found" -eq 0 ]; then
    echo "    (none running — start one with: solomog standalone CONFIG=minimal)"
  fi
  return 0
}

# Refuse a name that already belongs to a real cluster. Without this, `solomog teardown`
# would see one name with two meanings and could dispatch the wrong destroy.
refuse_cluster_name_collision() {   # args: <instance>
  local typ
  solomog_is_standalone "$1" && return 0
  typ="$(solomog_cluster_type "$1")"
  case "$typ" in
    eks|vsphere|external)
      die "'$1' is already a tracked $typ cluster (see: solomog cluster:list).
Pick a different CLUSTER so teardown stays unambiguous."
      ;;
  esac
  # A vind cluster is only "tracked" if it appears in the vind registry; the vind type is
  # also the fallback for any unknown name, so check the file rather than the type.
  if [ -f "$REPO_DIR/.solomog/clusters" ] \
    && awk -v c="$1" 'NF && $1==c{f=1} END{exit !f}' "$REPO_DIR/.solomog/clusters"; then
    die "'$1' is already a tracked vind cluster (see: solomog cluster:list).
Pick a different CLUSTER so teardown stays unambiguous."
  fi
  return 0
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
  INSTANCE="${INSTANCE:-$NAME}"
  refuse_cluster_name_collision "$INSTANCE"
  resolve_license

  local dir file cname
  cname="$(container_name "$INSTANCE")"
  dir="$(mount_dir "$INSTANCE" "$NAME")"

  # Pre-flight the $VAR references and the config itself, so a bad config fails here with a
  # readable message instead of as a crash-looping container. Always against the source
  # config, before any copy.
  do_validate >/dev/null

  # A scratch instance gets its own copy of the config, seeded once. Re-running an existing
  # scratch instance keeps whatever it has (including UI edits) rather than clobbering it;
  # delete it to start over.
  if is_scratch; then
    mkdir -p "$dir"
    if [ ! -f "$dir/config.yaml" ]; then
      cp "$(config_file "$NAME")" "$dir/config.yaml"
      echo "  seeded scratch config from standalone/$NAME/config.yaml"
    else
      echo "  reusing existing scratch config (delete the instance to re-seed)"
    fi
  fi
  file="$dir/config.yaml"

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
      --label solomog.standalone="$INSTANCE" \
      --label solomog.standalone.config="$NAME" \
      --label solomog.standalone.ui="http://${BIND}:${ui_host_port}/ui/" \
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
      die "container exited — full logs: solomog standalone:logs CLUSTER=$INSTANCE"
    fi
    if docker logs "$cname" 2>&1 | grep -q 'marking server ready'; then
      break
    fi
    sleep 1
    waited=$((waited+1))
  done

  # Register only once the instance is actually up, so a failed start leaves no ghost row
  # in cluster:list.
  solomog_register_standalone "$INSTANCE"

  echo ""
  echo "  instance            : $INSTANCE  (container $cname)"
  echo "  image               : $IMAGE"
  if is_scratch; then
    echo "  config              : .solomog/standalone/$INSTANCE/config.yaml (scratch copy of $NAME, read-write)"
  else
    echo "  config              : standalone/$NAME/config.yaml (mounted read-write)"
  fi
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
  echo "  logs    solomog standalone:logs CLUSTER=$INSTANCE"
  echo "  stop    solomog standalone:stop CLUSTER=$INSTANCE"
  echo "  delete  solomog standalone:delete CLUSTER=$INSTANCE   (or: solomog teardown CLUSTER=$INSTANCE)"

  if [ "$FOLLOW" = "true" ]; then
    echo ""
    docker logs -f "$cname"
  fi
}

# stop = the container goes away, everything else stays. Deliberately NOT a delete: the
# instance keeps its registry entry and its config/state, so re-running resumes it.
do_stop() {
  require_docker
  require_instance
  local cname
  cname="$(container_name "$INSTANCE")"
  if ! docker ps -aq --filter "name=^${cname}$" | grep -q .; then
    echo "  no container for instance '$INSTANCE' — nothing to stop"
    return 0
  fi
  docker rm -f "$cname" >/dev/null
  echo "  stopped $INSTANCE (config and state kept — re-run to resume)"
  echo "  to remove it entirely: solomog standalone:delete CLUSTER=$INSTANCE"
}

# delete = the instance stops existing. Removes the container, the registry entry, and any
# runtime state. The CONFIG under standalone/ is source, not state — the same way tearing
# down a cluster does not delete your helmfiles — so it is left alone, and the command to
# remove it is printed instead of run.
do_delete() {
  require_docker
  require_instance
  local cname rdir cfgdir known=0
  cname="$(container_name "$INSTANCE")"
  rdir="$(runtime_dir "$INSTANCE")"
  cfgdir="$(config_dir "$INSTANCE")"

  solomog_is_standalone "$INSTANCE" && known=1
  if [ "$known" -eq 0 ] \
    && ! docker ps -aq --filter "name=^${cname}$" | grep -q . \
    && [ ! -d "$rdir" ]; then
    echo "  no standalone instance '$INSTANCE' — nothing to delete"
    return 0
  fi

  if [ "${FORCE:-false}" != "true" ]; then
    echo ""
    echo "  This will delete standalone instance '$INSTANCE':"
    echo "    - container $cname"
    echo "    - registry entry in .solomog/standalone-instances"
    [ -d "$rdir" ] && echo "    - runtime state .solomog/standalone/$INSTANCE/ (including any UI edits)"
    echo ""
    read -rp "  Continue? [y/N] " confirm
    echo ""
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
      echo "  Delete cancelled."
      return 1
    fi
  fi

  docker rm -f "$cname" >/dev/null 2>&1 || true
  [ -d "$rdir" ] && rm -rf "$rdir"
  # Drop the scratch parent once the last instance leaves, so .solomog/ stays tidy.
  rmdir "$RUNTIME_DIR" 2>/dev/null || true
  solomog_unregister_standalone "$INSTANCE"
  echo "  deleted instance $INSTANCE"
  # Only mention the config dir when one exists under that name and it is not scratch.
  if [ -d "$cfgdir" ]; then
    echo "  kept the config at standalone/$INSTANCE/ — it is source, not state."
    echo "  remove it too with: rm -rf standalone/$INSTANCE"
  fi
  return 0
}

do_logs() {
  require_docker
  require_instance
  local cname
  cname="$(container_name "$INSTANCE")"
  docker ps -aq --filter "name=^${cname}$" | grep -q . \
    || die "no container for instance '$INSTANCE' — start it with: solomog standalone CONFIG=$INSTANCE"
  # TAIL_LINES, not LINES: bash sets LINES itself (terminal height) and an inherited value
  # would silently override the caller's intent. Same class of trap as GROUPS.
  docker logs "$cname" 2>&1 | tail -n "${TAIL_LINES:-60}"
}

# One row per instance, keyed on the registry so a stopped instance still appears, with the
# config it came from and the URL to open. Configs with no instance are listed separately —
# they are templates, not things that are running.
do_list() {
  require_docker
  local names rows n cname state cfg ui ports line found=0

  names="$(solomog_standalone_names)"
  echo "  instances:"
  if [ -z "$names" ]; then
    echo "    (none — start one with: solomog standalone CONFIG=minimal)"
  else
    rows=""
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      cname="$(container_name "$n")"
      line="$(docker ps -a --filter "name=^${cname}$" \
        --format '{{.State}}\t{{.Label "solomog.standalone.config"}}\t{{.Label "solomog.standalone.ui"}}\t{{.Ports}}' 2>/dev/null | head -1)"
      if [ -z "$line" ]; then
        state="gone"; cfg="?"; ui=""; ports=""
      else
        state="$(printf '%s' "$line" | cut -f1)"
        cfg="$(printf '%s' "$line" | cut -f2)"
        ui="$(printf '%s' "$line" | cut -f3)"
        ports="$(printf '%s' "$line" | cut -f4)"
      fi
      [ -n "$cfg" ] || cfg="?"
      if [ -d "$(runtime_dir "$n")" ]; then cfg="$cfg (scratch)"; fi
      rows="${rows}${n}"$'\t'"${state}"$'\t'"${cfg}"$'\t'"${ui}"$'\n'
      [ -n "$ports" ] && rows="${rows}"$'\t'$'\t'$'\t'"  ports: ${ports}"$'\n'
    done <<EOF
$names
EOF
    printf '%s' "$rows" | awk -F'\t' '
      BEGIN { printf "    %-14s  %-9s  %-22s  %s\n", "INSTANCE", "STATE", "CONFIG", "UI" }
      $1 != "" { printf "    %-14s  %-9s  %-22s  %s\n", $1, $2, $3, $4; next }
      { printf "    %-14s  %-9s  %-22s  %s\n", "", "", "", $4 }'
  fi

  echo ""
  echo "  configs under standalone/ with no instance running:"
  local d base
  for d in "$STANDALONE_DIR"/*/; do
    [ -f "${d}config.yaml" ] || continue
    base="$(basename "$d")"
    solomog_is_standalone "$base" && continue
    found=1
    echo "    $base"
  done
  if [ "$found" -eq 0 ]; then
    echo "    (none)"
  fi

  echo ""
  echo "  start   solomog standalone CONFIG=<config> [CLUSTER=<name>]"
  echo "  stop    solomog standalone:stop CLUSTER=<name>"
  echo "  delete  solomog standalone:delete CLUSTER=<name>   (or: solomog teardown CLUSTER=<name>)"
  return 0
}

do_import() {
  require_docker
  [ -n "$FILE" ] || die "FILE is required — the foreign config to import.
  e.g. solomog standalone:import FROM=litellm FILE=~/litellm/config.yaml CONFIG=from-litellm"
  [ -f "$FILE" ] || die "no such file: $FILE"
  require_name
  local dest src_dir src_base
  dest="$(config_dir "$NAME")"
  src_dir="$(cd "$(dirname "$FILE")" && pwd)"
  src_base="$(basename "$FILE")"

  [ -e "$dest/config.yaml" ] && die "standalone/$NAME/config.yaml already exists — pick another CONFIG"
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
  echo "  next: solomog standalone:validate CONFIG=$NAME"
}

case "$ACTION" in
  run)      do_run ;;
  stop)     do_stop ;;
  delete)   do_delete ;;
  list)     do_list ;;
  logs)     do_logs ;;
  validate) do_validate ;;
  import)   do_import ;;
  *)        die "unknown action '$ACTION' (run|stop|delete|list|logs|validate|import)" ;;
esac
