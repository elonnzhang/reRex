#!/bin/sh
# 用真实的 claude、codex、pi、hermes，以及 htop、btop 端到端测 rerex。
#
#   tests/e2e.sh [场景...]   不给场景就全跑，场景见 tests/scenarios.json
#   KEEP=1 tests/e2e.sh      跑完留下本次的目录：日志、快照、失败时的屏幕
#
# 过程：起一个单独的 Rex 服务器，每个场景开一个窗格跟 agent 聊一两轮，rerex daemon 在旁边存快照；
# 停掉服务器（窗格里的 agent 都会被结束），再起一个新实例，daemon 恢复，看每个窗格接回的对话对不对。
#
# 不碰你平时的 Rex 服务器、agent 配置和对话：四个 agent 的配置目录（CLAUDE_CONFIG_DIR、CODEX_HOME、
# PI_CODING_AGENT_DIR、HERMES_HOME）都在 $RERX_E2E_CACHE 下，rerex 的快照和 hook 记录在本次的目录里。
# XDG_CONFIG_HOME 也指到本次的目录：htop、btop 退出时会写配置，rerex 也不读你的 programs.json。
# Rex 的窗格用 login 启动 shell，会把 HOME 换回你的主目录，所以只能靠这几个变量隔离。
# 配置目录跑完保留：codex、hermes 第一次启动要装几百 MB 的运行时。删掉它就从头来。
# 每个场景一到两次模型调用，都走一个兼容 OpenAI 和 Anthropic 接口的网关。
# 网关和模型没有默认值：在环境变量里给，或者写进 tests/e2e.env（不进 git），见 README。

repo=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=/dev/null
[ -f "$repo/tests/e2e.env" ] && . "$repo/tests/e2e.env"
for v in RERX_GATEWAY RERX_GATEWAY_KEY RERX_CLAUDE_MODEL RERX_CODEX_MODEL RERX_PI_MODEL RERX_HERMES_MODEL; do
  eval "[ -n \"\${$v:-}\" ]" || { echo "要设 ${v}，见 README 的端到端测试一节"; exit 1; }
done
: "${RERX_E2E_CACHE:=$HOME/.cache/rerex-e2e}"

rex=$(command -v rex) || { echo "需要 rex"; exit 1; }
for c in jq curl $(jq -r '[.[].agent] | unique | join(" ")' "$repo/tests/scenarios.json"); do
  command -v "$c" >/dev/null || { echo "需要 $c"; exit 1; }
done
curl -sf -m 5 -o /dev/null -H "Authorization: Bearer $RERX_GATEWAY_KEY" "$RERX_GATEWAY/v1/models" ||
  { echo "连不上模型网关 $RERX_GATEWAY"; exit 1; }

run=$(mktemp -d /tmp/rerex-e2e.XXXXXX) && run=$(cd "$run" && pwd -P) || exit 1
mkdir -p -m 700 "$RERX_E2E_CACHE" && cache=$(cd "$RERX_E2E_CACHE" && pwd -P) || exit 1
claude_home=$cache/claude codex_home=$cache/codex pi_home=$cache/pi hermes_home=$cache/hermes
mkdir -p "$run/snap/agents" "$run/screens" "$run/xdg" "$claude_home" "$codex_home" "$pi_home" "$hermes_home"
: > "$run/init.lua"

# 选场景，给每个场景建工作目录
jq '[.[] | select(($ARGS.positional | length) == 0 or (.name | IN($ARGS.positional[])))]' \
  "$repo/tests/scenarios.json" --args "$@" > "$run/scenarios.json" || exit 1
[ "$(jq length "$run/scenarios.json")" -gt 0 ] || { echo "没有这些场景：$*"; exit 1; }
for name in $(jq -r '.[].name' "$run/scenarios.json"); do mkdir -p "$run/work/$name"; done
# 某个 agent 的场景的工作目录，JSON 数组
dirs() { jq -c --arg a "$1" --arg w "$run/work" '[.[] | select(.agent == $a) | $w + "/" + .name]' "$run/scenarios.json"; }

R() { env -u REX_SESSION -u REX_BLOCK -u REX_CLIENT XDG_CONFIG_HOME="$run/xdg" REX_SERVER="unix://$run/s.sock" "$rex" --autostart=false "$@"; }
# ---- agent 配置。每次都重写，旧的对话留着不碍事：每次的工作目录都是新的

