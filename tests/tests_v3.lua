-- Tests for GrindWatch v3 features.
package.path = assert(os.getenv("GW_TESTS"), "GW_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check

local function noErrors(c, name)
  local errs = c.errors()
  check(name .. ": no runtime errors", #errs == 0, errs[1])
end

-- Kill XP with a rested bonus: total XP gained and rested consumed.
local function restedKill(c, mob, base, bonus)
  c.fire("CHAT_MSG_COMBAT_XP_GAIN", string.format("%s dies, you gain %d experience.", mob, base + bonus))
  c.xp = c.xp + base + bonus
  c.rested = (c.rested or 0) - bonus
  if c.rested <= 0 then c.rested = nil end
  c.fire("PLAYER_XP_UPDATE", "player")
end

-- 1. Diagnostics log
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.xpKill("Boar", 50)
  check("debug off: nothing logged", #ns.DB.debugLog == 0)
  c.slash("debug on")
  c.fire("PLAYER_REGEN_DISABLED")
  c.xpKill("Boar", 50)
  c.cast(8613)
  c.corpse("Creature-0-1-2-3-100-DBG")
  c.gainMoney(120)
  c.fire("QUEST_TURNED_IN", 1, 0, 500)
  c.tick(1)
  c.item(2589, "Linen Cloth", 13); c.lootMsg(2589, "Linen Cloth", 2)
  c.fire("CHAT_MSG_COMBAT_XP_GAIN", "You gain 300 experience.")
  local all = table.concat(ns.DB.debugLog, "\n")
  check("logs looted items", all:find("loot: item 2589 %(Linen Cloth%) x2"), all)
  check("logs non-kill XP lines", all:find("xp: XP line, not a kill: You gain 300 experience%."))
  check("log lines have a wall clock", ns.DB.debugLog[1]:find("^%d%d:%d%d:%d%d %("), ns.DB.debugLog[1])
  check("logs kills", all:find("kill: XP kill: Boar"))
  check("logs casts with spell name and kind", all:find("cast: spell 8613 %(Skinning%) %-> gather"), all)
  check("logs loot window kind", all:find("loot: window %[Creature:.-%] kind=gather"), all)
  check("logs money", all:find("money: %+120 copper %(farm%)"))
  check("logs quests", all:find("quest: turned in"))
  check("logs clock transitions", all:find("clock: .* %-> running"))
  for _ = 1, ns.DEBUG_MAX + 20 do c.gainMoney(1) end
  check("log is capped", #ns.DB.debugLog == ns.DEBUG_MAX, #ns.DB.debugLog)
  local text = ns.ShowCopy("t", ns.ExportLines("debug"))
  check("export debug shows the log", text:find("GrindWatch diagnostics") and text:find("money:"))
  c.slash("debug echo")
  c.gainMoney(7)
  check("echo prints to chat", c.printedMatch("%[money%]"))
  c.slash("debug off")
  local n = #ns.DB.debugLog
  c.gainMoney(5)
  check("debug off stops logging", #ns.DB.debugLog == n)
  local saved = c.saved()
  local cR = H.boot({ saved = saved }); cR.login()
  check("log survives reload", #cR.ns.DB.debugLog == n, #cR.ns.DB.debugLog)
  c.slash("debug clear")
  check("debug clear empties", #ns.DB.debugLog == 0)
  noErrors(c, "debug")
end

-- 2. /gw check
do
  local c = H.boot({ auctionator = {} })
  c.login()
  c.slash("check")
  check("check: interface", c.printedMatch("Client interface: 16001"))
  check("check: known skinning name", c.printedMatch("Known gather spells: 8613=Skinning"))
  check("check: auctionator", c.printedMatch("Auctionator: yes"))
  noErrors(c, "check")
end

-- 3. Teaching a spell
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  check("unknown spell not gathering", ns.ClassifySpell(424242) == nil)
  c.slash("spell gather 424242")
  check("taught spell is gathering", ns.ClassifySpell(424242) == "gather")
  c.cast(424242); c.corpse("Creature-0-1-2-3-100-T1")
  check("taught spell: corpse isn't a kill", ns.Total({ "k" }) == 0)
  c.slash("spell list")
  check("spell list shows it", c.printedMatch("424242 %(nil%): gather") or c.printedMatch("424242 %(.-%): gather"))
  c.slash("spell remove 424242")
  check("removed spell no longer gathering", ns.ClassifySpell(424242) == nil)
  c.slash("spell bogus")
  check("bad spell command explained", c.printedMatch("use /gw spell gather"))
  c.slash("spell pickpocket 77")
  local saved = c.saved()
  local c2 = H.boot({ saved = saved }); c2.login()
  check("taught spells persist", c2.ns.ClassifySpell(77) == "pickpocket")
end

-- 4. Rested-aware time to level
do
  local c = H.boot()
  c.xp, c.xpMax, c.rested = 1000, 10000, 1600
  c.login()
  local ns = c.ns
  c.fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 10 do restedKill(c, "Murloc", 100, 100); c.tick(60) end
  -- 600s: x = 2000 XP -> 12000/hr, r = 1000 -> 6000/hr; rested left 600 -> 0.1h
  -- needed 7000; during rested 1200; then 5800 at 6000/hr -> 0.96667h; total 1.06667h
  local ttl, ends = ns.TimeToLevel()
  check("rested-aware ETA", ttl and math.abs(ttl - 3840) < 1, ttl)
  check("rested ends in 6 min", ends and math.abs(ends - 360) < 1, ends)
  check("window shows rested end", c.cellText():find("ends in 6m 00s"), c.cellText())
  c.slash("report")
  check("report shows rested end", c.printedMatch("rested runs out in 6m 00s"))
  -- resting in an inn (rested goes up) isn't consumption
  local r = ns.S.totals.r
  c.rested = 5000; c.fire("UPDATE_EXHAUSTION")
  check("rested increase ignored", ns.S.totals.r == r)
  noErrors(c, "rested")
end
do
  -- levels before rested runs out: plain ETA, no "ends in"
  local c = H.boot()
  c.xp, c.xpMax, c.rested = 1000, 4000, 50000
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 5 do restedKill(c, "Murloc", 100, 100); c.tick(60) end
  local ttl, ends = c.ns.TimeToLevel()
  -- x = 1000 in 300s = 12000/hr, needed 2000 -> 600s
  check("level before rested ends", ttl and math.abs(ttl - 600) < 1 and ends == nil, tostring(ttl) .. " " .. tostring(ends))
end
do
  -- all XP is rested bonus (impossible base) -> no ETA instead of nonsense
  local c = H.boot()
  c.xp, c.xpMax, c.rested = 1000, 100000, 500
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 4 do restedKill(c, "M", 0, 100); c.tick(60) end
  local ttl = c.ns.TimeToLevel()
  check("no base XP: no ETA", ttl == nil, ttl)
  -- secret rested value is unknown, not "zero" (no fake consumption)
  local c2 = H.boot({ secretAware = true })
  c2.rested = 3000
  c2.login()
  c2.fire("PLAYER_REGEN_DISABLED")
  c2.secret.rested = true; c2.fire("UPDATE_EXHAUSTION"); c2.secret.rested = false
  c2.fire("UPDATE_EXHAUSTION")
  check("secret rested read records nothing", c2.ns.S.totals.r == 0, c2.ns.S.totals.r)
end

-- 5. Level 60: loot-only kills name the mob
do
  local c = H.boot()
  c.level = 60; c.effectiveMax = true
  c.login()
  c.units.target = { guid = "Creature-0-1-2-3-100-L60", name = "Blackrock Warlock", dead = true }
  c.corpse("Creature-0-1-2-3-100-L60")
  check("loot-only kill names the mob", c.ns.S.mobs["Blackrock Warlock"] == 1)
  c.slash("report")
  check("top mobs at 60", c.printedMatch("Top mobs: Blackrock Warlock x1"))
end

-- 6. Reprice
do
  local prices = { [4306] = 100 }
  local c = H.boot({ auctionator = prices })
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150)
  c.lootMsg(4306, "Silk Cloth", 10)
  check("AH below vendor: vendor value", c.ns.S.totals.la == 1500)
  prices[4306] = 1000  -- Auctionator scanned: silk now 10s
  c.slash("reprice")
  check("reprice uses new AH price", c.ns.S.totals.la == 9500 and c.ns.S.items[4306].valueAH == 9500, c.ns.S.totals.la)
  local bucketSum = 0
  for _, b in pairs(c.ns.S.buckets) do bucketSum = bucketSum + (b.la or 0) end
  check("reprice scales buckets", math.abs(bucketSum - 9500) < 1e-6, bucketSum)
  local c2 = H.boot(); c2.login()
  c2.fire("PLAYER_REGEN_DISABLED")
  c2.item(2589, "Linen Cloth", 13, false); c2.lootMsg(2589, "Linen Cloth", 10)
  c2.tick(c2.ns.PENDING_MAX_TRIES + 1)   -- vendor price never loaded
  c2.cached[2589] = true
  c2.slash("reprice")
  check("reprice without Auctionator fixes vendor value", c2.ns.S.totals.l == 130 and c2.printedMatch("no Auctionator"),
    c2.ns.S.totals.l)
end

-- 7. Slowing-down alert and trend
do
  local c = H.boot()
  c.level = 60; c.effectiveMax = true
  c.login()
  local ns = c.ns
  c.fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 30 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  check("no alert while steady", not c.printedMatch("slowing down"))
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(2000); c.tick(60) end
  check("alert when the last 15m collapses", c.printedMatch("this spot is slowing down"))
  check("alert sound and screen message", #c.sounds == 1 and c.errorsFrame[1]:find("gold rate is dropping"))
  check("trend shown in status", c.cellText():find("Running%s+%-%d+%%"), c.cellText())
  local alerts = #c.sounds
  for _ = 1, 5 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(2000); c.tick(60) end
  check("alert cooldown", #c.sounds == alerts)
  c.slash("alert")
  check("alert toggle", ns.DB.alerts == false)
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(100); c.tick(60) end
  check("alerts off: silent", #c.sounds == alerts)
  noErrors(c, "alert")
end
do
  -- leveling: the alert follows XP, not gold
  local c = H.boot()
  c.xpMax = 10000000
  c.login()
  for _ = 1, 30 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("M", 1000); c.tick(60) end
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("M", 200); c.tick(60) end
  check("leveling alert is about XP", c.errorsFrame[1] and c.errorsFrame[1]:find("XP rate"), c.errorsFrame[1])
  -- no trend before the window fills
  local c2 = H.boot(); c2.level = 60; c2.effectiveMax = true; c2.login()
  for _ = 1, 10 do c2.fire("PLAYER_REGEN_DISABLED"); c2.gainMoney(10000); c2.tick(60) end
  check("no trend in the first 15 min (even with gains)", c2.ns.Trend() == nil and c2.ns.SessionRate(c2.ns.GoldFields()) > 0)
end

-- 8. Zone hint
do
  local c = H.boot()
  c.login()
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  c.zone = "Duskwood"
  for _ = 1, 9 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  check("no zone hint before 10 min", not c.printedMatch("as its own spot"))
  for _ = 1, 2 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  check("zone hint after 10 min", c.printedMatch("farmed Duskwood for 10%+ min, but this session is mostly Westfall"))
  local n = 0
  for _ = 1, 10 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  for _, p in ipairs(c.printed) do if p:find("as its own spot") then n = n + 1 end end
  check("zone hint only once", n == 1, n)
end

-- 9. Notes, history all/clear, spots, loot list, export
do
  local c = H.boot()
  c.level = 60; c.effectiveMax = true  -- gold ranking
  c.login()
  local ns = c.ns
  c.item(2589, "Linen Cloth", 13); c.item(4306, "Silk Cloth", 150)
  local function session(zone, minutes, goldPerMin, note)
    c.zone = zone
    if note then c.slash("note " .. note) end
    for _ = 1, minutes do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(goldPerMin * 10000); c.tick(60) end
    c.fire("PLAYER_REGEN_DISABLED")
    c.slash("reset")
  end
  session("Westfall", 10, 1, "murlocs, coast")
  session("Duskwood", 10, 3)
  session("Westfall", 30, 2)
  session("Stranglethorn", 2, 50)  -- too short to judge
  c.slash("history")
  check("history shows label", c.printedMatch('Westfall "murlocs, coast"'))
  c.printed = {}
  c.slash("spots")
  local first = c.printedMatch("^.-1%. ")
  check("spots ranks Duskwood first", first and first:find("Duskwood: 180g 0s gold/hr"), first)
  -- Westfall: 10 min at 1g + 30 min at 2g = 70g in 40 min (+ kept seconds) -> about 105g/hr
  check("spots time-weights a zone", c.printedMatch("Westfall: 10%dg .- gold/hr.-%(2 sessions"), c.printedMatch("Westfall"))
  check("spots skips too-short sessions", not c.printedMatch("Stranglethorn:"))
  check("spots at 60 ranked by gold", c.printedMatch("best spots by gold/hr"))
  -- loot list
  c.fire("PLAYER_REGEN_DISABLED")
  c.lootMsg(2589, "Linen Cloth", 20); c.lootMsg(4306, "Silk Cloth", 1)
  c.printed = {}
  c.slash("loot")
  check("loot list sorted by value", c.printed[1]:find("Linen Cloth x20") and c.printed[2]:find("Silk Cloth x1"), c.printed[1])
  -- export
  local text = ns.ShowCopy("t", ns.ExportLines("history"))
  local lines = {}
  for l in text:gmatch("[^\n]+") do lines[#lines + 1] = l end
  check("CSV header", lines[1]:find("^date,character,zone,label,minutes"))
  check("CSV has current + 4 sessions", #lines == 6, #lines)
  check("CSV quotes a label with a comma", text:find('"murlocs, coast"'))
  _G.VulcanGrindWatchCopyFrame.shown = false
  _G.VulcanGrindWatchCopyFrame.title:SetText("")
  c.slash("export")
  check("/gw export opens the copy window with the CSV",
    _G.VulcanGrindWatchCopyFrame.shown and _G.VulcanGrindWatchCopyFrame.title.text:find("history %(CSV%)"))
  local listed = false
  for _, n in ipairs(_G.UISpecialFrames or {}) do if n == "VulcanGrindWatchCopyFrame" then listed = true end end
  check("copy window closes with Esc", listed)
  -- history clear needs confirmation
  c.slash("history clear")
  check("clear asks first", #ns.DB.history == 4 and c.printedMatch("history clear yes"))
  c.slash("history clear yes")
  check("clear yes deletes", #ns.DB.history == 0)
  noErrors(c, "history tools")
end
do
  -- history shows 10 by default, all on request
  local c = H.boot()
  c.login()
  for _ = 1, 13 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(61); c.fire("PLAYER_REGEN_DISABLED"); c.slash("reset") end
  c.printed = {}
  c.slash("history")
  local n = 0
  for _, p in ipairs(c.printed) do if p:find("^|cffe8792bGrindWatch|r: %d+%. ") then n = n + 1 end end
  check("history shows 10", n == 10, n)
  check("history mentions the rest", c.printedMatch("3 more"))
  c.printed = {}
  c.slash("history all")
  n = 0
  for _, p in ipairs(c.printed) do if p:find("^|cffe8792bGrindWatch|r: %d+%. ") then n = n + 1 end end
  check("history all shows 13", n == 13, n)
end

do
  -- while leveling, spots rank by XP/hr
  local c = H.boot()
  c.xpMax = 100000000
  c.login()
  local function session(zone, xpPerMin, goldPerMin)
    c.zone = zone
    for _ = 1, 10 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("M", xpPerMin); c.gainMoney(goldPerMin * 10000); c.tick(60) end
    c.fire("PLAYER_REGEN_DISABLED"); c.slash("reset")
  end
  session("Westfall", 1000, 1)     -- XP spot
  session("Redridge", 200, 9)      -- gold spot
  c.printed = {}
  c.slash("spots")
  check("leveling: spots by XP/hr", c.printedMatch("best spots by XP/hr"))
  local first = c.printedMatch("^.-1%. ")
  check("leveling: XP spot first", first and first:find("Westfall"), first)
  -- compact mode shows the time
  c.slash("compact")
  check("compact shows time", c.cellText():find("Time %d+m %d+s"), c.cellText())
end

-- 10. Sync v3
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.inGroup = true
  for _ = 1, 10 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  c.tick(30)
  local last = c.addonSent[#c.addonSent].msg
  check("payload v4 has recent rates and the window", last:match("^4|") and select(2, last:gsub("|", "")) == 10 and last:match("|15$"), last)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "3|7200|10|0|200000|160000|500000|120000|90000|200000", "PARTY", "Mirel")
  c.tick(1)
  local text = c.cellText()
  -- Mirel recent vendor: 12g + 9g = 21g/hr; mine recent 60g/hr -> duo 81g/hr
  check("partner 15m shown", text:find("Mirel | 36g 0s | 18g 0s | 21g 0s"), text)
  local duoRecent = ns.RecentRate(ns.GoldFields()) + 210000
  check("duo 15m = my 15m + Mirel's", text:find("Duo gold | 46g 0s | %d+g %d+s | " .. ns.Money(duoRecent):gsub("%%", "")), text)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "3|7200|10|0|200000|160000|500000|-1|-1|-1", "PARTY", "Mirel")
  c.tick(1)
  check("partner without 15m yet: --", c.cellText():find("Mirel | 36g 0s | 18g 0s | %-%-"), c.cellText())
  -- version handling
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|7200|10|0|200000|160000|500000", "PARTY", "Bob")
  check("v2 partner accepted", ns.partners.Bob ~= nil)
  check("v2 partner told they can't see us", c.printedMatch("Bob runs an older GrindWatch"))
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "9|1|1|1|1|1|1|1|1|1|1", "PARTY", "Zed")
  check("newer partner ignored with a notice", ns.partners.Zed == nil and c.printedMatch("Zed runs a newer GrindWatch"))
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "9|1|1|1|1|1|1|1|1|1|1", "PARTY", "Zed")
  local n = 0
  for _, p in ipairs(c.printed) do if p:find("Zed runs") then n = n + 1 end end
  check("version notice once", n == 1, n)
  for _, bad in ipairs({ "3|1a|1|1|1|1|1|1|1|1", "3||7200|1|1|1|1|1|1|1|1", "3|1|1|1|1|1|1|1|1", "3|-5|1|1|1|1|1|1|1|1", "x|1" }) do
    c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", bad, "PARTY", "Eve")
  end
  check("malformed messages ignored", ns.partners.Eve == nil)
  noErrors(c, "sync v3")
end

-- 11. Compact mode, redraw caching, keybinds, files
do
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(30000); c.tick(200)
  c.slash("compact")
  local text = c.cellText()
  check("compact: no totals column", not text:find("Total") and text:find("Last 15m") and text:find("Gold"), text)
  check("compact: no coin/loot rows", not text:find("Coin") and not text:find("To level"), text)
  c.slash("compact")
  check("full again", c.cellText():find("Total"))
  c.slash("pause")
  local calls = c.ui.sizeCalls
  c.tick(5)
  check("no relayout when nothing changes", c.ui.sizeCalls == calls, c.ui.sizeCalls - calls)
  c.slash("resume"); c.tick(1)
  check("relayout when something changes", c.ui.sizeCalls > calls)
  VulcanGrindWatch_TogglePause()
  check("keybind pause", c.ns.S.paused)
  VulcanGrindWatch_ToggleWindow()
  check("keybind toggle", not c.ui.shown)
  check("binding names defined", BINDING_HEADER_VULCANGRINDWATCH == "Vulcan GrindWatch" and BINDING_NAME_VULCANGRINDWATCH_PAUSE)
  local xml = io.open(assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh") .. "Bindings.xml"):read("*a")
  check("Bindings.xml calls the toggle", xml:find("VulcanGrindWatch_ToggleWindow%(%)") and xml:find("VulcanGrindWatch_TogglePause%(%)"))
  -- every .lua in the folder is in the TOC (a missing entry silently never loads)
  local toc = io.open(assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh") .. "VulcanGrindWatch.toc"):read("*a")
  local p = io.popen('ls "' .. assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh") .. '"*.lua')
  for f in p:lines() do
    local name = f:match("([^/]+)$")
    check("TOC lists " .. name, toc:find("\n" .. name:gsub("%.", "%%.") .. "\n", 1) ~= nil)
  end
  p:close()
  noErrors(c, "ui v3")
end

-- 12. Help covers every command
do
  local c = H.boot()
  c.login()
  c.slash("help")
  local help = table.concat(c.printed, "\n")
  for _, cmd in ipairs({ "pause", "reset", "note", "report", "loot", "history", "spots", "export", "price",
      "reprice", "idle", "afk", "alert", "sync", "compact", "lock", "scale", "check", "debug", "spell" }) do
    check("help mentions /gw " .. cmd, help:find("/gw " .. cmd) or help:find(";  /gw " .. cmd), cmd)
  end
end

-- 13. Audit 3 (v3) regressions
do
  -- rested ran out on the last kill: ETA uses the base rate (12000 - 6000 = 6000/hr)
  local c = H.boot()
  c.xp, c.xpMax, c.rested = 1000, 100000, 1000
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 10 do restedKill(c, "Murloc", 100, 100); c.tick(60) end
  check("rested at 0", c.rested == nil)
  local ttl = c.ns.TimeToLevel()
  -- needed 100000 - 3000 = 97000 at 6000/hr = 16.1667h
  check("ETA after rested ends uses base rate", ttl and math.abs(ttl - 97000 / 6000 * 3600) < 1, ttl)
end
do
  -- export with an old history entry that has no xp
  local db = { history = { { when = 1700000000, zone = "Westfall", elapsed = 600, kills = 10, coin = 5000, loot = 100 } } }
  local c = H.boot({ saved = { db = db } })
  c.login()
  c.slash("export")
  noErrors(c, "export old entry")
  local text = c.ns.ShowCopy("t", c.ns.ExportLines("history"))
  check("old entry exported with xp 0", text:find("Westfall,,10%.0,10,0,5000,100,100"), text)
  c.slash("history"); c.slash("spots")
  noErrors(c, "history/spots old entry")
  -- CSV quote doubling
  c.ns.DB.history[1].label = 'say "hi", ok'
  text = c.ns.ShowCopy("t", c.ns.ExportLines("history"))
  check("CSV doubles quotes", text:find('"say ""hi"", ok"', 1, true), text)
end
do
  -- reprice when the old AH total was 0 updates the rolling window too
  local prices = {}
  local c = H.boot({ auctionator = prices })
  c.level = 60; c.effectiveMax = true
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)       -- price never loads: count kept, value 0
  for _ = 1, 6 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  prices[4306] = 1000
  c.ns.S.items[4306].value = 0
  c.ns.DB.priceSource = "auction"
  -- give the given-up entry an AH value via reprice
  local _, newTotal = c.ns.Reprice()
  check("reprice from 0 books a value", newTotal == 19000, newTotal)
  local recent = c.ns.RecentRate({ "la" })
  local session = c.ns.SessionRate({ "la" })
  check("rolling window agrees with total after reprice", recent and math.abs(recent - session) < 1,
    tostring(recent) .. " vs " .. tostring(session))
end
do
  local c = H.boot()
  c.login()
  local point = { c.ns.DB.point[1], c.ns.DB.point[2], c.ns.DB.point[3], c.ns.DB.point[4] }
  c.slash("scale nan")
  check("scale nan rejected", c.ns.DB.scale == 1 and c.ns.DB.point[3] == point[3])
  c.slash("idle nan")
  check("idle nan rejected", c.ns.DB.idleMinutes == 5)
  c.slash("spell remove 8613")
  check("built-in spell can't be removed (and says so)", c.printedMatch("built in as gather") and c.ns.ClassifySpell(8613) == "gather")
  c.slash("spell remove 5555")
  check("removing an unknown spell says so", c.printedMatch("5555 wasn't in your list"))
  c.slash("compact")
  check("compact: time in the label column", c.cellText():find("Time %d+m %d+s | /hr | Last 15m"), c.cellText())
end
do
  -- zone hint doesn't repeat after a reload
  local c = H.boot()
  c.login()
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  c.zone = "Duskwood"
  for _ = 1, 11 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  check("hint shown", c.printedMatch("as its own spot"))
  local c2 = H.boot({ saved = c.saved() })
  c2.zone = "Duskwood"
  c2.login()
  for _ = 1, 5 do c2.fire("PLAYER_REGEN_DISABLED"); c2.tick(60) end
  check("hint not repeated after reload", not c2.printedMatch("as its own spot"))
end
do
  -- alert needs 20 min, and only fires while running
  local c = H.boot()
  c.level = 60; c.effectiveMax = true
  c.login()
  for _ = 1, 3 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(100000); c.tick(60) end
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(100); c.tick(60) end
  -- 18 min: trend is terrible but too early
  check("no alert before 20 min", #c.sounds == 0 and c.ns.Trend() and c.ns.Trend() < -0.4)
  c.slash("pause")
  c.slash("set alertMinMinutes 10")  -- the session (18 min) is now long enough
  c.tick(20)
  check("no alert while paused", #c.sounds == 0)
  c.slash("resume"); c.fire("PLAYER_REGEN_DISABLED"); c.tick(20)
  check("alert once running again", #c.sounds == 1)
end
do
  -- plain() checks secrecy before anything else touches the value
  local src = io.open(assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh") .. "Util.lua"):read("*a")
  local body = src:match("function ns%.plain%(v%)%s*\n(.-)\nend")
  check("plain(): secret check is the first statement", body and body:match("^%s*if issecret%(v%) then"), body)
  local core = io.open(assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh") .. "Core.lua"):read("*a")
  local rested = core:match("local function ReadRested%(%)(.-)\nend")
  check("ReadRested: secret check before nil compare",
    rested and rested:find("IsSecret%(raw%)") < rested:find("raw == nil"), rested)
end

-- 14. Audit 4 (v3) regressions
do
  -- reprice-from-zero late in a session doesn't fake a 15m spike
  local prices = {}
  local c = H.boot({ auctionator = prices })
  c.level = 60; c.effectiveMax = true
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  for _ = 1, 60 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(1000); c.tick(60) end
  prices[4306] = 1000
  c.ns.DB.priceSource = "auction"
  c.ns.Reprice()
  local recent = c.ns.RecentRate({ "la" })
  check("late reprice: loot from an hour ago stays out of the 15m window", recent == 0, recent)
  check("late reprice: total updated", c.ns.S.totals.la == 19000, c.ns.S.totals.la)
  c.tick(1)
  check("late reprice: no fake trend", not c.cellText():find("Running%s+%+%d%d%%"), c.cellText())
end
do
  -- alert cooldown survives a reload
  local c = H.boot()
  c.level = 60; c.effectiveMax = true
  c.login()
  for _ = 1, 30 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(1000); c.tick(60) end
  check("first alert", #c.sounds == 1)
  local c2 = H.boot({ saved = c.saved(), gap = 60 })
  c2.level = 60; c2.effectiveMax = true
  c2.login()
  for _ = 1, 3 do c2.fire("PLAYER_REGEN_DISABLED"); c2.gainMoney(500); c2.tick(60) end
  check("no second alert inside the cooldown after a reload", #c2.sounds == 0)
end
do
  -- old history entries missing kills/coin/loot
  local db = { history = { { when = 1700000000, zone = "Westfall", elapsed = 600 } } }
  local c = H.boot({ saved = { db = db } })
  c.login()
  c.slash("history"); c.slash("spots"); c.slash("export")
  noErrors(c, "entry with no numbers")
  check("history line for empty entry", c.printedMatch("Westfall %(10m 00s%): 0c gold/hr, 0 kills/hr"))
end
do
  -- no zone hint while paused
  local c = H.boot()
  c.login()
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  c.zone = "Duskwood"
  for _ = 1, 11 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  c.slash("pause")
  c.ns.S.hintedZones = {}
  c.printed = {}
  c.tick(30)
  check("no zone hint while paused", not c.printedMatch("as its own spot"))
  c.slash("resume"); c.fire("PLAYER_REGEN_DISABLED"); c.tick(20)
  check("zone hint once running", c.printedMatch("as its own spot"))
end

do
  -- reprice when the loot sits exactly on the window's first bucket
  local prices = {}
  local c = H.boot({ auctionator = prices })
  c.level = 60; c.effectiveMax = true
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  local looted = false
  for _ = 1, 1800 do
    c.tick(1)
    if c.ns.Elapsed() % 60 == 0 then c.fire("PLAYER_REGEN_DISABLED") end
    if not looted and math.abs(c.ns.Elapsed() - 900) < 1e-9 then
      c.lootMsg(4306, "Silk Cloth", 20)  -- bucket 15
      looted = true
    end
  end
  check("boundary: elapsed exactly 1800", math.abs(c.ns.Elapsed() - 1800) < 1e-9, c.ns.Elapsed())
  prices[4306] = 1000
  c.ns.DB.priceSource = "auction"
  c.ns.Reprice()
  -- window starts at bucket ceil(900/60) = 15, covering 900s: 19000 per 900s
  local recent = c.ns.RecentRate({ "la" })
  check("boundary reprice: loot in the window's first bucket counts", math.abs(recent - 76000) < 1e-6, recent)
end

-- 15. Audit 6 (v3) regressions
do
  -- reprice with a mix of priced and never-priced items: no fake 15m spike
  local prices = {}
  local c = H.boot({ auctionator = prices })
  c.level = 60; c.effectiveMax = true
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  for _ = 1, 58 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  c.item(2589, "Linen Cloth", 13)
  c.lootMsg(2589, "Linen Cloth", 1)
  c.tick(1)
  prices[4306] = 1000
  c.cached[4306] = true  -- the item's data finally loads
  c.ns.DB.priceSource = "auction"
  c.ns.Reprice()
  check("mixed reprice total", c.ns.S.totals.la == 19013, c.ns.S.totals.la)
  -- silk was looted an hour ago (outside the window); only the linen is recent
  local elapsed = c.ns.Elapsed()
  local startIdx = math.ceil((elapsed - c.ns.WINDOW) / c.ns.BUCKET)
  local covered = elapsed - startIdx * c.ns.BUCKET
  local expected = 13 / covered * 3600
  local recent = c.ns.RecentRate({ "la" })
  check("mixed reprice: each item stays in the minute it was looted", math.abs(recent - expected) < 1e-6,
    recent .. " vs " .. expected)
  check("mixed reprice also fixes vendor value", c.ns.S.totals.l == 20 * 150 + 13 and c.ns.S.items[4306].value == 3000,
    c.ns.S.totals.l)
end
do
  -- XP kill, reset, then loot that corpse: still one kill in total
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.xpKill("Boar", 100); c.tick(70)
  c.slash("reset")
  c.corpse("Creature-0-1-2-3-100-RB")
  check("kill from before reset not counted again", c.ns.Total({ "k" }) == 0 and c.ns.DB.history[1].kills == 1)
end
do
  -- paused corpse is remembered
  local c = H.boot()
  c.login()
  c.slash("pause")
  c.corpse("Creature-0-1-2-3-100-PZ")
  c.slash("resume")
  c.tick(2)
  c.corpse("Creature-0-1-2-3-100-PZ")
  check("corpse looted while paused isn't a kill after resume", c.ns.Total({ "k" }) == 0)
end
do
  -- skinning your own kill uses up its XP kill
  local c = H.boot()
  c.login()
  c.killTargeted("Creature-0-1-2-3-100-PS", "Plainstrider")  -- killed while targeted: pinned
  c.tick(3)
  c.cast(8613); c.corpse("Creature-0-1-2-3-100-PS")
  c.units.target = nil
  c.tick(3)
  c.corpse("Creature-0-1-2-3-100-GREY")  -- grey mob, not targeted
  check("skinned own kill + grey corpse = 2 kills", c.ns.Total({ "k" }) == 2, c.ns.Total({ "k" }))
  check("skinning used up the pinned XP kill", #c.ns.S.unmatched == 0, #c.ns.S.unmatched)
end

-- 16. Audit 7 (v3) regressions
do
  -- skinning a stranger's same-name mob doesn't use up your kill
  local c = H.boot()
  c.login()
  c.killTargeted("Creature-0-1-2-3-100-BOARA", "Boar")  -- your Boar A, pinned
  c.tick(3)
  c.units.target = { guid = "Creature-0-1-2-3-100-BOARB", name = "Boar", dead = true }
  c.cast(8613); c.corpse("Creature-0-1-2-3-100-BOARB")   -- a stranger's Boar B
  c.tick(3)
  c.units.target = { guid = "Creature-0-1-2-3-100-BOARA", name = "Boar", dead = true }
  c.corpse("Creature-0-1-2-3-100-BOARA")
  check("stranger's skin + your boar = 1 kill", c.ns.Total({ "k" }) == 1, c.ns.Total({ "k" }))
end
do
  -- same, but your kill wasn't pinned (nothing targeted when it died)
  local c = H.boot()
  c.login()
  c.xpKill("Boar", 100)  -- unpinned
  c.tick(3)
  c.units.target = { guid = "Creature-0-1-2-3-100-STRB", name = "Boar", dead = true }
  c.cast(8613); c.corpse("Creature-0-1-2-3-100-STRB")   -- stranger's boar, named the same
  c.tick(3)
  c.units.target = nil
  c.corpse("Creature-0-1-2-3-100-MYBOAR")               -- your boar, untargeted
  check("unpinned kill survives a same-name stranger skin", c.ns.Total({ "k" }) == 1, c.ns.Total({ "k" }))
end
do
  -- skinning never uses up the oldest XP kill
  local c = H.boot()
  c.login()
  c.xpKill("Murloc", 100)          -- not pinned (nothing targeted)
  c.tick(3)
  c.cast(8613); c.corpse("Creature-0-1-2-3-100-UNT")  -- untargeted skin
  c.tick(3)
  c.units.target = { guid = "Creature-0-1-2-3-100-MUR", name = "Murloc", dead = true }
  c.corpse("Creature-0-1-2-3-100-MUR")
  check("skin doesn't eat the oldest kill", c.ns.Total({ "k" }) == 1 and c.ns.S.lootOnlyKills == 0,
    c.ns.Total({ "k" }) .. "/" .. c.ns.S.lootOnlyKills)
end
do
  -- looting your kill while paused uses up its XP kill
  local c = H.boot()
  c.login()
  c.xpKill("Wolf", 100)
  c.slash("pause")
  c.units.target = { guid = "Creature-0-1-2-3-100-WOLF", name = "Wolf", dead = true }
  c.corpse("Creature-0-1-2-3-100-WOLF")
  c.slash("resume")
  c.units.target = nil
  c.tick(3)
  c.corpse("Creature-0-1-2-3-100-GREY2")
  check("paused loot consumed its kill: grey counts", c.ns.Total({ "k" }) == 2, c.ns.Total({ "k" }))
end
do
  -- a kill pinned to one corpse is never taken by a different corpse
  local c = H.boot()
  c.login()
  c.killTargeted("Creature-0-1-2-3-100-P1", "Boar")
  c.units.target = nil
  c.tick(2)
  c.corpse("Creature-0-1-2-3-100-OTHER")  -- untargeted, different corpse
  check("pinned kill not matched to another corpse", c.ns.S.lootOnlyKills == 1 and #c.ns.S.unmatched == 1)
end
do
  -- reviewer's case: silk's AH price rises, linen unchanged; 15m = linen only
  local prices = {}
  local c = H.boot({ auctionator = prices })
  c.level = 60; c.effectiveMax = true
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150); c.item(2589, "Linen Cloth", 13)
  c.lootMsg(4306, "Silk Cloth", 20)
  for _ = 1, 60 do c.fire("PLAYER_REGEN_DISABLED"); c.lootMsg(2589, "Linen Cloth", 15); c.tick(60) end
  local before = c.ns.RecentRate({ "la" })
  prices[4306] = 1000
  c.ns.DB.priceSource = "auction"
  c.ns.Reprice()
  check("old silk repriced, recent rate untouched", math.abs(c.ns.RecentRate({ "la" }) - before) < 1e-6,
    c.ns.RecentRate({ "la" }) .. " vs " .. before)
end

-- 17. Audit 8 (v3) regressions
do
  -- duo: Boar 1 looted and still targeted when Mirel kills Boar 2
  local c = H.boot()
  c.login()
  c.killTargeted("Creature-0-1-2-3-100-B1", "Boar")
  c.corpse("Creature-0-1-2-3-100-B1")
  c.tick(3)
  c.xpKill("Boar", 100)                     -- Mirel's kill; Boar 1 still targeted
  check("not pinned to an already-looted corpse", c.ns.S.unmatched[1] and c.ns.S.unmatched[1].guid == nil)
  c.units.target = nil
  c.corpse("Creature-0-1-2-3-100-B2")
  check("2 boars = 2 kills", c.ns.Total({ "k" }) == 2, c.ns.Total({ "k" }))
  -- two boars die while one corpse is targeted
  local c2 = H.boot()
  c2.login()
  c2.killTargeted("Creature-0-1-2-3-100-X1", "Boar"); c2.xpKill("Boar", 100)
  check("second kill not pinned to the same corpse", c2.ns.S.unmatched[2].guid == nil)
  c2.corpse("Creature-0-1-2-3-100-X1"); c2.units.target = nil; c2.tick(2)
  c2.corpse("Creature-0-1-2-3-100-X2")
  check("2 kills, 2 corpses = 2", c2.ns.Total({ "k" }) == 2, c2.ns.Total({ "k" }))
end
do
  -- a late-loading item is booked in the minute it was looted (no double count)
  local c = H.boot()
  c.login()
  for _ = 1, 10 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  c.tick(55); c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)          -- second 55 of minute 10
  local lootBucket = math.floor(c.ns.Elapsed() / 60)
  c.tick(10)                                  -- now in minute 11
  c.cached[4306] = true
  c.fire("ITEM_DATA_LOAD_RESULT", 4306, true)
  check("late item detail in its loot minute", c.ns.S.buckets[lootBucket].q and c.ns.S.buckets[lootBucket].q[4306] == 20
    and c.ns.S.buckets[lootBucket].va[4306] == 3000)
  check("late item booked in its loot minute", c.ns.S.buckets[lootBucket].la == 3000
    and not (c.ns.S.buckets[lootBucket + 1] and c.ns.S.buckets[lootBucket + 1].la), lootBucket)
  local before = c.ns.RecentRate({ "la" })
  c.ns.Reprice()
  local sum = 0
  for _, b in pairs(c.ns.S.buckets) do sum = sum + (b.la or 0) end
  check("reprice keeps buckets equal to the total", sum == c.ns.S.totals.la and sum == 3000, sum)
  check("reprice with same prices doesn't change the 15m rate", math.abs(c.ns.RecentRate({ "la" }) - before) < 1e-6)
end
do
  -- old-build items (no unit price) with a cold item cache keep their value
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(2589, "Linen Cloth", 13)
  c.lootMsg(2589, "Linen Cloth", 100)
  c.ns.S.items[2589].unit = nil        -- as saved by the previous build
  c.cached[2589] = false               -- cache cold after login
  c.slash("reprice")
  check("unknown unit price keeps the known value", c.ns.S.totals.l == 1300 and c.ns.S.items[2589].value == 1300,
    c.ns.S.totals.l)
  check("and asks the client to load the item", c.loadRequests[#c.loadRequests] == 2589)
end

-- 18. Audit 9 (v3) regressions
do
  -- reprice without an AH price now keeps the AH value already earned
  local prices = { [4306] = 1000 }
  local c = H.boot({ auctionator = prices })
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 20)
  check("AH value earned", c.ns.S.totals.la == 19000)
  prices[4306] = nil              -- Auctionator lost its data
  c.ns.Reprice()
  check("no AH price now: value kept", c.ns.S.totals.la == 19000, c.ns.S.totals.la)
  _G.Auctionator = nil            -- or isn't loaded at all
  c.slash("reprice")
  check("no Auctionator: AH value kept", c.ns.S.totals.la == 19000, c.ns.S.totals.la)
  prices[4306] = 2000; _G.Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(_, id) return prices[id] end } } }
  c.ns.Reprice()
  check("new AH price replaces it", c.ns.S.totals.la == 38000, c.ns.S.totals.la)
  prices[4306] = 500
  c.ns.Reprice()
  check("a lower AH price replaces it too", c.ns.S.totals.la == 9500, c.ns.S.totals.la)
end
do
  -- a stranger's corpse targeted after it died can't claim your kill
  local c = H.boot()
  c.login()
  c.units.target = { guid = "Creature-0-1-2-3-100-STR", name = "Boar", dead = true }  -- already dead
  c.fire("PLAYER_TARGET_CHANGED")
  c.xpKill("Boar", 100)                                -- your pet kills another boar
  check("not pinned to a corpse never seen alive", c.ns.S.unmatched[1].guid == nil)
  c.units.target = nil
  c.tick(2)
  c.corpse("Creature-0-1-2-3-100-YOURS")
  check("1 boar = 1 kill", c.ns.Total({ "k" }) == 1, c.ns.Total({ "k" }))
end
do
  -- a target alive for a while (no target-change event) is noticed by the clock
  local c = H.boot()
  c.login()
  c.units.target = { guid = "Creature-0-1-2-3-100-LONG", name = "Ogre", dead = false }
  c.tick(2)
  c.units.target.dead = true
  c.xpKill("Ogre", 300)
  check("pinned via the per-second check", c.ns.S.unmatched[1].guid == "Creature-0-1-2-3-100-LONG")
end

do
  -- a stranger's boar you moused over alive a minute ago, now a corpse you target
  local c = H.boot()
  c.login()
  c.units.mouseover = { guid = "Creature-0-1-2-3-100-STR2", name = "Boar", dead = false }
  c.fire("UPDATE_MOUSEOVER_UNIT")
  c.units.mouseover = nil
  c.tick(3)  -- just past the 2s "alive moments ago" limit
  c.units.target = { guid = "Creature-0-1-2-3-100-STR2", name = "Boar", dead = true }
  c.fire("PLAYER_TARGET_CHANGED")
  c.xpKill("Boar", 100)    -- your pet's kill
  check("not pinned to a corpse seen alive long ago", c.ns.S.unmatched[1].guid == nil)
end

do
  -- the per-second alive check can be up to ~1s old when the XP line lands
  local c = H.boot()
  c.login()
  c.units.target = { guid = "Creature-0-1-2-3-100-LAG", name = "Boar", dead = false }
  c.tick(1)                       -- last alive check
  c.now = c.now + 0.9             -- the mob dies just before the next check
  c.units.target.dead = true
  c.xpKill("Boar", 100)
  check("kill still pinned when the alive check is 0.9s old", c.ns.S.unmatched[1].guid == "Creature-0-1-2-3-100-LAG")
end

do
  -- AoE pull: Boar 1 pinned and autolooted, Mirel's Boar 2 dies 0.5s later with
  -- Boar 1 still targeted (inside the 2s window): only the "already looted" guard
  -- stops it pinning to Boar 1's corpse.
  local c = H.boot()
  c.login()
  c.killTargeted("Creature-0-1-2-3-100-AOE1", "Boar")
  c.now = c.now + 0.5
  c.corpse("Creature-0-1-2-3-100-AOE1")
  c.now = c.now + 0.5
  c.xpKill("Boar", 100)          -- Mirel's Boar 2; target is still Boar 1's corpse
  check("not pinned to a corpse looted moments ago", c.ns.S.unmatched[1] and c.ns.S.unmatched[1].guid == nil)
  c.units.target = nil
  c.now = c.now + 1
  c.corpse("Creature-0-1-2-3-100-AOE2")
  check("AoE: 2 boars = 2 kills", c.ns.Total({ "k" }) == 2, c.ns.Total({ "k" }))
end

do
  -- notes are cut by whole characters, never mid-character
  local c = H.boot()
  c.login()
  c.slash("note x" .. string.rep("\195\169", 40))   -- x + 40 x "é" (2 bytes each)
  local note = c.ns.S.note
  check("note cut at a character boundary", #note == 59 and note:sub(-2) == "\195\169", #note)
  check("short note unchanged", c.ns.Truncate("murlocs by the coast", 60) == "murlocs by the coast")
  check("ASCII cut at 60", #c.ns.Truncate(string.rep("a", 100), 60) == 60)
end

os.exit(H.summary() and 0 or 1)
