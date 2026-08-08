# Starter Portal + httpbin ApiProduct must exist (applied by solomog portal + this bundle).
# Use fully-qualified Portal GVR — bare `portal` is ambiguous (portals / portalparameters / …).
kubectl --context "$CONTEXT" get portals.portal.solo.io my-portal -n portal-system >/dev/null
kubectl --context "$CONTEXT" get apiproducts.portal.solo.io httpbin-api -n portal-system >/dev/null
kubectl --context "$CONTEXT" get apidocs.portal.solo.io httpbin-apidoc -n portal-system >/dev/null
kubectl --context "$CONTEXT" get deploy portal-ui httpbin -n portal-system >/dev/null
kubectl --context "$CONTEXT" get httproute my-portal-backend my-portal-frontend httpbin-route -n portal-system >/dev/null
