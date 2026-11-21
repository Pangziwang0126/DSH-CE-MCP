import json
import sys
import urllib.request

URL = "http://127.0.0.1:8787/mcp"
FAIL = []


def post(payload, timeout=60):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        URL, data=data,
        headers={"Content-Type": "application/json",
                 "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode("utf-8")


def rpc(method, params=None, _id=1, timeout=60):
    status, raw = post({"jsonrpc": "2.0", "id": _id, "method": method,
                        "params": params or {}}, timeout)
    if not raw:
        return {}
    return json.loads(raw)


def call(name, args=None, timeout=120):
    r = rpc("tools/call", {"name": name, "arguments": args or {}}, 99, timeout)
    res = r.get("result", {})
    if not res:
        return {"ok": False, "error": "no result: %r" % r}
    txt = res["content"][0]["text"]
    if res.get("isError"):
        return {"ok": False, "error": txt}
    try:
        return json.loads(txt)
    except Exception:
        return {"ok": True, "raw": txt}


def check(label, cond, detail=""):
    if not cond:
        FAIL.append(label)
    print("[%s] %s %s" % ("PASS" if cond else "FAIL", label, detail))


# ============ 阶段一：协议层 ============
r = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "yq-test", "version": "1"}})
check("initialize", r["result"]["serverInfo"]["name"] == "yq-ce-mcp")
check("initialize.protocol", r["result"]["protocolVersion"] == "2025-06-18")

st, raw = post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
check("notification.202", st == 202 and raw == "")

r = rpc("tools/list", {}, 2)
tools = r["result"]["tools"]
check("tools/list", len(tools) == 30, "count=%d" % len(tools))
ok_schema = all(t["inputSchema"]["type"] == "object" for t in tools)
bad_req = [t["name"] for t in tools
           if "required" in t["inputSchema"] and not isinstance(t["inputSchema"]["required"], list)]
check("tools/list.schema", ok_schema and not bad_req, "bad required: %s" % bad_req)

s = call("ce_status")
check("ce_status", s.get("server", {}).get("running") is True,
      "ce=%s lua=%s" % (s.get("ce", {}).get("version"), s.get("ce", {}).get("lua")))

p = call("process_list", {"filter": "note"})
procs = p.get("processes", [])
check("process_list", p.get("ok") and isinstance(procs, list) and len(procs) > 0,
      "found=%d %s" % (len(procs), procs[:1]))

v = call("lua_eval", {"code": "return 6*7"})
check("lua_eval", v.get("value") == 42)

v = call("lua_eval", {"code": "return '中文测试'"})
check("lua_eval.utf8", v.get("value") == "中文测试", "-> %r" % v.get("value"))

# ============ 阶段二：真实进程操作 ============
op = call("process_open", {"name": "notepad.exe"})
check("process_open", op.get("ok") is True, "%s" % op.get("error", "pid=%s" % op.get("pid")))

if op.get("ok"):
    mods = call("module_list", {"filter": "notepad"})
    check("module_list", mods.get("ok") and mods.get("count", 0) >= 1,
          "modules=%s" % [m["name"] for m in mods.get("modules", [])][:3])
    main = (mods.get("modules") or [{}])[0]
    base = main.get("address_hex")
    check("module_list.base", bool(base) and main.get("size", 0) > 0, "base=%s size=%s" % (base, main.get("size")))

    ar = call("address_resolve", {"expression": "notepad.exe"})
    check("address_resolve", ar.get("ok") is True, "-> %s" % ar.get("address"))

    mr = call("memory_read", {"address": "notepad.exe", "type": "bytes", "size": 2})
    check("memory_read.bytes", mr.get("ok") and mr.get("hex") == "4D 5A", "-> %s" % mr.get("hex"))

    md = call("memory_dump", {"address": "notepad.exe", "size": 64})
    check("memory_dump", md.get("ok") and "4D 5A" in (md.get("dump") or ""),
          "first line: %s" % (md.get("dump") or "").split("\n")[0][:60])

    mq = call("memory_read", {"address": "notepad.exe", "type": "word"})
    check("memory_read.word", mq.get("ok") and mq.get("value") == 0x5A4D, "-> %r" % mq.get("value"))

    dis = call("disassemble", {"address": "notepad.exe", "count": 3})
    check("disassemble", dis.get("ok") and dis.get("count", 0) >= 1,
          "first: %s" % (dis.get("instructions") or [{}])[0].get("instruction", ""))

    rg = call("memory_regions", {"limit": 3})
    check("memory_regions", rg.get("ok") and rg.get("count", 0) >= 1,
          "regions=%d" % rg.get("count", 0))

    aob = call("aob_scan", {"pattern": "4D 5A", "module": "notepad.exe", "limit": 3})
    check("aob_scan", aob.get("ok") and aob.get("count", 0) >= 1,
          "hits=%d %s" % (aob.get("count", 0),
                          [m["address"] for m in aob.get("matches", [])][:3]))

    ta = call("table_add", {"description": "yq-test-dword", "address": "notepad.exe", "type": "dword"})
    check("table_add", ta.get("ok") is True, str(ta.get("error", "")))

    tl = call("table_list", {})
    names = [e["description"] for e in tl.get("entries", [])]
    check("table_list", tl.get("ok") and "yq-test-dword" in names, "entries=%s" % names[:5])

    idx = None
    for e in tl.get("entries", []):
        if e["description"] == "yq-test-dword":
            idx = e["index"]
    if idx:
        # 只改描述，不往目标进程的真实内存里写值
        tu = call("table_update", {"index": idx, "new_description": "yq-test-renamed"})
        check("table_update", tu.get("ok") is True, str(tu.get("error", "")))
        tr = call("table_remove", {"index": idx})
        check("table_remove", tr.get("ok") is True, str(tr.get("error", "")))
    else:
        check("table_update", False, "record not found")

    # 读写验证走 CE 在目标进程里分配的一块空白内存，不碰 PE 头
    alloc = call("lua_eval", {"code": "return allocateMemory(64)"})
    aaddr = alloc.get("value")
    if isinstance(aaddr, int) and aaddr > 0:
        wr = call("memory_write", {"address": hex(aaddr), "type": "dword", "value": "305419896"})
        rd = call("memory_read", {"address": hex(aaddr), "type": "dword"})
        check("memory_write", wr.get("ok") is True and rd.get("value") == 305419896,
              "wrote 0x12345678, read %r" % rd.get("value"))

        pm = call("memory_patch", {"address": hex(aaddr), "hex": "DE AD BE EF"})
        rd2 = call("memory_read", {"address": hex(aaddr), "type": "dword"})
        check("memory_patch", pm.get("ok") is True and rd2.get("value") == 0xEFBEADDE,
              "after patch %r (0x%X)" % (rd2.get("value"), rd2.get("value") or 0))
    else:
        check("memory_write", False, "allocateMemory failed: %r" % alloc)

    # 数值扫描（限主模块，几秒内应完成）
    try:
        vs = call("value_scan", {"value": "0", "type": "dword", "limit": 3}, timeout=180)
        check("value_scan", vs.get("ok") is True and vs.get("total", 0) >= 1,
              "total=%s" % vs.get("total"))
        call("scan_reset")
    except Exception as e:
        check("value_scan", False, str(e))
else:
    print("!! 跳过阶段二：没有打开进程")

print("\n=== %d failure(s) ===" % len(FAIL))
if FAIL:
    print("failed: " + ", ".join(FAIL))
    sys.exit(1)
