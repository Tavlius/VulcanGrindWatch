-- GrindWatch: slash commands, chat reports, and session history.
local _, ns = ...

function ns.SetPaused(paused)
  if paused then
    ns.CommitTime()  -- you were farming up to the moment you paused
  else
    ns.KeepAlive()   -- don't resume straight into "idle"
  end
  ns.S.paused = paused and true or false
  ns.Print(paused and "paused." or "resumed.")
  ns.UpdateDisplay()
  if ns.RelabelMenu then ns.RelabelMenu() end  -- an open gear menu says Pause/Resume
end

---------------------------------------------------------------------------
-- Reports
---------------------------------------------------------------------------
local function RateOr(fields, money)
  local r = ns.SessionRate(fields)
  if not r then return "--" end
  return money and ns.Money(r) or ns.Short(r)
end

local function PriceTag()
  return ns.DB.priceSource == "auction" and "AH" or "vendor"
end

-- Full report for your own chat frame.
function ns.ReportLines()
  local S = ns.S
  local gold = ns.GoldFields()
  local zone = ns.TopZone()
  local lines = {
    string.format("Session%s: %s active%s", S.note and (' "' .. S.note .. '"') or "",
      ns.Duration(ns.Elapsed()), zone and (" in " .. zone) or ""),
    string.format("Kills: %s (%s/hr) - %d with XP, %d loot-only", ns.Commas(ns.Total({ "k" })),
      RateOr({ "k" }), S.xpKills, S.lootOnlyKills),
  }
  if not ns.AtMaxLevel() then
    local ttl, restedEnds = ns.TimeToLevel()
    lines[#lines + 1] = string.format("XP: %s (%s/hr), level in %s%s", ns.Commas(ns.Total({ "x" })),
      RateOr({ "x" }), ttl and ns.Duration(ttl) or "--",
      restedEnds and (" (rested runs out in " .. ns.Duration(restedEnds) .. ")") or "")
  end
  local recent = ns.RecentRate(gold)
  lines[#lines + 1] = string.format("Gold: %s coin + %s loot (%s) = %s (%s/hr, last %dm %s/hr)",
    ns.Money(ns.Total({ "c" })), ns.Money(ns.Total({ ns.LootField() })), PriceTag(),
    ns.Money(ns.Total(gold)), RateOr(gold, true), ns.DB.windowMinutes, recent and ns.Money(recent) or "--")
  if S.spent > 0 then
    lines[#lines + 1] = string.format("Spent while tracking: %s (repairs, ammo, food, flights, training)", ns.Money(S.spent))
  end

  local mobs = {}
  for name, n in pairs(S.mobs) do mobs[#mobs + 1] = { name = name, n = n } end
  table.sort(mobs, function(a, b) return a.n > b.n end)
  if #mobs > 0 then
    local parts = {}
    for i = 1, math.min(3, #mobs) do parts[i] = mobs[i].name .. " x" .. mobs[i].n end
    lines[#lines + 1] = "Top mobs: " .. table.concat(parts, ", ")
  end

  local valueKey = ns.DB.priceSource == "auction" and "valueAH" or "value"
  local items = {}
  for _, it in pairs(S.items) do items[#items + 1] = it end
  table.sort(items, function(a, b) return (a[valueKey] or 0) > (b[valueKey] or 0) end)
  if #items > 0 then
    local parts = {}
    for i = 1, math.min(3, #items) do
      local it = items[i]
      parts[i] = string.format("%s x%d (%s)", it.name, it.count, ns.Money(it[valueKey] or 0))
    end
    lines[#lines + 1] = "Top loot: " .. table.concat(parts, ", ")
  end

  if S.questXP > 0 or S.questCoin > 0 then
    lines[#lines + 1] = string.format("Quest rewards (not in rates): %s XP, %s",
      ns.Commas(S.questXP), ns.Money(S.questCoin))
  end
  if ns.PendingCount() > 0 then
    lines[#lines + 1] = string.format("%d item(s) still loading prices.", ns.PendingCount())
  end
  return lines
end

-- Two short lines for party/guild/whisper so the report isn't spam.
function ns.ChatLines()
  local gold = ns.GoldFields()
  local zone = ns.TopZone()
  local first = string.format("[GrindWatch] %s%s: %s kills/hr, %s gold/hr (%s)",
    ns.Duration(ns.Elapsed()), zone and (" in " .. zone) or "", RateOr({ "k" }), RateOr(gold, true), PriceTag())
  if not ns.AtMaxLevel() then
    first = first .. string.format(", %s XP/hr", RateOr({ "x" }))
  end
  return { first, string.format("[GrindWatch] Totals: %s kills, %s gold",
    ns.Commas(ns.Total({ "k" })), ns.Money(ns.Total(gold))) }
end

local CHANNELS = {
  party = "PARTY", p = "PARTY", raid = "RAID", guild = "GUILD", g = "GUILD",
  say = "SAY", s = "SAY", instance = "INSTANCE_CHAT", i = "INSTANCE_CHAT",
}
local WHISPER = { w = true, whisper = true, tell = true, t = true }

function ns.Report(args)
  args = args or ""
  local word, rest = args:match("^(%S*)%s*(.-)$")
  word = (word or ""):lower()
  if word == "" then
    for _, line in ipairs(ns.ReportLines()) do ns.Print(line) end
    return
  end
  local channel, target = CHANNELS[word], nil
  if WHISPER[word] then
    channel, target = "WHISPER", rest:match("^(%S+)")
    if not target then ns.Print("usage: /gw report w <name>") return end
  end
  if not channel then
    ns.Print("unknown channel '" .. word .. "'. Use party, raid, guild, say, instance, or w <name>.")
    return
  end
  if (channel == "PARTY" and not IsInGroup()) or (channel == "RAID" and not IsInRaid()) then
    ns.Print("you're not in a " .. channel:lower() .. "; here's your report instead.")
    for _, line in ipairs(ns.ReportLines()) do ns.Print(line) end
    return
  end
  for _, line in ipairs(ns.ChatLines()) do
    local ok = pcall(ns.SendChat, ns.StripColors(line), channel, nil, target)
    if not ok then
      ns.Print("couldn't send to " .. channel:lower() .. ".")
      return
    end
  end
end

---------------------------------------------------------------------------
-- History
---------------------------------------------------------------------------
function ns.HistoryLines(limit)
  local out = {}
  for i, h in ipairs(ns.DB.history) do
    if limit and i > limit then break end
    local hours = h.elapsed / 3600
    local enough = h.elapsed >= ns.MIN_RATE_SECONDS  -- same rule as the live window
    local loot = h.loot or 0
    local gold = (h.coin or 0) + (ns.DB.priceSource == "auction" and (h.lootAH or loot) or loot)
    local when = (h.when and h.when > 0 and date) and date("%m/%d %H:%M", h.when) or (h.note or "?")
    local xpPart = (enough and (h.xp or 0) > 0) and string.format(", %s XP/hr", ns.Short(h.xp / hours)) or ""
    out[#out + 1] = string.format("%d. %s %s%s%s (%s): %s gold/hr, %s kills/hr%s", i, when,
      h.char and (h.char .. " ") or "", h.zone or "unknown zone", h.label and (' "' .. h.label .. '"') or "",
      ns.Duration(h.elapsed), enough and ns.Money(gold / hours) or "--",
      enough and ns.Short((h.kills or 0) / hours) or "--", xpPart)
  end
  return out
end

-- Best spots: history grouped by zone (sessions under 3 min are too short to
-- judge and are skipped). Ranked by what matters now: XP/hr while leveling,
-- gold/hr at max level. Rates are time-weighted. Returns lines and the ranking.
function ns.SpotLines()
  local zones, order = {}, {}
  for _, h in ipairs(ns.DB.history) do
    if h.elapsed >= ns.MIN_RATE_SECONDS then
      local key = h.zone or "unknown zone"
      local z = zones[key]
      if not z then
        z = { zone = key, n = 0, elapsed = 0, gold = 0, kills = 0, xp = 0 }
        zones[key] = z
        order[#order + 1] = z
      end
      z.n = z.n + 1
      z.elapsed = z.elapsed + h.elapsed
      local loot = h.loot or 0
      z.gold = z.gold + (h.coin or 0) + (ns.DB.priceSource == "auction" and (h.lootAH or loot) or loot)
      z.kills = z.kills + (h.kills or 0)
      z.xp = z.xp + (h.xp or 0)
    end
  end
  local byXP = not ns.AtMaxLevel()
  local key = byXP and "xp" or "gold"
  table.sort(order, function(a, b) return a[key] / a.elapsed > b[key] / b.elapsed end)
  local out = {}
  for i, z in ipairs(order) do
    local hours = z.elapsed / 3600
    out[#out + 1] = string.format("%d. %s: %s gold/hr, %s kills/hr%s (%d session%s, %s)", i, z.zone,
      ns.Money(z.gold / hours), ns.Short(z.kills / hours),
      z.xp > 0 and (", " .. ns.Short(z.xp / hours) .. " XP/hr") or "",
      z.n, z.n == 1 and "" or "s", ns.Duration(z.elapsed))
  end
  return out, byXP and "XP/hr" or "gold/hr"
end

-- Every looted item this session, most valuable first.
function ns.LootLines()
  local valueKey = ns.DB.priceSource == "auction" and "valueAH" or "value"
  local items = {}
  for _, it in pairs(ns.S.items) do items[#items + 1] = it end
  table.sort(items, function(a, b)
    if (a[valueKey] or 0) ~= (b[valueKey] or 0) then return (a[valueKey] or 0) > (b[valueKey] or 0) end
    return a.name < b.name
  end)
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = string.format("%s x%d - %s", it.name, it.count, ns.Money(it[valueKey] or 0))
  end
  return out
end

-- What this client supports, so behavior can be checked in-game.
function ns.CheckLines()
  local function yes(v) return v and "yes" or "NO" end
  local build = GetBuildInfo and select(4, GetBuildInfo())
  local lines = {
    "Client interface: " .. tostring(build) .. " (addon built for 16001)",
    "Secret values in use: " .. yes(issecretvalue) .. ", item info: " .. yes(ns.GetItemInfo)
      .. ", spell names: " .. yes((C_Spell and (C_Spell.GetSpellName or C_Spell.GetSpellInfo)) or GetSpellInfo),
    "Loot sources: " .. yes(GetLootSourceInfo) .. ", unit GUIDs: " .. yes(UnitGUID)
      .. ", addon messages: " .. yes(ns.SendAddon),
    "Max level: " .. (ns.AtMaxLevel() and "yes" or "no") .. " (effective-max API: "
      .. yes(IsPlayerAtEffectiveMaxLevel) .. ", GetMaxPlayerLevel = "
      .. tostring(GetMaxPlayerLevel and ns.plain(GetMaxPlayerLevel())) .. ")",
    "Auctionator: " .. yes(ns.HasAuctionator()),
    "Gear icon: " .. tostring(ns.gearTexture) .. ";  page in Options > AddOns: " .. yes(ns.optionsRegistered),
  }
  for kind, ids in pairs(ns.KNOWN_SPELLS) do
    local names = {}
    for _, id in ipairs(ids) do
      local ok, name = pcall(ns.SpellName, id)
      names[#names + 1] = id .. "=" .. (ok and name and tostring(name) or "?")
    end
    lines[#lines + 1] = "Known " .. kind .. " spells: " .. table.concat(names, ", ")
  end
  local custom = {}
  for id, kind in pairs(ns.DB.customSpells) do custom[#custom + 1] = id .. "=" .. kind end
  table.sort(custom)
  lines[#lines + 1] = "Your added spells: " .. (#custom > 0 and table.concat(custom, ", ") or "none")
  if ns.Persist then lines[#lines + 1] = ns.Persist.CheckLine() end
  return lines
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local HELP = {
  "|cffffd700Session|r",
  "/gw - show or hide the window (also: Key Bindings > AddOns)",
  "/gw pause | resume - stop or restart the clock (or right-click the window)",
  "/gw reset - save this session to history and start a new one",
  "/gw note <text> - label this session, e.g. /gw note murlocs by the coast",
  "|cffffd700Results|r",
  "/gw report - full report;  /gw report party | raid | guild | instance | say | w <name> - short summary",
  "/gw loot - every item looted this session",
  "/gw history [all | clear] - recent sessions;  /gw spots - best zones from your history",
  "/gw export - history as CSV to copy;  /gw export debug - the diagnostics log",
  "|cffffd700Settings|r",
  "/gw settings - open or close the settings window (or the gear on the GrindWatch window > Settings...)",
  "/gw set - list every setting;  /gw set <name> <value> - change one, e.g. /gw set alertPercent 50",
  "/gw defaults - every setting back to its default (asks first)",
  "/gw price vendor | ah - value loot at vendor or Auctionator price;  /gw reprice - re-value loot at current prices",
  "/gw idle <minutes> - stop the clock after this long with no activity (0 = off)",
  "/gw afk - toggle pause while AFK;  /gw alert - toggle the slowing-down alert",
  "/gw sync - toggle duo sharing;  /gw compact - toggle the small window;  /gw lock | unlock;  /gw scale <0.5-2>",
  "|cffffd700Troubleshooting|r",
  "/gw check - what this client supports;  /gw debug on | off | echo | clear - diagnostics log",
  "/gw spell gather | pickpocket | remove <spellID> - teach a skinning/pickpocket spell;  /gw spell list",
}

local function ShowHelp()
  for _, line in ipairs(HELP) do ns.Print(line) end
end

local commands = {}
commands[""] = function() ns.SetShown(not ns.frame:IsShown()) end
commands.toggle = commands[""]
commands.show = function() ns.SetShown(true) end
commands.hide = function() ns.SetShown(false) end
commands.pause = function() ns.SetPaused(true) end
commands.resume = function() ns.SetPaused(false) end
commands.start = commands.resume
-- Shared by /gw reset and the gear menu.
function ns.ResetAndReport()
  local archived, unvalued = ns.ResetSession()
  ns.Print((archived and "session saved to /gw history and reset." or "session reset.")
    .. " The clock starts at your next pull.")
  if archived and unvalued and unvalued > 0 then  -- only meaningful if something was saved
    ns.Print(string.format("%d looted item(s) had no price yet (item data not loaded) and aren't in the saved value.", unvalued))
  end
end
commands.reset = function() ns.ResetAndReport() end
commands.report = function(rest) ns.Report(rest) end
commands.history = function(rest)
  local arg = rest:lower()
  if arg == "clear" or arg == "clear yes" then
    local n = #ns.DB.history
    if arg == "clear" then
      ns.Print(string.format("this deletes all %d saved session(s). Type /gw history clear yes to confirm.", n))
      return
    end
    wipe(ns.DB.history)
    ns.Print(string.format("deleted %d saved session(s).", n))
    return
  end
  local limit = 10
  if arg == "all" then limit = nil end  -- (not `arg == "all" and nil or 10`: that's always 10)
  local lines = ns.HistoryLines(limit)
  if #lines == 0 then ns.Print("no saved sessions yet. /gw reset saves the current one.") return end
  for _, line in ipairs(lines) do ns.Print(line) end
  if arg ~= "all" and #ns.DB.history > 10 then
    ns.Print(string.format("%d more: /gw history all, or /gw spots for a summary by zone.", #ns.DB.history - 10))
  end
end
commands.spots = function()
  local lines, rankedBy = ns.SpotLines()
  if #lines == 0 then ns.Print("no sessions of 3+ minutes in your history yet. /gw reset saves the current one.") return end
  ns.Print("best spots by " .. rankedBy .. " (from your history):")
  for _, line in ipairs(lines) do ns.Print(line) end
end
commands.loot = function()
  local lines = ns.LootLines()
  if #lines == 0 then ns.Print("nothing looted this session yet.") return end
  for _, line in ipairs(lines) do ns.Print(line) end
end
commands.note = function(rest)
  if rest == "" then
    ns.S.note = nil
    ns.Print("session label cleared.")
  else
    ns.S.note = ns.Truncate(rest, 60)
    ns.Print('session labelled "' .. ns.S.note .. '".')
  end
end
commands.export = function(rest)
  local what = rest:lower() == "debug" and "debug" or "history"
  ns.ShowCopy(what == "debug" and "GrindWatch diagnostics" or "GrindWatch history (CSV)", ns.ExportLines(what))
end
commands.check = function()
  for _, line in ipairs(ns.CheckLines()) do ns.Print(line) end
end
commands.debug = function(rest)
  local arg = rest:lower()
  if arg == "on" then
    ns.SetSetting("debug", true)
    ns.Print("diagnostics on. Play normally, then /gw export debug to copy the log.")
  elseif arg == "off" then
    ns.SetSetting("debug", false)  -- also turns echo off
    ns.Print("diagnostics off (the log is kept until /gw debug clear).")
  elseif arg == "echo" then
    ns.SetSetting("debugEcho", not ns.DB.debugEcho)  -- turning echo on also turns recording on
    ns.Print("diagnostics " .. (ns.DB.debugEcho and "also printed to chat." or "no longer printed to chat."))
  elseif arg == "clear" then
    wipe(ns.DB.debugLog)
    ns.Print("diagnostics log cleared.")
  else
    ns.Print(string.format("diagnostics are %s (%d entries). Use /gw debug on | off | echo | clear.",
      ns.DB.debug and "on" or "off", #ns.DB.debugLog))
  end
end
-- Taught spells (shared by /gw spell and the settings window).
function ns.AddCustomSpell(id, kind)
  ns.DB.customSpells[id] = kind
  ns.Print(string.format("spell %d now counts as %s.", id, kind == "gather" and "gathering (skinning)" or "pickpocketing"))
  ns.Fire("SPELLS")
end
function ns.RemoveCustomSpell(id)
  local had = ns.DB.customSpells[id]
  ns.DB.customSpells[id] = nil
  local builtIn = ns.ClassifySpell(id)
  if builtIn then
    ns.Print(string.format("spell %d is built in as %s and can't be removed%s.", id, builtIn,
      had and " (your own entry for it was removed)" or ""))
  else
    ns.Print(string.format("spell %d %s.", id, had and "removed" or "wasn't in your list"))
  end
  ns.Fire("SPELLS")
end

commands.spell = function(rest)
  local kind, id = rest:lower():match("^(%a+)%s*(%d*)$")
  id = tonumber(id)
  if kind == "list" then
    local any = false
    for sid, k in pairs(ns.DB.customSpells) do
      any = true
      local ok, name = pcall(ns.SpellName, sid)
      ns.Print(string.format("%d (%s): %s", sid, ok and tostring(name) or "?", k))
    end
    if not any then ns.Print("no added spells. /gw debug echo shows spell IDs as you cast.") end
  elseif (kind == "gather" or kind == "pickpocket") and id then
    ns.AddCustomSpell(id, kind)
  elseif kind == "remove" and id then
    ns.RemoveCustomSpell(id)
  else
    ns.Print("use /gw spell gather <id>, /gw spell pickpocket <id>, /gw spell remove <id> or /gw spell list.")
  end
end
commands.reprice = function()
  -- Works without Auctionator too: items whose vendor price hadn't loaded get one.
  local oldVendor = ns.S.totals.l or 0
  local old, new = ns.Reprice()
  if ns.HasAuctionator() then
    ns.Print(string.format("loot re-valued at current prices: AH value %s -> %s.", ns.Money(old), ns.Money(new)))
  else
    ns.Print(string.format("loot re-valued at vendor prices: %s -> %s (no Auctionator, so no AH prices).",
      ns.Money(oldVendor), ns.Money(ns.S.totals.l)))
  end
  ns.UpdateDisplay()
end
-- Toggles share one path with the settings window (ns.SetSetting), so the
-- side effects (redraw, AFK check, partner wipe) can't drift apart.
local function Toggle(key, onText, offText)
  return function()
    ns.SetSetting(key, not ns.DB[key])
    ns.Print(ns.DB[key] and onText or offText)
  end
end
commands.compact = Toggle("compact", "compact window.", "full window.")
commands.alert = Toggle("alerts", "slowing-down alert on.", "slowing-down alert off.")
commands.afk = Toggle("autoAFKPause", "pause while AFK on.", "pause while AFK off.")
commands.sync = Toggle("sync", "duo sync on.", "duo sync off.")
commands.lock = function() ns.SetSetting("locked", true) ns.Print("window locked.") end
commands.unlock = function() ns.SetSetting("locked", false) ns.Print("window unlocked.") end
commands.price = function(rest)
  local v = rest:lower()
  if v ~= "ah" and v ~= "auction" and v ~= "vendor" then
    ns.Print("loot is valued at " .. (ns.DB.priceSource == "auction" and "AH" or "vendor")
      .. " price. Use /gw price vendor or /gw price ah.")
    return
  end
  local ok = ns.SetSetting("priceSource", v)
  if not ok then
    ns.Print("Auctionator isn't loaded, so AH prices aren't available. Staying on vendor prices.")
    return
  end
  if ns.DB.priceSource == "auction" and not ns.HasAuctionator() then
    -- Already on AH (from before), but there's nothing to read prices from now.
    ns.Print("loot is set to AH price, but Auctionator isn't loaded, so only vendor prices count for now.")
    return
  end
  ns.Print("loot now valued at " .. (ns.DB.priceSource == "auction" and "AH price (after the 5% cut, never below vendor)" or "vendor price") .. ".")
end
commands.idle = function(rest)
  local ok, n = ns.SetSetting("idleMinutes", rest)
  if not ok then
    ns.Print("idle cutoff is " .. ns.SettingText(ns.SettingDef("idleMinutes")) .. ". Use /gw idle <0-60> (0 turns it off).")
    return
  end
  ns.Print(n == 0 and "idle cutoff off." or ("clock stops after " .. n .. " min without activity."))
end
commands.scale = function(rest)
  local ok, n = ns.SetSetting("scale", rest)
  if not ok then
    ns.Print("window scale is " .. ns.SettingText(ns.SettingDef("scale")) .. ". Use /gw scale <0.5-2>.")
    return
  end
  ns.Print("window scale set to " .. n .. ".")
end

-- /gw set: every setting by name, including the ones without their own command.
function ns.SettingLines()
  local out = {}
  for _, def in ipairs(ns.SETTING_DEFS) do
    local range
    if def.kind == "number" and def.percent then
      range = string.format(" (%d%%-%d%%, or %s-%s)", def.min * 100, def.max * 100, def.min, def.max)
    elseif def.kind == "number" then
      range = string.format(" (%s-%s)", def.min, def.max)
    elseif def.kind == "choice" then
      range = " (" .. table.concat(def.choices, " | ") .. ")"
    else
      range = " (on | off)"
    end
    -- What you'd type: on/off for switches, the raw value otherwise.
    local value = def.kind == "bool" and ns.SettingText(def) or tostring(ns.DB[def.key])
    out[#out + 1] = string.format("%s = %s%s - %s", def.key, value, range, def.label)
  end
  return out
end
commands.set = function(rest)
  local name, value = rest:match("^(%S+)%s*(.-)$")
  if not name then
    ns.Print("settings (/gw set <name> <value>, or /gw settings for the window):")
    for _, line in ipairs(ns.SettingLines()) do ns.Print(line) end
    return
  end
  local def = ns.SettingDef(name)
  if not def then
    ns.Print("no setting called '" .. name .. "'. /gw set lists them.")
    return
  end
  if value == "" then
    ns.Print(def.key .. " is " .. ns.SettingText(def) .. ". " .. def.tip)
    return
  end
  local ok, v = ns.SetSetting(def.key, value)
  if not ok then
    ns.Print(string.format("couldn't set %s: %s.", def.key, v))
    return
  end
  ns.Print(def.label .. ": " .. ns.SettingText(def, v) .. ".")
end
commands.settings = function() ns.ToggleSettings() end
commands.options, commands.config, commands.opt = commands.settings, commands.settings, commands.settings
commands.defaults = function(rest)
  if rest:lower() ~= "yes" then
    ns.Print("this puts every setting back to its default (position, history and added spells are kept). "
      .. "Type /gw defaults yes to confirm.")
    return
  end
  ns.ResetSettings()
  ns.Print("settings back to defaults.")
end
commands.help = ShowHelp
-- Commands and help added by optional modules (Persist.lua).
for name, fn in pairs(ns.extraCommands or {}) do commands[name] = fn end
for _, line in ipairs(ns.extraHelp or {}) do table.insert(HELP, #HELP - 2, line) end

-- For the settings window's buttons, so they share the commands' messages.
function ns.RunCommand(name, rest)
  local fn = commands[name]
  if fn then fn(rest or "") end
end

SLASH_VULCANGRINDWATCH1 = "/gw"
SLASH_VULCANGRINDWATCH2 = "/grindwatch"
-- The names from before the Vulcan rename keep working.
SLASH_VULCANGRINDWATCH3 = "/ft"
SLASH_VULCANGRINDWATCH4 = "/farmtracker"
SlashCmdList.VULCANGRINDWATCH = function(input)
  if not ns.S then return end
  -- Keep the original case of the rest (whisper names are case-sensitive on some realms).
  local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  local fn = commands[cmd]
  if fn then
    fn(rest or "")
  else
    ns.Print("unknown command '" .. cmd .. "'.")
    ShowHelp()
  end
end

-- Click handler for the addon compartment (the addon menu by the minimap):
-- left-click shows/hides the window, right-click opens settings.
-- (Older clients pass the mouse button as a string; 11.0+ pass a table with
-- .buttonName.)
function VulcanGrindWatch_OnAddonCompartmentClick(_, button)
  if not ns.S then return end
  if type(button) == "table" then button = button.buttonName end
  if button == "RightButton" then ns.OpenSettings() return end
  ns.SetShown(not ns.frame:IsShown())
end
function VulcanGrindWatch_OnAddonCompartmentEnter(_, owner)
  if not GameTooltip then return end
  local anchored = type(owner) == "table" and owner.IsObjectType
    and pcall(GameTooltip.SetOwner, GameTooltip, owner, "ANCHOR_LEFT")
  if not anchored then
    if not GameTooltip_SetDefaultAnchor then return end
    GameTooltip_SetDefaultAnchor(GameTooltip, UIParent)
  end
  GameTooltip:AddLine("GrindWatch")
  GameTooltip:AddLine("Left-click: show/hide the window", 1, 1, 1)
  GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
  GameTooltip:Show()
end
function VulcanGrindWatch_OnAddonCompartmentLeave()
  if GameTooltip then GameTooltip:Hide() end
end

-- Key bindings (Bindings.xml): Game Menu > Options > Key Bindings > AddOns.
BINDING_HEADER_VULCANGRINDWATCH = "Vulcan GrindWatch"
BINDING_NAME_VULCANGRINDWATCH_TOGGLE = "Show/hide window"
BINDING_NAME_VULCANGRINDWATCH_PAUSE = "Pause/resume"
function VulcanGrindWatch_ToggleWindow()
  if ns.S then ns.SetShown(not ns.frame:IsShown()) end
end
function VulcanGrindWatch_TogglePause()
  if ns.S then ns.SetPaused(not ns.S.paused) end
end

---------------------------------------------------------------------------
-- Login messages
---------------------------------------------------------------------------
ns.Listen("LOGIN", function()
  if not ns.DB.welcomed then
    ns.DB.welcomed = true
    ns.Print("loaded. Click the small gear on the window for settings, or type /gw help for commands.")
  end
  if ns.migrated then
    ns.Print("updated from v1: your previous session was saved to /gw history.")
    ns.migrated = nil
  end
  if ns.repairedSettings and #ns.repairedSettings > 0 then
    ns.Print("some saved settings were invalid and were repaired (out-of-range values pulled into range, "
      .. "the rest set to defaults): " .. table.concat(ns.repairedSettings, ", ") .. ".")
    ns.repairedSettings = nil
  end
  local S = ns.S
  -- Only after a real break (not every /reload).
  local away = time() - (ns.previousLastSeen or 0)
  if S.started and S.elapsed >= ns.MIN_ARCHIVE_SECONDS and away > 1800 then
    local when = (S.startedAt > 0 and date) and date("%m/%d %H:%M", S.startedAt) or "earlier"
    ns.Print(string.format("continuing session from %s (%s tracked%s). /gw reset starts a new one.",
      when, ns.Duration(S.elapsed), ns.TopZone() and (" in " .. ns.TopZone()) or ""))
  end
end)
