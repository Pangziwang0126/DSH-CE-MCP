--[[===========================================================================
  YQ CE-MCP  -  MCP server for Cheat Engine
  ---------------------------------------------------------------------------
  Single file. Pure Lua. No compiler, no external process, no dependencies.

  Install : copy this file into  <Cheat Engine>\autorun\  and restart CE.
  Endpoint: http://127.0.0.1:8787/mcp

  Note: CE loads Lua sources through the system ANSI code page, so every
  string in this file is ASCII on purpose. Keep it that way.
=============================================================================]]

if _G.__YQ_CEMCP and _G.__YQ_CEMCP.stop then
  pcall(_G.__YQ_CEMCP.stop)
end

local YQ = {}
_G.__YQ_CEMCP = YQ
YQ.VERSION = "1.0.0"

-------------------------------------------------------------------------------
-- 0. Config
-------------------------------------------------------------------------------
local CFG = {
  host           = "127.0.0.1",
  port           = 8787,
  poll_ms        = 20,
  max_body       = 4 * 1024 * 1024,
  client_timeout = 8,
  log_file       = (os.getenv("TEMP") or ".") .. "\\yq-ce-mcp.log",
  log_ring       = 300,
  mark_title     = true,
  ai_window_sec  = 120,    -- how long a request keeps the "AI connected" light on
  verbose        = false,
}

