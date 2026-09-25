# Convert an Okta AI-Agent private key from JWK (JSON) to PKCS#8 PEM.
#
# WHY THIS EXISTS: on docs/OKTA-SETUP.md step 4 you generate a key pair on the AI Agent
# object and Okta shows you the PRIVATE KEY EXACTLY ONCE. Depending on where you copy it from you get
# either a PEM or a JWK. The gateway's `privateKeyJwt.signingKeyRef` wants a PEM, so a JWK has to be
# converted before 12-resource-as-config.sh will accept it.
#
# Usage:
#   helpers/xaa-jwk-to-pem.sh agent-a.jwk.json          # also writes agent-a.jwk.pem
#   helpers/xaa-jwk-to-pem.sh agent-a.jwk.json > a.pem  # stdout only
#
# Accepts a bare JWK object or a {"keys":[…]} set; with several keys it takes the first PRIVATE one.
set -euo pipefail

SRC="${1:?usage: xaa-jwk-to-pem.sh <jwk.json>  — the private key JSON Okta displayed once}"
[ -r "$SRC" ] || { echo "✗ cannot read ${SRC}" >&2; exit 1; }

# Already a PEM? Say so rather than emitting a confusing JSON parse error.
if grep -q 'BEGIN .*PRIVATE KEY' "$SRC"; then
  echo "↷ ${SRC} is already a PEM — point XAA_AGENT_*_PRIVATE_KEY straight at it." >&2
  exit 0
fi

OUT=""
[ -t 1 ] && OUT="${SRC%.json}.pem"

# uv keeps this dependency-free (system python is externally managed — CLAUDE.md).
PEM=$(SRC="$SRC" uv run --quiet --python 3.12 --with 'pyjwt[crypto]>=2.8,<3' - <<'PY'
import json, os, sys

from cryptography.hazmat.primitives import serialization
from jwt.algorithms import ECAlgorithm, RSAAlgorithm

raw = json.load(open(os.environ["SRC"]))
keys = raw.get("keys", [raw]) if isinstance(raw, dict) else raw
private = [k for k in keys if isinstance(k, dict) and "d" in k]
if not private:
    sys.exit(
        "✗ no PRIVATE key in this JWK (no `d` parameter). Okta shows the private key only once, at "
        "generation time — a downloaded public JWKS will not do. Regenerate the key pair on the "
        "agent if you no longer have it."
    )

jwk = private[0]
kty = jwk.get("kty")
# RSA covers the CRD's RS*/PS* algs, EC covers ES*.
loader = {"RSA": RSAAlgorithm, "EC": ECAlgorithm}.get(kty)
if loader is None:
    sys.exit(f"✗ unsupported kty={kty!r} — expected RSA or EC")

key = loader.from_jwk(json.dumps(jwk))
sys.stdout.write(
    key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()
)

# The kid is what `privateKeyJwt.kid` should carry when Okta registered more than one key.
if jwk.get("kid"):
    print(f"↳ kid={jwk['kid']} — set XAA_AGENT_KEY_KID if the agent has multiple keys", file=sys.stderr)
PY
) || exit 1

printf '%s\n' "$PEM"
if [ -n "$OUT" ]; then
  printf '%s\n' "$PEM" > "$OUT"
  chmod 600 "$OUT"
  echo "✓ wrote ${OUT} (mode 600) — set XAA_AGENT_*_PRIVATE_KEY to that path" >&2
fi
