-- e2e.lua：rerex 端到端测试的驱动。tests/e2e.sh 用 rex do 调它，连的是测试用的 Rex 服务器。
--
--   phase=talk    每个场景开一个会话，在窗格里启动 agent、按步骤对话，预期写进 <run>/expect.json
--   phase=verify  服务器重启、rerex 恢复以后，看每个窗格重开的对话对不对，结果写进 <run>/result.json
--
-- 场景在 <run>/scenarios.json，由 e2e.sh 从 tests/scenarios.json 里挑出来。步骤：
--   join         让 agent 把两段随机字符拼起来，屏幕上出现拼好的词就算答完。这个词不在问题里，
--                恢复后屏幕上又出现它，说明接回的是这个对话
--   sleep join   先让 agent 跑 sleep 15 再拼词。sleep 跑着时，子进程的环境变量里是这个对话的 ID
--   /clear、/new 换成一个新对话

local TERM = "com.superlogical.terminal"
local SHELL = "com.superlogical.terminal.shell"
local run = assert(rex.args.run, "要给 run=")
local phase = rex.args.phase

-- 每个程序的界面：type 是恢复结果里应有的 type，ready 判断能输入了，dialogs 是要替用户回答的提示和要按的键
local UI = {
  claude = {
    type = "agent",
    ready = function(s) return s:find("Claude Code v", 1, true) and s:find("\n❯", 1, true) end,
    dialogs = { { "Do you trust the files in this folder", "\r" } },
  },
  codex = {
    type = "agent",
    ready = function(s) return s:find("OpenAI Codex", 1, true) and s:find("for shortcuts", 1, true) end,
    -- 新装的 hook 要先信任，选第 2 项“全部信任并继续”。不用 app-server 的 codex 启动时，
    -- 别的 codex 已经起了 app-server，会问怎么办，选第 1 项“这次不用”
    dialogs = {
      { "Hooks need review", "2", "\r" },
      { "Run without daemon this time", "1", "\r" },
      { "Do you trust the contents of this directory", "\r" },
    },
  },
  pi = {
    type = "agent",
    -- 底栏的上下文用量，例如 0.0%/200k
    ready = function(s) return s:find("%d%.%d%%/%d") end,
    dialogs = {},
  },
  hermes = {
    type = "agent",
    -- 输入框里的提示语会换，看欢迎语和底栏
    ready = function(s) return s:find("Welcome to Hermes Agent", 1, true) and s:find("☤ ", 1, true) end,
    -- 第一次启动问要不要分享统计，默认选中的是“不了”
    dialogs = { { "Help improve Hermes", "\r" } },
  },
  -- 全屏 TUI 应用：不对话，看界面画出来了没有
  htop = { type = "tui", ready = function(s) return s:find("Mem[", 1, true) and s:find("Load average", 1, true) end, dialogs = {} },
  btop = { type = "tui", ready = function(s) return s:find("cpu", 1, true) and s:find("mem", 1, true) end, dialogs = {} },
}

-- 各动作的超时秒数。第一次启动 codex、hermes 要装运行时，ready 给得长
local TIMEOUT = { start = 10, ready = 300, switch = 30, ask = 180, verify = 180 }

local function read_json(p)
  local f = io.open(p)
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return rex.json.decode(text)
end

local function write_file(p, text)
  local f = assert(io.open(p, "w"))
  f:write(text)
  f:close()
end

-- label 为 name 的会话里唯一的那个窗格
local function pane_of(name)
  for _, s in ipairs(rex.call("session.list", {}).sessions or {}) do
    if s.label == name then
      rex.session.attach{ session_id = s.session_id }
      local w = (rex.call("session.view", { session_id = s.session_id }).windows or {})[1]
      local node = w and w.layers[1].layout
      return node and node.block_id and { sid = s.session_id, bid = node.block_id }
    end
  end
end

-- 屏幕加回滚缓冲区的纯文本
local function screen(p)
  local r = rex.block.call(TERM, "format", { session_id = p.sid, block_id = p.bid, format = "text", trim = true })
  return r and r.content or ""
end

local function send(p, data)
  rex.block.call(TERM, "write", { session_id = p.sid, block_id = p.bid, data = data })
end

-- 打一行字再回车。回车单独发：和字一起发的话，有的 agent 会当成粘贴进来的换行
local function enter(p, text)
  send(p, text)
  rex.sleep(0.5)
  send(p, "\r")
end

