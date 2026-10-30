#!/bin/sh
# rerex-hook.sh：给 rerex.lua 记下 agent 的会话 ID。
#
#   rerex-hook.sh claude|codex [目录]   agent 的 SessionStart hook，由 agent 调用
#   rerex-hook.sh install [目录]        把 hook 加进 Claude Code 和 Codex 的配置
#   rerex-hook.sh remove                从它们的配置里删掉
#
# agent 每次开始或换了对话（启动、/resume、/clear、compact）都会跑 hook。它从 stdin 的 JSON 里
# 取会话 ID，和 agent 的进程号一起写到 <目录>/<进程号>.json，rerex 保存快照时按进程号读。
# 目录默认是 ~/.local/state/rerex/agents，即 rerex.lua 默认快照旁边的 agents/；
# rerex.lua 用了 path= 时，install 要传同一个目录。
# 只在 Rex 的窗格里记。hook 什么都不输出，出错也不影响 agent。

self=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")

# install / remove：改之前在同一目录留一份备份，改完保持原来的权限
edit_config() {
  file=$1 agent=$2 action=$3
  if [ ! -f "$file" ]; then
    echo "跳过 ${agent}：没有 ${file}"
    return 0
  fi
  cmd="/bin/sh '$self' $agent${dir:+ '$dir'} 2>/dev/null || true"
  backup="$file.rerex-backup-$(date +%Y%m%d%H%M%S)"
  tmp="$file.rerex-tmp"
  cp -p "$file" "$backup" || return 1
  # 临时文件从原文件复制而来，权限和原来一样；改完再 rename 过去
  cp -p "$file" "$tmp" || { rm -f "$backup"; return 1; }
  # 先删掉以前装的（命令里有 rerex-hook.sh 的），再按需加上新的
  jq --arg cmd "$cmd" --arg action "$action" '
    ((.hooks.SessionStart // [])
      | map(.hooks |= map(select((.command // "") | contains("rerex-hook.sh") | not)))
      | map(select(.hooks | length > 0))) as $rest
    | if $action == "install" then
        .hooks.SessionStart = $rest + [{ hooks: [{ type: "command", command: $cmd, timeout: 5 }] }]
      elif ($rest | length) == 0 then del(.hooks.SessionStart)
      else .hooks.SessionStart = $rest end
  ' "$file" > "$tmp" || { rm -f "$tmp" "$backup"; return 1; }
  if [ -L "$file" ]; then
    # 配置是符号链接时写回它指向的文件，不把链接换成普通文件
    cat "$tmp" > "$file" && rm -f "$tmp" || return 1
  else
    mv -f "$tmp" "$file" || return 1
  fi
  # 变量名后面紧跟中文时要加花括号，否则有的 sh 会把中文当成变量名的一部分
  echo "${action} ${agent}：${file}（备份 ${backup}）"
}

case $1 in
  install|remove)
    command -v jq >/dev/null || { echo "需要 jq"; exit 1; }
    dir=$2
    # hook 命令里用单引号括着路径
    case $1:$self$dir in install:*\'*) echo "路径里有单引号，写不进 hook 命令：${self} ${dir}"; exit 1 ;; esac
    edit_config "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" claude "$1" || exit 1
    edit_config "${CODEX_HOME:-$HOME/.codex}/hooks.json" codex "$1" || exit 1
    exit 0
    ;;
esac

agent=$1
dir=${2:-$HOME/.local/state/rerex/agents}
case $agent in ''|*[!a-z0-9_-]*) exit 0 ;; esac
[ -n "$REX_BLOCK" ] || exit 0

input=$(cat | tr -d '\n')
# JSON 里的字符串字段，只认 ID 里常见的字符，含别的字符就当没有
field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([A-Za-z0-9._:-]*\)\".*/\1/p"
}
# 子 agent 也会触发，它和主对话在同一个进程里，不能记
[ -z "$(field agent_id)" ] || exit 0
id=$(field session_id)
[ -n "$id" ] || exit 0

# agent 是往上第一个不是 shell 的祖先进程：agent 用 shell 跑 hook
pid=$PPID n=0
while [ "$n" -lt 8 ] && [ "${pid:-0}" -gt 1 ]; do
  name=$(ps -o comm= -p "$pid" 2>/dev/null) || exit 0
  case ${name##*/} in sh|bash|zsh|dash|ksh|-sh|-bash|-zsh) ;; *) break ;; esac
  pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
  n=$((n + 1))
done
[ "${pid:-0}" -gt 1 ] || exit 0

umask 077
mkdir -p "$dir" || exit 0
tmp="$dir/.$pid.$$"
printf '{"agent":"%s","pid":%s,"session_id":"%s","time":%s}\n' "$agent" "$pid" "$id" "$(date +%s)" > "$tmp" &&
  mv -f "$tmp" "$dir/$pid.json"
exit 0
