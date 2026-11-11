/// Minimal stdio MCP server (Python 3, no dependencies) that bridges AI apps to the local Developer API.
enum MCPScript {
    static let source = #"""
#!/usr/bin/env python3
"""NotchHub MCP bridge — exposes notch tools to MCP clients over stdio."""
import json, os, sys, urllib.request

URL = os.environ.get("NOTCHHUB_URL", "http://127.0.0.1:9999")
TOKEN = os.environ.get("NOTCHHUB_TOKEN", "")

TOOLS = [
    {"name": "show_island", "description": "Show a transient island in the Mac notch",
     "inputSchema": {"type": "object", "properties": {"title": {"type": "string"}, "subtitle": {"type": "string"}, "icon": {"type": "string", "description": "SF Symbol name"}}, "required": ["title"]}},
    {"name": "set_activity", "description": "Set or clear a persistent live activity in the collapsed notch",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "text": {"type": "string"}, "icon": {"type": "string"}, "clear": {"type": "boolean"}}, "required": ["id"]}},
    {"name": "start_timer", "description": "Start a countdown timer", "inputSchema": {"type": "object", "properties": {"minutes": {"type": "number"}}, "required": ["minutes"]}},
    {"name": "keep_awake", "description": "Keep the Mac awake", "inputSchema": {"type": "object", "properties": {"on": {"type": "boolean"}, "minutes": {"type": "number"}}}},
    {"name": "status", "description": "Get notch status (now playing, timer, keep-awake)", "inputSchema": {"type": "object", "properties": {}}},
]
ROUTES = {"show_island": ("POST", "/v1/island"), "set_activity": ("POST", "/v1/activity"), "start_timer": ("POST", "/v1/timer"),
          "keep_awake": ("POST", "/v1/keepawake"), "status": ("GET", "/v1/status")}

def call(method, path, body=None):
    req = urllib.request.Request(URL + path, method=method, data=json.dumps(body or {}).encode() if method == "POST" else None,
                                 headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode()

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    mid, method = msg.get("id"), msg.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "notchhub", "version": "1.0"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        p = msg.get("params", {})
        m, path = ROUTES.get(p.get("name"), ("GET", "/v1/status"))
        try:
            text = call(m, path, p.get("arguments"))
            send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}]}})
        except Exception as e:
            send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": str(e)}], "isError": True}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
"""#
}
