# Print a private_key_jwt client assertion for leg 1 (RFC 7523 §2.2).
#
# Usage:  bash helpers/xaa-client-assertion.sh <client_id> <pem_path> <token_endpoint_url>
#
# WHY A HELPER: it lets `tests/08` authenticate leg 1 either way (client secret vs private_key_jwt)
# without duplicating the signing, and it makes the assertion inspectable by hand when Okta rejects it
# — paste the output into jwt.io and check `aud` first, that is the usual mistake.
#
# `aud` MUST be the token ENDPOINT url, not the issuer. Okta answers a wrong aud with a bare
# 401 invalid_client and no hint, which is indistinguishable from a wrong key.
#
# KID: pass KID_OVERRIDE (callers set it per agent) or XAA_AGENT_KEY_KID as a global default. Okta says
# `The client_assertion JWT kid is invalid` both when the kid is wrong AND when the key does not belong
# to that client at all — so on that error, check you are using the right OBJECT's key before hunting
# for a kid. Agents A and B necessarily have different keys, hence different kids.
set -euo pipefail

CLIENT_ID="${1:?usage: xaa-client-assertion.sh <client_id> <pem_path> <token_endpoint_url>}"
PEM="${2:?missing pem path}"
AUD="${3:?missing token endpoint url}"
[ -r "$PEM" ] || { echo "✗ cannot read PEM ${PEM}" >&2; exit 1; }

CLIENT_ID="$CLIENT_ID" PEM="$PEM" AUD="$AUD" \
  KID="${KID_OVERRIDE:-${XAA_AGENT_KEY_KID:-}}" ALG="${XAA_AGENT_KEY_ALG:-RS256}" \
  uv run --quiet --python 3.12 --with 'pyjwt[crypto]>=2.8,<3' python -c '
import os, time, uuid, jwt
now = int(time.time())
cid = os.environ["CLIENT_ID"]
kid = os.environ.get("KID") or None
print(jwt.encode(
    {"iss": cid, "sub": cid, "aud": os.environ["AUD"], "jti": str(uuid.uuid4()),
     "iat": now, "exp": now + 300},
    open(os.environ["PEM"]).read(),
    algorithm=os.environ["ALG"],
    headers={"kid": kid} if kid else None,
))'
