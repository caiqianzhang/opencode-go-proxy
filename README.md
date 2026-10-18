# opencode-go-proxy

本地反向代理，让 Codex 能使用 OpenCode Go 的推理接口。

OpenCode Go 强制要求每个请求携带稳定的 `x-opencode-session` 头，而 Codex 不发这个头。
Codex 会发送自己的 `thread-id` / `session-id`，这个代理把二者对应起来，其余请求和响应原样转发。

```
Codex  --POST /v1/responses-->  本地代理  --POST /v1/responses-->  OpenCode Go
         thread-id: abc          (补 x-opencode-session)          inference/go/openai
```

## 行为

| 输入（Codex 请求头） | 输出（`x-opencode-session`） |
| --- | --- |
| `thread-id: abc` | `sess-abc` |
| 无 `thread-id`，有 `session-id: def` | `sess-def` |
| 无 `thread-id`，有 `x-client-request-id: ghi` | `sess-ghi` |
| 三者都没有 | `sess-<随机 UUID>` |

同一对话复用同一个 session 值，因此上游路由和 prompt 缓存保持一致。

## 修复子 Agent 收不到任务

Codex 的 MultiAgent V2 给子 Agent 派任务时，请求体里用的是 OpenAI 内部格式：

```json
{
  "type": "agent_message",
  "author": "/root",
  "recipient": "/root/child",
  "content": [
    {"type": "input_text", "text": "Message Type: NEW_TASK\nTask name: /root/child\nPayload:\n"},
    {"type": "encrypted_content", "encrypted_content": "真正的任务内容"}
  ]
}
```

`agent_message` 和 `encrypted_content` 都不是 Responses API 的公开类型。第三方实现只认识
`message` / `function_call` / `function_call_output` / `reasoning`，于是整项被丢弃，子 Agent
只看到 `Payload:` 为空的信封，表现就是"没有任务 / 待命"。

代理会做一次改写（仅当请求里出现这两类字段时）：

| 原内容 | 改写后 |
| --- | --- |
| `agent_message` 输入项 | `message`，`role: "user"` |
| `encrypted_content` 内容块 | `input_text` 内容块 |

改写只替换 `input` 数组里受影响的那一项，其他字节（包括 key 顺序和大整数）保持原样，
因此普通请求和未受影响的前缀缓存不受影响。

如果 `encrypted_content` 不像明文（例如包含二进制/控制字符），或者你显式关闭了解包：

```bash
-no-unwrap-encrypted-content
```

代理会保留原始 `agent_message` 项并记录 warning，不会把真密文当任务正文喂给模型。

已知限制：如果父 Agent 用 OpenAI 官方模型、子 Agent 用第三方模型，父方发出的
`encrypted_content` 是真密文，本地代理无法解密，需要等上游修复；此时请使用
`-no-unwrap-encrypted-content`，让代理保持原样而不是输出密文。

此外：

- 转发全部 `/v1/*` 路径，`.../openai` 加 `/v1/responses` 拼成正确的上游地址。
- 流式响应不缓冲（SSE 逐块透传），不做压缩转换。
- 配置了 key 时用其覆盖入站的 `Authorization`。
- 剥离 Codex 专有请求头（`x-codex-*`、`thread-id` 等）。
- 每个请求记录一行日志，只含方法、路径和 session，不含 Authorization 和请求体。

## 构建

本机没有 Go 工具链，用容器构建：

```bash
docker run --rm -v "$PWD":/src -w /src golang:1.23-alpine \
  sh -c 'go build -trimpath -ldflags "-s -w" -o opencode-go-proxy .'
```

测试：

```bash
docker run --rm -v "$PWD":/src -w /src golang:1.23-alpine go test ./...
```

## 运行

```bash
export OPENCODE_GO_API_KEY='oc_sk_...'
./opencode-go-proxy -listen 127.0.0.1:8787
```

## 一键配置 Codex

交互式配置脚本参考了 DeepSeek 官方脚本的思路：菜单选择、配置备份、原子写入和恢复。

Linux / macOS / WSL：

```bash
bash scripts/setup.sh
```

Windows PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
```

也可以从 GitHub 直接运行（仓库为公开时）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/caiqianzhang/opencode-go-proxy/main/scripts/setup.sh)
```

```powershell
irm https://raw.githubusercontent.com/caiqianzhang/opencode-go-proxy/main/scripts/setup.ps1 | iex
```

菜单：

- `1`：使用远端 `https://<your-proxy-host>:9876/codex/v1`
- `2`：使用本机代理（仅 Linux systemd）
- `9`：恢复最近一次备份

Windows 的 `setup.ps1` 当前支持 `remote` 和 `restore`；本机代理模式请使用 WSL 或 Linux。

远端模式会要求输入 client token，并写入：

```toml
[model_providers.opencode-go]
name = "OpenCode Go"
base_url = "https://<your-proxy-host>:9876/codex/v1"
wire_api = "responses"
experimental_bearer_token = "<client token>"
```

