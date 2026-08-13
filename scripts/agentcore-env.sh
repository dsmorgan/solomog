#!/usr/bin/env bash
set -euo pipefail
#
# Puts a WORKING AWS identity in your own shell for the `agentcore` CLI (and CDK / the raw
# bedrock-agentcore-control calls), pointed at the right project dir and region.
#
# WHY THIS EXISTS — `aws:refresh` is the wrong tool for this job. It stashes three SHORT-LIVED
# static keys in .env, which is exactly right for a *bundle* (go-task loads .env as dotenv and the
# bundle turns them into a cluster Secret). But `agentcore` runs in YOUR interactive shell, which
# never reads .env — and worse, the static keys go stale in <=12h, so exporting them by hand starts
# a slow-motion footgun: expired statics SHADOW the SSO profile in the AWS credential chain, so
# every call keeps failing with "expired token" no matter how many times you re-run aws:refresh.
# The 4th var, AWS_CREDENTIAL_EXPIRATION, is never even written to .env, so a stale one left in the
# shell poisons calls that DO have fresh creds.
#
# So this helper takes the OPPOSITE posture to aws:refresh: it drops all four static vars and
# resolves credentials purely through the SSO PROFILE, which the AWS SDKs auto-refresh from the SSO
# cache. Nothing expires mid-session and there is nothing to re-stash. It also pins the two things
# that are easy to get wrong per project: the RUNTIME'S OWN REGION (projects in one repo routinely
# target different regions) and the project directory that holds agentcore/agentcore.json.
#
# Everything here is discovered from the projects on disk — no bundle, project or runtime name is
# hardcoded, so this works for any repo laid out with agentcore/ projects under bundles/.
#
# Usage:
#   agentcore-env.sh list                     # every agentcore project: name, region, deployed?, dir
#   agentcore-env.sh list LIVE=true            # ...verified against AWS instead of local state
#   agentcore-env.sh prune                     # drop local state for runtimes AWS no longer has
#   eval "$(agentcore-env.sh env NAME=x)"      # export creds+region into the CURRENT shell
#   agentcore-env.sh shell NAME=x              # interactive subshell, cd'd into the project dir
#
# Env:
#   LIVE     list only: true → cross-check every project against AWS (needs credentials).
#   DRY_RUN  prune only: true → report what would be pruned, change nothing.
#   NAME     project / runtime name (see `list`). Required for shell; optional for env
#            (without it you get creds only — no region pin, no dir).
#   REGION   override the region that would come from the project's aws-targets.json.
#   PROFILE  override the SSO profile (default: AWS_PROFILE from your shell, else from .env).
#
# In `env` mode ONLY shell-eval-able lines go to stdout — every human word goes to stderr, so
# `eval "$(...)"` stays safe even when it has to run `aws sso login` (browser) first.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
# shellcheck source=lib/envfile.sh
. "$REPO_DIR/scripts/lib/envfile.sh"

MODE="${1:-list}"
[ $# -gt 0 ] && shift
# Accept trailing KEY=VALUE args too, so the script works standalone exactly like it does
# through go-task (which passes these as env).
for arg in "$@"; do
  case "$arg" in
    NAME=*)    NAME="${arg#*=}" ;;
    REGION=*)  REGION="${arg#*=}" ;;
    PROFILE=*) PROFILE="${arg#*=}" ;;
    LIVE=*)    LIVE="${arg#*=}" ;;
    DRY_RUN=*) DRY_RUN="${arg#*=}" ;;
    *) echo "Error: unexpected argument '$arg' (want NAME=/REGION=/PROFILE=/LIVE=/DRY_RUN=)." >&2; exit 1 ;;
  esac
done
NAME="${NAME:-}"; REGION="${REGION:-}"; PROFILE="${PROFILE:-}"

command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI not found (AWS CLI v2)." >&2; exit 1; }

# ── Project discovery ────────────────────────────────────────────────────────────────────────
# A project is any dir holding agentcore/agentcore.json. .cache/ holds staged copies of the app
# tree during a build — never a real project, so it's excluded.
_projects() {
  find "$REPO_DIR/bundles" -name agentcore.json -path '*/agentcore/*' -not -path '*/.cache/*' \
    2>/dev/null | LC_ALL=C sort
}

