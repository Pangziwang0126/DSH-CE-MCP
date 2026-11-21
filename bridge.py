#!/usr/bin/env python3
"""stdio <-> HTTP bridge for YQ CE-MCP.

For MCP clients that only speak stdio (Claude Desktop and friends).
The Cheat Engine side stays an HTTP server; this process just relays.

    YQ_CE_MCP_URL   override the endpoint (default http://127.0.0.1:8787/mcp)

No third-party dependencies: stdlib only.
"""
import json
import os
import sys
import urllib.error
import urllib.request

ENDPOINT = os.environ.get("YQ_CE_MCP_URL", "http://127.0.0.1:8787/mcp")
TIMEOUT = float(os.environ.get("YQ_CE_MCP_TIMEOUT", "300"))


def post(payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        ENDPOINT,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read().decode("utf-8")


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception as exc:
            sys.stderr.write("yq-bridge: bad json: %s\n" % exc)
            continue

        try:
            body = post(msg)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:400]
            sys.stderr.write("yq-bridge: http %s %s\n" % (exc.code, detail))
            if "id" in msg:
                emit({"jsonrpc": "2.0", "id": msg["id"],
                      "error": {"code": -32603, "message": "CE MCP HTTP %s: %s" % (exc.code, detail)}})
            continue
        except Exception as exc:
            sys.stderr.write("yq-bridge: unreachable: %s\n" % exc)
            if "id" in msg:
                emit({"jsonrpc": "2.0", "id": msg["id"],
                      "error": {"code": -32603,
                                "message": "Cheat Engine MCP unreachable at %s (%s). "
                                           "Is Cheat Engine running with the plugin loaded?" % (ENDPOINT, exc)}})
            continue

        if body.strip():
            sys.stdout.write(body.strip() + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
