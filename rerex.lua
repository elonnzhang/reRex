-- rerex.lua: 保存并恢复 Rex 的会话布局，类似 tmux-resurrect。
--
--   rex do rerex.lua mode=save                 立即保存一次快照
--   rex do rerex.lua mode=restore              按快照重建缺失的会话
--   rex do rerex.lua mode=daemon --all         常驻：服务器换了实例就先恢复，之后有变化就保存
--
-- 参数：path=快照文件，默认 ~/.local/state/rerex/snapshot.json
--       only=Lua 模式，只处理 label 匹配的会话
--       interval=daemon 定时保存布局的秒数，默认 30
--       history=false 不保存、不回放窗格历史
--       history_max=每个窗格最多保留的历史字节数，默认 2097152（2 MiB）
--       history_interval=daemon 定时保存窗格历史的秒数，默认 60
--       programs=JSON 文件，增改认得的程序，默认 ~/.config/rerex/programs.json（有的话）
--       <名字>_bin=重开时用的命令，例如 claude_bin=my-claude
--
-- 能恢复：会话与窗口的 label 和顺序、平铺分屏树与比例、浮层、block label、
-- 终端的工作目录、每个窗口的焦点和 zoom、活动窗口、窗格的历史输出（回放，带颜色），
-- 以及配置里认得的程序：agent 对话（Claude Code、Codex、Pi、Hermes）在原目录里跑它的 resume 命令，
-- 例如 claude --resume <id>；herdr 接回原来的会话；htop、btop、top 按原来的命令行重跑。
-- 程序退出后窗格留下普通 shell。认得哪些程序、怎么重开，都在 programs.json 里，这个脚本只管流程。
-- 会话 ID 从 rerex-hook.sh 的记录和进程信息拿，拿不到时接着那个目录里最近的对话（agent 支持的话）。
-- 停机时正在回答的对话也只是重开，不自动续上那一轮。
-- 不能恢复：其他进程。服务器停止时，Rex 会结束其中所有程序。
-- 历史只保存到上一次保存为止，停机前最后一段输出可能没有。
--
-- 不读 agent 自己的文件。agent 的配置里只多一条 SessionStart hook（rerex-hook.sh install 装上，
-- rerex-hook.sh remove 删掉），它把会话 ID 记到快照旁边的 agents/ 下。没装 hook 的 agent
-- 从子进程的环境变量里取（例如 CLAUDE_CODE_SESSION_ID），只找这几个名字，环境里别的内容不留。
-- 还没说过话的对话没有记录，resume 会失败，这时窗格留下 shell。

local TERM = "com.superlogical.terminal"
local SHELL = "com.superlogical.terminal.shell"
local HOME = os.getenv("HOME")

local args = rex.args
local mode = args.mode or "save"
local path = args.path or (HOME .. "/.local/state/rerex/snapshot.json")
local only = args.only
local keep_history = args.history ~= false
local history_dir = path:gsub("[^/]*$", "") .. "history/"
-- rerex-hook.sh 写的会话记录，默认目录和它一致
local agents_dir = path:gsub("[^/]*$", "") .. "agents/"
local HISTORY_MAX = tonumber(args.history_max) or 2 * 1024 * 1024

local function call(method, a)
  local r, err = rex.call(method, a)
  if r == nil then error(method .. ": " .. tostring(err), 0) end
  return r
end

local function wanted(label)
  return only == nil or (label or ""):match(only) ~= nil
end

-- 读写其他会话前要先 attach。--all 也只在脚本顶层跑完、进入事件循环后才生效，
-- 而 daemon 的恢复和第一次保存都在顶层，所以每次都显式 attach。
-- 实测在 --all 下 attach 不会缩小监听范围。
local function ensure_attached(sid)
  rex.session.attach{ session_id = sid }
end

local function list_sessions()
  return call("session.list", {}).sessions or {}
end

local function is_dir(p)
  local r = rex.exec({ "test", "-d", p })
  return r ~= nil and r.ok
end

local function is_exec(p)
  local r = rex.exec({ "test", "-f", p, "-a", "-x", p })
  return r ~= nil and r.ok
end

local function read_file(p)
  local f = io.open(p, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function exists(p)
  local f = io.open(p, "r")
  if f then f:close() end
  return f ~= nil
end

-- 先写临时文件再 rename，中途被打断也不会留下半个文件。目录不存在时才去建，
-- 建成只有本人能进：历史文件里是终端输出，可能有密钥。
local function write_file(p, text)
  local tmp = p .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    rex.exec({ "mkdir", "-p", "-m", "700", p:match("^(.*)/") })
    f = assert(io.open(tmp, "w"))
  end
  -- 写失败（例如磁盘满）就报错，不拿写了一半的文件换掉原来的
  assert(f:write(text))
  assert(f:close())
  assert(os.rename(tmp, p))
end

-- file://host/a%20b -> /a b
local function url_path(u)
  local p = u and (u:match("^file://[^/]*(/.*)$") or u:match("^/.*"))
  if p then p = p:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end) end
  return p
end

local SHELLS = { zsh = true, bash = true, fish = true, sh = true, dash = true, ksh = true, tcsh = true, nu = true }