# jq is used repo-wide (graph.sh, tests); fall back to the dir name if it's somehow absent.
_json_get() {   # <file> <jq-filter>
  [ -f "$1" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r "$2 // empty" "$1" 2>/dev/null || true
}

# Echo "<name>\t<region>\t<arn>\t<projdir>" for every project.
#
# Empty fields are written as "-", NOT left blank: tab is an IFS *whitespace* character, so
# `IFS=$'\t' read` COLLAPSES consecutive tabs and a blank middle field silently shifts every later
# field left — a project with no deployed state was reading its own directory path as an ARN, and
# printing an empty DIR. Consumers map "-" back to empty via _unplaceholder.
_rows() {
  local cfg proj name region arn
  _projects | while IFS= read -r cfg; do
    proj="$(dirname "$(dirname "$cfg")")"
    name="$(_json_get "$cfg" '.name')"; [ -n "$name" ] || name="$(basename "$proj")"
    region="$(_json_get "$proj/agentcore/aws-targets.json" '.[0].region')"
    arn="$(_json_get "$proj/agentcore/.cli/deployed-state.json" \
             '.targets.default.resources.runtimes | to_entries[0].value.runtimeArn')"
    # No aws-targets region (scaffold writes []) — fall back to the deployed ARN's region field.
    if [ -z "$region" ] && [ -n "$arn" ]; then region="$(printf '%s' "$arn" | cut -d: -f4)"; fi
    printf '%s\t%s\t%s\t%s\n' "$name" "${region:--}" "${arn:--}" "$proj"
  done
}

_unplaceholder() { [ "$1" = "-" ] && printf '' || printf '%s' "$1"; }

# ── Credentials: SSO-profile only ────────────────────────────────────────────────────────────
# Resolve the profile, drop every static cred var, then make sure the SSO session is actually
# live. Emits nothing on stdout — callers decide what to print.
RESOLVED_PROFILE=""
_ensure_creds() {
  RESOLVED_PROFILE="${PROFILE:-${AWS_PROFILE:-}}"
  if [ -z "$RESOLVED_PROFILE" ] && [ -f "$ENV_FILE" ] && envfile_has "$ENV_FILE" AWS_PROFILE; then
    RESOLVED_PROFILE="$(envfile_get "$ENV_FILE" AWS_PROFILE 2>/dev/null || true)"
  fi
  if [ -z "$RESOLVED_PROFILE" ]; then
    {
      echo "Error: no AWS profile. Set AWS_PROFILE in .env (or pass PROFILE=<name>)."
      echo "       One-time setup:  aws configure sso     # session name: ${AWS_SSO_SESSION:-SOlo}"
    } >&2
    exit 1
  fi

  # THE footgun (see header): expired statics outrank the SSO profile in the credential chain.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  export AWS_PROFILE="$RESOLVED_PROFILE"

  # STS answers in any region, so probe region-less first — the caller may have none configured.
  if ! aws sts get-caller-identity >/dev/null 2>&1 \
    && ! aws sts get-caller-identity --region us-east-1 >/dev/null 2>&1; then
    echo "==> SSO session stale for profile '$AWS_PROFILE' — running aws sso login (opens a browser)" >&2
    aws sso login --profile "$AWS_PROFILE" >&2   # stdout→stderr keeps `eval` mode clean
    if ! aws sts get-caller-identity --region us-east-1 >/dev/null 2>&1; then
      {
        echo "Error: still no working credentials for profile '$AWS_PROFILE'."
        echo "       Check the profile exists:  aws configure list-profiles"
        echo "       Re-run SSO setup once:     aws configure sso"
      } >&2
      exit 1
    fi
  fi
}

# ── Live cross-check ─────────────────────────────────────────────────────────────────────────
# deployed-state.json is written by `agentcore deploy` and NEVER updated when a runtime is
# removed out of band (a CloudFormation delete-stack, or a delete in the console) — so the local
# view claims "deployed" long after AWS disagrees. These query AWS so list/prune can tell the
# difference. Matching is on the runtime ID (the ARN's last path segment), which is stable.
LIVE_DIR=""
_live_ids() {   # <region> — one runtime id per line; empty if the call fails
  [ -n "$LIVE_DIR" ] || { LIVE_DIR="$(mktemp -d)"; trap 'rm -rf "$LIVE_DIR"' EXIT; }
  if [ ! -f "$LIVE_DIR/$1" ]; then
    aws bedrock-agentcore-control list-agent-runtimes --region "$1" \
      --query 'agentRuntimes[].agentRuntimeArn' --output text 2>/dev/null \
      | tr '\t ' '\n\n' | sed 's|.*/||' > "$LIVE_DIR/$1" || true
  fi
  cat "$LIVE_DIR/$1"
}

# "yes" (in AWS) / "GONE" (local state claims it, AWS disagrees) / "-" (no local state at all).
_live_status() {   # <region> <arn>
  local id arn
  arn="$(_unplaceholder "$2")"
  [ -n "$arn" ] || { printf -- '-'; return; }
  id="${arn##*/}"
  if _live_ids "$1" | grep -qx "$id"; then printf 'yes'; else printf 'GONE'; fi
}

# Soft credential probe: true when AWS is reachable RIGHT NOW. Never logs in, never prompts —
# `list` uses it to decide whether it can tell the truth, without ambushing a plain listing with
# a browser SSO flow.
_creds_ok() {
  local p
  p="${PROFILE:-${AWS_PROFILE:-}}"
  if [ -z "$p" ] && [ -f "$ENV_FILE" ] && envfile_has "$ENV_FILE" AWS_PROFILE; then
    p="$(envfile_get "$ENV_FILE" AWS_PROFILE 2>/dev/null || true)"
  fi
  [ -n "$p" ] || return 1
  ( unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
    export AWS_PROFILE="$p"
    aws sts get-caller-identity --region us-east-1 >/dev/null 2>&1 ) || return 1
  RESOLVED_PROFILE="$p"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  export AWS_PROFILE="$p"
  return 0
}

# Look up one project by name; sets PROJ_DIR / PROJ_REGION / PROJ_ARN.
PROJ_DIR=""; PROJ_REGION=""; PROJ_ARN=""
_resolve_project() {   # <name>
  local row
  # `!seen++` (not awk's `exit`) takes the first match: exiting early would close the pipe, and the
  # SIGPIPE on _rows' find|while writer trips set -e — silently aborting the whole script.
  row="$(_rows | awk -F'\t' -v n="$1" '$1==n && !seen++ {print}')"
  if [ -z "$row" ]; then
    {
      echo "Error: no agentcore project named '$1'."
      echo "       Known projects:"
      _rows | awk -F'\t' '{printf "         %s\n", $1}'
    } >&2
    exit 1
  fi
  PROJ_REGION="$(printf '%s' "$row" | cut -f2)"
  PROJ_ARN="$(printf '%s' "$row" | cut -f3)"
  PROJ_DIR="$(printf '%s' "$row" | cut -f4)"
  # The CloudFormation stack CDK deployed this project into — deleting it is the one-step
  # teardown (runtime + execution role + the stack itself). Recorded by `agentcore deploy`;
  # fall back to the CLI's naming convention when there's no local state.
  PROJ_STACK="$(_json_get "$PROJ_DIR/agentcore/.cli/deployed-state.json" \
                  '.targets.default.resources.stackName')"
  [ -n "$PROJ_STACK" ] || PROJ_STACK="AgentCore-${1}-default"
  [ -n "$REGION" ] && PROJ_REGION="$REGION"
  if [ -z "$PROJ_REGION" ]; then
    echo "Error: no region for '$1' (empty aws-targets.json and never deployed) — pass REGION=." >&2
    exit 1
  fi
}

case "$MODE" in
  list)
    # Verified against AWS BY DEFAULT. Local deployed-state.json is written by `agentcore deploy`
    # and updated by nothing else, so trusting it silently reports deleted runtimes as live — a
    # listing that lies is worse than no listing. LIVE=auto (the default) uses AWS whenever
    # credentials already work, and says so plainly when it has to fall back to local state.
    #   auto  → verify if creds work now; never triggers a login
    #   true  → verify, logging in (browser) if the session is stale
    #   false → local state only, offline
    live=false; why="no working AWS credentials right now"
    case "${LIVE:-auto}" in
      true) _ensure_creds; live=true ;;
      false) why="LIVE=false — you asked for local state only" ;;
      *) if _creds_ok; then live=true; fi ;;
    esac

    if [ "$live" = true ]; then printf '%-18s %-11s %-9s %s\n' NAME REGION IN_AWS DIR
    else                        printf '%-18s %-11s %-9s %s\n' NAME REGION 'LOCAL?' DIR; fi
    stale=0
    while IFS=$'\t' read -r name region arn proj; do
      if [ "$live" = true ]; then
        st="$(_live_status "$region" "$arn")"
        [ "$st" = "GONE" ] && stale=$((stale + 1))
      else
        [ "$arn" = "-" ] && st="-" || st="yes"
      fi
      printf '%-18s %-11s %-9s %s\n' "$name" "$region" "$st" "${proj#$REPO_DIR/}"
    done <<EOF
