# Config check (no traffic): every provider in the backend has an auth policy whose
# sectionName matches it. Catches the second failure that bit us — a sectionName typo
# (e.g. mock-combo-provider) leaves a real provider with NO auth, so the gateway can't
# dispatch to it and returns a fast 503 that never triggers failover. ATTACHED=True does
# NOT validate sectionName, so this cross-checks provider names against auth sectionNames.
# Prints a line per provider showing which auth policy (and kind) covers it.
NS=agentgateway-system
BACKEND=mock-combo-backend

providers="$(kubectl --context "$CONTEXT" get eagbe "$BACKEND" -n "$NS" -o json \
  | jq -r '.spec.ai.groups[].providers[].name' | LC_ALL=C sort -u)"
pol_json="$(kubectl --context "$CONTEXT" get eagpol -n "$NS" -o json)"

fail=0
echo "  providers in $BACKEND (← auth policy by sectionName):"
for p in $providers; do
  match="$(printf '%s' "$pol_json" | jq -r --arg b "$BACKEND" --arg p "$p" '
    .items[]
    | select(.spec.targetRefs[0].name == $b
             and .spec.targetRefs[0].sectionName == $p
             and (.spec.backend.auth != null))
    | "\(.metadata.name) (\(.spec.backend.auth | keys[0]))"' | head -n1)"
  if [ -n "$match" ]; then
    echo "    ✓ $p ← $match"
  else
    echo "    ✗ $p ← (no auth policy with sectionName=$p)"; fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "  ✗ some providers have no matching auth policy"; exit 1
fi
echo "  ✓ every provider in $BACKEND has a matching auth policy"