-------------------------------------------------------------------------------
-- 1. Logging
-------------------------------------------------------------------------------
local LOG = {}
local function log(msg)
  local line = os.date("%H:%M:%S ") .. tostring(msg)
  LOG[#LOG + 1] = line
  while #LOG > CFG.log_ring do table.remove(LOG, 1) end
  local f = io.open(CFG.log_file, "a")
  if f then f:write(line, "\n"); f:close() end
end

-------------------------------------------------------------------------------
-- 2. JSON
-------------------------------------------------------------------------------
local Json = {}

local NULL = setmetatable({}, { __tostring = function() return "null" end })
Json.null = NULL

local str_filter = function(s) return s end
Json.set_string_filter = function(fn) str_filter = fn end

local OBJECT_MT = { __json_object = true }
local function O(t) return setmetatable(t or {}, OBJECT_MT) end
Json.object = O

local ESC_MAP = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
  ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function json_escape(s)
  return (s:gsub('[%z\1-\31\\"]', function(c)
    local e = ESC_MAP[c]
    if e then return e end
    return string.format("\\u%04x", string.byte(c))
  end))
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  if n == 0 then return false end
  return n == #t
end

local encode_value

local function encode_table(t, out, indent, depth)
  local pad = indent and string.rep("  ", depth) or ""
  local pad2 = indent and string.rep("  ", depth + 1) or ""
  local nl = indent and "\n" or ""
  local sep = indent and ": " or ":"

  if t == NULL then out[#out + 1] = "null"; return end

  local forced_object = (getmetatable(t) == OBJECT_MT)

  -- #t is always 0 for string-keyed tables, so an empty table has to be told
  -- apart with next(); otherwise every object would encode as [].
  if not forced_object and (is_array(t) or next(t) == nil) then
    if #t == 0 then out[#out + 1] = "[]"; return end
    out[#out + 1] = "["
    for i = 1, #t do
      out[#out + 1] = nl .. pad2
      encode_value(t[i], out, indent, depth + 1)
      if i < #t then out[#out + 1] = "," end
    end
    out[#out + 1] = nl .. pad .. "]"
  else
    local keys, seen = {}, {}
    for k in pairs(t) do
      if type(k) == "string" or type(k) == "number" then
        local ks = tostring(k)
        if not seen[ks] then seen[ks] = true; keys[#keys + 1] = k end
      end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    if #keys == 0 then out[#out + 1] = "{}"; return end
    out[#out + 1] = "{"
    for i = 1, #keys do
      local k = keys[i]
      out[#out + 1] = nl .. pad2 .. '"' .. json_escape(tostring(k)) .. '"' .. sep
      encode_value(t[k], out, indent, depth + 1)
      if i < #keys then out[#out + 1] = "," end
    end
    out[#out + 1] = nl .. pad .. "}"
  end
end

encode_value = function(v, out, indent, depth)
  local tv = type(v)
  if v == nil or v == NULL then
    out[#out + 1] = "null"
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    local iv = math.tointeger(v)
    if iv then
      out[#out + 1] = string.format("%d", iv)
    else
      local s = string.format("%.14g", v)
      if s == "inf" then s = "1e999"
      elseif s == "-inf" then s = "-1e999"
      elseif s ~= s then s = "null" end
      out[#out + 1] = s
    end
  elseif tv == "string" then
    out[#out + 1] = '"' .. json_escape(str_filter(v)) .. '"'
  elseif tv == "table" then
    encode_table(v, out, indent, depth)
  else
    out[#out + 1] = '"' .. json_escape(tostring(v)) .. '"'
  end
end

function Json.encode(v, pretty)
  local out = {}
  encode_value(v, out, pretty and true or false, 0)
  return table.concat(out)
end

-- --- decode -------------------------------------------------------------
local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
  end
  if cp < 0x10000 then
    return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end
  return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
                     0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

local decode_value

local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return j + 1
end

local function decode_string(s, i)
  local buf = {}
  i = i + 1
  while true do
    local c = s:sub(i, i)
    if c == "" then error("unterminated string") end
    if c == '"' then return table.concat(buf), i + 1 end
    if c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local cp = tonumber(s:sub(i + 2, i + 5), 16) or 0
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
          local cp2 = tonumber(s:sub(i + 2, i + 5), 16) or 0
          if cp2 >= 0xDC00 and cp2 <= 0xDFFF then
            cp = 0x10000 + ((cp - 0xD800) << 10) + (cp2 - 0xDC00)
            i = i + 6
          end
        end
        buf[#buf + 1] = utf8_char(cp)
      else
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
                      ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        buf[#buf + 1] = map[e] or e
        i = i + 2
      end
    else
      local j = s:find('["\\]', i) or (#s + 1)
      buf[#buf + 1] = s:sub(i, j - 1)
      i = j
    end
  end
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "" then error("unexpected end") end
  if c == '"' then return decode_string(s, i) end
  if c == "{" then
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      local k; k, i = decode_string(s, skip_ws(s, i))
      i = skip_ws(s, i)
      if s:sub(i, i) ~= ":" then error("expected ':' at " .. i) end
      local v; v, i = decode_value(s, i + 1)
      obj[k] = v
      i = skip_ws(s, i)
      local ch = s:sub(i, i)
      if ch == "," then i = i + 1
      elseif ch == "}" then return obj, i + 1
      else error("expected ',' or '}' at " .. i) end
    end
  end
  if c == "[" then
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local v; v, i = decode_value(s, i)
      arr[#arr + 1] = v
      i = skip_ws(s, i)
      local ch = s:sub(i, i)
      if ch == "," then i = i + 1
      elseif ch == "]" then return arr, i + 1
      else error("expected ',' or ']' at " .. i) end
    end
  end
  if c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4 end
  if c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5 end
  if c == "n" and s:sub(i, i + 3) == "null" then return NULL, i + 4 end
  local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if num and #num > 0 then
    local n = tonumber(num)
    if n then
      return math.tointeger(n) or n, i + #num
    end
  end
  error("unexpected token at " .. i)
end

function Json.decode(s)
  local v, i = decode_value(s, 1)
  i = skip_ws(s, i)
  if i <= #s then error("trailing garbage at " .. i) end
  return v
end

-------------------------------------------------------------------------------
-- 3. Win32 bridge: drive Winsock from inside CE's own Lua state
--    CE ships no socket library, but getAddressSafe() can resolve ws2_32
--    exports of the CE process itself and executeCodeLocalEx() can call them.
-------------------------------------------------------------------------------
local W = { ok = false }

local function htons(p) return ((p & 0xFF) << 8) | ((p >> 8) & 0xFF) end

local SYMS = {
  "WSAStartup", "WSACleanup", "socket", "bind", "listen", "accept",
  "recv", "send", "closesocket", "ioctlsocket",
  "MultiByteToWideChar", "WideCharToMultiByte",
  "LoadImageA", "SendMessageA",
}

function W.init()
  local net = createMemoryStream(); net.Size = 65536
  local cnv = createMemoryStream(); cnv.Size = 65536
  W.net, W.cnv = net, cnv
  W.P = net.Memory
  W.C = cnv.Memory
  W.RX      = W.P + 0x0800
  W.TX      = W.P + 0x2800
  W.TXSIZE  = 0x8000
  W.SA      = W.P + 0x0400
  W.NONBLK  = W.P + 0x0440
  W.WSADATA = W.P + 0x0000

  W.sym = {}
  for _, n in ipairs(SYMS) do
    local a = getAddressSafe(n, true)
    if type(a) ~= "number" or a == 0 then
      return false, "cannot resolve symbol inside CE process: " .. n
    end
    W.sym[n] = a
  end
  if CFG.verbose then
    log(string.format("buffers: P=0x%X size=%d TX=0x%X", W.P, net.Size, W.TX))
  end
  W.ok = true
  return true
end

local function ccall(name, ...)
  local args = { ... }
  local params = {}
  for i = 1, #args do
    params[i] = { type = 0, value = args[i] }
  end
  return executeCodeLocalEx(W.sym[name], table.unpack(params))
end

local function utf8_valid(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    if c < 0x80 then i = i + 1
    elseif c >= 0xC2 and c <= 0xDF then
      local b = s:byte(i + 1)
      if not b or b < 0x80 or b > 0xBF then return false end
      i = i + 2
    elseif c >= 0xE0 and c <= 0xEF then
      local b2, b3 = s:byte(i + 1), s:byte(i + 2)
      if not b2 or not b3 or b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then return false end
      if c == 0xE0 and b2 < 0xA0 then return false end
      if c == 0xED and b2 > 0x9F then return false end
      i = i + 3
    elseif c >= 0xF0 and c <= 0xF4 then
      local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
      if not b2 or not b3 or not b4 then return false end
      if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then return false end
      i = i + 4
    else
      return false
    end
  end
  return true
end

-- Target-process strings come back in the system code page; JSON must be UTF-8.
local function to_utf8(s)
  if type(s) ~= "string" or s == "" then return s end
  if utf8_valid(s) then return s end
  if not W.ok then return s end
  local ok, out = pcall(function()
    local src = W.C + 0x0000
    local wbuf = W.C + 0x4000
    local ubuf = W.C + 0x8000
    writeStringLocal(src, s)
    local wl = ccall("MultiByteToWideChar", 0, 0, src, -1, wbuf, 0x2000)
    if not wl or wl <= 0 then return s end
    local ul = ccall("WideCharToMultiByte", 65001, 0, wbuf, -1, ubuf, 0x2000, 0, 0)
    if not ul or ul <= 0 then return s end
    return readStringLocal(ubuf, ul - 1) or s
  end)
  if ok and type(out) == "string" and out ~= "" then return out end
  return s
end

YQ.to_utf8 = to_utf8
Json.set_string_filter(to_utf8)

-------------------------------------------------------------------------------
-- 4. Cheat Engine helpers
-------------------------------------------------------------------------------
local CE = {}

local function addr_of(v)
  if type(v) == "number" then return math.tointeger(v) or v end
  if type(v) ~= "string" then return nil end
  local s = v:match("^%s*(.-)%s*$")
  if s == "" then return nil end
  local n = tonumber(s)
  if n then return math.tointeger(n) or n end
  local ok, a = pcall(getAddressSafe, s)
  if ok and type(a) == "number" and a > 0 then return a end
  local ok2, a2 = pcall(getAddress, s)
  if ok2 and type(a2) == "number" and a2 > 0 then return a2 end
  return nil
end
CE.addr_of = addr_of

local TYPES = {
  byte    = { read = readByte,          write = writeByte,         size = 1 },
  word    = { read = readSmallInteger,  write = writeSmallInteger, size = 2 },
  dword   = { read = readInteger,       write = writeInteger,      size = 4 },
  qword   = { read = readQword,         write = writeQword,        size = 8 },
  float   = { read = readFloat,         write = writeFloat,        size = 4 },
  double  = { read = readDouble,        write = writeDouble,       size = 8 },
  pointer = { read = readPointer,       write = writePointer,      size = 8 },
}
CE.TYPES = TYPES

local function hexdump(base, size, bytes)
  local lines = {}
  for off = 0, size - 1, 16 do
    local chunk, ascii = {}, {}
    for k = 0, 15 do
      local idx = off + k + 1
      if idx <= size then
        local b = bytes[idx]
        chunk[#chunk + 1] = string.format("%02X", b)
        ascii[#ascii + 1] = (b >= 32 and b < 127) and string.char(b) or "."
      else
        chunk[#chunk + 1] = "  "
        ascii[#ascii + 1] = " "
      end
    end
    lines[#lines + 1] = string.format("%016X  %s  |%s|",
      base + off, table.concat(chunk, " "), table.concat(ascii))
  end
  return table.concat(lines, "\n")
end

local MOD_CACHE = { t = 0, pid = nil, list = nil }

function CE.modules()
  local okp, pid = pcall(getOpenedProcessID)
  if not okp then pid = -1 end
  local now = os.time()
  if MOD_CACHE.list and MOD_CACHE.pid == pid and (now - MOD_CACHE.t) < 3 then
    return MOD_CACHE.list
  end

  local ok, list = pcall(enumModules)
  if not ok or type(list) ~= "table" then return {} end

  local cur = tostring(process or ""):lower()
  local out = {}
  for _, m in ipairs(list) do
    -- enumModules has no size field; getModuleSize is the only source
    local sz = 0
    local oksz, s = pcall(getModuleSize, m.Name)
    if oksz and type(s) == "number" then sz = s end
    local name = to_utf8(tostring(m.Name or ""))
    out[#out + 1] = {
      name    = name,
      address = math.tointeger(m.Address) or m.Address,
      size    = sz,
      is64    = m.Is64Bit and true or false,
      main    = (name:lower() == cur and cur ~= ""),
      path    = m.PathToFile and to_utf8(tostring(m.PathToFile)) or nil,
    }
  end
  table.sort(out, function(a, b) return a.address < b.address end)
  MOD_CACHE = { t = now, pid = pid, list = out }
  return out
end

local function module_containing(addr)
  if type(addr) ~= "number" then return nil, nil end
  for _, m in ipairs(CE.modules()) do
    if m.size and m.size > 0 then
      if addr >= m.address and addr < m.address + m.size then
        return m, addr - m.address
      end
    elseif addr == m.address then
      return m, 0
    end
  end
  return nil, nil
end
CE.module_containing = module_containing

function CE.status()
  local pid = nil
  local ok, p = pcall(getOpenedProcessID)
  if ok then pid = p end
  return {
    server = {
      endpoint = "http://" .. CFG.host .. ":" .. CFG.port .. "/mcp",
      version  = YQ.VERSION,
      running  = YQ.running and true or false,
    },
    ce = {
      version = (function() local o, v = pcall(getCEVersion); return o and v or nil end)(),
      lua     = _VERSION,
      arch    = (function()
        local o, v = pcall(targetIs64Bit)
        if not o then return "unknown" end
        return v and "x64" or "x86"
      end)(),
    },
    process = {
      pid     = (pid and pid ~= 0) and pid or nil,
      name    = (pid and pid ~= 0) and to_utf8(tostring(process or "")) or nil,
      modules = #CE.modules(),
    },
  }
end

-------------------------------------------------------------------------------
-- 5. Tools
-------------------------------------------------------------------------------
local TOOLS = {}
local TOOLS_BY_NAME = {}

local function tool(name, description, schema, fn)
  local t = { name = name, description = description, inputSchema = schema, fn = fn }
  TOOLS[#TOOLS + 1] = t
  TOOLS_BY_NAME[name] = t
end

local function S(props, required)
  local t = { type = "object", properties = O(props or {}) }
  if required and #required > 0 then t.required = required end
  return t
end

local function P(desc, typ, extra)
  local t = { type = typ or "string", description = desc }
  if extra then for k, v in pairs(extra) do t[k] = v end end
  return t
end

-- --- process ------------------------------------------------------------
tool("ce_status",
  "Report Cheat Engine version, Lua version, the attached process, the MCP endpoint and whether the AI client is currently connected. Call this first to confirm the link is alive.",
  S({}), function()
    return YQ.status()
  end)

tool("process_list",
  "List system processes, optionally filtered by a name substring. Returns pid and name.",
  S({ filter = P("name substring to match, case-insensitive; omit for all") }), function(a)
    local ok, list = pcall(getProcesslist)
    if not ok or type(list) ~= "table" then
      return { ok = false, error = "could not enumerate processes: " .. tostring(list) }
    end
    local f = a.filter and a.filter:lower() or nil
    local out = {}
    -- getProcesslist() yields a pid -> name map, not an array
    for pid, pname in pairs(list) do
      local name = to_utf8(tostring(pname))
      if not f or name:lower():find(f, 1, true) then
        out[#out + 1] = { pid = pid, name = name }
      end
    end
    table.sort(out, function(x, y) return tostring(x.name):lower() < tostring(y.name):lower() end)
    if #out > 400 then
      local cut = {}
      for i = 1, 400 do cut[i] = out[i] end
      out = cut
    end
    return { ok = true, count = #out, processes = out }
  end)

tool("process_open",
  "Attach Cheat Engine to a process by name (include .exe) or by pid.",
  S({ name = P("process name, e.g. game.exe"), pid = P("process id", "integer") }), function(a)
    local pid = a.pid
    if not pid and a.name then
      local ok, p = pcall(getProcessIDFromProcessName, a.name)
      if ok and p and p ~= 0 then pid = p end
    end
    if not pid then return { ok = false, error = "process not found: " .. tostring(a.name) } end
    local ok, err = pcall(openProcess, pid)
    if not ok then return { ok = false, error = "attach failed: " .. tostring(err) } end
    MOD_CACHE = { t = 0, pid = nil, list = nil }
    local ok2, cur = pcall(getOpenedProcessID)
    return { ok = true, pid = pid, name = to_utf8(tostring(process or "")),
             attached = ok2 and cur or nil }
  end)

tool("process_control",
  "Pause or resume the attached process.",
  S({ action = P("pause or resume", "string", { enum = { "pause", "resume" } }) }, { "action" }),
  function(a)
    if a.action == "pause" then pcall(pause) else pcall(unpause) end
    return { ok = true, action = a.action }
  end)

tool("module_list",
  "List loaded modules of the attached process: name, base address, size, path.",
  S({ filter = P("module name substring, case-insensitive") }), function(a)
    local f = a.filter and a.filter:lower() or nil
    local out = {}
    for _, m in ipairs(CE.modules()) do
      if not f or m.name:lower():find(f, 1, true) then
        m.address_hex = string.format("0x%X", m.address)
        out[#out + 1] = m
      end
    end
    return { ok = true, count = #out, modules = out }
  end)

-- --- memory -------------------------------------------------------------
tool("memory_read",
  "Read target memory. type is byte/word/dword/qword/float/double/pointer/string/bytes. count>1 reads an array of that type.",
  S({
    address = P("address: integer, 0x hex, or a symbol expression like game.exe+1A2B"),
    type    = P("value type", "string",
                { enum = { "byte", "word", "dword", "qword", "float", "double",
                           "pointer", "string", "bytes" } }),
    count   = P("number of elements to read, default 1", "integer"),
    size    = P("byte count for string/bytes, default 32", "integer"),
  }, { "address" }),
  function(a)
    local addr = addr_of(a.address)
    if not addr then return { ok = false, error = "address could not be resolved: " .. tostring(a.address) } end
    local typ = a.type or "dword"
    local count = a.count or 1

    if typ == "string" then
      local n = a.size or 32
      local ok, v = pcall(readString, addr, n, false)
      return { ok = ok, address = string.format("0x%X", addr), type = "string",
               value = ok and to_utf8(v) or nil, error = (not ok) and tostring(v) or nil }
    end
    if typ == "bytes" then
      local n = a.size or 32
      local ok, bt = pcall(readBytes, addr, n, true)
      if not ok or type(bt) ~= "table" then
        return { ok = false, error = "read failed: " .. tostring(bt) }
      end
      local hex = {}
      for i = 1, #bt do hex[i] = string.format("%02X", bt[i]) end
      return { ok = true, address = string.format("0x%X", addr), type = "bytes",
               size = #bt, hex = table.concat(hex, " "), dump = hexdump(addr, #bt, bt) }
    end

    local T = TYPES[typ]
    if not T then return { ok = false, error = "unsupported type: " .. tostring(typ) } end
    local vals = {}
    for i = 0, count - 1 do
      local ok, v = pcall(T.read, addr + i * T.size)
      if not ok then v = nil end
      vals[#vals + 1] = v
    end
    local res = { ok = true, address = string.format("0x%X", addr), type = typ, values = vals }
    if count == 1 then res.value = vals[1] end
    return res
  end)

tool("memory_write",
  "Write a typed value into target memory. Types as in memory_read, excluding string/bytes.",
  S({
    address = P("target address"),
    type    = P("value type", "string",
                { enum = { "byte", "word", "dword", "qword", "float", "double", "pointer" } }),
    value   = P("numeric value to write"),
  }, { "address", "type", "value" }),
  function(a)
    local addr = addr_of(a.address)
    if not addr then return { ok = false, error = "address could not be resolved" } end
    local T = TYPES[a.type]
    if not T then return { ok = false, error = "unsupported type: " .. tostring(a.type) } end
    local num = tonumber(a.value)
    if not num then return { ok = false, error = "value is not numeric: " .. tostring(a.value) } end
    local ok, r = pcall(T.write, addr, num)
    return { ok = ok and r ~= false, address = string.format("0x%X", addr),
             type = a.type, value = num, error = (not ok) and tostring(r) or nil }
  end)

tool("memory_patch",
  "Patch raw bytes from a hex string, e.g. 90 90 90 or 48 8B 05 ?? ?? ?? ??. Reads the range back to verify.",
  S({
    address = P("target address"),
    hex     = P("hex byte string, space separated; ?? keeps the original byte"),
    verify  = P("read back afterwards, default true", "boolean"),
  }, { "address", "hex" }),
  function(a)
    local addr = addr_of(a.address)
    if not addr then return { ok = false, error = "address could not be resolved" } end
    local bytes = {}
    for tok in a.hex:gmatch("%S+") do
      if tok ~= "??" and tok ~= "**" then
        local b = tonumber(tok:gsub("^0[xX]", ""), 16)
        if not b then return { ok = false, error = "bad byte: " .. tok } end
        bytes[#bytes + 1] = b
      else
        bytes[#bytes + 1] = -1
      end
    end
    if #bytes == 0 then return { ok = false, error = "no bytes to write" } end

    local ok, err = pcall(function()
      for i = 1, #bytes do
        if bytes[i] >= 0 then writeByte(addr + i - 1, bytes[i]) end
      end
    end)
    if not ok then return { ok = false, error = "write failed: " .. tostring(err) } end

    local res = { ok = true, address = string.format("0x%X", addr), wrote = #bytes }
    if a.verify ~= false then
      local ok2, bt = pcall(readBytes, addr, #bytes, true)
      if ok2 and type(bt) == "table" then
        local hex = {}
        for i = 1, #bt do hex[i] = string.format("%02X", bt[i]) end
        res.after = table.concat(hex, " ")
      end
    end
    return res
  end)

tool("memory_dump",
  "Hex dump a memory range with an ASCII gutter.",
  S({ address = P("start address"), size = P("byte count, default 256, max 4096", "integer") },
    { "address" }),
  function(a)
    local addr = addr_of(a.address)
    if not addr then return { ok = false, error = "address could not be resolved" } end
    local size = math.min(a.size or 256, 4096)
    local ok, bt = pcall(readBytes, addr, size, true)
    if not ok or type(bt) ~= "table" then
      return { ok = false, error = "read failed: " .. tostring(bt) }
    end
    return { ok = true, address = string.format("0x%X", addr), size = #bt,
             dump = hexdump(addr, #bt, bt) }
  end)

tool("memory_regions",
  "List memory regions of the attached process with protection flags. Filter by an address to get the single region holding it.",
  S({ filter = P("only return the region containing this address"), limit = P("max rows", "integer") }),
  function(a)
    local ok, list = pcall(enumMemoryRegions)
    if not ok or type(list) ~= "table" then
      return { ok = false, error = "could not enumerate memory regions: " .. tostring(list) }
    end
    local want = a.filter and addr_of(a.filter) or nil
    local limit = a.limit or 200
    local out = {}
    for _, r in ipairs(list) do
      local base = r.BaseAddress
      local size = r.RegionSize or 0
      local include = true
      if want then include = (want >= base and want < base + size) end
      if include then
        local mod = r.AllocationBase and module_containing(r.AllocationBase) or nil
        out[#out + 1] = {
          base = string.format("0x%X", base),
          size = size,
          protect = tostring(r.Protect or ""),
          state = tostring(r.State or ""),
          type = tostring(r.Type or ""),
          module = mod and mod.name or nil,
        }
        if #out >= limit then break end
      end
    end
    return { ok = true, count = #out, regions = out }
  end)

tool("address_resolve",
  "Resolve a symbol expression (game.exe+1A2B, [0x12345678]+10) into an absolute address, plus its module and offset.",
  S({ expression = P("address expression") }, { "expression" }),
  function(a)
    local addr = addr_of(a.expression)
    if not addr then return { ok = false, error = "cannot resolve: " .. tostring(a.expression) } end
    local m, off = module_containing(addr)
    return {
      ok = true,
      expression = a.expression,
      address = string.format("0x%X", addr),
      decimal = addr,
      module = m and m.name or nil,
      offset = off and string.format("0x%X", off) or nil,
    }
  end)

-- --- scanning -----------------------------------------------------------
tool("aob_scan",
  "Array-of-bytes scan. pattern like \"48 8B 05 ?? ?? ?? ??\". Restrict to a module with module, or set unique for a single hit.",
  S({
    pattern = P("byte pattern, space separated, ?? is a wildcard"),
    module  = P("module name, e.g. game.exe; omit to scan the whole process"),
    unique  = P("return only the first match", "boolean"),
    limit   = P("max addresses to return, default 50", "integer"),
  }, { "pattern" }),
  function(a)
    local limit = a.limit or 50
    local addrs = {}

    if a.unique then
      local ok, addr
      if a.module then
        ok, addr = pcall(AOBScanModuleUnique, a.module, a.pattern)
      else
        ok, addr = pcall(AOBScanUnique, a.pattern)
      end
      if ok and type(addr) == "number" and addr > 0 then addrs[1] = addr end
    else
      local ok, list = pcall(AOBScan, a.pattern)
      if ok and list then
        -- CE's StringList is 0-based; grab extra so module filtering still fills the page
        local cnt = list.Count or 0
        local take = math.min(cnt, math.max(limit * 8, 200))
        for i = 0, take - 1 do
          local s = list[i]
          if s then
            local v = tonumber(s, 16)
            if v then addrs[#addrs + 1] = math.tointeger(v) or v end
          end
        end
        pcall(function() list.destroy() end)
      end
    end

    local out = {}
    for _, addr in ipairs(addrs) do
      local m, off = module_containing(addr)
      if not a.module or (m and m.name:lower() == a.module:lower()) then
        out[#out + 1] = {
          address = string.format("0x%X", addr),
          module = m and m.name or nil,
          offset = off and string.format("0x%X", off) or nil,
          symbol = (m and off) and (m.name .. "+" .. string.format("%X", off)) or nil,
        }
        if #out >= limit then break end
      end
    end
    return { ok = true, count = #out, matches = out }
  end)

local SCAN_STATE = { scan = nil, list = nil }

tool("value_scan",
  "First value scan. type defaults to dword. Scope defaults to the main module; whole=true scans the entire process address space and is slow.",
  S({
    value = P("value to search for"),
    type  = P("value type", "string",
              { enum = { "byte", "word", "dword", "qword", "float", "double", "string" } }),
    whole = P("scan the whole process instead of the main module", "boolean"),
    writable_only = P("only scan writable regions", "boolean"),
    limit = P("max results, default 50", "integer"),
  }, { "value" }),
  function(a)
    local vt = ({ byte = "vtByte", word = "vtWord", dword = "vtDword",
                  qword = "vtQword", float = "vtSingle", double = "vtDouble",
                  string = "vtString" })[a.type or "dword"]
    if not vt then return { ok = false, error = "unsupported type" } end
    if _G[vt] == nil then return { ok = false, error = "missing CE constant: " .. vt } end

    local startAddr, stopAddr = 0, 0x7FFFFFFFFFFF
    if not a.whole then
      local main = nil
      for _, m in ipairs(CE.modules()) do
        if m.main then main = m break end
      end
      main = main or CE.modules()[1]
      if main then startAddr = main.address; stopAddr = main.address + main.size end
    end

    local ok, err = pcall(function()
      local ms = createMemScan()
      ms.ScanOption     = _G.soExactValue
      ms.VarType        = _G[vt]
      ms.RoundingType   = _G.rtRounded
      ms.Scanvalue      = tostring(a.value)
      ms.StartAddress   = startAddr
      ms.StopAddress    = stopAddr
      ms.AlignmentType  = _G.fsmNotAligned
      ms.AlignmentParam = "1"
      if a.writable_only ~= false then ms.ScanWritable = 2 end  -- scanInclude
      ms.scan()
      -- the scan runs on its own thread; without this the result list is empty
      if type(ms.waitTillDone) == "function" then ms.waitTillDone() end
      SCAN_STATE.scan = ms
      local fl = createFoundList(ms)
      fl.initialize()
      SCAN_STATE.list = fl
    end)
    if not ok then return { ok = false, error = "scan failed: " .. tostring(err) } end

    local fl = SCAN_STATE.list
    local limit = a.limit or 50
    local out = {}
    local total = fl.Count or 0
    for i = 1, math.min(total, limit) do
      local addrstr = fl.getAddress(i)
      local val = fl.getValue(i)
      local n = tonumber(addrstr)
      local addr = n and (math.tointeger(n) or n) or nil
      local m, off = nil, nil
      if addr then m, off = module_containing(addr) end
      out[#out + 1] = {
        address = addrstr,
        value = val,
        symbol = (m and off) and (m.name .. "+" .. string.format("%X", off)) or nil,
      }
    end
    return { ok = true, total = total, returned = #out, results = out,
             scope = a.whole and "whole-process" or "main-module" }
  end)

tool("value_scan_next",
  "Narrow the previous scan result set (next scan).",
  S({ value = P("new value to filter by") }, { "value" }),
  function(a)
    if not SCAN_STATE.scan then
      return { ok = false, error = "no first scan yet; call value_scan first" }
    end
    local ok, err = pcall(function()
      local ms = SCAN_STATE.scan
      if SCAN_STATE.list then pcall(function() SCAN_STATE.list.deinitialize() end) end
      ms.Scanvalue = tostring(a.value)
      ms.nextScan()
      if type(ms.waitTillDone) == "function" then ms.waitTillDone() end
      local fl = createFoundList(ms)
      fl.initialize()
      SCAN_STATE.list = fl
    end)
    if not ok then return { ok = false, error = "next scan failed: " .. tostring(err) } end
    local fl = SCAN_STATE.list
    local total = fl.Count or 0
    local out = {}
    for i = 1, math.min(total, 50) do
      out[#out + 1] = { address = fl.getAddress(i), value = fl.getValue(i) }
    end
    return { ok = true, total = total, returned = #out, results = out }
  end)

tool("scan_reset", "Drop scan state and results.", S({}), function()
  if SCAN_STATE.list then pcall(function() SCAN_STATE.list.deinitialize() end) end
  if SCAN_STATE.scan then pcall(function() SCAN_STATE.scan.destroy() end) end
  SCAN_STATE.scan, SCAN_STATE.list = nil, nil
  return { ok = true }
end)

-- --- disassembly --------------------------------------------------------
tool("disassemble",
  "Disassemble consecutive instructions from an address. Returns address, raw bytes and mnemonic for each.",
  S({ address = P("start address"), count = P("instruction count, default 10, max 100", "integer") },
    { "address" }),
  function(a)
    local addr = addr_of(a.address)
    if not addr then return { ok = false, error = "address could not be resolved" } end
    local n = math.min(a.count or 10, 100)
    local out = {}
    local cur = addr
    for _ = 1, n do
      local ok, s = pcall(disassemble, cur)
      if not ok or not s then break end
      -- measured return order is (note, instruction, bytes, address)
      local ok2, _note, instr, bytes, addrstr = pcall(splitDisassembledString, s)
      if not ok2 then
        out[#out + 1] = { address = string.format("0x%X", cur), raw = s }
        break
      end
      local nbytes = 0
      for _t in tostring(bytes or ""):gmatch("%x%x") do nbytes = nbytes + 1 end
      if nbytes == 0 then nbytes = 1 end
      out[#out + 1] = {
        address = "0x" .. tostring(addrstr or string.format("%X", cur)),
        bytes = (tostring(bytes or ""):gsub("%s+$", "")),
        instruction = tostring(instr or ""),
        raw = s,
      }
      cur = cur + nbytes
    end
    return { ok = true, count = #out, instructions = out }
  end)

tool("assemble",
  "Run a Cheat Engine auto-assemble script (alloc, label, aobscanmodule, full AA syntax).",
  S({ script = P("full auto-assemble script text") }, { "script" }),
  function(a)
    -- check first: a failing autoAssemble can raise a modal dialog and freeze the server
    local okc, clean, cerr = pcall(autoAssembleCheck, a.script, true, false)
    if okc and clean == false then
      return { ok = false, error = "syntax check failed: " .. tostring(cerr) }
    end
    local ok, r, extra = pcall(autoAssemble, a.script)
    if not ok then return { ok = false, error = "assemble failed: " .. tostring(r) } end
    local res = { ok = (r ~= false), assembled = true }
    if r == false then res.error = "autoAssemble returned false" end
    if type(extra) == "table" then
      local keys = {}
      for k in pairs(extra) do keys[#keys + 1] = tostring(k) end
      res.symbols = keys
    end
    return res
  end)

tool("assemble_instruction",
  "Write one instruction in place at an address. Returns the disassembly before and after so you can see whether trailing bytes were clobbered.",
  S({ address = P("address"), instruction = P("instruction text, e.g. nop or mov eax,1") },
    { "address", "instruction" }),
  function(a)
    local addr = addr_of(a.address)
    if not addr then return { ok = false, error = "address could not be resolved" } end
    local okb, before = pcall(disassemble, addr)
    local script = string.format("%X:\n%s\n", addr, a.instruction)
    local ok, r = pcall(autoAssemble, script)
    if not ok then return { ok = false, error = "assemble failed: " .. tostring(r) } end
    local oka, after = pcall(disassemble, addr)
    return {
      ok = (r ~= false),
      address = string.format("0x%X", addr),
      before = okb and before or nil,
      after = oka and after or nil,
      error = (r == false) and "autoAssemble returned false" or nil,
    }
  end)

-- --- debugging ----------------------------------------------------------
tool("breakpoint_set",
  "Set a breakpoint. trigger is execute, write or access. The target process really stops there, so follow up with debug_resume.",
  S({
    address = P("address"),
    trigger = P("trigger type", "string", { enum = { "execute", "write", "access" } }),
  }, { "address" }),
  function(a)
    local addr = addr_of(a.address)
    if not addr then return { ok = false, error = "address could not be resolved" } end
    local trig = ({ execute = "bptExecute", write = "bptWrite", access = "bptAccess" })[a.trigger or "execute"]
    local ok, err = pcall(debug_setBreakpoint, addr, nil, _G[trig])
    if not ok then return { ok = false, error = "breakpoint failed: " .. tostring(err) } end
    return { ok = true, address = string.format("0x%X", addr), trigger = a.trigger or "execute" }
  end)

tool("breakpoint_remove", "Remove the breakpoint at an address.",
  S({ address = P("address") }, { "address" }), function(a)
    local addr = addr_of(a.address)
    if not addr then return { ok = false, error = "address could not be resolved" } end
    local ok, err = pcall(debug_removeBreakpoint, addr)
    return { ok = ok, address = string.format("0x%X", addr),
             error = (not ok) and tostring(err) or nil }
  end)

tool("debug_resume",
  "Resume execution from a breakpoint. mode is run (default), stepinto or stepover.",
  S({ mode = P("resume mode", "string", { enum = { "run", "stepinto", "stepover" } }) }),
  function(a)
    local m = ({ run = "co_run", stepinto = "co_stepinto", stepover = "co_stepover" })[a.mode or "run"]
    local ok, err = pcall(debug_continueFromBreakpoint, _G[m])
    return { ok = ok, mode = a.mode or "run", error = (not ok) and tostring(err) or nil }
  end)

-- --- address list -------------------------------------------------------
tool("table_list",
  "List cheat-table entries: index, description, address, type, value and frozen state. Indexes are 1-based.",
  S({ limit = P("max rows, default 200", "integer") }), function(a)
    local ok, al = pcall(getAddressList)
    if not ok then return { ok = false, error = "could not get the address list" } end
    local limit = a.limit or 200
    local out = {}
    local n = al.Count or 0
    -- CE record indexes are 0-based; expose them 1-based
    for i = 0, math.min(n, limit) - 1 do
      local ok2, rec = pcall(function() return al.getMemoryRecord(i) end)
      if ok2 and rec then
        local okv, val = pcall(function() return rec.Value end)
        out[#out + 1] = {
          index = i + 1,
          description = to_utf8(tostring(rec.Description or "")),
          address = tostring(rec.Address or ""),
          type = tostring(rec.VarType or ""),
          value = okv and tostring(val) or nil,
          active = rec.Active and true or false,
        }
      end
    end
    return { ok = true, count = n, returned = #out, entries = out }
  end)

tool("table_add",
  "Add a cheat-table entry. freeze=true activates it immediately.",
  S({
    description = P("label shown in the table"),
    address     = P("address expression, e.g. game.exe+1A2B"),
    type        = P("value type", "string",
                    { enum = { "byte", "word", "dword", "qword", "float", "double",
                               "string", "bytes", "pointer" } }),
    value       = P("initial value, optional"),
    freeze      = P("activate/freeze right away", "boolean"),
  }, { "description", "address" }),
  function(a)
    local ok, al = pcall(getAddressList)
    if not ok then return { ok = false, error = "could not get the address list" } end
    local vt = ({ byte = "vtByte", word = "vtWord", dword = "vtDword", qword = "vtQword",
                  float = "vtSingle", double = "vtDouble", string = "vtString",
                  bytes = "vtByteArray", pointer = "vtQword" })[a.type or "dword"]
    local ok2, err = pcall(function()
      local rec = al.createMemoryRecord()
      rec.Description = a.description
      rec.Address = tostring(a.address)
      rec.VarType = vt
      if a.value ~= nil then rec.Value = tostring(a.value) end
      if a.freeze then rec.Active = true end
    end)
    if not ok2 then return { ok = false, error = "create failed: " .. tostring(err) } end
    return { ok = true, description = a.description, address = a.address, type = a.type or "dword" }
  end)

tool("table_update",
  "Update an entry by index (1-based) or by description: value, frozen state, description.",
  S({
    index           = P("entry index, 1-based", "integer"),
    description     = P("entry description, alternative to index"),
    value           = P("new value"),
    active          = P("true freezes, false unfreezes", "boolean"),
    new_description = P("new label"),
  }), function(a)
    local ok, al = pcall(getAddressList)
    if not ok then return { ok = false, error = "could not get the address list" } end
    local rec
    if a.index then
      local o, r = pcall(function() return al.getMemoryRecord(a.index - 1) end)
      if o then rec = r end
    elseif a.description then
      local o, r = pcall(function() return al.getMemoryRecordByDescription(a.description) end)
      if o then rec = r end
    end
    if not rec then return { ok = false, error = "entry not found" } end
    local ok2, err = pcall(function()
      if a.value ~= nil then rec.Value = tostring(a.value) end
      if a.active ~= nil then rec.Active = a.active and true or false end
      if a.new_description then rec.Description = a.new_description end
    end)
    if not ok2 then return { ok = false, error = "update failed: " .. tostring(err) } end
    return { ok = true, description = to_utf8(tostring(rec.Description or "")) }
  end)

tool("table_remove", "Delete a cheat-table entry by 1-based index.",
  S({ index = P("entry index, 1-based", "integer") }, { "index" }), function(a)
    local ok, al = pcall(getAddressList)
    if not ok then return { ok = false, error = "could not get the address list" } end
    local ok2, err = pcall(function()
      local rec = al.getMemoryRecord(a.index - 1)
      if not rec then error("no entry at index " .. tostring(a.index)) end
      rec.destroy()
    end)
    return { ok = ok2, error = (not ok2) and tostring(err) or nil }
  end)

-- --- misc ---------------------------------------------------------------
tool("speedhack",
  "Read or set the speedhack multiplier. Omit speed to just read it.",
  S({ speed = P("multiplier, e.g. 2.0; omit to read") }), function(a)
    if a.speed then
      local ok, err = pcall(speedhack_setSpeed, tonumber(a.speed))
      if not ok then return { ok = false, error = tostring(err) } end
    end
    local ok2, cur = pcall(speedhack_getSpeed)
    return { ok = true, speed = ok2 and cur or nil }
  end)

tool("inject_dll", "Inject a DLL into the attached process.",
  S({ path = P("absolute path to the DLL") }, { "path" }), function(a)
    local ok, r = pcall(injectDLL, a.path)
    if not ok then return { ok = false, error = "inject failed: " .. tostring(r) } end
    return { ok = r and true or false, path = a.path, result = tostring(r) }
  end)

tool("lua_eval",
  "Execute arbitrary Lua inside Cheat Engine and return the value. Ultimate escape hatch: anything the other tools cannot express, do it here.",
  S({ code = P("Lua code; use return to hand back a value") }, { "code" }), function(a)
    local chunk, err = load("return " .. a.code, "yq_eval")
    if not chunk then chunk, err = load(a.code, "yq_eval") end
    if not chunk then return { ok = false, error = "syntax error: " .. tostring(err) } end
    local ok, res = pcall(chunk)
    if not ok then return { ok = false, error = "runtime error: " .. tostring(res) } end
    local rt = type(res)
    if rt == "table" or rt == "boolean" or rt == "number" then
      return { ok = true, type = rt, value = res }
    end
    return { ok = true, type = rt, value = res ~= nil and tostring(res) or nil }
  end)

tool("show_message",
  "Flash a short text on the Cheat Engine title bar for a few seconds. Non-modal on purpose: a real message box would block CE's message loop and stall this server.",
  S({ text = P("text to show") }, { "text" }), function(a)
    local ok = pcall(function()
      local mf = getMainForm()
      local old = mf.Caption
      mf.Caption = old .. "  |  " .. tostring(a.text)
      createTimer(5000, function()
        pcall(function() mf.Caption = old end)
      end)
    end)
    return { ok = ok, shown = a.text }
  end)

tool("server_log", "Read the recent MCP server log lines.",
  S({ limit = P("line count, default 50", "integer") }), function(a)
    local n = math.min(a.limit or 50, #LOG)
    local out = {}
    for i = #LOG - n + 1, #LOG do
      if i >= 1 then out[#out + 1] = LOG[i] end
    end
    return { ok = true, log = out }
  end)

-------------------------------------------------------------------------------
-- 6. MCP
-------------------------------------------------------------------------------
local PROTOCOL_DEFAULT = "2024-11-05"
local TOOLS_CACHE = nil

local function tool_descriptors()
  if TOOLS_CACHE then return TOOLS_CACHE end
  local out = {}
  for _, t in ipairs(TOOLS) do
    out[#out + 1] = { name = t.name, description = t.description, inputSchema = t.inputSchema }
  end
  TOOLS_CACHE = out
  return out
end

local function text_result(v)
  local body = (type(v) == "string") and v or Json.encode(v, true)
  return { content = { { type = "text", text = body } }, isError = false }
end

local function error_result(msg)
  return { content = { { type = "text", text = tostring(msg) } }, isError = true }
end

local function handle_rpc(msg)
  local id = msg.id
  local method = msg.method
  local params = msg.params or {}
  local is_notification = (id == nil)

  if msg.jsonrpc ~= "2.0" or type(method) ~= "string" then
    return { jsonrpc = "2.0", id = id, error = { code = -32600, message = "Invalid Request" } }
  end

  if method == "initialize" then
    local proto = params.protocolVersion or PROTOCOL_DEFAULT
    return { jsonrpc = "2.0", id = id, result = {
      protocolVersion = proto,
      capabilities = { tools = { listChanged = false } },
      serverInfo = { name = "yq-ce-mcp", version = YQ.VERSION },
    } }
  end

  if method == "notifications/initialized" or method == "initialized" then return nil end
  if method == "ping" then return { jsonrpc = "2.0", id = id, result = O({}) } end
  if method == "tools/list" then
    return { jsonrpc = "2.0", id = id, result = { tools = tool_descriptors() } }
  end

  if method == "tools/call" then
    local name = params.name
    local args = params.arguments or {}
    local t = TOOLS_BY_NAME[name]
    if not t then
      return { jsonrpc = "2.0", id = id, result = error_result("unknown tool: " .. tostring(name)) }
    end
    log("call " .. tostring(name))
    local ok, res = pcall(t.fn, args)
    if not ok then
      log("tool error " .. tostring(name) .. ": " .. tostring(res))
      return { jsonrpc = "2.0", id = id, result = error_result("tool raised: " .. tostring(res)) }
    end
    return { jsonrpc = "2.0", id = id, result = text_result(res) }
  end

  if method == "resources/list" then
    return { jsonrpc = "2.0", id = id, result = { resources = {} } }
  end
  if method == "prompts/list" then
    return { jsonrpc = "2.0", id = id, result = { prompts = {} } }
  end

  if is_notification then return nil end
  return { jsonrpc = "2.0", id = id,
           error = { code = -32601, message = "Method not found: " .. method } }
end

-------------------------------------------------------------------------------
-- 6.5 Title bar status light
--     The HTTP side is stateless, so "connected" can only mean "a client spoke
--     to us recently". ai_window_sec is how long one request keeps it green.
--     Text is written as UTF-8 byte escapes: CE loads Lua sources through the
--     system code page, so a literal here would arrive corrupted.
-------------------------------------------------------------------------------
local TITLE_STATE = { base = nil, last = nil }

local GLYPH_ON  = "\xE2\x97\x8F"                            -- filled circle
local GLYPH_OFF = "\xE2\x97\x8B"                            -- hollow circle
local TXT_ON    = "\xE5\xB7\xB2\xE8\xBF\x9E\xE6\x8E\xA5"    -- connected
local TXT_OFF   = "\xE6\x9C\xAA\xE8\xBF\x9E\xE6\x8E\xA5"    -- not connected

-- Windows 10 cannot colour part of a system title bar (that arrived with the
-- Win11 DWM attributes), so the colour rides on the window icon instead: a
-- green dot when connected, a red one when not. Title text stays legible.
local ICON = { on = nil, off = nil, current = nil }

local function load_dot_icon(name)
  if not W.ok then return nil end
  local candidates = {
    "autorun\\" .. name,
    (os.getenv("TEMP") or ".") .. "\\" .. name,
  }
  local buf = W.C + 0x1000   -- scratch the UTF-8 converter does not use
  for _, path in ipairs(candidates) do
    local ok = pcall(function()
      writeStringLocal(buf, path)
    end)
    if ok then
      local h = ccall("LoadImageA", 0, buf, 1, 16, 16, 0x10)   -- IMAGE_ICON, LR_LOADFROMFILE
      if h and h > 0 and h ~= 0xFFFFFFFFFFFFFFFF then return h end
    end
  end
  return nil
end

local function apply_icon(on)
  if CFG.mark_title == false then return end
  local key = on and "on" or "off"
  if ICON.current == key then return end
  local h = on and ICON.on or ICON.off
  if not h then return end
  pcall(function()
    local hwnd = getMainForm().Handle
    ccall("SendMessageA", hwnd, 0x80, 0, h)   -- WM_SETICON / ICON_SMALL
    ICON.current = key
  end)
end

-- A live request says "the AI is working right now". A quiet one does not mean
-- the bridge is gone, so when the window expires we also check that the host
-- process still exists. ever_connected keeps a never-wired CE showing "off"
-- instead of "on" just because some client happens to be installed.
local PROC_CACHE = { t = 0, alive = false }

local function harness_alive()
  local now = os.time()
  if (now - PROC_CACHE.t) < 5 then return PROC_CACHE.alive end
  PROC_CACHE.t = now
  local alive = false
  local ok, list = pcall(getProcesslist)
  if ok and type(list) == "table" then
    for _, pname in pairs(list) do
      local n = tostring(pname):lower()
      if n:find("deepseek", 1, true) or n:find("dsh", 1, true) then
        alive = true
        break
      end
    end
  end
  PROC_CACHE.alive = alive
  return alive
end

function YQ.ai_connected()
  if not YQ.ever_connected then return false end
  local last = YQ.last_req_at or 0
  if last > 0 and (os.time() - last) <= CFG.ai_window_sec then return true end
  return harness_alive()
end

local function refresh_title(force)
  if not CFG.mark_title then return end
  local ok, err = pcall(function()
    local mf = getMainForm()
    if not mf then error("no main form yet") end
    if not TITLE_STATE.base then
      -- strip any suffix a previous load left behind
      local base = tostring(mf.Caption or "Cheat Engine")
      base = base:gsub("%s+%[YQ%-MCP :%d+[^%]]*%]$", "")
      TITLE_STATE.base = base
    end

    local on = YQ.ai_connected()
    if not force and TITLE_STATE.last == on then return end
    TITLE_STATE.last = on

    mf.Caption = TITLE_STATE.base
      .. "  [YQ-MCP :" .. CFG.port
      .. " " .. (on and GLYPH_ON or GLYPH_OFF)
      .. " AI " .. (on and TXT_ON or TXT_OFF) .. "]"

    apply_icon(on)
  end)
  if not ok then log("title error: " .. tostring(err)) end
  return ok
end
YQ.refresh_title = refresh_title

-------------------------------------------------------------------------------
-- 7. HTTP server
-------------------------------------------------------------------------------
local SRV = { fd = nil, running = false, timer = nil, pending = {}, conns = 0, reqs = 0 }

local function ws_close(fd)
  if fd then pcall(ccall, "closesocket", fd) end
  SRV.pending[fd] = nil
end

local function ws_send_all(fd, data)
  local total = #data
  local sent = 0
  while sent < total do
    local chunk = data:sub(sent + 1, math.min(sent + W.TXSIZE, total))
    local okw, werr = pcall(writeStringLocal, W.TX, chunk)
    if not okw then log("writeStringLocal failed: " .. tostring(werr)); return false end
    local n = ccall("send", fd, W.TX, #chunk, 0)
    if CFG.verbose then
      log(string.format("send fd=%s chunk=%d ret=%s", tostring(fd), #chunk, tostring(n)))
    end
    if not n or n <= 0 then return false end
    sent = sent + #chunk
  end
  return true
end

local function parse_http_request(buf)
  local hdr_end = buf:find("\r\n\r\n", 1, true)
  if not hdr_end then return nil end
  local head = buf:sub(1, hdr_end - 1)
  local body = buf:sub(hdr_end + 4)

  local method, path = head:match("^(%u+)%s+(%S+)%s+HTTP/")
  if not method then return nil end

  local headers = {}
  for line in head:gmatch("[^\r\n]+") do
    local k, v = line:match("^([^:]+):%s*(.*)$")
    if k then headers[k:lower()] = v end
  end

  local clen = tonumber(headers["content-length"] or "0") or 0
  if #body < clen then
    return { incomplete = true, method = method, path = path, headers = headers }
  end
  return { method = method, path = path, headers = headers, body = body:sub(1, clen) }
end

local function http_response(status, body, ctype)
  ctype = ctype or "application/json"
  local head = table.concat({
    "HTTP/1.1 " .. status,
    "Content-Type: " .. ctype .. "; charset=utf-8",
    "Content-Length: " .. #body,
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Headers: Content-Type, Mcp-Session-Id, Authorization",
    "Access-Control-Allow-Methods: POST, GET, OPTIONS",
    "Connection: close",
    "", "",
  }, "\r\n")
  return head .. body
end

local function dispatch_http(req)
  -- only real MCP traffic counts as "the AI is talking"; health probes do not
  if req.method == "POST" then
    YQ.last_req_at = os.time()
    YQ.ever_connected = true
    refresh_title()
  end

  if req.method == "OPTIONS" then
    return http_response("204 No Content", "", "text/plain")
  end

  if req.method == "GET" then
    if req.path:find("/health", 1, true) or req.path == "/" then
      return http_response("200 OK", Json.encode(CE.status(), true))
    end
    return http_response("404 Not Found", '{"error":"not found"}')
  end

  if req.method ~= "POST" then
    return http_response("405 Method Not Allowed", '{"error":"method not allowed"}')
  end

  if CFG.token and CFG.token ~= "" then
    if (req.headers["authorization"] or "") ~= ("Bearer " .. CFG.token) then
      return http_response("401 Unauthorized", '{"error":"unauthorized"}')
    end
  end

  local ok, payload = pcall(Json.decode, req.body)
  if not ok then
    return http_response("400 Bad Request",
      Json.encode({ jsonrpc = "2.0", id = NULL,
                    error = { code = -32700, message = "Parse error: " .. tostring(payload) } }))
  end

  if type(payload) == "table" and payload.jsonrpc == nil and type(payload[1]) == "table" then
    local responses = {}
    for _, m in ipairs(payload) do
      local r = handle_rpc(m)
      if r then responses[#responses + 1] = r end
    end
    if #responses == 0 then return http_response("202 Accepted", "") end
    return http_response("200 OK", Json.encode(responses))
  end

  local resp = handle_rpc(payload)
  if resp == nil then return http_response("202 Accepted", "") end
  return http_response("200 OK", Json.encode(resp))
end

local function pump()
  if not SRV.running or not W.ok then return end
  local now = os.time()

  -- title light rides on the same timer: one timer object, no second one to
  -- fight over the message loop. ~1 Hz is plenty for a status indicator.
  SRV.tick = (SRV.tick or 0) + 1
  if SRV.tick % 50 == 0 then refresh_title() end

  for _ = 1, 4 do
    local c = ccall("accept", SRV.fd, 0, 0)
    if not c or c < 0 or c > 0x7FFFFFFF then break end
    -- client sockets must stay non-blocking: a blocking recv freezes CE's
    -- message loop and the whole UI with it
    writeIntegerLocal(W.NONBLK, 1)
    pcall(ccall, "ioctlsocket", c, 0x8004667E, W.NONBLK)
    SRV.pending[c] = { buf = "", t0 = now }
    SRV.conns = SRV.conns + 1
    if CFG.verbose then log("accept fd=" .. tostring(c)) end
  end

  for fd, st in pairs(SRV.pending) do
    if now - st.t0 > CFG.client_timeout then
      ws_close(fd)
    else
      for _ = 1, 8 do
        local n = ccall("recv", fd, W.RX, 8192, 0)
        if n and n > 0 then
          st.buf = st.buf .. (readStringLocal(W.RX, n) or "")
          st.t0 = now
          if #st.buf > CFG.max_body then break end
        else
          break
        end
      end

      local req = parse_http_request(st.buf)
      if req and not req.incomplete then
        local ok, resp = pcall(dispatch_http, req)
        if not ok then
          resp = http_response("500 Internal Server Error", Json.encode({ error = tostring(resp) }))
          log("http error: " .. tostring(resp))
        end
        local sentok = pcall(ws_send_all, fd, resp)
        if CFG.verbose then
          log(string.format("serve %s %s -> %dB sent=%s",
            tostring(req.method), tostring(req.path), #resp, tostring(sentok)))
        end
        SRV.reqs = SRV.reqs + 1
        ws_close(fd)
      end
    end
  end
end

function YQ.start()
  if YQ.running then return true end
  if SRV.fd then pcall(ccall, "closesocket", SRV.fd); SRV.fd = nil end
  SRV.pending = {}

  local ok, err = pcall(function()
    if ccall("WSAStartup", 0x0202, W.WSADATA) ~= 0 then error("WSAStartup failed") end

    local fd = ccall("socket", 2, 1, 6)
    if not fd or fd < 0 or fd > 0x7FFFFFFF then error("socket() failed") end
    SRV.fd = fd

    writeSmallIntegerLocal(W.SA + 0, 2)
    writeSmallIntegerLocal(W.SA + 2, htons(CFG.port))
    writeIntegerLocal(W.SA + 4, 0x0100007F)   -- 127.0.0.1
    writeIntegerLocal(W.SA + 8, 0)
    writeIntegerLocal(W.SA + 12, 0)

    if ccall("bind", fd, W.SA, 16) ~= 0 then
      error("bind failed on port " .. CFG.port .. " (already in use?)")
    end
    if ccall("listen", fd, 16) ~= 0 then error("listen failed") end

    writeIntegerLocal(W.NONBLK, 1)
    pcall(ccall, "ioctlsocket", fd, 0x8004667E, W.NONBLK)
  end)

  if not ok then
    local msg = tostring(err)
    -- CE's 32-bit build has no executeCodeLocalEx at all, so the Winsock bridge
    -- cannot exist there. Say so plainly instead of surfacing a raw Lua error.
    if msg:find("32%-bit") or msg:find("32 bit") then
      YQ.arch_unsupported = true
      log("unsupported: this is the 32-bit Cheat Engine build; use cheatengine-x86_64.exe")
      pcall(function()
        local mf = getMainForm()
        mf.Caption = tostring(mf.Caption or "Cheat Engine") .. "  [YQ-MCP needs 64-bit CE]"
      end)
      if SRV.fd then pcall(ccall, "closesocket", SRV.fd); SRV.fd = nil end
      YQ.last_error = "32-bit Cheat Engine: not supported"
      return false, YQ.last_error
    end

    log("start failed: " .. msg)
    if SRV.fd then pcall(ccall, "closesocket", SRV.fd); SRV.fd = nil end
    YQ.last_error = msg
    return false, msg
  end

  SRV.running = true
  YQ.running = true
  YQ.last_error = nil

  SRV.timer = createTimer(nil, true)
  SRV.timer.Interval = CFG.poll_ms
  SRV.timer.OnTimer = function()
    local ok2, e2 = pcall(pump)
    if not ok2 then log("pump error: " .. tostring(e2)) end
  end

  log("listening on http://" .. CFG.host .. ":" .. CFG.port .. "/mcp")
  return true
end

function YQ.stop()
  if YQ.title_timer then
    pcall(function() YQ.title_timer.Enabled = false; YQ.title_timer.destroy() end)
    YQ.title_timer = nil
  end
  if SRV.timer then pcall(function() SRV.timer.Enabled = false; SRV.timer.destroy() end) end
  SRV.timer = nil
  for fd in pairs(SRV.pending) do pcall(ccall, "closesocket", fd) end
  SRV.pending = {}
  if SRV.fd then pcall(ccall, "closesocket", SRV.fd); SRV.fd = nil end
  SRV.running = false
  YQ.running = false
  log("stopped")
  return true
end

function YQ.status()
  local st = CE.status()
  st.server.connections = SRV.conns
  st.server.requests = SRV.reqs
  st.server.pending = (function()
    local n = 0
    for _ in pairs(SRV.pending) do n = n + 1 end
    return n
  end)()
  st.server.last_error = YQ.last_error
  st.server.ai_connected = YQ.ai_connected()
  st.server.ever_connected = YQ.ever_connected and true or false
  st.server.idle_seconds = (YQ.last_req_at and YQ.last_req_at > 0)
    and (os.time() - YQ.last_req_at) or nil
  st.tools = #TOOLS
  return st
end

_G.yq_mcp_start  = function() return YQ.start() end
_G.yq_mcp_stop   = function() return YQ.stop() end
_G.yq_mcp_status = function() return YQ.status() end

-------------------------------------------------------------------------------
-- 8. Boot
-------------------------------------------------------------------------------
local okw, werr = W.init()
if not okw then
  log("win32 bridge init failed: " .. tostring(werr))
  YQ.last_error = werr
else
  local ok, err = YQ.start()
  if not ok then
    log("start failed: " .. tostring(err))
    -- a modal box blocks CE's message loop, so only raise one when the failure
    -- is something the user can act on; the 32-bit case is already in the title
    if not YQ.arch_unsupported then
      pcall(showMessage, "YQ CE-MCP failed to start:\n\n" .. tostring(err))
    end
  elseif CFG.mark_title then
    ICON.on  = load_dot_icon("yq-on.ico")
    ICON.off = load_dot_icon("yq-off.ico")
    if not (ICON.on and ICON.off) then
      log("status icons not found next to the plugin; falling back to text only")
    end
    refresh_title(true)
  end
end

log("loaded v" .. YQ.VERSION .. " tools=" .. #TOOLS)
