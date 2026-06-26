# A test is just the command(s) you'd run. The runner judges pass/fail by EXIT CODE —
# `kubectl get` exits non-zero if the namespace is missing, so this needs no extra logic.
# It runs with $CONTEXT exported (plus $CLUSTER/$GATEWAY/$HOST and any .env var).
kubectl --context "$CONTEXT" get namespace solomog-example >/dev/null
