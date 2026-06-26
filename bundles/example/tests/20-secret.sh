# Another exit-code check: the Secret created by the bundle's .sh hook (20-demo-secret.sh)
# exists. Demonstrates that tests can validate whatever the bundle produced — manifests,
# templated resources, or hook output alike.
kubectl --context "$CONTEXT" get secret demo-secret -n solomog-example >/dev/null
