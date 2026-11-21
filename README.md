# YQ CE-MCP

给 Cheat Engine 装的 MCP 服务器。装好之后，任何支持 MCP 的 AI 客户端（Cursor、Cline、Claude Code、Claude Desktop……）可以直接操作 CE：读内存、写内存、特征码扫描、数值扫描、反汇编、打补丁、管地址表、下断点。

> **直接下载** → [YQ-CE-MCP-Setup.exe](https://github.com/Pangziwang0126/DSH-CE-MCP/releases/latest/download/YQ-CE-MCP-Setup.exe) · 109 KB · 双击即装，CE 插件和 DSH 接线一次做完

**单文件、纯 Lua、免编译、零外部依赖。**

---

## 和参考项目的关系

参考了 [Eruditi/CE-MCP-Plugin](https://github.com/Eruditi/CE-MCP-Plugin) 的能力面（它做了 75 个文本命令，用 C 写 CE 插件 DLL）。这份实现换了底层路线：

| | CE-MCP-Plugin | 本插件 |
|---|---|---|
| 语言 | C + CE Plugin SDK | 纯 Lua |
| 需要编译 | 是（MSVC + 对应位数） | 否 |
| 部署 | 编译出 DLL 放进 `plugins\` | 一个 `.lua` 丢进 `autorun\` |
| 协议 | 自定义文本 `CMD:args` | 标准 MCP（JSON-RPC 2.0） |
| 传输 | 裸 TCP | HTTP，stdio 客户端走 `bridge.py` |
| 工具 | 75 条文本命令 | 30 个带 JSON Schema 的工具 |

标准 MCP 的意思是：客户端能自己发现工具、自己拼参数，不需要你在中间翻译命令。

---

## 安装

### 单文件 EXE：双击即装

**`YQ-CE-MCP-Setup.exe`**，109 KB，一个文件。双击，看一眼输出，装完。

它把下面这 11 个文件全部嵌在自己身上，运行时解压到 `%TEMP%\yq-cemcp-<随机>`，跑完 `install.ps1` 再把这个临时目录删掉：

```
YQ-CE-MCP.lua   yq-on.ico   yq-off.ico
install.ps1     install.bat  uninstall.ps1  uninstall.bat
bridge.py       mcp.json     README.md      test_mcp.py
```

装失败时会保留临时目录并打印路径，方便查日志。

- 只要机器上有 .NET Framework 4（Windows 10 / 11 自带），不需要任何运行时。
- 没有管理员权限也能装 —— 除非 Cheat Engine 装在 `Program Files` 下，那种情况需要右键「以管理员身份运行」。
- 想跳过最后的按键暂停（自动化用）：`YQ-CE-MCP-Setup.exe --no-pause`。

自己重新打包：`build-exe.ps1` 会调用 Windows 自带的 `csc.exe`，把 `installer.cs` 和上面 11 个文件编译成 EXE。改了任何文件之后重跑一次即可，不需要装 SDK。

### 一键（CE + DSH 一次到位）

双击 **`install.bat`**。四件事一起做完，不需要再手动改任何配置：

1. 扫盘定位 Cheat Engine，把插件放进 `autorun\`
2. 找到 `~/.dsh`，给每个 profile 的 `cordis.patch.yml` 写入 MCP 行（自动备份、只保留一块、重复跑不会叠加）
3. 启动 CE
4. 验证端点真的起来了

```
[*] Locating Cheat Engine
[+] Cheat Engine: D:\Cheat Engine 7.5
[+] Port 8787 is free
[+] Installed: D:\Cheat Engine 7.5\autorun\YQ-CE-MCP.lua
[*] Wiring DeepSeek Harness
[+] desktop: row added in C:\Users\Administrator\.dsh\profiles\desktop\cordis.patch.yml
[+] DSH is running; the patch layer is watched, the tools appear without a restart.
[*] Starting Cheat Engine
[+] Server is live: http://127.0.0.1:8787/mcp

  Cheat Engine side : http://127.0.0.1:8787/mcp
  DeepSeek Harness  : wired - ask the agent to "read memory at notepad.exe"
  Tools             : 30, registered as mcp__ce__*
```

跑完就能在 DSH 里直接说「读一下 notepad.exe 的 PE 头」。工具以 `mcp__ce__*` 注册。

没装 DSH 时自动跳过第二步，只装 CE 侧；`-NoDsh` 可以显式跳过。

参数：

| 参数 | 作用 |
|---|---|
| `-Port 9000` | 换端口，CE 插件和 DSH 行会同步改 |
| `-NoLaunch` | 只装不启动 CE |
| `-NoDsh` | 只装 CE 侧 |

`install.bat` 直接双击即可；要带参数就在命令行跑 `powershell -ExecutionPolicy Bypass -File install.ps1 -Port 9000`。

**DSH 开着的时候可以直接装。** 补丁层是被监听的，写完就生效，不用重启。CE 没开的时候那行会降级成「暂时没工具」，CE 起来后自动连回去。

### 手动

把 `YQ-CE-MCP.lua` 复制到：

```
<Cheat Engine 安装目录>\autorun\YQ-CE-MCP.lua
```

重启 CE。`autorun` 目录下的脚本 CE 每次启动都会自动执行。

### 卸载

双击 `uninstall.bat`。它删掉 CE 那边的 `autorun\YQ-CE-MCP.lua`，同时从每个 DSH profile 里摘掉 `yq-ce-mcp` 那块（同样先备份），然后重启 CE 即可。

只想卸一边：`uninstall.ps1 -NoCe`（只摘 DSH）或 `-NoDsh`（只删插件）。

---

## 客户端配置

### Cursor / Cline / Continue / 任何支持 HTTP 的客户端

`mcp.json`：

```json
{
  "mcpServers": {
    "yq-ce": {
      "url": "http://127.0.0.1:8787/mcp"
    }
  }
}
```

### Claude Code

```bash
claude mcp add --transport http yq-ce http://127.0.0.1:8787/mcp
```

### Claude Desktop 等只支持 stdio 的客户端

用 `bridge.py` 转发（标准库，无需装包）：

```json
{
  "mcpServers": {
    "yq-ce": {
      "command": "python",
      "args": ["C:\\path\\to\\ce-mcp\\bridge.py"]
    }
  }
}
```

端点不在默认端口时，用环境变量 `YQ_CE_MCP_URL` 覆盖。

### 验证

```bash
curl http://127.0.0.1:8787/health
```

---

## 接入 DeepSeek Harness

DSH 内置了官方 MCP 客户端桥 `@deepseek-ai/dsh-mcp-client`，支持 `streamable-http`，正好对上本插件的端点，不需要装任何包。

`install.bat` 已经把这一行写进 `~/.dsh/profiles/<profile>/cordis.patch.yml` 了。下面是它写的内容，配置被改坏了可以照这个恢复，或者直接重跑一次安装器：

编辑 `~/.dsh/profiles/desktop/cordis.patch.yml`，追加：

```yaml
- insert:
    - id: yq-ce-mcp
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: ce
        transport: streamable-http
        url: http://127.0.0.1:8787/mcp
        toolCallTimeoutMs: 180000
        failOnStartupError: false
        reconnect:
          enabled: true
          initialDelayMs: 1000
          maxDelayMs: 30000
          maxAttempts: 60
```

要点：

- `insert` 是新增行；直接写 `- id: xxx` 是覆盖已存在的行，两者别混。
- **一行 patch 会整体替换 `config`，不做深合并**。改这一行时要把 `config` 写全。
- `reconnect` 只认四个子键（`enabled` / `initialDelayMs` / `maxDelayMs` / `maxAttempts`）。多写一个未知键会让整行加载失败。
- `failOnStartupError: false` 是必须的：CE 没开时这一行降级为「暂时没有工具」，不能让宿主启动失败。
- `serverName` 决定工具前缀。`ce` → `mcp__ce__memory_read`、`mcp__ce__aob_scan`……
- 换端口时这里的 `url` 要跟 `CFG.port` 一起改。

写完存盘，工具就挂到模型上了。验证：

```
mcp__ce__ce_status
```

返回 CE 版本、Lua 版本、当前附加的进程和模块数，就是通了。

**CE 必须先开着。** 关掉 CE 后工具会报连接失败，DSH 按 `reconnect` 策略重试（默认 60 次 × 30 秒）。重新启动 CE，插件在 `autorun` 里自动加载，桥会自动连回去，不需要重启 DSH。

想开机就绪，把 CE 放进启动项（`shell:startup` 放个快捷方式），并确认 `autorun\YQ-CE-MCP.lua` 在装好的位置。

---

## 工具清单

**进程与模块**

| 工具 | 作用 |
|---|---|
| `ce_status` | CE 版本、当前进程、服务器状态 |
| `process_list` | 系统进程（可过滤） |
| `process_open` | 按名字或 PID 附加 |
| `process_control` | 暂停 / 恢复目标 |
| `module_list` | 模块基址、大小、路径 |

**内存**

| 工具 | 作用 |
|---|---|
| `memory_read` | 分类型读取（byte/word/dword/qword/float/double/pointer/string/bytes） |
| `memory_write` | 分类型写入 |
| `memory_patch` | 十六进制字节串打补丁，自动回读校验 |
| `memory_dump` | 带 ASCII 侧栏的十六进制转储 |
| `memory_regions` | 内存区域与保护属性 |
| `address_resolve` | `game.exe+1A2B` → 绝对地址 + 模块偏移 |

**扫描**

| 工具 | 作用 |
|---|---|
| `aob_scan` | 特征码扫描，支持 `??` 通配、模块限定、唯一匹配 |
| `value_scan` | 首次数值扫描 |
| `value_scan_next` | 次扫（在上一轮结果里继续筛） |
| `scan_reset` | 清空扫描状态 |

**反汇编与汇编**

| 工具 | 作用 |
|---|---|
| `disassemble` | 连续反汇编，返回地址 / 字节 / 助记符 |
| `assemble` | 执行完整 autoAssemble 脚本 |
| `assemble_instruction` | 就地写一条指令，返回改写前后对比 |

**调试**

| 工具 | 作用 |
|---|---|
| `breakpoint_set` | 下断（execute / write / access） |
| `breakpoint_remove` | 移除断点 |
| `debug_resume` | 继续 / 单步进入 / 单步跳过 |

**地址表**

| 工具 | 作用 |
|---|---|
| `table_list` | 列出表项 |
| `table_add` | 新增表项（可冻结） |
| `table_update` | 改值 / 冻结 / 改描述 |
| `table_remove` | 删除表项 |

**其它**

| 工具 | 作用 |
|---|---|
| `speedhack` | 变速 |
| `inject_dll` | 注入 DLL |
| `lua_eval` | 执行任意 CE Lua，万能兜底 |
| `show_message` | CE 里弹提示 |
| `server_log` | 服务器日志 |

> `table_*` 系列的 `index` 从 **1** 开始。CE 内部是 0 基，插件已经转换过。

---

## 它是怎么在不装 socket 库的 Lua 里开服务器的

CE 7.5 的 Lua 沙箱里没有 `socket`，也没有 TCP 类。但有两样东西：

1. `getAddressSafe("socket", true)` —— 能把 **CE 自己进程**里 `ws2_32.dll` 的导出地址解出来；
2. `executeCodeLocalEx(addr, args...)` —— 能在 CE 自己的进程里真正发起一次函数调用。

插件拿这两件东西手搓了一个 HTTP 服务器：`WSAStartup` → `socket` → `bind` → `listen` → `ioctlsocket(FIONBIO)` 设成非阻塞 → 在自己的 `createTimer` 里轮询 `accept` / `recv` / `send`。

缓冲区用的是 `createMemoryStream()` 拿到的 CE 侧内存，`writeStringLocal` / `readStringLocal` 直接搬运。客户端 socket **全程非阻塞**——这一点是必须的，阻塞的 `recv` 会把 CE 主线程锁死，界面直接卡住。

同理，插件不用 `showMessage` 做启动提示：模态对话框会堵死消息循环，timer 就不再触发了。启动状态写在日志和 CE 标题栏里。

---

## 标题栏状态灯

CE 标题栏实时显示 AI 的连接状态，**绿色 / 红色**两个颜色：

```
● Cheat Engine 7.5  [YQ-MCP :8787 ● AI 已连接]      ← 标题栏图标是绿点
● Cheat Engine 7.5  [YQ-MCP :8787 ○ AI 未连接]      ← 标题栏图标是红点
```

| 已连接 | 未连接 |
| --- | --- |
| ![connected](docs/titlebar-connected.png) | ![disconnected](docs/titlebar-disconnected.png) |

`ce_status` 里也能读到同样的字段（`ai_connected` / `ever_connected` / `idle_seconds`）。

**颜色为什么落在窗口图标上**

Windows 10 的系统标题栏是 DWM 整行绘制的，没有「只给某一段文字上色」的能力 —— `DWMWA_TEXT_COLOR` / `DWMWA_CAPTION_COLOR` 这批属性是 Windows 11 22H2 才加的，在 Win10 上调会直接失败。

所以颜色走标题栏最左侧的窗口图标：

- 绿点 = 已连接
- 红点 = 未连接

十六进制色值：绿 `#30D158`，红 `#E84141`。两个图标是 16×16 的 PNG 压缩 ICO（各 300 多字节），安装器会同时放到 `autorun\` 和 `%TEMP%\`，插件按这个顺序找，找不到就只显示文字，不影响功能。

标题栏文字保持系统默认色，`●` / `○` 加「已连接 / 未连接」照样可读。

判定规则：

- **从未有过 AI 请求** → 未连接。CE 刚起来、桥还没接上时就是这个状态。
- **最近 120 秒内有 MCP 请求** → 已连接。这是最硬的信号，AI 正在操作 CE。
- **超过 120 秒没请求，但 DSH 进程还在** → 仍显示已连接。HTTP 是无状态的，静默不等于断开，所以用宿主进程存活兜底，避免 AI 停下来喝口水就变红。
- **DSH 进程都没了** → 未连接。

想改静默窗口，改插件顶部的 `CFG.ai_window_sec`（默认 120 秒）。

一个使用细节：CE 重启后 `ever_connected` 归零，要等 AI 发第一个请求才会变绿。这是有意的，避免「DSH 装着但根本没接这个 CE」也显示已连接。

---

## 兼容性

| 维度 | 状态 |
|---|---|
| **Cheat Engine 位数** | **仅 64 位**（`cheatengine-x86_64.exe`）。32 位构建明确拒绝，见下 |
| **CE 版本** | 7.5 实测通过。依赖 `executeCodeLocalEx`、`getAddressSafe(name, local)`、`createMemScan` + `waitTillDone`、`autoAssembleCheck`，都是 CE 7.x 的 API。6.x 未验证 |
| **Windows 版本** | Windows 10 build 19045 实测通过。7 / 8 / 8.1 / 11 理论可用 —— 只调 `ws2_32` / `kernel32` / `user32` 的老接口（Winsock 2.2、`LoadImageA`、`SendMessageA`、`MultiByteToWideChar`），没有用 Win11 专有的 DWM 属性。实际下限取决于 CE 本身支持到哪个 Windows |
| **架构** | x64 |
| **系统语言** | 中文系统（CP_936）正常。英文系统下，目标进程里读出的中文名会按 CP_1252 解释而乱码，工具本身照常工作 |
| **权限** | 继承 CE 进程的权限。附加受保护进程仍需管理员 |
| **网络** | 只监听 `127.0.0.1`，不触发防火墙入站规则 |

### 32 位 Cheat Engine 跑不了

这是硬边界，不是配置问题。32 位构建的 Lua 绑定里根本没有 `executeCodeLocalEx`，调用会直接抛：

```
executeCodeLocalEx is currently not supported on the 32-bit build
```

而整套 HTTP 服务器就建立在它之上 —— 用它在 CE 自己的进程里调 Winsock。没有它就没有服务器，也就没有 MCP。

插件会自己认出来，不会甩一串 Lua 报错：

```
23:03:02 unsupported: this is the 32-bit Cheat Engine build; use cheatengine-x86_64.exe
23:03:02 start failed: 32-bit Cheat Engine: not supported
```

这个分支**故意不弹模态框** —— 弹窗会堵死 CE 的消息循环。安装器在只找到 32 位构建时也会提前警告，不会让你装完了才发现。

要用它，换 `cheatengine-x86_64.exe`。

---

## 已知限制

- 只监听 `127.0.0.1`。要换端口，改 `YQ-CE-MCP.lua` 顶部的 `CFG.port`。
- 一次只处理一个请求。全进程范围的 `value_scan`（`whole=true`）会让 CE 界面卡住几秒到几十秒，这是 CE 扫描器本身在跑。
- 下断点会让目标进程真的停下，记得用 `debug_resume` 放行。
- 没附加进程时，内存类工具会返回错误而不是空结果。
- `lua_eval` 是完全放开的口子，执行什么由调用方负责。

---

## 排错

**端口被占用** — `install.ps1` 会先探测。手动改 `CFG.port` 后重启 CE。

**装好了但连不上** — 看日志：

```
%TEMP%\yq-ce-mcp.log
```

正常启动应该有这两行：

```
listening on http://127.0.0.1:8787/mcp
loaded v1.0.0 tools=30
```

**中文变成乱码** — CE 按系统代码页（GBK）读取 Lua 源文件。插件在 JSON 编码前会把字符串统一转成 UTF-8，客户端拿到的是合法 JSON。如果你自己改源码加了中文常量，不用额外处理，同一条链路会转。

**CE 版本** — 在 7.5 / Lua 5.3 上实测通过。更老的版本可能缺 `executeCodeLocalEx`，那样插件会在日志里报「Win32 桥初始化失败」。

**为什么插件里的字符串全是英文** — Cheat Engine 加载 `.lua` 时不按 UTF-8 解码，而是走系统代码页。中文注释和字符串会在加载阶段就被破坏（实测：UTF-8 源文件里的中文变成 GBK 乱码，转存成 GBK 源文件又会被二次解码成私用区字符），而且这个损坏发生在 Lua 拿到字符串之前，代码里再怎么转码都救不回来。工具描述又是给模型读的，英文本来就是更合适的形式。所以源码保持纯 ASCII。

目标进程里读出来的中文（进程名、模块路径、字符串值）不受影响：那些走的是运行时数据，插件会用 `MultiByteToWideChar` / `WideCharToMultiByte` 转成 UTF-8 再发出去。

**只弹模态框会卡死服务器** — `showMessage` 是模态的，会堵住 CE 的消息循环，`OnTimer` 随之停摆，之后所有请求超时。插件启动时不弹窗，`show_message` 工具也改成写标题栏。自己写扩展脚本时注意这一点。

---

## 文件

```
YQ-CE-MCP.lua     插件本体，装进 autorun\
yq-on.ico         状态灯：绿点（已连接），安装器会铺到 autorun\ 和 %TEMP%\
yq-off.ico        状态灯：红点（未连接）
install.bat       一键安装（双击）
install.ps1       安装逻辑
uninstall.bat     卸载
uninstall.ps1
bridge.py         stdio ↔ HTTP 桥，给只支持 stdio 的客户端
mcp.json          客户端配置片段
test_mcp.py       端到端自测（25 项，需要 notepad.exe 作为靶子）
```

跑自测：

```bash
python test_mcp.py
```
