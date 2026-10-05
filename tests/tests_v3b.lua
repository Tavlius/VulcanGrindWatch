-- GrindWatch: secret-value sweep, source scan, and behaviors found untested by
-- mutation testing (audit 15 of v3).
package.path = assert(os.getenv("GW_TESTS"), "GW_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check
local ADDON_DIR = assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh")
local X = H.SECRET

local function noErrors(c, name)
  local errs = c.errors()
  check(name .. ": no runtime errors", #errs == 0, errs[1])
end

---------------------------------------------------------------------------
-- 1. Secret sweep: one secret source at a time through a full farming session.
--    A missing plain() guard shows up as a reported runtime error.
---------------------------------------------------------------------------
local SOURCES = { "afk", "effmax", "xpdisabled", "level", "maxlevel", "xpMax", "xp", "rested", "guid", "dead",
  "unitname", "spellname", "itemname", "sellprice", "money", "numloot", "lootsrc", "deadorghost", "combat", "zone",
  "playername", "a_unit", "a_spell", "a_lootmsg", "a_xpmsg", "a_quest", "a_itemload", "a_flags", "a_pim", "a_addon" }
for _, src in ipairs(SOURCES) do
  local on = false
  local function S(key, v) if on and key == src then return X end return v end
  local c = H.boot({ secretAware = true })
  -- what the secret pretends to be, so type() checks can't filter it
  local NUMERIC = { level = 1, maxlevel = 1, xpMax = 1, xp = 1, rested = 1, sellprice = 1, money = 1, numloot = 1,
    a_spell = 1, a_quest = 1, a_itemload = 1, a_pim = 1 }
  local BOOLEAN = { afk = 1, effmax = 1, xpdisabled = 1, dead = 1, deadorghost = 1, combat = 1 }
  c.secretType = NUMERIC[src] and "number" or BOOLEAN[src] and "boolean" or "string"
  local wrapped = {}
  for name, key in pairs({ UnitIsAFK = "afk", IsPlayerAtEffectiveMaxLevel = "effmax", IsXPUserDisabled = "xpdisabled",
      UnitLevel = "level", GetMaxPlayerLevel = "maxlevel", UnitXPMax = "xpMax", UnitXP = "xp", GetXPExhaustion = "rested",
      UnitGUID = "guid", UnitIsDead = "dead", GetMoney = "money", GetNumLootItems = "numloot",
      UnitIsDeadOrGhost = "deadorghost", UnitAffectingCombat = "combat", GetRealZoneText = "zone" }) do
    local f = _G[name]
    wrapped[name] = f
    _G[name] = function(...)
      local r = { f(...) }
      if on and key == src then return X, X end
      return unpack(r)
    end
  end
  local unitName = _G.UnitName
  _G.UnitName = function(u)
    if on and ((u ~= "player" and src == "unitname") or (u == "player" and src == "playername")) then return X end
    return unitName(u)
  end
  local lootSource = _G.GetLootSourceInfo
  _G.GetLootSourceInfo = function(slot) if on and src == "lootsrc" then return X, X end return lootSource(slot) end
  local spellName = _G.C_Spell.GetSpellName
  _G.C_Spell.GetSpellName = function(id) return S("spellname", spellName(id)) end
  local itemInfo = _G.C_Item.GetItemInfo
  _G.C_Item.GetItemInfo = function(id)
    local r = { itemInfo(id) }
    if r[1] == nil then return nil end
    r[1] = S("itemname", r[1])
    r[11] = S("sellprice", r[11])
    return unpack(r, 1, 11)
  end
  c.ns.GetItemInfo = _G.C_Item.GetItemInfo
  c.login()
  c.slash("debug on")  -- the diagnostics paths read these values too
  on = true
  c.rested = 3000
  c.fire("PLAYER_REGEN_DISABLED")
  c.fire("PLAYER_FLAGS_CHANGED", S("a_flags", "player"))
  c.item(2589, "Linen Cloth", 13)
  for i = 1, 3 do
    local g = "Creature-0-1-2-3-100-K" .. i
    c.units.target = { guid = g, name = "Boar", dead = false }
    c.fire("PLAYER_TARGET_CHANGED"); c.fire("UPDATE_MOUSEOVER_UNIT")
    c.units.target.dead = true
    c.fire("CHAT_MSG_COMBAT_XP_GAIN", S("a_xpmsg", "Boar dies, you gain 200 experience. (+100 exp Rested bonus)"))
    c.xp = c.xp + 200; c.rested = c.rested - 100
    c.fire("PLAYER_XP_UPDATE", "player"); c.fire("UPDATE_EXHAUSTION")
    c.loot = { { g, 1 } }; c.fire("LOOT_READY"); c.fire("LOOT_OPENED")
    c.fire("CHAT_MSG_LOOT", S("a_lootmsg", "You receive loot: |cffffffff|Hitem:2589::::::::20:::::|h[Linen Cloth]|h|rx2."))
    c.gainMoney(150)
    c.fire("UNIT_SPELLCAST_SUCCEEDED", S("a_unit", "player"), "Cast-1", S("a_spell", 8613))
    c.loot = { { g, 1 } }; c.fire("LOOT_READY")
    c.tick(70)
  end
  c.item(9999, "Slow", 50, false)
  c.fire("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:9999::::|h[Slow]|h|r.")
  c.cached[9999] = true
  c.fire("ITEM_DATA_LOAD_RESULT", S("a_itemload", 9999), S("a_itemload", true))
  c.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", S("a_pim", 5)); c.gainMoney(500)
  c.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", S("a_pim", 5))
  c.tick(5)
  c.fire("QUEST_TURNED_IN", S("a_quest", 1), S("a_quest", 500), S("a_quest", 1000))
  c.gainMoney(1000); c.xp = c.xp + 500; c.fire("PLAYER_XP_UPDATE")
  c.xp = c.xpMax - 10; c.fire("PLAYER_XP_UPDATE"); c.xp = 20; c.xpMax = 6000; c.fire("PLAYER_XP_UPDATE")
  c.inGroup = true
  c.fire("CHAT_MSG_ADDON", S("a_addon", "VulcanGrindWatch"), S("a_addon", "3|7200|10|0|200000|160000|500000|1|1|1"),
    "PARTY", S("a_addon", "Mirel-R"))
  c.combat = true; c.tick(3); c.combat = false
  c.dead = true; c.tick(3); c.dead = false
  c.zone = "Duskwood"; c.tick(40)
  for _, cmd in ipairs({ "report", "check", "loot", "reprice", "history", "spots", "export", "compact", "compact",
      "report party", "reset" }) do
    c.slash(cmd)
  end
  c.ui.scripts.OnEnter(c.ui)
  on = false
  noErrors(c, "secret " .. src)
  for name, f in pairs(wrapped) do _G[name] = f end
end

---------------------------------------------------------------------------
-- 2. Source scan: Lua 5.1 can't make `==` or `if v then` throw on a secret, so
--    check that every read of these APIs goes through plain() / ns.plain().
---------------------------------------------------------------------------
do
  local APIS = { "UnitXP", "UnitXPMax", "UnitLevel", "GetMaxPlayerLevel", "GetMoney", "UnitIsAFK",
    "UnitIsDeadOrGhost", "UnitAffectingCombat", "UnitName", "UnitGUID", "UnitIsDead", "GetRealZoneText",
    "GetNumLootItems", "IsPlayerAtEffectiveMaxLevel", "IsXPUserDisabled", "GetXPExhaustion",
    "C_Spell.GetSpellName", "GetSpellInfo", "GetLootSourceInfo", "select" }
  -- Allowed unguarded uses (reviewed): results captured into a table that is then
  -- read through plain(), the raw read in ReadRested (checked for secrecy first),
  -- the item-info table in AddLoot (both fields read via plain()), and select()
  -- calls that aren't item info.
  local ALLOW = {
    ["local sources = { GetLootSourceInfo(slot) }"] = true,
    ["local raw = GetXPExhaustion()"] = true,
    ["local info = C_Spell.GetSpellInfo(id)"] = true,
    ["local build = GetBuildInfo and select(4, GetBuildInfo())"] = true,
  }
  local bad = {}
  -- Every file the TOC loads, so a new file can't slip past the scan.
  local tocFiles = {}
  for line in io.lines(ADDON_DIR .. "VulcanGrindWatch.toc") do
    if line:match("%.lua%s*$") then tocFiles[#tocFiles + 1] = line:match("^%s*(.-)%s*$") end
  end
  check("scan covers every TOC file (" .. #tocFiles .. ")", #tocFiles >= 9, #tocFiles)
  for _, file in ipairs(tocFiles) do
    local n = 0
    for line in io.lines(ADDON_DIR .. file) do
      n = n + 1
      local code = line:gsub("%-%-.*$", "")
      for _, api in ipairs(APIS) do
        local start = 1
        while true do
          local s = code:find("[%w_%.]*" .. api .. "%(", start)
          if not s then break end
          local token = code:match("^[%w_%.]*", s)
          start = s + #token + 1
          if token == api then
            local before = code:sub(1, s - 1)
            if not before:match("plain%(%s*$") and not before:match("plain%(%(%s*$") and not ALLOW[code:match("^%s*(.-)%s*$")] then
              bad[#bad + 1] = file .. ":" .. n .. ": " .. code:match("^%s*(.-)%s*$")
            end
          end
        end
      end
    end
  end
  check("every API read goes through plain()", #bad == 0, bad[1])
  local core = io.open(ADDON_DIR .. "Core.lua"):read("*a")
  check("GetLootSourceInfo results are read via plain()", core:find("local guid = plain%(sources%[i%]%)") ~= nil)
  check("GetXPExhaustion raw value is checked for secrecy first",
    core:find("local raw = GetXPExhaustion%(%)%s+if ns%.IsSecret%(raw%) then return nil end") ~= nil)
end

---------------------------------------------------------------------------
-- 3. Behaviors mutation testing showed were untested
---------------------------------------------------------------------------
do
  -- pause stops money and XP too, not just time and kills
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.slash("pause")
  c.gainMoney(5000); c.xp = c.xp + 300; c.fire("PLAYER_XP_UPDATE")
  check("paused: no coin", c.ns.S.totals.c == 0, c.ns.S.totals.c)
  check("paused: no XP", c.ns.S.totals.x == 0, c.ns.S.totals.x)
  c.slash("resume")
  c.gainMoney(100)
  check("resumed: coin counts again (baseline moved while paused)", c.ns.S.totals.c == 100, c.ns.S.totals.c)
end
do
  -- pausing keeps the time farmed right before it
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(120)
  c.slash("pause")
  check("pause commits time since last activity", math.abs(c.ns.S.elapsed - 120) < 1e-6, c.ns.S.elapsed)
end
do
  -- sync channel: party normally, raid in a raid; nothing while solo or before the clock starts
  local c = H.boot()
  c.login()
  c.inGroup = true
  c.tick(40)
  check("no sync before the clock starts", #c.addonSent == 0)
  c.fire("PLAYER_REGEN_DISABLED")
  c.inGroup = false
  c.tick(40)
  check("no sync while solo", #c.addonSent == 0)
  c.inGroup = true
  c.tick(31)
  check("party sync uses PARTY", c.addonSent[1] and c.addonSent[1].ch == "PARTY", c.addonSent[1] and c.addonSent[1].ch)
  c.inRaid = true
  c.tick(30)
  check("raid sync uses RAID", c.addonSent[#c.addonSent].ch == "RAID", c.addonSent[#c.addonSent].ch)
end
do
  -- a valid payload under another addon's prefix is ignored; same-version partner gets no notice
  local c = H.boot()
  c.login()
  c.fire("CHAT_MSG_ADDON", "Other", "4|7200|10|0|200000|160000|500000|1|1|1|15", "PARTY", "Bob")
  check("foreign prefix ignored", c.ns.partners.Bob == nil)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|1|1|1|15", "PARTY", "Mirel")
  check("same-version partner accepted", c.ns.partners.Mirel ~= nil)
  check("no version notice for the same version", not c.printedMatch("runs a"))
end
do
  -- a short AFK: back at the keyboard, the clock waits for activity
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(30)
  c.afk = true; c.fire("PLAYER_FLAGS_CHANGED", "player")
  c.tick(60)
  c.afk = false; c.fire("PLAYER_FLAGS_CHANGED", "player")
  local e = c.ns.Elapsed()
  c.tick(60)
  check("after a 1-min AFK the clock waits", c.ns.ClockState() == "idle" and c.ns.Elapsed() == e, c.ns.ClockState())
end
do
  -- time to level follows the last-15m pace, not the session average
  local c = H.boot()
  c.xp, c.xpMax = 0, 10000000
  c.login()
  for _ = 1, 30 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("M", 100); c.tick(60) end    -- slow
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("M", 1000); c.tick(60) end   -- fast
  local ttl = c.ns.TimeToLevel()
  local needed = c.xpMax - c.xp
  check("ETA uses the current pace", ttl and math.abs(ttl - needed / c.ns.RecentRate({ "x" }) * 3600) < 1, ttl)
end
do
  -- /gw price vendor switches back (and only vendor does)
  local c = H.boot({ auctionator = {} })
  c.login()
  c.slash("price ah")
  check("price ah", c.ns.DB.priceSource == "auction")
  c.slash("price vendor")
  check("price vendor switches back", c.ns.DB.priceSource == "vendor")
  c.slash("price bogus")
  check("unknown price source leaves it", c.ns.DB.priceSource == "vendor")
end
do
  -- reprice recomputes vendor buckets too
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(2589, "Linen Cloth", 13, false)
  c.lootMsg(2589, "Linen Cloth", 10)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.cached[2589] = true
  c.ns.Reprice()
  local sum = 0
  for _, b in pairs(c.ns.S.buckets) do sum = sum + (b.l or 0) end
  check("vendor buckets recomputed", sum == 130 and c.ns.S.totals.l == 130, sum)
end
do
  -- the duo /hr column is exactly mine + partner's
  local c = H.boot()
  c.login()
  c.inGroup = true
  for _ = 1, 10 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "3|7200|10|0|200000|160000|500000|-1|-1|-1", "PARTY", "Mirel")
  c.tick(1)
  local mine = c.ns.SessionRate(c.ns.GoldFields())
  local expected = c.ns.Money(mine + 180000)
  check("duo /hr = mine + Mirel's", c.cellText():find("Duo gold | 46g 0s | " .. expected:gsub("%%", "%%%%") .. " |", 1, false),
    c.cellText() .. " / " .. expected)
end
do
  -- compact -> full: every row is visible again
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(200)
  local function visibleRows()
    local n = 0
    for _, fs in ipairs(c.ui.fontstrings) do if fs.shown and fs.text ~= "" then n = n + 1 end end
    return n
  end
  local full = visibleRows()
  c.slash("compact")
  check("compact shows fewer cells", visibleRows() < full)
  c.slash("compact")
  check("full again shows every cell", visibleRows() == full, visibleRows() .. " vs " .. full)
end
do
  -- spending: within the grace after mailing it isn't spent; after it, flights count
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.fire("MAIL_SHOW"); c.fire("MAIL_CLOSED")
  c.gainMoney(-200)
  check("gold leaving right after the mailbox isn't spent", c.ns.S.spent == 0, c.ns.S.spent)
  c.tick(4)
  c.gainMoney(-50)
  check("a flight after the grace is spent", c.ns.S.spent == 50, c.ns.S.spent)
  c.fire("MERCHANT_SHOW"); c.fire("MERCHANT_CLOSED")
  c.gainMoney(-75)
  check("spending right after a merchant counts", c.ns.S.spent == 125, c.ns.S.spent)
end
do
  -- history and spots follow the AH price setting
  local c = H.boot({ auctionator = {} })
  c.level = 60; c.effectiveMax = true
  c.login()
  c.ns.DB.history = { { when = 1700000000, zone = "Westfall", elapsed = 3600, kills = 10, xp = 0,
    coin = 10000, loot = 10000, lootAH = 90000 } }
  c.slash("history")
  check("history vendor: 2g/hr", c.printedMatch("Westfall %(1h 00m%): 2g 0s gold/hr"))
  c.slash("price ah")
  c.printed = {}
  c.slash("history"); c.slash("spots")
  check("history AH: 10g/hr", c.printedMatch("Westfall %(1h 00m%): 10g 0s gold/hr"))
  check("spots AH: 10g/hr", c.printedMatch("Westfall: 10g 0s gold/hr"))
end
do
  -- the session start time is stamped once, not on every activity
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  local started = c.ns.S.startedAt
  c.tick(100); c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("M", 10)
  check("startedAt stamped once", started > 0 and c.ns.S.startedAt == started)
end
do
  -- pinning while other XP kills are pending
  local c = H.boot()
  c.login()
  c.xpKill("Wolf", 10); c.xpKill("Wolf", 10)
  c.killTargeted("Creature-0-1-2-3-100-W3", "Wolf")
  check("third kill pinned despite pending ones", c.ns.S.unmatched[3].guid == "Creature-0-1-2-3-100-W3")
end
do
  -- the saved window position and scale are restored at login
  local c = H.boot()
  c.login()
  c.ns.DB.point = { "BOTTOMLEFT", "BOTTOMLEFT", 123, 45 }
  c.ns.DB.scale = 1.25
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  local p = c2.ui.lastPoint
  check("position restored", p and p[1] == "BOTTOMLEFT" and p[4] == 123 and p[5] == 45, p and table.concat({ tostring(p[1]), tostring(p[4]) }, ","))
  check("scale restored", c2.ui.scale == 1.25)
end
do
  -- rested consumed reported only by UPDATE_EXHAUSTION still counts
  local c = H.boot()
  c.rested = 2000
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.rested = 1700
  c.fire("UPDATE_EXHAUSTION")
  check("rested use from UPDATE_EXHAUSTION", c.ns.S.totals.r == 300, c.ns.S.totals.r)
end
do
  -- items still loading survive a /reload and a reset
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(2)
  local c2 = H.boot({ saved = c.saved() })
  c2.item(4306, "Silk Cloth", 150, true)
  c2.login()
  c2.fire("ITEM_DATA_LOAD_RESULT", 4306, true)
  check("pending item resolved after a reload", c2.ns.S.totals.l == 3000 and c2.ns.S.items[4306].count == 20,
    c2.ns.S.totals.l)
  -- reset while still loading: the count stays with the old session
  local c3 = H.boot()
  c3.login()
  c3.ns.PENDING_MAX_TRIES = 1000  -- still loading at the reset
  c3.fire("PLAYER_REGEN_DISABLED")
  c3.item(4306, "Silk Cloth", 150, false)
  c3.lootMsg(4306, "Silk Cloth", 20)
  c3.tick(70)
  check("item still pending before the reset", c3.ns.PendingCount() == 1)
  c3.slash("reset")
  check("reset tells you about items it couldn't value", c3.printedMatch("20 looted item%(s%) had no price yet"))
  check("new session starts with no pending items", next(c3.ns.S.pending) == nil)
end

os.exit(H.summary() and 0 or 1)
