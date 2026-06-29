# Config check (no traffic): the backend exists, and every policy for this backend is
# ATTACHED to it. Catches the failure that bit us — a policy whose targetRefs.name points at
# a phantom/wrong backend silently never attaches, so failover (or auth) just doesn't happen.
# Runs first (00-) so wiring problems surface before the live failover test spends tokens.
# Prints a line per policy so you can see exactly what was checked. Uses $CONTEXT + jq.
NS=agentgateway-system
BACKEND=mock-combo-backend

if kubectl --context "$CONTEXT" get eagbe "$BACKEND" -n "$NS" >/dev/null 2>&1; then
  echo "  ✓ backend $BACKEND present"
else
  echo "  ✗ backend $BACKEND not found"; exit 1
fi

rows="$(kubectl --context "$CONTEXT" get eagpol -n "$NS" -o json | jq -r --arg b "$BACKEND" '
  .items[]
  | select(.metadata.name | test("combo|5xx"))
  | [ .metadata.name,
      (.spec.targetRefs[0].name // "-"),
      (.spec.targetRefs[0].sectionName // "-"),
      ((.status.ancestors[0].conditions[]? | select(.type=="Attached") | .status) // "?") ]
  | @tsv')"

fail=0
echo "  policies targeting this bundle (→ target[/section], attached?):"
while IFS=$(printf '\t') read -r name target section attached; do
  [ -z "$name" ] && continue
  mark="✓"
  if [ "$target" != "$BACKEND" ] || [ "$attached" != "True" ]; then mark="✗"; fail=1; fi
  sec=""; [ "$section" != "-" ] && sec="/$section"
  echo "    $mark $name → ${target}${sec}   attached=$attached"
done <<EOF
$rows
EOF

if [ "$fail" -ne 0 ]; then
  echo "  ✗ one or more policies not attached to $BACKEND (wrong target or not reconciled)"; exit 1
fi
echo "  ✓ all policies attached to $BACKEND"
