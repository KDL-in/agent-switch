# Agent Switch

在 Windows 上一键部署 [CC Switch Web](https://github.com/Laliet/cc-switch-web) + [Mihomo (Clash Meta)](https://github.com/MetaCubeX/mihomo)，统一管理 AI 供应商、代理出站，并自动配置多种 AI Agent CLI。

## 项目简介

如果你同时使用多个 AI 编程助手（Claude Code、Codex、Gemini CLI、OpenCode 等），通常会碰到这些问题：

- **供应商分散**：每个 Agent 各自维护 API Key、Base URL、模型配置，切换成本高
- **网络环境复杂**：部分 AI API 需要代理才能稳定访问，但每个 CLI 单独配代理很麻烦
- **配置容易丢失**：重装系统或换机器后，要重新找文档、填一遍配置

Agent Switch 把这些问题合并成一套本地基础设施：

| 能力 | 说明 |
|------|------|
| **统一供应商管理** | 通过 CC Switch Web UI 集中配置 OpenAI、Anthropic、Google 等供应商和 API Key |
| **统一代理出站** | 所有 AI 请求经 CC Switch 转发，出站流量自动走 Clash 代理节点 |
| **一键 Agent 配置** | 安装脚本自动写入 Claude / Codex / Gemini / OpenCode 的配置文件，指向本地代理 |
| **可视化运维** | Web UI 管理供应商，YACD 面板管理 Clash 节点，PowerShell 脚本负责启停和切换 |

典型使用场景：在 Windows 开发机上跑 AI Agent CLI，需要稳定访问海外 API，且希望在多个 Agent 之间共享同一套供应商和代理策略。

## 架构概览

```
┌─────────────────────────────────────────────────────────────────┐
│  宿主机 (Windows)                                                │
│                                                                 │
│  AI Agent CLI          浏览器                                    │
│  Claude / Codex /      Web UI (:3000)                          │
│  Gemini / OpenCode     YACD 面板 (:9097)                       │
│       │                      │                                  │
│       │ :3457                │ :3000 / :9097                   │
│       ▼                      ▼                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Docker Compose (agent-switch-net)                      │   │
│  │                                                         │   │
│  │  cc-switch-proxy ──► cc-switch ──HTTP_PROXY──► clash   │   │
│  │  (socat 端口转发)      (供应商管理)              (Mihomo) │   │
│  │                            ▲                            │   │
│  │  cc-switch-gate ───────────┘                            │   │
│  │  (nginx 网关)                                           │   │
│  │                                                         │   │
│  │  clash-ui ──► clash API (:9090)                         │   │
│  │  (YACD 面板)                                            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
└──────────────────────────────┼──────────────────────────────────┘
                               ▼
                         VPN 节点 ──► AI API
```

**请求路径（Agent CLI）**：CLI → 本地代理 `:3457` → CC Switch → Clash `:7890` → 订阅节点 → AI 供应商 API

**请求路径（浏览器）**：浏览器 → nginx 网关 `:3000` → CC Switch Web UI；或浏览器 → YACD `:9097` → Clash 面板

## Docker 架构

`docker-compose.yml` 定义 5 个服务，全部接入 `agent-switch-net` 桥接网络（`cc-switch-proxy` 例外，见下文）。

| 容器 | 镜像 | 职责 |
|------|------|------|
| **clash** | `metacubex/mihomo` | Clash Meta 核心，提供 HTTP 代理 (`7890`) 和 REST API (`9090`)，读取 `config/clash/` 下的订阅与规则 |
| **clash-ui** | `haishanh/yacd` | YACD 可视化面板，通过 Clash API 展示节点、规则和连接状态 |
| **cc-switch** | `ghcr.io/laliet/cc-switch-web` | CC Switch Web 后端，管理 AI 供应商配置；通过 `HTTP_PROXY` 环境变量让出站流量走 Clash |
| **cc-switch-gate** | `nginx:alpine` | Web UI 反向代理网关，对外暴露 `:3000`；代填 Basic Auth，浏览器访问无需手动登录 |
| **cc-switch-proxy** | `alpine/socat` | 端口转发 Sidecar，将 `:3457` 映射到 CC Switch 内部 `:3456`，供 Agent CLI 连接 |

### 容器依赖关系

```
clash (健康检查通过)
  ├── clash-ui
  ├── cc-switch
  │     ├── cc-switch-gate
  │     └── cc-switch-proxy (network_mode: service:cc-switch)
  └── ...
```

- **clash** 最先启动，通过 healthcheck 确认 API 可用后，其他服务才启动
- **cc-switch** 挂载 `./data/cc-switch` 持久化供应商配置和密钥
- **cc-switch-proxy** 与 cc-switch 共享网络命名空间（`network_mode: service:cc-switch`），实现 Sidecar 模式，无需额外端口映射

### 端口映射

| 端口 | 服务 | 绑定 | 访问方 |
|------|------|------|--------|
| `3000` | cc-switch-gate | `0.0.0.0` | 浏览器 → Web UI |
| `3457` | cc-switch-proxy | `127.0.0.1` | Agent CLI → 本地代理 |
| `7890` | clash | `0.0.0.0` | 可选，供宿主机其他程序使用 |
| `9090` | clash API | `127.0.0.1` | 脚本切换节点 |
| `9097` | clash-ui | `127.0.0.1` | 浏览器 → YACD 面板 |

Agent 代理和 Clash 管理端口仅绑定 `127.0.0.1`，避免局域网暴露；Web UI 绑定 `0.0.0.0` 方便本机浏览器访问。

### 数据持久化

| 路径 | 说明 |
|------|------|
| `config/clash/` | Clash 配置与订阅（运行时由 `setup.ps1` 生成 `config.yaml`） |
| `data/cc-switch/` | CC Switch 供应商配置、API Key、Web 密码等 |
| `config/nginx/` | nginx 网关配置（只读挂载） |

## 隐私与安全

以下内容**仅保存在本机**，已被 `.gitignore` 排除，**不会进入 Git 仓库**：

| 文件 / 目录 | 含敏感信息 |
|-------------|-----------|
| `.env` | Clash 订阅链接 `CLASH_SUB_URL` |
| `config/clash/config.yaml` | 代理节点密码、服务器地址 |
| `config/clash/providers/` | 订阅拉取后的节点列表 |
| `data/cc-switch/` | AI 供应商 API Key、`managed-auth.key`、Web 密码 |

提交前请确认：

```powershell
git status          # 不应出现 .env、config/clash/config.yaml、data/
git diff --cached   # 确认暂存区无订阅链接或 API Key
```

仓库中只保留 `.env.example`（占位符）和 `config/clash/config.yaml.example`（模板）。若订阅链接曾意外提交，需轮换订阅并清理 Git 历史。

## 快速开始

```powershell
git clone <repo-url> agent-switch
cd agent-switch
.\install.bat
```

或：

```powershell
.\bin\install.bat
scripts\install.ps1 -Agents claude,codex
```

## 目录结构

```
agent-switch/
├── README.md                 # 项目说明
├── .env.example              # 环境变量模板
├── docker-compose.yml        # Docker 编排（基础设施层）
│
├── bin/                      # 用户入口（双击 / 命令行）
│   ├── install.bat           # 一键安装
│   ├── start.bat             # 启动服务
│   └── stop.bat              # 停止服务
│
├── scripts/                  # 运维脚本
│   ├── lib/
│   │   └── common.ps1        # 公共函数（路径、Docker、.env）
│   ├── install.ps1           # 安装主逻辑
│   ├── setup.ps1             # 部署 + 健康检查
│   ├── start.ps1             # 启动
│   ├── stop.ps1              # 停止
│   ├── start-proxy.ps1       # 启动 CC Switch 代理
│   ├── setup-agents.ps1      # 配置 AI Agent CLI
│   ├── setup-claude.ps1      # Claude 快捷配置
│   ├── switch-node.ps1       # 切换 Clash 节点
│   ├── install-autostart.ps1 # 注册开机自启
│   ├── uninstall-autostart.ps1
│   └── verify-browser.mjs    # Web UI 端到端验证
│
├── config/                   # 配置模板（运行时生成 config.yaml）
│   ├── clash/
│   │   └── config.yaml.example
│   └── nginx/
│       └── cc-switch-gate.conf
│
└── data/                     # 运行时数据（git 忽略）
    └── cc-switch/
```

根目录的 `install.bat` / `start.bat` / `stop.bat` 是指向 `bin/` 的快捷入口。

## 前置要求

- Windows 10/11
- PowerShell 5.1+
- Docker Desktop（`install.ps1` 可自动安装）

## 安装

| 命令 | 说明 |
|------|------|
| `install.bat` | 交互式一键安装 |
| `scripts\install.ps1 -Silent` | 静默安装 |
| `scripts\install.ps1 -Agents claude,codex` | 只配置指定 Agent |
| `scripts\install.ps1 -SkipDockerInstall` | 跳过 Docker 安装 |

## 日常使用

| 命令 | 说明 |
|------|------|
| `start.bat` | 启动全部服务 |
| `stop.bat` | 停止全部服务 |
| `scripts\switch-node.ps1` | 交互式切换 Clash 节点 |
| `scripts\setup-agents.ps1` | 重新配置 Agent CLI |

## 支持的 AI Agent

| Agent | 配置文件 | 连接方式 |
|-------|---------|---------|
| Claude Code | `~/.claude/settings.json` | `ANTHROPIC_BASE_URL` |
| Codex CLI | `~/.codex/config.toml` | `base_url` → `/v1` |
| Gemini CLI | `~/.gemini/.env` | `GOOGLE_GEMINI_BASE_URL` |
| OpenCode | `~/.config/opencode/opencode.json` | `baseURL` |

## 服务地址

| 服务 | 地址 |
|------|------|
| Web UI | http://localhost:3000 |
| Agent 代理 | http://127.0.0.1:3457 |
| Clash 面板 | http://127.0.0.1:9097 |
| Clash HTTP 代理 | localhost:7890 |

## 环境变量

复制 `.env.example` 为 `.env`：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CC_SWITCH_PORT` | 3000 | Web UI 端口 |
| `CC_SWITCH_PROXY_PORT` | 3457 | Agent 代理端口 |
| `CLASH_HTTP_PORT` | 7890 | Clash HTTP 代理 |
| `CLASH_API_PORT` | 9090 | Clash API |
| `CLASH_UI_PORT` | 9097 | YACD 面板 |
| `CLASH_SUB_URL` | — | Clash 订阅链接 |

## 配置 Clash

1. **Clash Verge 自动导入**（推荐）：`scripts\setup.ps1` 读取本机 Verge 活跃订阅
2. **订阅链接**：在 `.env` 设置 `CLASH_SUB_URL` 后运行 `scripts\setup.ps1`
3. **手动编辑**：复制 `config/clash/config.yaml.example` 为 `config.yaml`

## 开机自启动

```powershell
scripts\install-autostart.ps1
scripts\uninstall-autostart.ps1
```

## 故障排查

```powershell
docker compose ps                          # 查看容器状态
docker compose logs -f cc-switch           # 查看日志
scripts\setup-agents.ps1                   # 重新配置 Agent
```

验证 Clash 出站：

```powershell
docker run --rm --network agent-switch_agent-switch-net curlimages/curl:8.5.0 `
  -s -o /dev/null -w "%{http_code}" -x http://clash:7890 http://www.gstatic.com/generate_204
```

期望输出 `204`。

## 参考链接

- [cc-switch-web](https://github.com/Laliet/cc-switch-web)
- [CC Switch](https://github.com/farion1231/cc-switch)
- [Mihomo](https://github.com/MetaCubeX/mihomo)