-- 屏幕上出现提示就按它的键。回滚缓冲区里会一直留着提示，所以每个只答一次
local function answer_dialogs(job, s)
  for i, d in ipairs(UI[job.agent].dialogs) do
    if not job.answered[i] and s:find(d[1], 1, true) then
      job.answered[i] = true
      for k = 2, #d do
        send(job.pane, d[k])
        rex.sleep(0.5)
      end
    end
  end
end

local function fail(job, why, s)
  job.done, job.error = true, why
  write_file(run .. "/screens/" .. job.name .. "-" .. phase .. ".txt", s)
  print(("%-18s 失败：%s"):format(job.name, why))
end

math.randomseed(os.time())
local function part()
  return string.char(math.random(97, 122), math.random(97, 122)) .. math.random(0, 9)
end

local function question(a, b, sleep)
  local q = ("join the two parts '%s' and '%s' with nothing between them. Reply with only the result."):format(a, b)
  if sleep then return "First run the shell command `sleep 15`. Then " .. q end
  return "J" .. q:sub(2)
end

-- 场景的步骤展开成动作：start 启动 agent，ready 等到能输入，ask 问一句并等到回答，switch 换对话
local function plan(sc)
  local acts = { { "start" }, { "ready" } }
  for _, step in ipairs(sc.steps) do
    if step:sub(1, 1) == "/" then
      table.insert(acts, { "switch", step })
      table.insert(acts, { "ready" })
    else
      table.insert(acts, { "ask", sleep = step == "sleep join" })
    end
  end
  return acts
end
-- 推进一个场景：当前动作开个头就返回，下一轮再看它做完没有。ready 要连着三轮都对，
-- 免得界面刚画出来、还没准备好收输入
local function advance(job)
  local act = job.acts[job.at]
  local s = screen(job.pane)
  answer_dialogs(job, s)
  if not act.t then
    act.t, act.seen = 0, 0
    if act[1] == "start" then
      send(job.pane, job.cmd .. "\r")
    elseif act[1] == "switch" then
      enter(job.pane, act[2])
    elseif act[1] == "ask" then
      local a, b = part(), part()
      act.word = a .. b
      table.insert(job.words, act.word)
      enter(job.pane, question(a, b, act.sleep))
    end
    return
  end
  act.t = act.t + 0.5
  local ok
  if act[1] == "ready" then
    act.seen = UI[job.agent].ready(s) and act.seen + 1 or 0
    ok = act.seen >= 3
  elseif act[1] == "ask" then
    ok = s:find(act.word, 1, true) ~= nil
  else
    ok = act.t >= 3
  end
  if ok then
    job.at = job.at + 1
    job.done = job.at > #job.acts
    if act[1] == "ask" then print(("%-18s 答了 %s"):format(job.name, act.word)) end
  elseif act.t > TIMEOUT[act[1]] then
    fail(job, act[1] == "ask" and "等回答超时" or act[1] .. " 超时", s)
  end
end

-- 让所有 job 交替推进，直到都做完
local function drive(jobs, step)
  local left = #jobs
  while left > 0 do
    left = 0
    for _, job in ipairs(jobs) do
      if not job.done then step(job) end
      if not job.done then left = left + 1 end
    end
    rex.sleep(0.5)
  end
end

