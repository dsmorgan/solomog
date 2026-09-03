# apply (bundle unroll) for scripts/explain.sh. Sourced, not executed.

explain_apply_render() {
  local file="$1"
  local sed_args=(
    -e "s|%%CLUSTER%%|${CLUSTER}|g"
    -e "s|%%GATEWAY%%|${GATEWAY}|g"
    -e "s|%%HOST%%|${HOST}|g"
  )
  [ -n "${BEDROCK_GUARDRAIL_ID:-}" ] && \
    sed_args+=(-e "s|%%BEDROCK_GUARDRAIL_ID%%|${BEDROCK_GUARDRAIL_ID}|g")
  [ -n "${BEDROCK_GUARDRAIL_VERSION:-}" ] && \
    sed_args+=(-e "s|%%BEDROCK_GUARDRAIL_VERSION%%|${BEDROCK_GUARDRAIL_VERSION}|g")
  sed "${sed_args[@]}" "$file"
}

explain_redact_hook() {
  local text="$1" line name val
  text="$(printf '%s' "$text" | sed \
    -e 's/kubectl --context "[^"]*" /kubectl /g' \
    -e "s/kubectl --context '[^']*' /kubectl /g" \
    -e 's/kubectl --context \$[A-Za-z_][A-Za-z0-9_]* /kubectl /g')"
  while IFS= read -r line || [ -n "$line" ]; do
    name="${line%%=*}"
    val="${line#*=}"
    [ -n "$name" ] && [ "$name" != "$val" ] || continue
    case "$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')" in
      *KEY*|*TOKEN*|*SECRET*|*PASSWORD*|*PASS*)
        [ "${#val}" -ge 8 ] || continue
        text="${text//${val}/\$\{${name}\}}"
        ;;
    esac
  done <<EOF
$(env)
EOF
  printf '%s' "$text"
}

explain_apply_one() {
  local bundle="$1" dir="" name f rendered leftover

  if [ -d "$REPO_DIR/bundles/private/$bundle" ]; then
    dir="$REPO_DIR/bundles/private/$bundle"
  elif [ -d "$REPO_DIR/bundles/$bundle" ]; then
    dir="$REPO_DIR/bundles/$bundle"
  else
    echo "Error: bundle '$bundle' not found in bundles/ or bundles/private/." >&2
    return 1
  fi

  echo "# Bundle ${bundle} — kubectl apply in filename order."
  echo "# GATEWAY=${GATEWAY}  HOST=${HOST}  CLUSTER=${CLUSTER}"
  echo

  local files
  files="$(cd "$dir" && LC_ALL=C ls 2>/dev/null | grep -E '\.(yaml|yml)(\.tmpl)?$|\.sh$' | LC_ALL=C sort || true)"
  if [ -z "$files" ]; then
    echo "Error: bundle '$bundle' ($dir) has no .yaml/.yml/.sh files." >&2
    return 1
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    f="$dir/$name"
    case "$name" in
      *.sh)
        echo "# Hook ${name} — run these commands; do not apply the file as YAML."
        echo
        explain_redact_hook "$(cat "$f")"
        echo
        echo
        ;;
      *.tmpl)
        rendered="$(explain_apply_render "$f")"
        leftover="$(printf '%s\n' "$rendered" | grep -oE '%%[A-Z0-9_]+%%' | LC_ALL=C sort -u || true)"
        if [ -n "$leftover" ]; then
          echo "Error: unsubstituted token(s) in ${name}: $(echo "$leftover" | tr '\n' ' ')" >&2
          echo "       Supported: %%CLUSTER%% %%GATEWAY%% %%HOST%% %%BEDROCK_GUARDRAIL_ID%% %%BEDROCK_GUARDRAIL_VERSION%%" >&2
          return 1
        fi
        echo "# ${name} (tokens rendered)"
        echo "kubectl apply -f - <<'EXPLAIN_EOF'"
        printf '%s\n' "$rendered"
        echo "EXPLAIN_EOF"
        echo
        ;;
      *)
        echo "# ${name}"
        echo "kubectl apply -f - <<'EXPLAIN_EOF'"
        cat "$f"
        echo "EXPLAIN_EOF"
        echo
        ;;
    esac
  done <<EOF
$files
EOF
}

explain_task_apply() {
  local list="${BUNDLE:-${BUNDLES:-}}"
  explain_section "apply"
  if [ -z "$list" ]; then
    echo "# apply requires BUNDLE=<name> (or BUNDLES=)."
    echo "explain: apply needs BUNDLE=" >&2
    return 0
  fi
  local b
  for b in $list; do
    explain_apply_one "$b" || return 1
  done
}