$(_rows)
EOF
    echo
    if [ "$live" != true ]; then
      echo "⚠ NOT verified — local state only ($why)."
      echo "  LOCAL? is what 'agentcore deploy' last recorded; it does NOT know about runtimes"
      echo "  deleted outside the CLI. To verify (logs in if needed):  solomog agentcore:list LIVE=true"
    elif [ "$stale" -gt 0 ]; then
      echo "⚠ $stale GONE — deleted outside the CLI, so the local state file still claims them."
      echo "  Reconcile:  solomog agentcore:prune            (add DRY_RUN=true to preview)"
    else
      echo "✓ verified against AWS — local state agrees"
    fi
    echo "  '-' = no local deploy record (never deployed from here, or already pruned)."
    echo
    echo "Use one:  eval \"\$(solomog agentcore:env NAME=<name>)\"   |   solomog agentcore:shell NAME=<name>"
    ;;

  prune)
    # Drop local deployed-state entries for runtimes AWS no longer has. Only ever removes state
    # that is already false — it never touches AWS, and never touches agentcore.json.
    _ensure_creds
    backup_dir="$REPO_DIR/.solomog/agentcore-state-backups"
    pruned=0
    while IFS=$'\t' read -r name region arn proj; do
      [ -n "$arn" ] || continue
      [ "$(_live_status "$region" "$arn")" = "GONE" ] || continue
      state="$proj/agentcore/.cli/deployed-state.json"
      if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "would prune  $name  (${state#$REPO_DIR/})"
        pruned=$((pruned + 1)); continue
      fi
      mkdir -p "$backup_dir"
      cp "$state" "$backup_dir/${name}-$(date +%Y%m%d-%H%M%S).json"
      # Drop this runtime. If it was the only one the whole file goes — that IS the shape of a
      # never-deployed project, so DEPLOYED/IN_AWS then read correctly instead of half-true.
      if [ "$(jq -r '.targets.default.resources.runtimes | length' "$state")" -le 1 ]; then
        rm -f "$state"
        echo "pruned  $name  — removed ${state#$REPO_DIR/} (no runtimes left)"
      else
        tmp="$state.tmp.$$"
        jq --arg n "$name" 'del(.targets.default.resources.runtimes[$n])' "$state" > "$tmp" \
          && mv "$tmp" "$state"
        echo "pruned  $name  — dropped its entry from ${state#$REPO_DIR/}"
      fi
      pruned=$((pruned + 1))
    done <<EOF