脚本会优先复用 `~/.codex/models.newapi.json` 或 `~/.codex/models.json` 作为模型目录；
如果没有，可用 `--catalog /path/to/models.json` 指定。备份位于
`~/.codex/backup-opencode-go-proxy/`，其中 `original` 始终保留首次安装前的配置。

### 监听地址

`-listen` 可以是任意合法的 `host:port`，不限于 `127.0.0.1`：

| 地址 | 含义 |
| --- | --- |
| `127.0.0.1:8787` | 仅本机（默认，最安全） |
| `192.168.1.20:8787` | 只监听某个内网 IP |
| `0.0.0.0:8787` | 所有 IPv4 网卡 |
| `[::]:8787` | 所有 IPv6 网卡 |

绑定非回环地址时，代理会打印 warning。此时建议同时设置入站鉴权：

```bash
export PROXY_CLIENT_TOKEN='a-long-random-token'
./opencode-go-proxy -listen 0.0.0.0:8787 -client-token "$PROXY_CLIENT_TOKEN"
```

Codex 侧把 `experimental_bearer_token` 设成这个 client token；代理会用
`OPENCODE_GO_API_KEY` 覆盖发往上游的 Authorization。否则任何能访问该端口的人
都可以使用你的上游 key。

## 开机自启（systemd user service）

`deploy/install.sh` 会把二进制安装到 `~/.local/bin/opencode-go-proxy`，写入服务单元、
保存密钥、启用并重启服务，之后每次登录自动运行。

```bash
cd /home/you/zcq/opencode_go_proxy
export OPENCODE_GO_API_KEY='oc_sk_...'
bash deploy/install.sh
```

密钥单独存放在 `~/.config/opencode-go-proxy.env`（权限 600），不写进 unit 文件。
重复执行是安全的：会更新二进制和密钥，并显式重启服务。

服务监听地址和入站 token 也通过环境变量配置：

```bash
export PROXY_LISTEN='0.0.0.0:8787'
export PROXY_CLIENT_TOKEN='a-long-random-token'
bash deploy/install.sh
```

安装脚本会把它们写入同一个 env 文件。默认仍是 `127.0.0.1:8787`。

常用命令：

```bash
systemctl --user status opencode-go-proxy     # 查看状态
systemctl --user restart opencode-go-proxy    # 重启（改了配置或换了 key 之后）
systemctl --user stop opencode-go-proxy       # 停止
journalctl --user -u opencode-go-proxy -f     # 跟踪日志
systemctl --user disable --now opencode-go-proxy  # 取消自启并停止
```

注意：默认情况下 user service 只在你登录期间运行，注销后停止。若希望注销或重启后仍自动运行：

```bash
sudo loginctl enable-linger you
```

参数：

| 参数 | 环境变量 | 默认值 |
| --- | --- | --- |
| `-listen` | `PROXY_LISTEN` | `127.0.0.1:8787` |
| `-upstream` | `OPENCODE_GO_BASE_URL` | `https://opencode.ai/inference/go/openai` |
| `-token` | `OPENCODE_GO_API_KEY` | 空（转发入站 Authorization） |
| `-session-prefix` | `PROXY_SESSION_PREFIX` | `sess-` |
| `-dump-dir` | `PROXY_DUMP_DIR` | 空（不落盘） |
| `-max-body-bytes` | `PROXY_MAX_BODY_BYTES` | `67108864`（64 MiB） |
| `-no-unwrap-encrypted-content` | `PROXY_NO_UNWRAP_ENCRYPTED_CONTENT` | `false` |
| `-client-token` | `PROXY_CLIENT_TOKEN` | 空（不校验入站请求） |

`-dump-dir` 会把每个请求体原样写到目录里，用于排查"Codex 到底发了什么"。
请求体可能包含 prompt 和文件内容，**只在调试时开启**，用完记得清理。

超过 `-max-body-bytes` 的请求会原样透传、不做改写，避免大图片请求占用过多内存。
`-token` 会出现在进程列表中，日常建议只用 `OPENCODE_GO_API_KEY` 或 env 文件。

## 配置 Codex

在 `~/.codex/config.toml` 中增加一个 provider：

```toml
[model_providers.opencode-go-local]
name = "OpenCode Go (local proxy)"
base_url = "http://127.0.0.1:8787/v1"
wire_api = "responses"
experimental_bearer_token = "proxy-managed"
```

然后选择模型：

```toml
model = "deepseek-v4.1-flash"
model_provider = "opencode-go-local"
```

密钥只放在代理进程的环境变量里，不写进 Codex 配置。

## 安全

- 默认只监听 `127.0.0.1`，这是最安全的用法。
- 监听 `0.0.0.0`、`[::]` 或具体网卡 IP 时，建议同时设置 `-client-token`；
  否则任何能访问该端口的人都可以使用你的上游 key。
- 不要把没有入站鉴权的代理直接暴露到公网。
- 日志不包含 Authorization 和请求体。
- 上游可能记录请求内容，敏感内容请自行评估。