local function talk()
  local jobs = {}
  for _, sc in ipairs(read_json(run .. "/scenarios.json")) do
    rex.call("session.create", { label = sc.name, initial_windows = { { layout = { block = {
      flavor = SHELL, label = sc.name, options = { cwd = run .. "/work/" .. sc.name },
    } } } } })
    table.insert(jobs, {
      name = sc.name, agent = sc.agent, cmd = sc.cmd, via = sc.via, restart = sc.restart, command = sc.command,
      acts = plan(sc), at = 1,
      pane = pane_of(sc.name), answered = {}, words = {},
    })
  end
  drive(jobs, advance)
  -- 换过对话的，恢复后应当是最后那个对话：最后一个词在，第一个词不在
  local switched = {}
  for _, sc in ipairs(read_json(run .. "/scenarios.json")) do
    for _, step in ipairs(sc.steps) do
      if step:sub(1, 1) == "/" then switched[sc.name] = true end
    end
  end
  local out = {}
  for _, job in ipairs(jobs) do
    table.insert(out, {
      name = job.name, agent = job.agent, error = job.error, via = job.via, restart = job.restart,
      command = job.command, expect = job.words[#job.words],
      stale = switched[job.name] and job.words[1] or nil,
    })
  end
  write_file(run .. "/expect.json", rex.json.encode(out, { indent = true }))
end

-- 在 restore 的结果里按窗格 label 找
local function find(list, name)
  for _, x in ipairs(list or {}) do
    if x.pane == name then return x end
  end
end

-- 恢复前的快照里，这个窗格记下的 agent 和会话 ID 从哪来
local function recorded(name)
  local snap = read_json(run .. "/snap/snapshot.json.prev") or {}
  for _, ss in ipairs(snap.sessions or {}) do
    for _, w in ipairs(ss.windows or {}) do
      local b = w.layout and w.layout.block
      if b and b.label == name then return b.agent, b.fg end
    end
  end
end

-- 恢复前的快照里这个窗格记下的情况。e.via 是会话 ID 应当来自的地方，对不上就是 rerex 的问题，
-- 哪怕 agent 接着最近的对话碰巧接对了
local function describe(e)
  local a, fg = recorded(e.name)
  if not a then return "快照里没认出 agent，前台程序是 " .. tostring(fg), e.via and "没认出 agent" end
  local how = a.command and "快照里记了命令行"
    or a.session_id and "快照里的会话 ID 来自 " .. tostring(a.via) or "快照里没有会话 ID"
  if e.via and a.via ~= e.via then return how, "会话 ID 应当来自 " .. e.via end
  return how
end

-- 等恢复出的窗格里出现上一轮的回答，再看换对话之前的那个词是不是也在。
-- 没有回答的（TUI 应用）等界面画出来
local function check(job)
  local s = screen(job.pane)
  answer_dialogs(job, s)
  job.t = job.t + 0.5
  local want = job.expect or "界面"
  if job.expect and s:find(job.expect, 1, true) or not job.expect and UI[job.agent].ready(s) then
    if job.stale and s:find(job.stale, 1, true) then
      return fail(job, "接回的是换对话之前的那个（" .. job.stale .. " 也在屏幕上）", s)
    end
    job.done = true
    print(("%-18s 接回了 %s"):format(job.name, want))
  elseif job.t > TIMEOUT.verify then
    fail(job, "等了 " .. TIMEOUT.verify .. " 秒，屏幕上没出现 " .. want, s)
  end
end

local function verify()
  local restored = read_json(run .. "/restore.json") or {}
  local jobs, results = {}, {}
  for _, e in ipairs(read_json(run .. "/expect.json")) do
    local how, wrong = describe(e)
    local r = { name = e.name, how = how, wrong_via = wrong }
    local resumed = find(restored.resumed, e.name)
    local skipped = find(restored.not_restarted, e.name)
    local pane = pane_of(e.name)
    local entry = resumed or skipped
    if e.error then
      r.error = "对话阶段就失败了：" .. e.error
    elseif not pane then
      r.error = "会话没恢复"
    elseif entry and entry.type ~= UI[e.agent].type then
      r.error = "恢复结果里的 type 应当是 " .. UI[e.agent].type .. "，实际是 " .. tostring(entry.type)
    elseif e.restart == false then
      -- 不该重开的：要认出 agent，并且留下 shell
      if resumed then
        r.error = "不该重开，rerex 却重开了"
      elseif not (skipped and skipped.agent == e.agent) then
        r.error = "rerex 没认出它是 " .. e.agent
      else
        r.resumed = "按预期没重开：" .. tostring(skipped.reason)
      end
    elseif not resumed then
      r.error = "rerex 没重开它" .. (skipped and skipped.reason and "：" .. skipped.reason or "")
    elseif e.command and table.concat(resumed.command or {}, " ") ~= e.command then
      r.error = "应当重跑 " .. e.command .. "，实际是 " .. table.concat(resumed.command or {}, " ")
    else
      r.resumed = resumed.command and "重跑 " .. table.concat(resumed.command, " ")
        or resumed.continued and "接着最近的对话" or "按会话 ID 重开"
      table.insert(jobs, {
        name = e.name, agent = e.agent, expect = e.expect, stale = e.stale,
        pane = pane, answered = {}, t = 0, result = r,
      })
    end
    table.insert(results, r)
  end
  drive(jobs, check)
  for _, job in ipairs(jobs) do job.result.error = job.error end
  for _, r in ipairs(results) do r.ok = r.error == nil and r.wrong_via == nil end
  write_file(run .. "/result.json", rex.json.encode(results, { indent = true }))
end

if phase == "talk" then
  talk()
elseif phase == "verify" then
  verify()
else
  error("phase 只能是 talk 或 verify", 0)
end