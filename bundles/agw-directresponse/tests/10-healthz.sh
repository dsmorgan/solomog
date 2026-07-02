# /healthz returns {"status":"ok"} via a directResponse policy — deterministic, no backend,
# no API cost. The ideal portable curl test. Copy-paste: `export HOST=agw.<cluster>.test`.
# --fail-with-body → any HTTP >=400 (e.g. route/policy not applied) fails the test.
curl --fail-with-body -sS "https://$HOST/healthz"