$(_rows)
EOF
    echo
    if [ "$pruned" -eq 0 ]; then
      echo "✓ nothing to prune — local state already agrees with AWS"
    elif [ "${DRY_RUN:-false}" = "true" ]; then
      echo "$pruned stale entr(ies). Re-run without DRY_RUN=true to apply."
    else
      echo "$pruned stale entr(ies) pruned. Backups: ${backup_dir#$REPO_DIR/}/"
      echo "Reminder: also clear the matching ARN in .env if the runtime is gone for good."
    fi
    ;;

  env)
    # Resolve the project FIRST — it's offline and free, so a typo'd NAME errors out instead of
    # sending you through a browser SSO login only to fail afterwards.
    [ -n "$NAME" ] && _resolve_project "$NAME"
    _ensure_creds
    echo "unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION"
    echo "export AWS_PROFILE=$RESOLVED_PROFILE"
    if [ -n "$NAME" ]; then
      echo "export AWS_REGION=$PROJ_REGION"
      echo "export AWS_DEFAULT_REGION=$PROJ_REGION"
      echo "export AGENTCORE_PROJECT=$NAME"
      # verify_sigv4.py and the runbooks read this name; scoped to this project it's unambiguous.
      [ -n "$PROJ_ARN" ] && echo "export AGENTCORE_RUNTIME_ARN=$PROJ_ARN"
      {
        echo "✓ profile $RESOLVED_PROFILE · region $PROJ_REGION · project $NAME"
        echo "  cd ${PROJ_DIR#$REPO_DIR/}"
      } >&2
    elif [ -n "$REGION" ]; then
      echo "export AWS_REGION=$REGION"
      echo "export AWS_DEFAULT_REGION=$REGION"
      echo "✓ profile $RESOLVED_PROFILE · region $REGION (no NAME — creds only)" >&2
    else
      echo "✓ profile $RESOLVED_PROFILE (no NAME/REGION — creds only, region unpinned)" >&2
    fi
    ;;

  shell)
    [ -n "$NAME" ] || { echo "Error: shell mode needs NAME=<project>. See: solomog agentcore:list" >&2; exit 1; }
    _resolve_project "$NAME"   # offline; fail on a bad name before any SSO round-trip
    _ensure_creds
    export AWS_REGION="$PROJ_REGION" AWS_DEFAULT_REGION="$PROJ_REGION"
    export AGENTCORE_PROJECT="$NAME" AGENTCORE_STACK="$PROJ_STACK"
    [ -n "$PROJ_ARN" ] && export AGENTCORE_RUNTIME_ARN="$PROJ_ARN"
    IDENT="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo '?')"
    echo "==> agentcore subshell — exit to return"
    echo "    project  $NAME       (\$AGENTCORE_PROJECT)"
    echo "    dir      ${PROJ_DIR#$REPO_DIR/}"
    echo "    region   $PROJ_REGION       profile $AWS_PROFILE"
    echo "    identity $IDENT"
    if [ -n "$PROJ_ARN" ]; then echo "    runtime  $PROJ_ARN"; else echo "    runtime  (not deployed)"; fi
    echo
    echo "    agentcore status --runtime \"\$AGENTCORE_PROJECT\""
    echo
    echo "    Teardown — the stack IS the runtime + its IAM role, so deleting it is the whole job"
    echo "    (and it works with these SSO creds; 'agentcore deploy' needs static keys instead):"
    echo "      aws cloudformation delete-stack        --region \$AWS_REGION --stack-name \$AGENTCORE_STACK"
    echo "      aws cloudformation wait stack-delete-complete --region \$AWS_REGION --stack-name \$AGENTCORE_STACK"
    echo "      solomog agentcore:prune                  # then reconcile the local state file"
    echo "    Config-only alternative (leaves an empty stack behind):"
    echo "      agentcore remove agent --name \"\$AGENTCORE_PROJECT\" -y && agentcore deploy"
    # Warn off a bare redeploy for JWT-inbound runtimes. Ask AWS what the authorizer ACTUALLY is
    # rather than guessing from the path — the authorizer is control-plane-only state that no file
    # in the project records, and hardcoding bundle names would make this script repo-specific.
    if [ -n "$PROJ_ARN" ]; then
      AUTHZ="$(aws bedrock-agentcore-control get-agent-runtime --region "$PROJ_REGION" \
                 --agent-runtime-id "${PROJ_ARN##*/}" --query authorizerType --output text 2>/dev/null || true)"
      case "$AUTHZ" in
        CUSTOM_JWT)
          echo "    ⚠ JWT-inbound (authorizerType=CUSTOM_JWT). 'agentcore deploy' is a full PUT — it"
          echo "      reverts this runtime to IAM and wipes env vars / header allowlist / protocol."
          echo "      Redeploy through whatever wrapper re-applies the authorizer, not a bare deploy." ;;
      esac
    fi
    echo
    cd "$PROJ_DIR"
    exec "${SHELL:-/bin/bash}" -i
    ;;

  *)
    echo "Usage: agentcore-env.sh {list|prune|env|shell} [NAME=<project>] [REGION=<r>] [PROFILE=<p>]" >&2
    exit 1
    ;;
esac
