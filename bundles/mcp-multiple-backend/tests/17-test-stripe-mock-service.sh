# MCP handshake test: connect through the gateway, initialize, list tools.
# Uses the `mcp` Python SDK, run via `uv` so the dependency lives in an ephemeral, cached,
# isolated env — no venv to manage, nothing installed into system Python (which is PEP 668
# externally-managed and would reject `pip install` anyway). `brew install uv` (setup.sh does this).
#   --with mcp         inject the SDK for this run only (cached after first resolve)
#   --with truststore  use the OS trust store for TLS, not Python's bundled certifi — so the
#                      gateway's mkcert cert (its root CA is in the macOS keychain after
#                      `mkcert -install`, which `expose` runs) is trusted. Without this, the
#                      uv-managed Python fails with CERTIFICATE_VERIFY_FAILED on the https URL.
#   --python 3.12      pin a known-good interpreter (uv downloads a managed CPython if needed)
if ! command -v uv >/dev/null 2>&1; then
  echo "✗ uv not found — install it:  brew install uv   (or re-run: solomog setup)" >&2
  exit 1
fi

uv run --with mcp --with truststore --python 3.12 - <<'PY'
import truststore; truststore.inject_into_ssl()   # trust the OS keychain (mkcert CA) for TLS
import os, sys, asyncio
from mcp.client.streamable_http import streamablehttp_client
from mcp import ClientSession

host = os.environ["HOST"]

async def main():
    try:
        async with streamablehttp_client("https://" + host + "/stripe") as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                print(f"✓ Connected — {len(tools.tools)} tool(s) found")
                for tool in tools.tools:
                    desc = (tool.description or "").strip().splitlines()
                    desc = desc[0] if desc else ""
                    params = list((tool.inputSchema or {}).get("properties", {}).keys())
                    print(f"  - {tool.name}: {desc}" if desc else f"  - {tool.name}")
                    if params:
                        print(f"      params: {', '.join(params)}")
                return 0
    except BaseException as e:
        # The SDK runs I/O in an asyncio TaskGroup, which re-raises failures as an
        # ExceptionGroup ("unhandled errors in a TaskGroup") that hides the real cause.
        # Unwrap nested .exceptions so the actual error (TLS, 404, protocol) is visible.
        def unwrap(exc, depth=0):
            print(f"✗ FAIL: {'  ' * depth}{type(exc).__name__}: {exc}", file=sys.stderr)
            for sub in getattr(exc, "exceptions", []):
                unwrap(sub, depth + 1)
        unwrap(e)
        return 1

sys.exit(asyncio.run(main()))
PY
