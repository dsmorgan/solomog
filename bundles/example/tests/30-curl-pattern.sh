# The headline test style: a portable curl. In a real (routed) bundle a test file is just:
#
#     curl --fail-with-body -sS https://$HOST/your-path \
#       -H 'content-type: application/json' -d '{...}'
#
# `--fail-with-body` makes HTTP >=400 exit non-zero (test fails) while still printing the
# body. $HOST is exported by the runner, so it's copy-paste runnable (`export HOST=…`).
# See bundles/agw-dr/tests (a live, no-cost example) and bundles/llmroute/tests.
#
# The example bundle deploys NO HTTP endpoint, so this self-skips (exit 0) when $HOST has
# no gateway — that's the only bit of logic; a real test wouldn't need the guard.
if curl -sS -o /dev/null --max-time 3 "https://$HOST/" 2>/dev/null; then
  curl --fail-with-body -sS "https://$HOST/" >/dev/null
else
  echo "  (skip) no gateway reachable at https://$HOST/ — example bundle has no route"
fi