-- 终端的直接子进程在 macOS 上是 /usr/bin/login，真正的 shell 在它下面。
-- 从 child 往前台方向找第一个不是 login 的进程，当作 shell。
local function find_shell(p)
  local chain = { p.child }
  local anc = p.ancestors or {}
  for i = #anc, 1, -1 do
    if anc[i].pid ~= p.child.pid then table.insert(chain, anc[i]) end
  end
  table.insert(chain, p.foreground)
  for _, proc in ipairs(chain) do
    if proc and proc.name ~= "login" then return proc end
  end
end

-- 认得的程序（agent，以及 herdr、htop 这类全屏 TUI 应用）都在配置里，这里只管怎么用：
--   rerex.lua 旁边的 programs.json 是内置的；用户的（programs=，默认 $XDG_CONFIG_HOME/rerex/programs.json，
--   没设 XDG_CONFIG_HOME 时是 ~/.config/rerex/programs.json）
--   按 name 并进来，逐个字段替换，新的加在后面。文件读不了或格式不对就报错退出，不悄悄用默认的。
-- 字段：type 是 agent 或 tui（全屏 TUI 应用），记进快照和恢复结果。match 是程序名，
-- node、python 这类解释器跑的取脚本名。
-- 会话 ID 从这几处找：
--   hook  rerex-hook.sh 在 agent 每次开始或换了对话时写的 agents/<进程号>.json，跟得上 /resume
--   env   agent 给子进程设的环境变量。它自己的环境里没有；子进程里的值是子进程启动时的，
--         /resume、/clear 之后启动的子进程才有新值，所以取最晚启动的那个。只看直接子进程
--   argv  命令行里跟在这些参数后面的值；不带 - 的（子命令，可以是几个词）只认开头的
-- hook 和 env 都有时取更晚的那个；再和上次记下的比，谁更晚就用谁。argv 只是启动时的，最后才用。
-- 有 ID 用 resume（{id} 换成会话 ID），没有用 continue（接着这个目录里最近的对话），都不行就只留 shell。
-- rerun：不找会话 ID，把完整的命令行记进快照，恢复时原样重跑。
-- skip_flags、skip_commands：带这些参数，或第一个参数是这些子命令时，不是交互对话，不重开。
-- skip_children：参数里有这些词的子进程，不看它的环境变量。
-- shared：同一个会话可以在几个窗格里同时打开，恢复时不查重。
if args.agents then error("agents= 改名为 programs= 了", 0) end
local PROGRAMS, PROGRAM = {}, {}

local function load_programs(file)
  local list, err = rex.json.decode(read_file(file) or error("读不到 " .. file, 0))
  if type(list) ~= "table" then error(file .. ": " .. tostring(err), 0) end
  for _, x in ipairs(list) do
    if type(x) ~= "table" or type(x.name) ~= "string" then error(file .. ": 每项都要有 name", 0) end
    if not PROGRAM[x.name] then
      PROGRAM[x.name] = {}
      table.insert(PROGRAMS, PROGRAM[x.name])
    end
    local spec = PROGRAM[x.name]
    for k, v in pairs(x) do spec[k] = v end
    if spec.type ~= "agent" and spec.type ~= "tui" then
      error(file .. ": " .. x.name .. " 的 type 要是 agent 或 tui", 0)
    end
    if not (spec.resume or spec.continue or spec.rerun) then
      error(file .. ": " .. x.name .. " 要有 resume、continue 或 rerun", 0)
    end
  end
end