# claude：模型走网关；跳过首次启动的引导，信任工作目录；sleep join 要跑的命令不用确认
jq -n --arg url "$RERX_GATEWAY" --arg key "$RERX_GATEWAY_KEY" --arg m "$RERX_CLAUDE_MODEL" '{
  model: "haiku",
  env: { ANTHROPIC_BASE_URL: $url, ANTHROPIC_AUTH_TOKEN: $key, ANTHROPIC_DEFAULT_HAIKU_MODEL: $m },
  permissions: { allow: ["Bash(sleep 15)"] }
}' > "$claude_home/settings.json"
[ -f "$claude_home/.claude.json" ] || echo '{}' > "$claude_home/.claude.json"
jq --argjson dirs "$(dirs claude)" '.hasCompletedOnboarding = true | .theme = (.theme // "dark")
  | reduce $dirs[] as $d (.; .projects[$d].hasTrustDialogAccepted = true)' \
  "$claude_home/.claude.json" > "$run/claude.json" && mv "$run/claude.json" "$claude_home/.claude.json"

# codex：自定义的 provider 走网关，不用登录；信任工作目录；命令不用确认
{
  printf 'model = "%s"\nmodel_provider = "rerex"\nmodel_reasoning_effort = "low"\n' "$RERX_CODEX_MODEL"
  printf 'approval_policy = "never"\nsandbox_mode = "workspace-write"\ncheck_for_update_on_startup = false\n'
  printf '\n[features]\nhooks = true\n'
  printf '\n[model_providers.rerex]\nname = "rerex"\nbase_url = "%s/v1"\nwire_api = "responses"\n' "$RERX_GATEWAY"
  printf 'experimental_bearer_token = "%s"\n' "$RERX_GATEWAY_KEY"
  for d in $(dirs codex | jq -r '.[]'); do printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$d"; done
} > "$codex_home/config.toml"
echo '{"hooks":{}}' > "$codex_home/hooks.json"

# 用 install 装 rerex 的 hook，记录写到本次的目录
CLAUDE_CONFIG_DIR=$claude_home CODEX_HOME=$codex_home sh "$repo/rerex-hook.sh" install "$run/snap/agents" \
  > "$run/hook-install.log" || { cat "$run/hook-install.log"; exit 1; }
rm -f "$claude_home"/settings.json.rerex-backup-* "$codex_home"/hooks.json.rerex-backup-*

# pi：provider 走网关；不显示更新说明；信任工作目录
jq -n --arg url "$RERX_GATEWAY" --arg key "$RERX_GATEWAY_KEY" --arg m "$RERX_PI_MODEL" '{ providers: { rerex: {
  baseUrl: ($url + "/v1"), api: "openai-completions", apiKey: $key,
  models: [{ id: $m, name: $m, contextWindow: 200000, maxTokens: 8000, input: ["text"], reasoning: false }]
} } }' > "$pi_home/models.json"
jq -n --arg m "$RERX_PI_MODEL" --arg v "$(pi --version 2>/dev/null)" '{
  defaultProvider: "rerex", defaultModel: $m, defaultThinkingLevel: "off", theme: "dark", lastChangelogVersion: $v
}' > "$pi_home/settings.json"
jq -n --argjson dirs "$(dirs pi)" 'reduce $dirs[] as $d ({}; .[$d] = true)' > "$pi_home/trust.json"

# hermes：provider 走网关；不问统计、不显示一次性提示
cat > "$hermes_home/config.yaml" <<EOF
model:
  default: "$RERX_HERMES_MODEL"
  provider: rerex
  base_url: "$RERX_GATEWAY/v1"
  api_mode: chat_completions
providers:
  rerex:
    api_key: "$RERX_GATEWAY_KEY"
    api_mode: chat_completions
    base_url: "$RERX_GATEWAY/v1"
    models:
      - "$RERX_HERMES_MODEL"
telemetry:
  shared_metrics:
    enabled: false
    send: false
    offer_version: 2
onboarding:
  seen:
    busy_input_prompt: true
    openclaw_residue_cleanup: true
