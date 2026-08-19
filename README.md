# dsh-tray

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **Основано на** [spacecat398/dsh-tray](https://github.com/spacecat398/dsh-tray) — исходник, на котором построен этот репозиторий.

把仓库地址给你的 dsh-agent，你除了复制粘贴以外不需要做任何事情。

---

欢迎你，Agent 👋

这个仓库是一个 Windows 托盘程序：**DeepSeek Harness（dsh web）的常驻开关 + 看门狗**。托盘负责启动 / 重启 / 停止 dsh web、健康监控、崩溃自动拉起，还带"开启新对话"和日志复制。菜单语言跟随系统（中文 / English），一切参数通过 `dsh-tray.json` 配置。

下面的**协议**是给你（安装 / 配置 / 运维它的 Agent）看的操作契约。请先读完协议再动手，尤其是**安全规则**和**完成检查**。

---

## 📜 给 Agent 的协议（Agent Protocol）

本协议适用于安装、配置、启动、验证 dsh-tray 的 AI Agent。

### 1. Objective

在一台 Windows 机器上把 dsh-tray 部署为常驻托盘程序：开机自启、托盘控制 dsh web（默认端口 3080）、崩溃自动拉起。优先最小可用配置，不要引入额外依赖。

### 2. Requirements

- Windows 10/11（自带 PowerShell 5.1+，程序依赖 `powershell.exe`，不是 pwsh）
- Node.js 全局安装 dsh：`npm i -g @deepseek-ai/dsh`，且 `dsh web` 能启动
- 本仓库已克隆到目标机器（例如 `C:\dsh-tray\`）

### 3. Install

```powershell
# 1. 克隆（如尚未克隆）
git clone https://github.com/subfocusx/dsh-tray.git
# 2. 复制配置模板
Copy-Item dsh-tray.example.json dsh-tray.json
# 3. 按需编辑 dsh-tray.json（至少确认 startscript 指向一个能启动 dsh web 的脚本）
# 4. 启动托盘
wscript //nologo dsh-tray-launch.vbs
```

零依赖：纯 PowerShell + WinForms，不需要 npm install / pip / Docker。

### 4. Configure（dsh-tray.json）

| 键 | 默认 | 说明 |
|---|---|---|
| `port` | `3080` | dsh web 端口。**3080 是 dsh 的开箱默认端口**（官方 README 与 web-app 包内补丁均为 `?? 3080`）；healthurl/dashboardurl 由它派生 |
| `startscript` | `start-dsh.cmd` | 启动脚本；托盘以 `<port>` 作为 %1 调用它 |
| `dshlogfile` | `logs\dsh-web.log` | "复制最近日志"菜单读取的文件 |
| `healthintervalseconds` | `10` | 健康检查间隔（秒） |
| `startupgraceseconds` | `120` | 启动宽限期（期间只显示 Warming up） |
| `restartdelayseconds` | `5` | 崩溃重启基础延迟；退避上限 ×6 = 30s |
| `maxconsecutiverestarts` | `10` | **v1.7.1** 连续崩溃自动重启上限（退避随次数 5s→30s 增长）；达到后停止自动重启，状态显示「需要干预」，手动「重启 dsh」重置计数并恢复自动重启 |
| `language` | `auto` | `auto`（跟随系统）/ `zh` / `ru` / `en` |
| `notifications` | `true` | 状态跳变通知气泡开关 |
| `whaleicon` | `true` | 健康时使用鲸鱼图标（`assets\dsh-whale.png`） |
| `agentmonitor` | `true` | **v1.4.0** 开启「代理 (Agents)」子菜单与轮询 |
| `agentpollseconds` | `5` | **v1.4.0** 代理轮询间隔（秒，最小 2） |
| `agentnotifications` | `true` | **v1.4.0** 代理启动 / 完成 / 等待时通知气泡 |
| `badgeicon` | `true` | **v1.4.0** 在托盘图标上叠加运行中代理数量徽标 |
| `maxagentloglines` | `200` | **v1.4.0** 代理日志窗口显示行数上限 |
| `agenthistorylines` | `40` | **v1.4.0** 拉取 subagent.history 事件数（日志尾部） |
| `chromeapplnk` | *(空)* | **v1.4.1** Chrome App 快捷方式路径。设置后「打开面板」/双击图标/新对话都在独立 Chrome 应用窗口打开，而非新标签页；为空或失效则回退为普通浏览器标签。常见位置：① `Start Menu\Programs\Chrome Apps\DeepSeek Harness.lnk`；② 若 PWA 安装在某个 Chrome 配置文件内：`…\Chrome\User Data\Profile N\Web Applications\_crx_<appid>\DeepSeek Harness.lnk`（用真实存在的那个，检查其目标是 `chrome_proxy.exe` 而非 `dsh-tray-launch.vbs`） |
| `menutheme` | `dark` | **v1.5.0 / v1.8.0** 菜单与 toast 主题：`auto`（跟随系统明/暗）/ `light` / `dark`。**v1.8.0 起默认 `dark`**，且可在托盘菜单「主题 / Theme / 主题」子菜单中即时切换（写回 dsh-tray.json，无需重启） |
| `toastson` | `true` | **v1.5.0** `true` → 现代 Windows 11 通知（自绘圆角 toast + 强调色条 + 鲸鱼图标）；`false` → 经典系统气泡（回退） |
| `toastduration` | `4000` | **v1.8.0** toast 自动关闭前停留时间（毫秒，范围 1000–60000）。**v1.8.0 修复了 toast「永远不消失」**：所有 toast 计时器现在有根引用，另有 250ms 巡检在 duration+2500ms 硬上限强制关闭，任何情况下 toast 都不会无限悬挂 |
| `menubicons` | `true` | **v1.5.0** 在菜单项上显示 MDL2 图标（Segoe MDL2 Assets 字体内置绘制，无需外部图片） |
| `uifont` | `Segoe UI Variable Text` | **v1.6.0** 菜单与 toast 的统一字体；系统无此字体时自动回退 `Segoe UI` |
| `uifontsize` | `9` | **v1.6.0** 菜单 / toast 正文字号的基准（pt）；标题自动 +1 |
| `updatecheck` | `true` | **v1.6.0** 是否检查 `@deepseek-ai/dsh`（npm）的新版本 |
| `updateintervalhours` | `24` | **v1.6.0** 自动检查周期（小时）；`0` 关闭周期检查（仍保留手动菜单项） |
| `updateapply` | `true` | **v1.6.0** 是否允许一键应用更新（`npm i -g @deepseek-ai/dsh@latest`） |

### 5. 运行与验证（Completion Check）

报告完成前，逐条核对：

1. `dsh-tray.ps1` 能被 Windows PowerShell 5.1 正常解析（**文件必须保存为 UTF-8 with BOM**，否则中文按 ANSI 解码直接语法崩溃）
2. 托盘进程在运行且**单实例**：
   ```powershell
   Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match '-File.*dsh-tray\.ps1' }
   ```
3. 托盘菜单完整：状态行 / 打开面板 / 开启新对话 / 重启 dsh / 停止 dsh / **退出** / 复制最近日志 / 开机自启 / 代理 (Agents)
4. dsh web 健康：菜单状态行显示 `Healthy (:<port>)`，且 `Get-NetTCPConnection -LocalPort <port> -State Listen` 有监听（默认 3080）
5. 托盘日志 `logs\dsh-tray.log` 有 `Tray application starting ... v1.x.x` 记录，无 FATAL
6. 开机自启已按用户意愿设置（托盘菜单勾选，或 `powershell -File install-autostart.ps1`）

### 6. 安全规则

- 不要提交或暴露 `dsh-tray.json`（含本机路径）、`logs/`、任何 `*.log`（仓库 `.gitignore` 已排除，保持即可）
- `dsh-tray.ps1` 含中文，**必须 UTF-8 with BOM**；编辑后务必重新确认 BOM 存在
- 停止 dsh 时托盘会先校验进程身份（node/bun + 命令行含 dsh）再 `taskkill`，**不要绕过该校验去杀任意进程**
- 不要随意改端口，除非用户明确要求（两个 URL 都由 port 派生，改 `port` 即可，别手改 URL）
- 不要把托盘提升为管理员 / 服务运行 —— 它是普通用户级常驻程序
- 本机安全注意：若系统防火墙 Private 配置文件被关闭，其他 0.0.0.0 监听服务可能对局域网可见（与托盘无关，但值得提醒用户）

### 7. 运行约束

- 平台：Windows + PowerShell 5.1（`powershell.exe`），**不是 pwsh**
- 托盘常驻：**"停止 dsh"** 只停服务、托盘留在系统托盘中；**"退出"（v1.4.1）** 停止服务并彻底关闭托盘程序本身
- 看门狗**只管生命周期、不管快慢**：进程活着绝不杀（慢启动不误杀）；进程消失才重启（5s→30s 退避）
- "开启新对话"优先用 UI Automation 驱动 GUI 自己的"新建会话"流程（点按钮→选新条目，创建/切换/持久化全由 GUI 处理）；GUI 不可达时回退 RPC 建会话 + 新标签页
- 健康检查与 dsh web 服务全部绑定 127.0.0.1，不对局域网开放
- 修改 `dsh-tray.ps1` 后需要重载托盘才生效：先杀旧托盘进程，再运行 `dsh-tray-launch.vbs`

### 8. 重要文件

```text
dsh-tray.ps1            # 主控：WinForms 托盘 + 看门狗 + 菜单 + 配置加载 + i18n
dsh-tray-launch.vbs     # 无窗口启动器（双击 / 开机自启入口）
install-autostart.ps1   # 开机自启安装 / 卸载
start-dsh.cmd           # 默认 dsh 启动模板（接收 %1 = 端口）
dsh-tray.example.json   # 配置模板（复制为 dsh-tray.json）
assets\dsh-whale.png    # 鲸鱼托盘图标
logs\dsh-tray.log       # 托盘自身日志（运行时生成，不入库）
```

---

## 功能一览（给人类）

| 功能 | 说明 |
|---|---|
| 🖱️ 托盘菜单 | 状态行 / 打开面板 / **开启新对话** / **代理 (Agents)** / 重启 dsh / 停止 dsh / **退出** / 复制最近日志 / 开机自启 |
| 🧭 三语 | 菜单、状态、通知气泡按系统语言自动切换：中文 / English / **Русский**（`language` 可强制） |
| 🐳 健康图标 | 健康 = 鲸鱼图标；异常 = 系统警告/错误图标 |
| 🔢 徽标徽章 | **v1.4.0** 健康时在鲸鱼图标右上角叠加当前运行中代理数量的红色徽章 |
| 🕵️ 代理监控 | **v1.4.0** "代理 (Agents)" 子菜单实时列出运行中/等待输入的子代理，每个可「查看日志」「停止」 |
| 📜 代理日志 | **v1.4.0** 弹窗展示代理最近输出（assistant 正文 + turn 结束原因），点击「查看日志」打开 |
| 🔔 代理通知 | **v1.4.0** 代理启动 / 完成 / 等待输入时通知气泡（`agentnotifications` 可关） |
| 💬 通知气泡 | 状态跳变（启动/停止/恢复/异常/自动重启）时通知，不刷屏 |
| ⏱️ Toast 自动关闭 | **v1.8.0** 修复 toast 悬挂问题：自动关闭计时器全部根级持有 + 250ms 硬截止扫描（duration+2500ms 强制关闭），toast 再也不会「一直挂着」；停留时长可用 `toastduration` 调节 |
| 🌙 深色设计 | **v1.8.0** 默认深色主题；菜单 / toast / 图标全套深色调色板（近黑面板、柔和悬停、高对比文字）；菜单「Тема / Theme / 主题」即时切换 自动/浅色/深色并写入配置 |
| 🪟 Chrome 应用 | **v1.4.1** 「打开面板」/双击图标/新对话在独立 **Chrome 应用（PWA）** 窗口打开，而非新标签页（配置 `chromeapplnk` 指向 `Chrome Apps\DeepSeek Harness.lnk`；失效则回退普通标签页） |
| 🚪 退出 | **v1.4.1** 「退出」停止 dsh 服务并彻底关闭托盘程序本身（「停止 dsh」只停服务、托盘留在托盘） |
| 🛡️ 看门狗 | 只管生命周期：进程活着绝不杀；崩溃才重启（5s→30s 退避） |
| 🔍 更新检查 | **v1.6.0** 「检查更新」菜单 + 周期自动检查 `@deepseek-ai/dsh`（npm）；发现新版 → Win11 toast；`updateapply: true` 时「更新到 vN」一键安装并重启 |
| 🔤 平滑字体 | **v1.6.0** 菜单 / toast / MDL2 图标统一使用平滑抗锯齿字体（`uifont`，默认 Segoe UI Variable，自动回退）+ 进程级 DPI 感知，不再“锯齿/毛边” |
| 🎯 停止安全 | 杀进程前校验身份（node/bun + 命令行含 dsh），不误杀外来进程 |
| 🆕 开启新对话 | 驱动 GUI 自己的"新建会话"流程，**真正打开新空对话** |
| 📋 复制日志 | 一键复制最近 25 行 dsh 日志到剪贴板 |
| 🔄 防双开 | Mutex `Local\DshTray-<port>` |
| ⚙️ 配置文件 | 所有参数在 `dsh-tray.json`，无需改脚本 |

**使用**：双击 `dsh-tray-launch.vbs` 启动；开机自启在菜单里勾选"开机自启"；**"停止 dsh"** 只停服务（托盘留下），**"退出"** 停服务并彻底关闭托盘。

## 📜 版本历史

| 版本 | 内容 |
|---|---|
| **v1.8.0** | 🔔 **toast 自动关闭修复 + 深色设计**：修复通知「挂在屏幕永不消失」——根因是 fade-out / 自动关闭的 WinForms Timer 作为事件闭包里的无根局部变量被 GC 回收，fade 永不执行；现在所有 toast 计时器挂在脚本级注册表（`$script:ToastTimers`）+ toast 上下文包，另加 250ms 硬截止扫描（duration+2500ms 强制关闭），toast 寿命有严格上限。新增 `toastduration`（毫秒，默认 4000）。🌇 **深色设计**：默认 `menutheme: dark`，菜单/toast/图标深色调色板重做（更漆黑的表面、更柔和的悬停、深色下更高对比）；菜单图标按主题即时重绘；新增菜单「Тема ▸ 自动/浅色/深色」子菜单，即时切换并把 `menutheme` 写回 `dsh-tray.json`。 |
| **v1.7.1** | 🛡️ **崩溃-循环稳定化 + 不再卡 UI 的菜单动作**：修复 backoff 永不增长的 bug（RestartCount 不再在每次 `Start-Process` 后被清零，只在真正 Healthy 时重置 → 退避 5s→30s 真实生效）；新增 `maxconsecutiverestarts`（默认 10）上限，超过后停止自动重启、状态「需要干预」+ 一次错误 toast，手动「重启 dsh」重置。「开启新对话」与「停止代理」改为后台 runspace 执行（UI Automation / RPC 不再阻塞点击，新对话菜单项在执行期间显示禁用/"…"）；`Read-Config` 数值字段校验（非数字/非正/越界 → WARN + 回退默认值）。 |
| **v1.6.0** | ✨ **统一平滑字体 + 更新检查**：菜单/图标/toast 统一使用配置字体（`uifont`，默认 Win11 的 Segoe UI Variable，自动回退 Segoe UI）；MDL2 图标与文字改用平滑抗锯齿（`Antialias` 替代 `AntiAliasGridFit`），消除“锯齿/毛边”；新增进程级 DPI 感知。新增**「检查更新」**菜单 + 周期自动检查（`updatecheck`/`updateintervalhours`）**@deepseek-ai/dsh（npm）**新版本；发现新版 → Win11 toast「发现新版本 X → Y」；`updateapply: true` 时**「更新到 vN」一键 `npm i -g` 并重启 dsh**。 |
| **v1.5.0** | ✨ **Windows 11 现代 UI**：菜单改用 fluent 配色 + 跟随系统明/暗主题 + DWM 圆角；菜单项加 MDL2 图标（保留 DeepSeek 鲸鱼品牌）；状态/错误/停止托盘图标改为鲸鱼 + 彩色圆环（不再用系统标准图标，并修复旧 `DrawIcon` 徽标 WARN）；通知由经典气泡升级为自绘 Windows 11 toast（圆角 + 强调色条 + 鲸鱼 + 点击打开 + 4 秒自关）。新配置：`menutheme` / `toastson` / `menubicons` |
| **v1.4.1** | 🪟 **打开独立 Chrome 应用窗口**：明确「打开面板」与「开启新对话」的走向——**打开面板/双击图标**→ 打开/激活 Chrome 应用窗口；**开启新对话** → 优先在已打开的 Chrome 应用窗口内驱动 GUI 新建会话，不可达时回退 RPC 建会话 + 打开 Chrome 应用；新增 **「退出」** 菜单（停止 dsh 服务并彻底关闭托盘程序）；配置 `chromeapplnk` 指向 `Chrome Apps\DeepSeek Harness.lnk`，为空/失效时自动回退普通标签页。`launch.cmd` 同步改为打开同一个 PWA 快捷方式（原先硬编码的 `Profile 1` 与真实 `Profile 5` 不符） |
| **v1.4.0** | 🕵️ **代理监控 + 通知 + 徽章**：新增「代理 (Agents)」子菜单（实时运行/等待列表，查看日志、停止）；代理启动/完成/等待输入通知气泡；鲸鱼图标右上角运行数量徽章；新增 `agentmonitor` / `agentpollseconds` / `agentnotifications` / `badgeicon` / `maxagentloglines` / `agenthistorylines` 配置；菜单新增 **Русский** 语言 |
| **v1.3.0** | 🔧 **默认端口修正为 3080**：此前默认 3090 实为作者本机 profile 覆盖（为与 WSL 实例共存），dsh 开箱默认是 3080（官方 README + 包内补丁确认）；本地配置显式写端口则不受影响 |
| **v1.2.0** | 🔥 **开启新对话真正生效**：UI Automation 驱动 GUI 自身流程，彻底绕开浏览器 localStorage 限制；GUI 不可用时回退 RPC + 新标签页 |
| **v1.1.1** | 修复新对话不可见：会话挂到当前工作区 + 唯一 fragment 强制新标签页 |
| **v1.1.0** | 正式发布版：配置文件、中英双语、新菜单、通知气泡、看门狗强化 |

## 📄 License

[MIT](./LICENSE)

---

## English

**dsh-tray** is a Windows-native tray switch + watchdog for the DeepSeek Harness (`dsh web`). Give the repo URL to your dsh-agent — you don't need to do anything but copy-paste.

- Menu: status / Open Dashboard / **New Conversation** / **Agents** / Restart / Stop / **Exit** / Copy Recent Log / Start with Windows. ("Stop" stops only the server; "Exit" (v1.4.1) stops the server and fully closes the tray app)
- **Agents monitor (v1.4.0):** a live "Agents" submenu lists running + waiting-for-input subagents, each with **Show log** (window with the recent output) and **Stop**; native balloons fire on agent start / finish / wait; the whale icon shows a running-count badge. All toggles via config: `agentmonitor`, `agentpollseconds`, `agentnotifications`, `badgeicon`, `maxagentloglines`, `agenthistorylines`.
- Languages: zh / **English** / **Русский** (auto-follows the system UI).
- New Conversation drives the GUI's own flow via UI Automation — a fresh empty conversation truly opens
- Watchdog manages lifecycle, not liveness: a live-but-slow process is never killed; crashes restart with 5s → 30s backoff; Stop verifies process identity before taskkill
- Config: copy `dsh-tray.example.json` → `dsh-tray.json`; default port **3080** (dsh's out-of-the-box default)
- **Chrome App (v1.4.1):** "Open Dashboard", double-click and New Conversation open the UI in the installed **Chrome App (PWA)** window (own `profile-directory` + `--app-id`) instead of a new tab; set `chromeapplnk` to the `Chrome Apps\DeepSeek Harness.lnk` path, falls back to a regular tab if unset/missing.
- **Modern Windows 11 UI (v1.5.0):** fluent menu that follows the system light/dark theme (`menutheme: auto|light|dark`) with MDL2 item icons (`menubicons`) and DWM rounded corners; tray state icons stay branded (whale + colour ring) instead of stock SystemIcons; notifications are self-drawn Win11 toasts (rounded, accent bar, whale icon, click-to-open, auto-dismiss) — set `toastson: false` to fall back to classic balloons.
- **Smooth fonts + update checks (v1.6.0):** a unified configurable UI font (`uifont`, default Win11 "Segoe UI Variable" with automatic Segoe UI fallback; `uifontsize`) is applied to the menu, toasts and MDL2 icons; MDL2 glyphs and text now use smooth anti-aliasing (`Antialias` instead of `AntiAliasGridFit`) plus process-level DPI awareness, removing jagged/"rough" edges. A **「Check for Updates」** menu item plus a periodic auto-check (`updatecheck`, `updateintervalhours`) polls **`@deepseek-ai/dsh` on npm**; a new version raises a Win11 toast "New version X → Y", and with `updateapply: true` a **「Update to vN」** item runs `npm i -g @deepseek-ai/dsh@latest` and restarts dsh in one click.
- Requires `npm i -g @deepseek-ai/dsh`; Windows PowerShell 5.1+; UTF-8 **with BOM** for `dsh-tray.ps1` (contains non-ASCII zh/ru) — a bare no-BOM UTF-8 file is decoded as ANSI and will not parse
- **Crash-loop hardening (v1.7.1):** the restart backoff really escalates now (5s → 30s, `restartdelayseconds * min(restarts, 6)`) because the crash counter is only reset when dsh is confirmed Healthy again; after `maxconsecutiverestarts` (default 10) consecutive crashes the tray stops auto-restarting, shows a "Needs intervention" status + one error toast, and the manual **Restart dsh** item resets the counter. "New Conversation" and "Stop agent" menu actions run their UI-Automation/RPC work on background runspaces so clicks never block the UI; `Read-Config` now rejects garbage numeric config values with a logged WARN.
- **Toast auto-dismiss fixed + dark design (v1.8.0):** toasts no longer hang on screen forever — the auto-dismiss/fade timers now live on a script-scope registry plus the toast's own context, and a 250ms sweep force-closes any toast past `toastduration` (default 4000 ms) + 2.5 s, so a toast's lifetime is strictly bounded. The app now ships dark by default (`menutheme: dark`), with a reworked dark palette for the menu, fluent color table and toasts; a new **Theme** submenu (Auto / Light / Dark) switches the look live and persists `menutheme` to `dsh-tray.json`.
