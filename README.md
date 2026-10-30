# rerex

Rex 服务器重启后，rerex 把会话按原样建回来：布局、目录、窗格历史，以及窗格里在跑的 agent 对话。做法和 tmux-resurrect 一样，是一个 Rex Lua 脚本，用 `rex do` 运行。

## 能恢复什么

- 会话和窗口：label、顺序、活动窗口，以及每个窗口的焦点和 zoom
- 布局：平铺分屏的树和比例、浮层、block label
- 每个终端的工作目录
- 窗格的历史输出：带颜色回放，末尾加一行"以上是恢复前的输出"
- agent 对话：在原目录里跑它的 resume 命令，例如 `claude --resume <id>`。对话退出后，窗格留下普通 shell
- herdr 客户端：重新接回原来的 herdr 会话
- htop、btop、top 这类全屏 TUI 应用：在原目录里按原来的命令行重跑，参数也在

认得哪些程序、怎么重开，都写在 [`programs.json`](#程序配置) 里，可以加。其他正在运行的程序（dev server、vim、ssh 等）默认不恢复。Rex 停机时会结束窗格里的所有程序，这些窗格只恢复目录和历史。

## 文件

| 文件 | 作用 |
|---|---|
| `rerex.lua` | 主脚本，有保存、恢复、常驻三种模式。只管流程 |
| `programs.json` | 内置的程序配置：认得哪些 agent 和 TUI 应用、怎么找会话 ID、怎么重开 |
| `rerex-hook.sh` | 可选的 SessionStart hook。Claude Code 和 Codex 每次开始或换了对话时，用它记下会话 ID |
| `tests/` | 用真实 agent 的端到端测试，见[端到端测试](#端到端测试) |

## 要求

- Rex，要支持 `rex do`。目前只在 macOS 上用过
- `jq`，只有 `rerex-hook.sh install` 和 `remove` 用到

## 用法

手动保存和恢复：

```sh
rex do rerex.lua mode=save      # 保存一次快照
rex do rerex.lua mode=restore   # 按快照建回缺失的会话
```

常驻：

```sh
rex do rerex.lua mode=daemon --all
```

daemon 启动时会比较快照记录的服务器实例。和当前实例不同，就说明服务器重启过，它先恢复，再开始定时保存：

- 快照：布局或目录变化后 1 秒、前台程序变化时，以及每 30 秒
- 历史：每 60 秒；窗格里一条命令跑完 2 秒后，也会单独保存那个窗格

服务器停掉或换了实例时，daemon 会退出，下次启动时恢复。所以要交给 launchd 这类进程管理器，让它自动重新拉起。

### 用 launchd 常驻（macOS）

新建 `~/Library/LaunchAgents/local.rerex.plist`。plist 里不能用 `~`，要把 `/Users/you` 换成你的主目录。`rex` 的路径用 `command -v rex` 查：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.rerex</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/you/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex</string>
    <string>--autostart=false</string>
    <string>do</string>
    <string>/Users/you/code-space/GitHub/rerex/rerex.lua</string>
    <string>mode=daemon</string>
    <string>--all</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>LANG</key>
    <string>en_US.UTF-8</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>/Users/you/.local/state/rerex/daemon.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/you/.local/state/rerex/daemon.log</string>
</dict>
</plist>
```

```sh
mkdir -p -m 700 ~/.local/state/rerex
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.rerex.plist   # 加载并启动
launchctl kickstart -k gui/$(id -u)/local.rerex                              # 改了 rerex.lua 后重启它
launchctl bootout gui/$(id -u)/local.rerex                                   # 停用
```

- `--autostart=false`：daemon 不会替你启动 Rex 服务器。服务器没起来时，launchd 每 10 秒拉起一次 daemon，每次失败都会在日志里留一行错误
- 每次恢复的结果会写进 `daemon.log`，是一行 JSON，格式见[恢复结果](#恢复结果)

## agent 对话

### 认得的 agent

| agent | 程序名 | 有会话 ID 时 | 没有时 |
|---|---|---|---|
| Claude Code | `claude` | `claude --resume <id>` | `claude --continue` |
| Codex | `codex` | `codex resume <id>` | `codex resume --last` |
| Pi | `pi` | `pi --session <id>` | `pi --continue` |
| Hermes | `hermes`。它的启动器用 `python -c` 跑一段代码，看代码里的 `hermes_cli` | `hermes --resume <id>` | 不重开 |

- 一次性运行的不算对话，不重开，例如 `claude -p`、`codex exec`、`hermes -z`
- `hermes -c` 不按目录找最近的对话，恢复后窗格换了终端，会接到别的对话上，所以 Hermes 没有 ID 时不重开

### herdr

herdr 不是 agent，是全屏 TUI 应用。它的服务器在 Rex 外面，Rex 停机后还在，所以 rerex 重开 herdr 就能接回原来的会话：

- 用 `herdr --session <名字>` 或 `herdr session attach <名字>` 启动的，重开 `herdr --session <名字>`；不带名字的重开 `herdr`，接默认会话
- 几个窗格可以接同一个 herdr 会话，恢复时不查重
- `herdr status` 这类子命令不重开；`herdr --remote` 连的是别的机器，也不重开
- 它的窗格不存历史，herdr 重开后自己会重画屏幕
- 配置里是 `"type": "tui"`。快照和恢复结果里，它的名字也记在 `agent` 字段下，`type` 是 `tui`

### htop、btop、top

和 tmux-resurrect 的做法一样：快照里记下完整的命令行，恢复时在原目录里原样重跑，例如 `htop -d 25`。这几个程序在配置里写了 `"rerun": true`，见[程序配置](#程序配置)。

- 参数会写进快照文件。所以只对配置里写了 `rerun` 的程序这么做，别的程序的参数只在内存里用来认程序
- 命令行是从 `ps` 里按空格拆出来的，参数里原有的引号和空格会丢。`less "my notes.txt"` 这类不适合用 `rerun`
- 窗格不存历史，程序重开后自己会画界面
- 不查重，几个窗格都开着 htop 就都重开

### 会话 ID 从哪来

rerex 不读 agent 自己的文件，例如 `~/.claude/sessions/`、对话记录。它按下面几处取 ID：

1. **hook 记录**：`rerex-hook.sh` 写的 `agents/<进程号>.json`。agent 每次开始或换了对话都会更新它，所以 `/resume`、`/clear` 之后也是对的。要先装 hook，见下一节
2. **子进程的环境变量**：agent 给它的子进程（MCP 服务、工具命令）设了 `CLAUDE_CODE_SESSION_ID`、`CODEX_THREAD_ID`、`PI_SESSION_ID`、`HERMES_SESSION_ID`，agent 自己的环境里没有
   - 子进程里的值是它启动那一刻的，所以取最晚启动的那个子进程
   - 只看 agent 直接起的子进程。孙进程的环境是从父进程继承的，`/clear` 之后才起的也可能带着旧 ID
   - 只找这几个变量名，环境里别的内容（可能有密钥）用完就丢
3. **命令行参数**：例如 `claude --resume <id>`。这只是启动时的 ID，最后才用

hook 记录和环境变量都有时，取更晚的那个。每次快照还会和上次记下的比，旧值不会覆盖新值。

不装 hook 也能用，但有一个缺陷：`/resume` 换了对话以后，要等 agent 起了新子进程（比如跑一次工具命令），rerex 才看得到新 ID。在那之前停机，会恢复成旧对话。

几种进程不会被当成 ID 的来源：

- 孙进程，包括工具命令里又跑的 agent（例如 `claude -p`）的子进程，它们带的是那个 agent 自己的会话
- Codex 共用的 `app-server`。它的环境来自第一个启动它的窗格

### Codex 和 Hermes 的共用后台进程

Codex（0.165 起默认）和 Hermes 让几个窗格共用一个后台进程：Codex 是 `app-server`，Hermes 是 `gateway`。对话在后台进程里跑，hook 和工具命令都是它的子进程，环境也是第一个启动它的窗格的。所以 rerex 分不清哪个对话属于哪个窗格，hook 和环境变量这两处都拿不到 ID：

- Codex 退回 `codex resume --last`，接这个目录里最近的对话。同一个目录里开了几个 Codex 时，只恢复一个
- Hermes 没有可靠的"接着最近的对话"，不重开。用 `hermes --resume <id>` 启动的，按命令行里的 ID 重开
- 想让 Codex 拿到确切的 ID，可以在 `config.toml` 里关掉共用的 app-server：

  ```toml
  [features]
  daemon_auto_start = false
  ```

  关掉后 hook 和工具命令都在窗格里的 codex 下面，`/new`、`/resume` 之后也能跟上。端到端测试里的 `codex-new-hook`、`codex-new-env` 测的就是这种情况

### 装 hook（Claude Code、Codex）

```sh
./rerex-hook.sh install          # 加进 ~/.claude/settings.json 和 ~/.codex/hooks.json 的 SessionStart
./rerex-hook.sh install <目录>   # 同上，记录写到 <目录>，不是默认的 ~/.local/state/rerex/agents
./rerex-hook.sh remove           # 删掉
```

`install` 做这几件事：

- 改之前在原文件旁边留一份备份，文件名是 `*.rerex-backup-<时间>`
- 只加一条 hook，其他内容不动，文件权限保持不变；重复 install 不会加出重复的 hook
- 遵循 `CLAUDE_CONFIG_DIR` 和 `CODEX_HOME`
- `rerex-hook.sh` 所在的路径里有单引号时不装：hook 命令用单引号括着路径

hook 本身的行为：

- 只在 Rex 窗格里记录（看 `REX_BLOCK`），子 agent 不记
- 不输出任何东西，出错也不影响 agent
- 从 hook 收到的 JSON 里取 `session_id`，只接受字母、数字和 `._:-`

装好以后，已经在运行的对话可能要到下次启动或 `/clear` 才会跑它。Codex 可能要你先在 `/hooks` 里批准。检查是否生效：

```sh
ls ~/.local/state/rerex/agents   # 有以 agent 进程号命名的 .json 文件
```

rerex.lua 用了 `path=` 时，hook 要写到同一个目录：`./rerex-hook.sh install <快照目录>/agents`。

### 恢复时的规则

- 已有同名会话的跳过，所以重复运行 restore 不会建出重复的会话
- 同一个对话只在一个窗格里重开。如果它已经在别处运行，比如 Rex 外的终端，就不重开，窗格留下 shell
- 只能"接着最近的对话"时：
  - 同一个目录只接一次
  - 同目录里还有已知 ID 的同类对话时不接，免得接错
- 目录已不存在的，退回默认目录，agent 不重开
- 刚恢复的窗格，agent 启动后要过一会儿才认得出会话。最多 60 秒内，快照照旧记着它，这时停机也不会丢

### 恢复结果

`mode=restore` 返回、daemon 写进日志的都是这样一行 JSON：

```json
{
  "restored": ["work", "notes"],
  "skipped": ["already-there"],
  "failed": [{ "label": "x", "error": "..." }],
  "resumed": [
    { "pane": "shell", "agent": "claude", "type": "agent", "session_id": "6fa03ee9-…", "cwd": "/Users/you/proj" },
    { "pane": "shell", "agent": "pi", "type": "agent", "continued": true, "cwd": "/Users/you/notes" },
    { "pane": "shell", "agent": "htop", "type": "tui", "command": ["htop", "-d", "25"], "cwd": "/Users/you" }
  ],
  "not_restarted": [
    { "pane": "shell", "program": "claude", "agent": "claude", "type": "agent", "session_id": "e43cf4a4-…", "reason": "已在别的窗格打开" },
    { "pane": "shell", "program": "bat" }
  ]
}
```

`continued` 表示用的是"接着最近的对话"，`command` 表示按原来的命令行重跑。`agent` 是配置里的 `name`，`type` 是它的 `type`。`not_restarted` 里没有 `agent` 的，是配置里没有的程序。空的列表输出成 `{}`：Rex 的 JSON 编码把空表当成对象。

## 参数

写法是 `rex do rerex.lua key=value ...`。

| 参数 | 默认 | 说明 |
|---|---|---|
| `mode` | `save` | `save`、`restore` 或 `daemon` |
| `path` | `~/.local/state/rerex/snapshot.json` | 快照文件。历史和 hook 记录放在它旁边的 `history/`、`agents/` |
| `only` | 全部 | Lua 模式，只处理 label 匹配的会话 |
| `interval` | `30` | daemon 定时保存快照的秒数 |
| `history` | 开 | 设成 `false` 就不保存、不回放历史 |
| `history_max` | `2097152` | 每个窗格最多保留的历史字节数（2 MiB），超出时从截断处的下一行开始保留 |
| `history_interval` | `60` | daemon 定时保存历史的秒数 |
| `programs` | `~/.config/rerex/programs.json` | 用户的程序配置，并进内置的。默认位置的文件没有就不读；遵循 `XDG_CONFIG_HOME` |
| `<名字>_bin` | | 重开时换掉命令名，例如 `claude_bin=my-claude`，用包装过的 Claude Code 时有用 |

以前的 `agents=` 改名为 `programs=`，还用 `agents=` 会报错退出。

### 程序配置

认得哪些程序、怎么重开，都写在 JSON 里，`rerex.lua` 只按配置做事：

- 内置的是 `rerex.lua` 旁边的 `programs.json`：Claude Code、Codex、Pi、Hermes、herdr、htop、btop、top
- 用户的配置是一个同样格式的 JSON 数组，每项按 `name` 并进内置的，逐个字段替换；新的 `name` 加在后面
- 文件读不了或格式不对时报错退出，不会悄悄改用默认的

```json
[
  {
    "name": "myagent", "type": "agent", "match": ["myagent"], "env": ["MYAGENT_SESSION_ID"], "argv": ["--load"],
    "resume": ["myagent", "--load", "{id}"], "continue": ["myagent", "--last"]
  },
  { "name": "lazygit", "type": "tui", "match": ["lazygit"], "rerun": true },
  { "name": "pi", "continue": ["pi", "--continue", "--verbose"] }
]
```

每项都要有 `type`，并且至少有 `resume`、`continue`、`rerun` 中的一个。改内置的项时只写要改的字段，不用重写 `type`，比如上面的 `pi`。

| 字段 | 说明 |
|---|---|
| `name` | 名字，恢复结果里的 `agent`。必填 |
| `type` | `agent`（agent 对话）或 `tui`（全屏 TUI 应用，例如 herdr、htop），记进快照和恢复结果。新加的项必填 |
| `match` | 程序名。node、python 这类解释器跑的看脚本名 |
| `rerun` | `true` 时把完整的命令行记进快照，恢复时原样重跑。用于 htop 这类没有会话的程序，其余字段都用不到 |
| `resume` | 有会话 ID 时的命令，`{id}` 换成会话 ID |
| `continue` | 没有会话 ID 时的命令。都不设的话，只留 shell |
| `env` | 子进程环境里放会话 ID 的变量名 |
| `argv` | 命令行里跟着 ID 的参数。不带 `-` 的是子命令，只认命令行开头的，可以是几个词，例如 `"session attach"` |
| `skip_flags`、`skip_commands` | 带这些参数，或第一个参数是这些子命令时，不算交互对话，不重开 |
| `skip_children` | 参数里有这些词的子进程，不看它的环境变量 |
| `shared` | 同一个会话能在几个窗格同时打开，恢复时不查重 |
| `note` | 说明，rerex 不看 |

## 文件位置

```
~/.local/state/rerex/         目录只有本人能进（700）
  snapshot.json               快照
  snapshot.json.prev          上一次恢复用的快照
  history/<block>.vt          窗格历史，快照不再引用的会被删掉
  agents/<进程号>.json         hook 记下的会话 ID，进程退出后删掉
  daemon.log                  launchd 的输出（在 plist 里配置）
~/.config/rerex/programs.json  用户的程序配置，可选
```

历史文件是终端输出的原文，可能含密钥，比如跑过 `env` 的窗格。

## 限制

- 只在 macOS 上用过。Linux 上读 `/proc/<pid>/environ` 的代码没跑过
- 还没说过话的对话没有记录，resume 会失败，窗格留下 shell
- 停机时正在回答的那一轮不会续上，只是重开对话
- 历史只保存到上一次保存为止，停机前最后约 60 秒的输出可能没有
- Pi 空闲时通常没有子进程，命令行里也看不到参数，多半只能 `pi --continue`
- Codex 默认用共用的 app-server 时拿不到会话 ID，只能 `codex resume --last`；Hermes 拿不到 ID 就不重开。见[Codex 和 Hermes 的共用后台进程](#codex-和-hermes-的共用后台进程)
- Hermes 的进程名是 `python3`，rerex 查"这个对话是不是已经在别处打开"时看不到它
- 命令行参数是从 `ps` 里按空格拆出来的，引号已经丢了，所以子命令只认第一个参数。`codex --full-auto exec` 会被当成交互对话；`claude "update docs"` 会被当成 `claude update`，不重开
- fish、nu 这类 shell 里，agent 由 `/bin/sh` 带着窗格原有的环境重开，不读这些 shell 的配置。agent 所在的目录只在这些配置里加进 PATH 时，会找不到命令
- detach 出去、不在任何窗口里的 block 不保存

## 开发

```sh
luajit -e 'assert(loadfile("rerex.lua"))'   # 语法检查
sh -n rerex-hook.sh
tests/e2e.sh                                 # 用真实的 agent 端到端测试，见下
```

不要在你日常用的 Rex 服务器上测试恢复：停掉它会结束所有窗格。另起一个服务器，并把 `REX_SERVER` 指向它：

```sh
T=/tmp/rerex-test; mkdir -p $T/state; : > $T/init.lua
env -u REX_SERVER -u REX_SESSION -u REX_BLOCK \
  rex server run --listen unix://$T/s.sock --state-dir $T/state --config $T/init.lua &
env -u REX_SESSION -u REX_BLOCK REX_SERVER=unix://$T/s.sock \
  rex --autostart=false do rerex.lua mode=daemon --all path=$T/snap/snapshot.json
```

从 agent 的终端里起测试服务器时，还要去掉 `CLAUDE_CODE_SESSION_ID` 这类变量，否则测试窗格里的程序都会带着它。

### 端到端测试

`tests/e2e.sh` 用真实的 claude、codex、pi、hermes，以及 htop、btop 跑一遍保存和恢复：

1. 起一个单独的 Rex 服务器和 rerex daemon，每个场景开一个窗格，启动 agent，让它把两段随机字符拼起来
2. 停掉服务器，窗格里的 agent 都被结束
3. 再起一个服务器，daemon 恢复。窗格里重开的对话显示出那个拼好的词，就算接对了

```sh
tests/e2e.sh                          # 全部场景，几分钟
tests/e2e.sh claude-clear codex-new   # 只跑这几个
KEEP=1 tests/e2e.sh                   # 留下日志、快照和失败时的屏幕
```

场景在 `tests/scenarios.json`，每个写明 agent、启动命令和步骤：

| 步骤 | 做什么 |
|---|---|
| `join` | 让 agent 把两段随机字符拼起来，等屏幕上出现拼好的词 |
| `sleep join` | 先让 agent 跑 `sleep 15`，再拼词。命令跑着的时候，rerex 能从它的环境变量里看到会话 ID |
| `/clear`、`/new` | 换一个新对话。恢复后应当是最后那个对话，第一个词不该出现 |

场景里写了 `via` 的，还要求快照里的会话 ID 来自这里（`hook` 或 `env`）。写了 `"restart": false` 的，要求 rerex 认出这个 agent 但不重开，目前是 Hermes。写了 `command` 的（htop、btop），没有对话步骤，要求恢复时重跑的就是这条命令，并且界面画了出来。启动命令是 `REX_BLOCK= claude` 这种写法时，hook 不记，用来测只靠环境变量的情况。

测试不碰你平时的配置和对话：

- 四个 agent 的配置目录（`CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`PI_CODING_AGENT_DIR`、`HERMES_HOME`）都在 `~/.cache/rerex-e2e` 下，每次重写配置。目录跑完保留，因为 codex、hermes 第一次启动要装几百 MB 的运行时。删掉它就从头来
- rerex 的 hook 用 `install <目录>` 装在这几个配置目录里，记录写进本次的临时目录
- 测试服务器只带几个必要的环境变量，不继承你终端里的 `CLAUDE_CODE_*` 之类
- `XDG_CONFIG_HOME` 指到本次的临时目录：htop、btop 退出时写的配置不落到你的 `~/.config`，rerex 也不读你的 `programs.json`

模型都走一个兼容 OpenAI 和 Anthropic 接口的网关，每个场景一到两次调用。网关和模型没有默认值，用环境变量给，或者写进 `tests/e2e.env`（`.gitignore` 里已排除）。`e2e.sh` 启动时会先读这个文件：

```sh
# tests/e2e.env
RERX_GATEWAY=http://127.0.0.1:8080        # 网关地址，下面要有 /v1/models
RERX_GATEWAY_KEY=your-key                 # 网关的 key
RERX_CLAUDE_MODEL=claude-haiku-4-5        # claude 用的模型，走 Anthropic 接口
RERX_CODEX_MODEL=gpt-5-mini               # codex 用的模型，走 OpenAI Responses 接口
RERX_PI_MODEL=claude-haiku-4-5            # pi 用的模型，走 OpenAI Chat Completions 接口
RERX_HERMES_MODEL=claude-haiku-4-5        # hermes 用的模型，同上
```

| 变量 | 说明 |
|---|---|
| `RERX_GATEWAY`、`RERX_GATEWAY_KEY` | 网关地址和 key。必填 |
| `RERX_CLAUDE_MODEL`、`RERX_CODEX_MODEL`、`RERX_PI_MODEL`、`RERX_HERMES_MODEL` | 各 agent 用的模型，挑便宜快的就行。必填 |
| `RERX_E2E_CACHE` | agent 配置目录的位置，默认 `~/.cache/rerex-e2e` |

`RERX_GATEWAY_KEY` 会写进缓存目录里的配置文件。