display:
  in_app_tips: false
  in_app_tours: false
  tui_agents_nudge: false
EOF
# ---- 测试服务器和 rerex daemon

server='' daemon=''
# 环境只留这几项和四个 agent 的配置目录。恢复出的窗格直接继承服务器的环境，所以两个服务器要一样
start_server() {
  env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL="${SHELL:-/bin/zsh}" \
    LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" XDG_CONFIG_HOME="$run/xdg" CLAUDE_CONFIG_DIR="$claude_home" \
    CODEX_HOME="$codex_home" PI_CODING_AGENT_DIR="$pi_home" HERMES_HOME="$hermes_home" \
    "$rex" server run --listen "unix://$run/s.sock" --state-dir "$1" --config "$run/init.lua" \
    >> "$run/server.log" 2>&1 &
  server=$!
  i=0
  until R do -e 'return 1' >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || { echo "测试服务器没起来，见 $run/server.log"; exit 1; }
    sleep 0.2
  done
}

start_daemon() {
  R do "$repo/rerex.lua" mode=daemon --all path="$run/snap/snapshot.json" interval=2 history_interval=5 \
    > "$1" 2>&1 &
  daemon=$!
}

# 等进程退出，最多 $2 秒
wait_gone() {
  i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt $(($2 * 5)) ]; do
    sleep 0.2
    i=$((i + 1))
  done
}

# 服务器一停，窗格里的程序都被结束，daemon 也会自己退出
stop_server() {
  [ -n "$server" ] || return 0
  kill -TERM "$server" 2>/dev/null
  wait_gone "$server" 10
  wait_gone "$daemon" 10
  kill "$daemon" 2>/dev/null
  server='' daemon=''
}

# codex 的 app-server、hermes 的 gateway 不在窗格的进程组里，服务器停了还在。
# 按配置目录找出已经没有父进程的这些进程，结束掉
kill_leftovers() {
  ps -E -A -ww -o pid=,ppid=,command= 2>/dev/null |
    awk -v me=$$ -v a="$codex_home/packages/" -v b="HERMES_HOME=$hermes_home " \
      '$1 != me && $2 == 1 && (index($0, a) || index($0 " ", b)) { print $1 }' |
    while read -r p; do kill "$p" 2>/dev/null; done
}

trap 'stop_server; kill_leftovers' EXIT
trap 'exit 130' INT TERM

# ---- 第一个服务器：启动 agent、对话；第二个服务器：rerex 恢复、检查

kill_leftovers
# hermes 换了数据目录，第一次运行要装一份自己的运行时，先装好
if jq -e 'any(.agent == "hermes")' "$run/scenarios.json" >/dev/null; then
  echo "== 准备 hermes"
  HERMES_HOME=$hermes_home hermes sessions list > "$run/hermes-warmup.log" 2>&1
fi

echo "== 第一个服务器：启动 agent、对话"
start_server "$run/state-a"
start_daemon "$run/daemon-a.log"
R do "$repo/tests/e2e.lua" phase=talk run="$run"
[ -f "$run/expect.json" ] || { echo "对话阶段出错，见 $run"; exit 1; }
# 等 daemon 把最后的样子存进快照（interval=2）
sleep 5
stop_server

echo "== 第二个服务器：rerex 恢复"
start_server "$run/state-b"
start_daemon "$run/daemon-b.log"
i=0
until grep -m1 '^{' "$run/daemon-b.log" > "$run/restore.json"; do
  i=$((i + 1))
  [ "$i" -lt 150 ] || { echo "daemon 没有恢复，见 $run/daemon-b.log"; exit 1; }
  sleep 0.2
done
R do "$repo/tests/e2e.lua" phase=verify run="$run"
stop_server

echo
jq -r '.[] | (if .ok then "✓ " else "✗ " end) + .name + "：" + ([.resumed, .how, .wrong_via] | map(select(.)) | join("，"))
  + (if .error then "\n    " + .error else "" end)' "$run/result.json"
failed=$(jq '[.[] | select(.ok | not)] | length' "$run/result.json")
if [ "$failed" -gt 0 ] || [ -n "${KEEP:-}" ]; then
  echo "日志、快照和屏幕在 $run"
else
  rm -rf "$run"
fi
[ "$failed" -eq 0 ]