-- 内置的配置在脚本旁边
load_programs((debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/") or ".") .. "/programs.json")
local user_programs = (os.getenv("XDG_CONFIG_HOME") or HOME .. "/.config") .. "/rerex/programs.json"
if args.programs then
  load_programs(tostring(args.programs))
elseif exists(user_programs) then
  load_programs(user_programs)
end

local BY_PROGRAM = {}
for _, spec in ipairs(PROGRAMS) do
  for _, n in ipairs(spec.match or {}) do BY_PROGRAM[n] = spec end
end

-- 会话 ID 会原样放进命令行，只收常见的字符
local function valid_id(v)
  return type(v) == "string" and #v <= 128 and v:match("^%w[%w._:-]*$") ~= nil
end

-- 进程表，每次快照只跑一次 ps -A，只取进程号和程序名，不取参数：别的进程的参数里可能有密钥，
-- 只读窗格前台进程组和 agent 直接子进程的。
local proc_cache
local function procs()
  if proc_cache then return proc_cache end
  local t = { pgid = {}, groups = {}, kids = {}, name = {}, info = {} }
  local r = rex.exec({ "ps", "-A", "-o", "pid=,ppid=,pgid=,comm=" })
  for line in (r and r.stdout or ""):gmatch("[^\n]+") do
    local pid, ppid, pgid, comm = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)%s*(.-)%s*$")
    if pid then
      pid, ppid, pgid = tonumber(pid), tonumber(ppid), tonumber(pgid)
      t.pgid[pid] = pgid
      t.name[pid] = comm:match("[^/]*$")
      t.groups[pgid] = t.groups[pgid] or {}
      table.insert(t.groups[pgid], pid)
      t.kids[ppid] = t.kids[ppid] or {}
      table.insert(t.kids[ppid], pid)
    end
  end
  proc_cache = t
  return t
end

-- ps 的 etime：1-02:03:04 -> 秒
local function seconds(etime)
  local d, rest = etime:match("^(%d+)%-(.*)$")
  local s = 0
  for n in (rest or etime):gmatch("%d+") do s = s * 60 + tonumber(n) end
  return s + (tonumber(d) or 0) * 86400
end

local INTERPRETERS = { node = true, bun = true, deno = true, ruby = true, perl = true, bash = true, sh = true, zsh = true, env = true }

-- 程序名和参数：解释器跑的取脚本名，去掉 .js、.py 这类后缀。
-- python -c 跑的一段代码（hermes 的启动器就是这样）取代码里 from X.main import main 的 X。
-- ps 把换行显示成 \012，这样的代码以换行结尾，参数从最后一个以 \012 结尾的词之后开始；
-- 没有这样的词就当后面全是代码，没有参数
local function program(words)
  local i = 1
  local name = (words[1] or ""):match("[^/]*$")
  if INTERPRETERS[name] or name:match("^python[%d.]*$") then
    i = 2
    while words[i] and (words[i]:sub(1, 1) == "-" or words[i]:find("=", 1, true)) do
      if words[i] == "-c" then
        local at = #words
        while at > i and not words[at]:find("\\012$") do at = at - 1 end
        if at == i then at = #words end
        local code = table.concat(words, " ", i + 1, at)
        return code:match("from ([%w_]+)[%w_.]* import main") or "", { unpack(words, at + 1) }
      end
      i = i + 1
    end
    name = (words[i] or ""):match("[^/]*$")
  end
  return (name:gsub("%.[cm]?[jt]s$", ""):gsub("%.py$", "")), { unpack(words, i + 1) }
end

-- 补上这些进程的存活秒数和参数。参数只在内存里用来认程序；只有配置了 rerun 的程序，
-- 完整的命令行（argv）才进快照。
local function proc_info(pids)
  local t = procs()
  local need = {}
  for _, pid in ipairs(pids) do
    if t.info[pid] == nil then
      t.info[pid] = false
      table.insert(need, pid)
    end
  end
  if #need == 0 then return t.info end
  -- 有的进程已经不在时 ps 返回非 0，但仍会列出还在的
  local r = rex.exec({ "ps", "-ww", "-o", "pid=,etime=,args=", "-p", table.concat(need, ",") })
  for line in (r and r.stdout or ""):gmatch("[^\n]+") do
    local pid, etime, cmd = line:match("^%s*(%d+)%s+(%S+)%s*(.-)%s*$")
    if pid then
      local words = {}
      for w in cmd:gmatch("%S+") do table.insert(words, w) end
      local name, args = program(words)
      t.info[tonumber(pid)] = { pid = tonumber(pid), age = seconds(etime), name = name, args = args, argv = words }
    end
  end
  return t.info
end

local LINUX = exists("/proc/self/environ")

-- words 里有没有 list 里的词
local function has_any(words, list)
  for _, w in ipairs(words) do
    for _, s in ipairs(list or {}) do
      if w == s then return true end
    end
  end
  return false
end

-- agent 设给子进程的环境变量，返回值和它出自的子进程的启动时间。只找这几个名字，
-- 环境里的其他内容（可能有密钥）用完就丢。
-- 只看 agent 直接起的子进程，值是子进程启动时的，所以取最晚启动的那个。孙进程的环境继承自它的
-- 父进程，比如 /clear 之后 MCP 服务新起的进程带的还是旧会话，值比它的启动时间旧，不能看。
local function env_id(spec, root)
  local kids = procs().kids[root]
  if not kids then return nil end
  local info = proc_info(kids)
  local best
  -- 在空白分隔的 NAME=value 里找；macOS 的 ps -E 把环境接在参数后面，取最后一个
  local function pick(p, text)
    if not p or has_any(p.args, spec.skip_children) then return end
    for _, n in ipairs(spec.env) do
      local v
      for x in text:gmatch("%s" .. n:gsub("%p", "%%%0") .. "=(%S+)") do v = x end
      if valid_id(v) and (not best or p.age < best.age) then best = { id = v, age = p.age } end
    end
  end
  if LINUX then
    for _, pid in ipairs(kids) do
      local env = read_file("/proc/" .. pid .. "/environ")
      -- 每项以 \0 结尾，换成换行
      if env then pick(info[pid], "\n" .. env:gsub("%z", "\n")) end
    end
  else
    local r = rex.exec({ "ps", "-E", "-ww", "-o", "pid=,command=", "-p", table.concat(kids, ",") })
    for line in (r and r.stdout or ""):gmatch("[^\n]+") do
      pick(info[tonumber(line:match("^%s*(%d+)"))], line)
    end
  end
  if best then return best.id, os.time() - best.age end
end

-- 参数 f 在命令行里的位置和它的值，f v 和 f=v 两种写法都认，-- 之后的不算
local function find_flag(words, f)
  for i, x in ipairs(words) do
    if x == "--" then return nil end
    if x == f then return i, words[i + 1] end
    if x:sub(1, #f + 1) == f .. "=" then return i, x:sub(#f + 2) end
  end
end

-- 一次性任务（claude -p、codex exec 这类）不算对话。子命令只认第一个参数：后面不带 - 的词
-- 可能是别的参数的值，例如 codex -C app 里的 app
local function skipped(spec, words)
  for _, f in ipairs(spec.skip_flags or {}) do
    if find_flag(words, f) then return true end
  end
  for _, c in ipairs(spec.skip_commands or {}) do
    if c == words[1] then return true end
  end
  return false
end

-- 命令行里跟在 argv 这些参数后面的会话 ID。不带 - 的是子命令（可以是几个词），也只认开头的
local function argv_id(spec, words)
  for _, f in ipairs(spec.argv or {}) do
    local v
    if f:sub(1, 1) == "-" then
      v = select(2, find_flag(words, f))
    else
      local n = select(2, f:gsub("%S+", ""))
      if #words > n and table.concat(words, " ", 1, n) == f then v = words[n + 1] end
    end
    if valid_id(v) then return v end
  end
end

-- rerex-hook.sh 记下的会话 ID 和记录的时间。写的时间要不早于这个进程启动，
-- 免得进程号被复用后读到先前那个进程留下的记录。
local function hook_id(spec, p)
  local text = read_file(agents_dir .. p.pid .. ".json")
  local r = text and rex.json.decode(text)
  if type(r) ~= "table" or r.agent ~= spec.name or r.pid ~= p.pid or not valid_id(r.session_id) then return nil end
  local at = tonumber(r.time)
  if not at or at < os.time() - p.age - 5 then return nil end
  return r.session_id, at
end

-- 这个 agent 进程现在的会话 ID、找到的地方和时间：hook 和环境变量里取更晚的，都没有再看命令行
local function session_of(spec, p)
  local id, since = hook_id(spec, p)
  local via = id and "hook"
  if spec.env then
    local eid, esince = env_id(spec, p.pid)
    if eid and (not id or esince > since) then id, since, via = eid, esince, "env" end
  end
  if id then return id, via, since end
  id = argv_id(spec, p.args)
  if id then return id, "argv" end
end

-- 认出窗格前台进程组里的 agent，返回恢复它要的种类、会话 ID 和目录。
-- 在整个进程组里找：包装脚本不 exec 时，agent 是它在同一进程组里的子进程。
-- 组里有几个 agent 程序时取最先启动的：claude 当 MCP 服务起的 codex mcp-server 也在 claude 的组里。
local function find_agent(f, cwd)
  local t = procs()
  local members = t.groups[t.pgid[f.pid] or f.pid] or { f.pid }
  local info = proc_info(members)
  local p
  for _, pid in ipairs(members) do
    local q = info[pid]
    if q and BY_PROGRAM[q.name] and (not p or q.age > p.age or (q.age == p.age and q.pid < p.pid)) then p = q end
  end
  local spec = p and BY_PROGRAM[p.name]
  if not spec or skipped(spec, p.args) then return nil end
  -- npm 装的 codex 是 node 写的启动器，原样带着参数启动同名的原生程序，agent 是那个子进程
  for _, k in ipairs(t.kids[p.pid] or {}) do
    local c = info[k]
    if c and c.name == p.name and table.concat(c.args, " ") == table.concat(p.args, " ") then p = c end
  end
  local a = { kind = spec.name, type = spec.type, pid = p.pid, cwd = f.cwd or cwd }
  if spec.rerun then
    a.command = p.argv
  else
    a.session_id, a.via, a.since = session_of(spec, p)
  end
  return a
end

-- 正在运行的对话（不管在不在 Rex 里）
local function running_sessions()
  local t = procs()
  local pids = {}
  for pid, name in pairs(t.name) do
    if BY_PROGRAM[name] then table.insert(pids, pid) end
  end
  local info = proc_info(pids)
  local keys = {}
  for _, pid in ipairs(pids) do
    local p = info[pid]
    local spec = p and BY_PROGRAM[p.name]
    local id = spec and not spec.rerun and not skipped(spec, p.args) and session_of(spec, p)
    if id then keys[spec.name .. " " .. id] = true end
  end
  return keys
end

-- 工作目录优先取 shell 进程的实时 cwd，取不到再用 OSC 7 上报的 pwd。
-- 前台程序只记名字：Rex 不返回其余参数，因为里面可能有密钥。
local function terminal_info(sid, bid)
  local where = { session_id = sid, block_id = bid }
  local info = {}
  local p = rex.block.call(TERM, "process", where)
  if p and p.child then
    info.alive = true
    local shell = find_shell(p)
    info.cwd = shell and shell.cwd
    info.shell = shell and shell.path
    local f = p.foreground
    if f and not (shell and f.pid == shell.pid) then
      info.agent = find_agent(f, info.cwd)
      if not SHELLS[f.name] then info.fg = f.script or f.argv0 or f.name end
    end
  end
  if info.cwd == nil then
    local w = rex.block.call(TERM, "pwd", where)
    info.cwd = url_path(w and w.pwd)
  end
  return info
end

local function history_file(bid)
  return history_dir .. bid:gsub("[^%w%-]", "_") .. ".vt"
end

-- 依次对快照里的每个 block 调用 fn
local function each_block(snap, fn)
  local function walk(node)
    if node == nil then return end
    if node.split then
      walk(node.split.before)
      walk(node.split.after)
    elseif node.block then
      fn(node.block)
    end
  end
  for _, ss in ipairs(snap and snap.sessions or {}) do
    for _, w in ipairs(ss.windows or {}) do
      walk(w.layout)
      for _, fl in ipairs(w.floating or {}) do walk(fl.layout) end
    end
  end
end

-- 上一次快照里的 block，按 ID 查
local last_blocks = {}
local function remember_blocks(snap)
  last_blocks = {}
  each_block(snap, function(b) last_blocks[b.id] = b end)
end

-- 刚恢复、正在重开对话的窗格（新 block ID -> agent）。agent 启动后要过一会儿才认得出它的会话，
-- 这段时间里照旧把 agent 记进快照，免得这时停机就丢了对话。
-- 检测到它已在运行，或过了 60 秒，就不再代记。
local launched = {}

-- 能重开的 agent 窗格不存历史：resume 会自己重画对话
local function will_resume(a)
  if a == nil then return false end
  return a.session_id ~= nil or a.command ~= nil or (PROGRAM[a.kind] or {}).continue ~= nil
end

-- 这次找到的会话 ID 没有 was 里的新，就沿用 was 的：这次没找到，或找到的出自比上次更早启动的
-- 子进程（空闲时只剩启动时就开着的 MCP 服务这类，它们的值可能已经旧了）。
-- 命令行里的 ID 只是启动时的，比环境变量里的旧。
local function keep_newer(a, was)
  if not (was and was.session_id and was.kind == a.kind) then return end
  if a.session_id and (a.since or 0) >= (was.since or 0) then return end
  a.session_id, a.via, a.since = was.session_id, was.via, was.since
end

-- 终端窗格的目录、前台程序、shell 和 agent 写进 out，要保存历史的放进 terms。
-- 服务器停机时先结束窗格里的程序，窗格还在而程序已经没了，这时沿用上一次记下的
-- 目录和 agent，免得把要恢复的对话从快照里抹掉。
local function snap_terminal(sid, bid, out, terms)
  local info, old = terminal_info(sid, bid), last_blocks[bid]
  if not info.alive and old then info = old end
  local a = info.agent
  if a then
    -- 同一个 agent 进程沿用上次记下的；刚重开的进程沿用重开时的
    local was = old and old.agent
    keep_newer(a, launched[bid] or (was and was.pid == a.pid and was))
    launched[bid] = nil
  elseif info.alive then
    a = launched[bid]
  end
  out.cwd, out.fg, out.shell, out.agent = info.cwd, info.fg, info.shell, a
  if not keep_history or will_resume(a) then return end
  out.history = history_file(bid)
  if info.alive then table.insert(terms, { sid = sid, bid = bid, file = out.history }) end
end

local function snap_layout(node, sid, blocks, terms)
  if node == nil then return nil end
  if node.split then
    local s = node.split
    local before = snap_layout(s.before, sid, blocks, terms)
    local after = snap_layout(s.after, sid, blocks, terms)
    return { split = { direction = s.direction, ratio = s.ratio, before = before, after = after } }
  end
  local b = blocks[node.block_id] or {}
  local out = { id = node.block_id, flavor = b.flavor, label = b.label }
  if b.creator_name == TERM then snap_terminal(sid, node.block_id, out, terms) end
  return { block = out }
end

local function snap_window(sid, w, terms)
  local out = { focused = w.focused_block_id, zoomed = w.zoomed_block_id, floating = {} }
  -- "Window 6fc89798" 是服务器按窗口 ID 生成的默认名，不保存
  if w.label ~= "Window " .. w.window_id:sub(-8) then out.label = w.label end
  for _, l in ipairs(w.layers or {}) do
    local blocks = {}
    for _, b in ipairs(l.blocks or {}) do blocks[b.block_id] = b end
    local tree = snap_layout(l.layout, sid, blocks, terms)
    if l.kind == "tiled" then
      out.layout = tree
    elseif tree then
      table.insert(out.floating, { bounds = l.bounds, layout = tree })
    end
  end
  return out
end

local function snapshot(instance)
  local snap = { version = 1, server_instance = instance, sessions = {} }
  local terms = {}
  proc_cache = nil
  for _, s in ipairs(list_sessions()) do
    if wanted(s.label) then
      ensure_attached(s.session_id)
      local v = call("session.view", { session_id = s.session_id })
      local ss = { label = v.label, windows = {} }
      for _, w in ipairs(v.windows or {}) do
        local sw = snap_window(s.session_id, w, terms)
        sw.active = w.window_id == v.active_window_id or nil
        table.insert(ss.windows, sw)
      end
      table.insert(snap.sessions, ss)
    end
  end
  return snap, terms
end

-- 终端历史：vt 格式是屏幕加回滚缓冲区，带颜色。unwrap 把自动折行接回去，
-- 换了宽度的窗格回放时会重新折行。太长时只留最后 HISTORY_MAX 字节，
-- 从截断处的下一行开始，免得留下半个字符或半个转义序列。
local CHUNK = 983040  -- format、blob_read 单次最多返回 960 KiB
local FFFD = "\239\191\189"

local function drop_first_line(text)
  local nl = text:find("\n", 1, true)
  return nl and text:sub(nl + 1) or ""
end

-- 从 offset 读到结尾；offset 必须落在字符边界上，这样每次加上收到的字节数仍在边界上
local function read_from(where, offset, total, parts)
  while offset < total do
    where.offset, where.max_bytes = offset, CHUNK
    local b = rex.block.call(TERM, "blob_read", where)
    if not b or #b.data == 0 then return nil end
    table.insert(parts, b.data)
    offset = offset + #b.data
    if b.eof then break end
  end
  return parts
end

-- 从 total - HISTORY_MAX 起读。这个位置可能在一个多字节字符中间，服务器会把每个残缺的
-- 字节换成一个 U+FFFD（3 字节），收到的长度就和读过的字节数对不上。所以先找第一个换行，
-- 按开头 U+FFFD 的个数推算它的真实位置（开头本来就是 U+FFFD 时会有歧义，逐个核对），
-- 再从换行后面对齐着读。
local function read_tail(where, total)
  local start = total - HISTORY_MAX
  where.offset, where.max_bytes = start, CHUNK
  local probe = rex.block.call(TERM, "blob_read", where)
  local nl = probe and probe.data:find("\n", 1, true)
  if not nl then return nil end
  local k = 0
  while k < 3 and probe.data:sub(3 * k + 1, 3 * k + 3) == FFFD do k = k + 1 end
  if k == 0 then
    return read_from(where, start + #probe.data, total, { probe.data:sub(nl + 1) })
  end
  for j = k, 0, -1 do
    local at = start + nl - 1 - 2 * j
    where.offset, where.max_bytes = at, 16
    local b = rex.block.call(TERM, "blob_read", where)
    if b and b.data:sub(1, 1) == "\n" then return read_from(where, at + 1, total, {}) end
  end
end

local function read_history(sid, bid)
  local r = rex.block.call(TERM, "format", {
    session_id = sid, block_id = bid, format = "vt", trim = true, unwrap = true, max_bytes = CHUNK,
  })
  if not r then return nil end
  local parts
  if not r.id then
    parts = { #r.content > HISTORY_MAX and drop_first_line(r.content:sub(-HISTORY_MAX)) or r.content }
  else
    local where = { session_id = sid, block_id = bid, id = r.id }
    if r.total > HISTORY_MAX then
      parts = read_tail(where, r.total)
    else
      parts = read_from(where, #r.content, r.total, { r.content })
    end
  end
  if not parts then return nil end
  local text = table.concat(parts)
  -- 去掉末尾的空行和只剩样式的残留，回放后新提示符紧跟在历史后面。只在结尾一段里找。
  local head, tail = text:sub(1, -65537), text:sub(-65536)
  repeat
    local n1, n2
    tail, n1 = tail:gsub("%s+$", "")
    tail, n2 = tail:gsub("\27%[[%d;:]*m$", "")
  until n1 + n2 == 0
  return head .. tail
end

-- 只比较长度和首尾，不在内存里留整份历史
local history_seen = {}
local function save_history(sid, bid, file)
  local text = read_history(sid, bid)
  if text == nil then return end
  local mark = #text .. ":" .. text:sub(1, 1024) .. text:sub(-4096)
  if history_seen[file] == mark then return end
  if text == "" then
    os.remove(file)
  else
    write_file(file, "\27[0m" .. text .. "\27[0m")
  end
  history_seen[file] = mark
end

local function read_snapshot()
  local text = read_file(path)
  if text == nil then return nil end
  local snap, err = rex.json.decode(text)
  if snap == nil then error(path .. ": " .. tostring(err), 0) end
  return snap, text
end

local last_text
-- 写快照；with_history 时顺带保存每个终端的历史
local function save(instance, with_history)
  local snap, terms = snapshot(instance)
  if with_history then
    local attached
    for _, t in ipairs(terms) do
      if t.sid ~= attached then
        ensure_attached(t.sid)
        attached = t.sid
      end
      save_history(t.sid, t.bid, t.file)
    end
  end
  local text = assert(rex.json.encode(snap, { indent = true }))
  if text == last_text then return snap end
  -- 服务器停机时 block 会陆续关闭，别用空快照盖掉有内容的旧快照
  if #snap.sessions == 0 and next(last_blocks) then
    rex.log("warn", "没有会话可保存，保留旧快照")
    return snap
  end
  write_file(path, text)
  last_text = text
  remember_blocks(snap)
  return snap
end

-- 删掉快照和 .prev 都不再引用的历史文件。.prev 是上次恢复用的快照，
-- 它引用的文件可能还在被恢复出来的窗格读。
local function prune_history()
  local keep = {}
  for _, p in ipairs({ path, path .. ".prev" }) do
    local text = read_file(p)
    local snap = text and rex.json.decode(text)
    each_block(snap, function(b) if b.history then keep[b.history] = true end end)
  end
  local r = rex.exec({ "ls", "-1", history_dir })
  if not (r and r.ok) then return end
  for name in r.stdout:gmatch("[^\n]+") do
    local file = history_dir .. name
    if not keep[file] then
      os.remove(file)
      history_seen[file] = nil
    end
  end
end

-- 删掉进程已经不在的会话记录。先列文件再重新查进程：用快照开头的进程表，
-- 会把那之后才启动的 agent 刚写下的记录当成没有进程
local function prune_agents()
  local r = rex.exec({ "ls", "-1", agents_dir })
  if not (r and r.ok) then return end
  proc_cache = nil
  local t = procs()
  for name in r.stdout:gmatch("[^\n]+") do
    local pid = tonumber(name:match("^(%d+)%.json$"))
    if pid and not t.pgid[pid] then os.remove(agents_dir .. name) end
  end
end

-- 恢复出的窗格先用 /bin/sh 回放历史，这时还没读 shell 的配置文件，它们的输出不会夹进历史里；
-- 再在用户的 shell（登录、交互，PATH 和平时一样）里跑 agent，agent 退出后留下普通 shell。
-- fish、nu 这类和 sh 语法不同的 shell 不能这样传参数，agent 由 /bin/sh 跑，用窗格原有的环境。
-- $1 是 shell，$2 是历史文件（可为空），其余是 agent 的命令行。
local START = [[
s=$1 h=$2
shift 2
if [ -n "$h" ] && [ -f "$h" ]; then
  cat -- "$h"
  printf '\r\n\033[2m──── >_* reRex: 以上是恢复前的输出 <_*────\033[0m\r\n'
fi
[ $# -eq 0 ] && exec "$s" -l
case ${s##*/} in
  zsh|bash|ksh|sh|dash) exec "$s" -l -i -c 'trap : INT; "$@"; trap - INT; exec "$0" -l' "$s" "$@" ;;
esac
trap : INT
"$@"
trap - INT
exec "$s" -l
]]

local function pane_shell(b)
  local s = b.shell
  if s and SHELLS[s:match("[^/]*$")] and is_exec(s) then return s end
  s = os.getenv("SHELL")
  if s and is_exec(s) then return s end
  return is_exec("/bin/zsh") and "/bin/zsh" or "/bin/sh"
end

-- 返回重开的命令行和方式（resume、continue 或 rerun），不能重开时返回 nil 和原因。
-- 同一个对话只在一个窗格里重开；shared 的（herdr 这类，几个客户端可以接同一个会话，
-- 不带名字时总是接默认会话）和 rerun 的不查重。
local resumed = {}
-- 快照里有会话 ID 的对话所在的目录（种类 + 目录），这些目录里不再接着“最近的对话”
local has_id = {}
local function resume_argv(a)
  local spec = PROGRAM[a.kind]
  if not spec then return nil, "配置里没有这个程序" end
  if not a.cwd then return nil, "不知道它的目录" end
  if not is_dir(a.cwd) then return nil, "目录已不存在" end
  local key, argv, how
  if spec.rerun then
    if type(a.command) ~= "table" or not a.command[1] then return nil, "快照里没有它的命令行" end
    argv, how = a.command, "rerun"
  elseif a.session_id and spec.resume then
    key, argv, how = a.kind .. " " .. a.session_id, spec.resume, "resume"
  elseif not spec.continue then
    return nil, "没找到会话 ID"
  elseif has_id[a.kind .. " " .. a.cwd] and not spec.shared then
    return nil, "没找到会话 ID，同目录还有别的对话，接着最近的可能接错"
  else
    key, argv, how = a.kind .. " @" .. a.cwd, spec.continue, "continue"
  end
  if key and not spec.shared then
    if resumed[key] then return nil, how == "resume" and "已在别的窗格打开" or "同目录已有窗格接着最近的对话" end
    resumed[key] = true
  end
  local out = {}
  for i, x in ipairs(argv) do
    out[i] = how == "rerun" and tostring(x) or (tostring(x):gsub("{id}", function() return a.session_id end))
  end
  out[1] = args[a.kind .. "_bin"] and tostring(args[a.kind .. "_bin"]) or out[1]
  return out, how
end

-- 窗格的创建参数：目录，以及要回放的历史和要重开的程序。结果记进 ctx，第二个返回值是重开的 agent。
-- type 按现在的配置取：旧快照里没有它
local function pane_options(b, ctx)
  local pane, a = b.label or b.id, b.agent
  local argv, detail, kind
  if a then
    argv, detail = resume_argv(a)
    kind = (PROGRAM[a.kind] or {}).type or a.type
  end
  if argv then
    table.insert(ctx.resumed, {
      pane = pane, agent = a.kind, type = kind, session_id = a.session_id, cwd = a.cwd,
      continued = detail == "continue" or nil, command = detail == "rerun" and argv or nil,
    })
  elseif a then
    table.insert(ctx.not_restarted, {
      pane = pane, program = b.fg, agent = a.kind, type = kind, session_id = a.session_id, reason = detail,
    })
  elseif b.fg then
    table.insert(ctx.not_restarted, { pane = pane, program = b.fg })
  end
  -- 目录已不存在时整个会话都会创建失败，这时退回默认目录
  local options = {}
  local cwd = argv and a.cwd or b.cwd
  if cwd and is_dir(cwd) then options.cwd = cwd end
  local hist = keep_history and b.history and exists(b.history) and b.history
  if argv or hist then
    options.shell = "none"
    options.command = { "/bin/sh", "-c", START, "rerex", pane_shell(b), hist or "", unpack(argv or {}) }
  end
  return next(options) and options or nil, argv and a
end

-- 把快照里的布局树还原成 session.create / new_layer 接受的 layout。
-- order 按 before、after 的顺序记下旧 block ID 和重开的 agent，和服务器返回的 block_ids 一一对应。
local function to_layout(node, order, ctx)
  if node == nil then return nil end
  if node.split then
    local s = node.split
    local before = to_layout(s.before, order, ctx)
    local after = to_layout(s.after, order, ctx)
    return { split = { direction = s.direction, ratio = s.ratio, before = before, after = after } }
  end
  local b = node.block
  local options, agent = pane_options(b, ctx)
  table.insert(order, { id = b.id, agent = agent })
  return { block = { flavor = b.flavor or SHELL, label = b.label, options = options } }
end

-- 按 order 把旧 block ID 对上服务器返回的新 ID 记进 ids，重开了对话的新窗格记进 launched
local function place(order, block_ids, ids)
  for j, o in ipairs(order) do
    ids[o.id] = block_ids[j]
    launched[block_ids[j]] = o.agent
  end
end

local function restore_session(ss, ctx)
  local wins, orders = {}, {}
  for i, w in ipairs(ss.windows or {}) do
    orders[i] = {}
    local layout = to_layout(w.layout, orders[i], ctx) or { block = { flavor = SHELL } }
    wins[i] = { window_label = w.label, layout = layout }
  end
  -- 没有窗口时不传 initial_windows：空表会编码成 JSON 对象，服务器不收
  local c = call("session.create", { label = ss.label, initial_windows = wins[1] and wins })
  local sid = c.session_id
  ensure_attached(sid)
  local active
  for i, w in ipairs(ss.windows or {}) do
    local cw, ids = c.initial_windows[i], {}
    place(orders[i], cw.block_ids, ids)
    for _, fl in ipairs(w.floating or {}) do
      local order = {}
      local l = call("session.new_layer", {
        session_id = sid, window_id = cw.window_id,
        bounds = fl.bounds, layout = to_layout(fl.layout, order, ctx),
      })
      place(order, l.block_ids, ids)
    end
    if ids[w.zoomed] then
      call("session.zoom_block", { session_id = sid, block_id = ids[w.zoomed], zoom = true })
    end
    if ids[w.focused] then call("session.focus_block", { session_id = sid, block_id = ids[w.focused] }) end
    if w.active then active = cw.window_id end
  end
  -- focus_block 会顺带切换活动窗口，所以最后再定活动窗口
  if active then call("session.focus_window", { session_id = sid, window_id = active }) end
end

-- 已有同名会话的跳过，所以重复运行不会建出重复会话。
-- 正在运行的对话（不管在不在 Rex 里）也不再重开。
local function restore(snap)
  local existing = {}
  for _, s in ipairs(list_sessions()) do existing[s.label] = true end
  proc_cache = nil
  resumed = running_sessions()
  has_id = {}
  each_block(snap, function(b)
    local a = b.agent
    if a and a.session_id and a.cwd then has_id[a.kind .. " " .. a.cwd] = true end
  end)
  local res = { restored = {}, skipped = {}, failed = {}, resumed = {}, not_restarted = {} }
  for _, ss in ipairs(snap.sessions or {}) do
    if not wanted(ss.label) then
      -- 不在 only 范围内
    elseif existing[ss.label] then
      table.insert(res.skipped, ss.label)
    else
      local ok, err = pcall(restore_session, ss, res)
      if ok then table.insert(res.restored, ss.label)
      else table.insert(res.failed, { label = ss.label, error = err }) end
    end
  end
  return res
end

local function instance_id()
  return call("server.status", {}).instance_id
end

if mode ~= "save" and mode ~= "restore" and mode ~= "daemon" then
  error("mode 只能是 save、restore 或 daemon", 0)
end
local snap, text = read_snapshot()
if mode == "restore" then
  if snap == nil then error("没有快照：" .. path, 0) end
  return restore(snap)
end
-- 沿用上次记下的目录和 agent。服务器换过实例时 block ID 全都不同，对不上也不碍事
remember_blocks(snap)
if mode == "save" then
  local saved = save(instance_id(), keep_history)
  if keep_history then prune_history() end
  prune_agents()
  local labels = {}
  for _, ss in ipairs(saved.sessions) do table.insert(labels, ss.label) end
  return { path = path, sessions = labels }
end

-- daemon：快照来自别的服务器实例，说明服务器重启过，先恢复再开始保存
local instance = instance_id()
local restored = snap and snap.server_instance ~= instance
if restored then
  write_file(path .. ".prev", text)
  print(rex.json.encode(restore(snap)))
  rex.after(60, function() launched = {} end)
end

local function tick(with_history)
  -- 连不上服务器或服务器换了实例就退出，交给 launchd 重新拉起，下次启动时恢复
  local ok, now = pcall(instance_id)
  if not ok then
    rex.log("error", now)
    rex.stop(1)
    return
  end
  if now ~= instance then
    rex.stop(75)
    return
  end
  save(instance, with_history)
  if with_history then prune_history() end
  prune_agents()
end

-- 刚恢复的窗格还在回放历史，等一会儿再存它们的历史
tick(keep_history and not restored)
if keep_history and restored then rex.after(3, function() tick(true) end) end

-- 布局变化往往成串到达，停 1 秒没有新事件再保存
local pending
local function schedule()
  if pending then pending:cancel() end
  pending = rex.after(1, function()
    pending = nil
    tick(false)
  end)
end

for _, name in ipairs({
  "session_view_changed", "session_label_changed", "window_label_changed",
  "session_created", "session_destroyed", "terminal.pwd_changed",
}) do
  rex.on(name, schedule)
end

-- 前台程序变了（一条命令跑完、agent 启动或退出）：快照要更新 agent，
-- 停 2 秒后再存这个窗格的历史
local block_pending = {}
local function history_later(sid, bid)
  if block_pending[bid] then block_pending[bid]:cancel() end
  block_pending[bid] = rex.after(2, function()
    block_pending[bid] = nil
    local b = last_blocks[bid]
    if not (b and b.history) then return end  -- 不在快照里，或是能重开的 agent 的窗格
    ensure_attached(sid)
    proc_cache = nil
    local info = terminal_info(sid, bid)
    if info.alive and not will_resume(info.agent) then save_history(sid, bid, b.history) end
  end)
end

rex.on("terminal.process_changed", function(ctx, ev)
  schedule()
  local sid = ctx and ctx.session_id or ev and ev.session_id
  local bid = ctx and ctx.block_id or ev and ev.block_id
  if keep_history and sid and bid then history_later(sid, bid) end
end)

if keep_history then
  rex.every(tonumber(args.history_interval) or 60, function() tick(true) end)
end

-- 没开 OSC 7 的 shell 改目录不会发事件，Claude Code 是否在回答中也没有事件，靠定时保存兜底
rex.every(tonumber(args.interval) or 30, function() tick(false) end)
