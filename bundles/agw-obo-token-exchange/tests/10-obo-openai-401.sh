#!/usr/bin/env bash
set -euo pipefail
status=$(curl -sk -o /dev/null -w "%{http_code}" "https://${HOST}/obo/openai" \
  -H "Content-Type: application/json" \
  -d '{"model": "mock-gpt-4o", "messages": [{"role": "user", "content": "Hello"}]}')
[ "$status" -eq 401 ] || { echo "expected 401, got $status"; exit 1; }
