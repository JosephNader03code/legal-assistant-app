# Fill sl_request_log.tokens_in / tokens_out with the REAL token counts from n8n execution data.
# n8n records tokenUsage on every LLM sub-node run, but the workflow itself cannot read it, so this runs
# from a Claude session that has the n8n MCP token (proxy-injected for joe03.app.n8n.cloud).
# Usage: backfill_tokens.py EXEC_ID [EXEC_ID ...]   -> prints SQL to run (sl_log_set_tokens per execution)
import json, sys, urllib.request
MCP = "https://joe03.app.n8n.cloud/mcp-server/http"
WORKFLOWS = ["Urs8CLRcjtJbkZ8G"]  # main workflow (chat + mind map)

def call(name, args):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}}).encode()
    req = urllib.request.Request(MCP, body, {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                                              "Authorization": "Bearer proxy-injected"})
    raw = urllib.request.urlopen(req, timeout=120).read().decode()
    line = next(l for l in raw.splitlines() if l.startswith("data: "))
    return json.loads(json.loads(line[6:])["result"]["content"][0]["text"])

def tokens(exec_id):
    t_in = t_out = 0
    for wf in WORKFLOWS:
        try:
            ex = call("get_workflow_execution", {"workflowId": wf, "executionId": str(exec_id), "includeData": True})
        except Exception:
            continue
        for runs in ex.get("data", {}).get("resultData", {}).get("runData", {}).values():
            for r in runs:
                for item in (r.get("data", {}).get("ai_languageModel") or [[]])[0]:
                    u = (item.get("json") or {}).get("tokenUsage") or {}
                    t_in += u.get("promptTokens", 0) or 0
                    t_out += u.get("completionTokens", 0) or 0
        return t_in, t_out
    return None

for e in sys.argv[1:]:
    r = tokens(e)
    if r: print(f"select sl_log_set_tokens('{e}', {r[0]}, {r[1]});  -- in={r[0]} out={r[1]}")
