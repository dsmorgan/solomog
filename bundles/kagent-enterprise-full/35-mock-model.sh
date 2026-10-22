#!/usr/bin/env bash
# An OpenAI-compatible mock model in its own namespace, so a turn needs no provider key and its
# answer is predictable.
#
# helpers/mocks/mock_llm.py replies "ECHO <last user message>", turns "CALL:<tool>" into a tool call,
# and records every request at /requests, so a test can prove a turn reached the model.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/helpers/env.sh"
CTX="${CONTEXT:?CONTEXT not set — solomog sets this for bundle hooks}"
k() { kubectl --context "$CTX" "$@"; }
SRC="$HERE/helpers/mocks/mock_llm.py"

echo "==> mock model → ${MOCK_NS} (${MODEL_URL})"
k create namespace "$MOCK_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
k -n "$MOCK_NS" create configmap mock-llm --from-file=mock_llm.py="$SRC" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: mock-llm, namespace: ${MOCK_NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app: mock-llm}}
  template:
    metadata:
      labels: {app: mock-llm}
      annotations: {mocks/hash: "$(shasum < "$SRC" | cut -c1-12)"}
    spec:
      containers:
      - name: mock
        image: public.ecr.aws/docker/library/python:3.12-alpine
        command: [python3, -u, /mocks/mock_llm.py, "8080"]
        ports: [{containerPort: 8080}]
        readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 2}
        resources: {requests: {cpu: 20m, memory: 32Mi}}
        volumeMounts: [{name: mocks, mountPath: /mocks}]
      volumes: [{name: mocks, configMap: {name: mock-llm}}]
---
apiVersion: v1
kind: Service
metadata: {name: mock-llm, namespace: ${MOCK_NS}}
spec: {selector: {app: mock-llm}, ports: [{name: http, port: 8080, targetPort: 8080}]}
YAML
k -n "$MOCK_NS" rollout status deploy/mock-llm --timeout=180s
