-- GrindWatch: tests for gaps found by the second mutation-testing pass.
package.path = assert(os.getenv("GW_TESTS"), "GW_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check
local ADDON_DIR = assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh")

local function noErrors(c, name)
  local errs = c.errors()
  check(name .. ": no runtime errors", #errs == 0, errs[1])
end

---------------------------------------------------------------------------
-- 1. Every event-handler argument goes through plain() before use.
--    (Lua 5.1 can't make `==` or table indexing throw on a secret, so a missing
--    guard on an event argument can't be caught at runtime in the mock.)
---------------------------------------------------------------------------
do
  local bad, checked = {}, 0
  -- Every file the TOC loads, so a new file can't slip past the scan.
  local tocFiles = {}
  for line in io.lines(ADDON_DIR .. "VulcanGrindWatch.toc") do
    if line:match("%.lua%s*$") then tocFiles[#tocFiles + 1] = line:match("^%s*(.-)%s*$") end
  end
  check("scan covers every TOC file (" .. #tocFiles .. ")", #tocFiles >= 9, #tocFiles)
  for _, file in ipairs(tocFiles) do
    local lines = {}
    for line in io.lines(ADDON_DIR .. file) do lines[#lines + 1] = line end
    local src = table.concat(lines, "\n")
    -- named functions, so ns.On("EVENT", Name) can be resolved to its body
    local named = {}
    for i, line in ipairs(lines) do
      local name, params = line:match("^local function ([%w_]+)%(([^)]*)%)")
      if name then named[name] = { params = params, line = i } end
    end
    local function body(startLine)
      local out = {}
      for i = startLine + 1, #lines do
        if lines[i]:match("^end") then break end
        out[#out + 1] = lines[i]
      end
      return table.concat(out, "\n")
    end
    for i, line in ipairs(lines) do
      local event, rest = line:match('ns%.On%("([%u_]+)",%s*(.*)$')
      if event then
        local params, startLine
        local inline = rest:match("^function%(([^)]*)%)")
        if inline then
          params, startLine = inline, i
        else
          local name = rest:match("^([%w_]+)%)")
          if name and named[name] then params, startLine = named[name].params, named[name].line end
        end
        if params then
          local text = body(startLine)
          for p in params:gmatch("[%w_]+") do
            if p ~= "_" then
              checked = checked + 1
              if not text:find("plain%(" .. p .. "%)") then
                bad[#bad + 1] = file .. ":" .. startLine .. " " .. event .. " arg '" .. p .. "'"
              end
            end
          end
        end
      end
    end
    local _ = src
  end
  check("event-handler args scanned", checked >= 12, checked)
  check("every event-handler argument goes through plain()", #bad == 0, bad[1])
end

---------------------------------------------------------------------------
-- 2. Behaviors
---------------------------------------------------------------------------
do
  -- an XP update with no change adds nothing
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.fire("PLAYER_XP_UPDATE"); c.fire("PLAYER_XP_UPDATE")
  check("no-change XP update adds 0", c.ns.S.totals.x == 0, c.ns.S.totals.x)
end
do
  -- PvP/DND flag changes (not AFK) don't stop the clock
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(30)
  c.fire("PLAYER_FLAGS_CHANGED", "player")   -- afk stays false
  c.tick(10)
  check("non-AFK flag change keeps running", c.ns.ClockState() == "running" and c.ns.Elapsed() >= 40, c.ns.ClockState())
end
do
  -- full window and compact rows are all there
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(200)
  local text = c.cellText()
  for _, label in ipairs({ "Time", "Kills", "XP", "Coin", "Loot", "Gold", "To level" }) do
    check("full window row: " .. label, text:find("| " .. label .. " |", 1, true), text)
  end
  c.slash("compact")
  text = c.cellText()
  for _, label in ipairs({ "XP", "Gold", "Kills" }) do
    check("compact row: " .. label, text:find("| " .. label .. " |", 1, true), text)
  end
end
do
  -- an item that finishes loading at the reset is valued in the saved session
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.ns.PENDING_MAX_TRIES = 1000  -- keep it loading for the whole session
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(70)
  c.cached[4306] = true      -- loaded, but no load event and no tick yet
  c.slash("reset")
  check("just-loaded item reaches the history entry", c.ns.DB.history[1] and c.ns.DB.history[1].loot == 3000,
    c.ns.DB.history[1] and c.ns.DB.history[1].loot)
end
do
  -- looting a corpse right after closing a vendor: its coin counts
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.fire("MERCHANT_SHOW"); c.fire("MERCHANT_CLOSED")
  c.now = c.now + 1
  c.corpse("Creature-0-1-2-3-100-CV", true)
  c.gainMoney(250)
  check("corpse coin right after a vendor counts", c.ns.S.totals.c == 250, c.ns.S.totals.c)
end
do
  -- after a reload the clock waits; /gw resume starts it
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(50)
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  c2.slash("pause"); c2.slash("resume")
  local e = c2.ns.Elapsed()
  c2.tick(10)
  check("resume after reload runs", c2.ns.ClockState() == "running" and math.abs(c2.ns.Elapsed() - e - 10) < 1e-6,
    c2.ns.ClockState())
end
do
  -- a kill isn't pinned to a dead target with a different name
  local c = H.boot()
  c.login()
  c.units.target = { guid = "Creature-0-1-2-3-100-WOLFX", name = "Wolf", dead = false }
  c.fire("PLAYER_TARGET_CHANGED")
  c.units.target.dead = true
  c.xpKill("Boar", 100)
  check("not pinned to a differently named corpse", c.ns.S.unmatched[1].guid == nil)
end
do
  -- the price setting reaches the CSV, report, loot list and labels
  local c = H.boot({ auctionator = { [4306] = 1000 } })
  c.level = 60; c.effectiveMax = true
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(200)
  c.ns.DB.history = { { when = 1700000000, zone = "Westfall", elapsed = 3600, kills = 10, xp = 0,
    coin = 10000, loot = 10000, lootAH = 90000 } }
  c.slash("price ah")
  local csv = c.ns.ShowCopy("t", c.ns.ExportLines("history"))
  check("CSV gold/hr under AH", csv:find("Westfall,,60%.0,10,0,10000,10000,90000,10%.00,"), csv)
  c.printed = {}
  c.slash("report")
  check("report tags AH", c.printedMatch("loot %(AH%)"))
  check("report top loot at AH value", c.printedMatch("Silk Cloth x20 %(1g 90s%)"), c.printedMatch("Top loot"))
  c.printed = {}
  c.slash("loot")
  check("/gw loot at AH value", c.printedMatch("Silk Cloth x20 %- 1g 90s"))
  c.tick(1)
  check("window label Loot (AH)", c.cellText():find("Loot (AH)", 1, true))
  c.slash("price vendor")
  c.printed = {}
  c.slash("loot")
  check("/gw loot at vendor value", c.printedMatch("Silk Cloth x20 %- 30s 0c"))
end
do
  -- a started session under 60s isn't saved to history
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(30)
  c.slash("reset")
  check("under-a-minute session not archived", #c.ns.DB.history == 0)
end
do
  -- a partner's real 0 rate shows as 0, not "--"
  local c = H.boot()
  c.login()
  c.inGroup = true
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "3|7200|10|0|0|0|0|0|0|0", "PARTY", "Mirel")
  c.tick(1)
  check("partner 0 rate shown as 0c", c.cellText():find("Mirel | 0c | 0c | 0c", 1, true), c.cellText())
end
do
  -- older clients: a send that returns nothing counts as sent (no resend every second)
  local c = H.boot()
  c.login()
  c.oldClientSend = true
  c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED")
  c.tick(40)
  check("old-client send counted once", #c.addonSent == 1, #c.addonSent)
end
do
  -- an Auctionator error falls back to the vendor price
  local c = H.boot({ auctionator = { [4306] = 1000 }, auctionatorThrows = true })
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 2)
  check("Auctionator error -> vendor value", c.ns.S.totals.la == 300, c.ns.S.totals.la)
  noErrors(c, "auctionator error")
end
do
  -- report's XP/loot-only split, the oldest unmatched kill, and small commands
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.xpKill("Boar", 10); c.xpKill("Wolf", 10)
  c.corpse("Creature-0-1-2-3-100-UNK")     -- name unknown: takes the oldest (Boar)
  check("oldest unmatched kill used", #c.ns.S.unmatched == 1 and c.ns.S.unmatched[1].mob == "Wolf",
    c.ns.S.unmatched[1] and c.ns.S.unmatched[1].mob)
  c.ns.S.unmatched = {}
  c.corpse("Creature-0-1-2-3-100-GREYZ")
  c.slash("report")
  check("report splits XP and loot-only kills", c.printedMatch("2 with XP, 1 loot%-only"))
  c.slash("idle -1")
  check("idle -1 rejected", c.ns.DB.idleMinutes == 5)
  c.slash("note test label"); c.slash("note")
  check("empty note clears the label", c.ns.S.note == nil)
  c.slash("debug echo")
  check("debug echo turns logging and echo on", c.ns.DB.debug and c.ns.DB.debugEcho)
  c.slash("debug echo")
  check("debug echo toggles echo off", c.ns.DB.debugEcho == false)
  c.slash("debug echo"); c.slash("debug off")
  check("debug off clears echo too", c.ns.DB.debug == false and c.ns.DB.debugEcho == false)
  c.slash("PAUSE")
  check("commands are case-insensitive", c.ns.S.paused)
  c.slash("resume")
  local hint
  for _, fs in ipairs(c.ui.fontstrings) do if tostring(fs.text):find("drag to move") then hint = fs end end
  c.slash("lock")
  check("hint hidden when locked", hint and hint.shown == false)
  c.slash("unlock")
  check("hint shown when unlocked", hint and hint.shown == true)
end
do
  -- spots kills/hr
  local c = H.boot()
  c.login()
  c.ns.DB.history = { { when = 1700000000, zone = "Elwynn", elapsed = 1800, kills = 60, xp = 0, coin = 0, loot = 0 } }
  c.slash("spots")
  check("spots kills/hr", c.printedMatch("Elwynn: 0c gold/hr, 120 kills/hr"))
end

do
  -- older clients: prefix registration that returns nothing still counts
  local c = H.boot({ prefixReturnsNil = true })
  c.login()
  c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(31)
  check("sync works when registration returns nothing", #c.addonSent == 1, #c.addonSent)
end
do
  -- channel names are case-insensitive; /gw export debug opens the diagnostics
  local c = H.boot()
  c.login()
  c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(200)
  c.slash("report PARTY")
  check("report PARTY works", #c.sent == 2 and c.sent[1].ch == "PARTY", #c.sent)
  c.slash("debug on"); c.gainMoney(5)
  c.slash("export debug")
  check("/gw export debug opens the diagnostics", _G.VulcanGrindWatchCopyFrame.title.text:find("diagnostics"))
end

do
  -- the "still loading" note only when something was saved and something is pending
  local c = H.boot()
  c.login()
  c.ns.PENDING_MAX_TRIES = 1000
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(30)
  c.slash("reset")   -- under a minute: nothing saved
  check("no 'saved value' note when nothing was saved", not c.printedMatch("had no price yet"))
  local c2 = H.boot()
  c2.login()
  c2.fire("PLAYER_REGEN_DISABLED"); c2.tick(90)
  c2.slash("reset")  -- saved, nothing pending
  check("no note when nothing is pending", not c2.printedMatch("had no price yet"))
end
do
  -- spells are recognized by ID even when spell names aren't available yet
  local c = H.boot()
  _G.C_Spell.GetSpellName = function() return nil end
  c.login()
  check("skinning by ID without names", c.ns.ClassifySpell(8613) == "gather")
  c.units.target = { guid = "Creature-0-1-2-3-100-SNN", name = "Boar", dead = true }
  c.cast(8613); c.corpse("Creature-0-1-2-3-100-SNN")
  check("skinning a stranger's corpse without names: no kill", c.ns.Total({ "k" }) == 0)
end
do
  -- the older-version notice prints once, however many messages arrive
  local c = H.boot()
  c.login()
  for _ = 1, 3 do c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|7200|10|0|200000|160000|500000", "PARTY", "Bob") end
  local n = 0
  for _, p in ipairs(c.printed) do if p:find("Bob runs an older") then n = n + 1 end end
  check("older-version notice once", n == 1, n)
end
do
  -- the party report includes XP/hr while leveling (and not at 60)
  local c = H.boot()
  c.login()
  c.inGroup = true
  for _ = 1, 4 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("M", 100); c.tick(60) end
  c.slash("report party")
  check("party report has XP/hr while leveling", c.sent[1] and c.sent[1].msg:find("XP/hr"), c.sent[1] and c.sent[1].msg)
  c.level = 60; c.effectiveMax = true
  c.slash("report party")
  check("party report has no XP/hr at 60", not c.sent[3].msg:find("XP/hr"), c.sent[3].msg)
end
do
  -- reloading while AFK shows AFK, not idle
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(30)
  local saved = c.saved()
  local c2 = H.boot({ saved = saved })
  c2.afk = true
  c2.login()
  check("reload while AFK shows AFK", c2.ns.ClockState() == "afk", c2.ns.ClockState())
end
do
  -- a quest reward never takes more than the gain it matched
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.gainMoney(5000)
  c.fire("QUEST_TURNED_IN", 1, 0, 3000)
  c.fire("QUEST_TURNED_IN", 2, 0, 3000)  -- its coin never arrives
  check("second reward can't reuse the first gain", c.ns.S.totals.c == 2000, c.ns.S.totals.c)
end

do
  -- a malformed /gw spell command leaves taught spells alone
  local c = H.boot()
  c.login()
  c.slash("spell gather 424242")
  c.slash("spell bogus 424242")
  check("bad /gw spell keeps the taught spell", c.ns.DB.customSpells[424242] == "gather")
  c.slash("spell remove")
  noErrors(c, "spell remove without an ID")
  check("remove without an ID explained", c.printedMatch("use /gw spell gather"))
end
do
  -- a short history has no "N more" line
  local c = H.boot()
  c.login()
  c.ns.DB.history = {
    { when = 1700000000, zone = "A", elapsed = 600, kills = 1, xp = 0, coin = 0, loot = 0 },
    { when = 1700000000, zone = "B", elapsed = 600, kills = 1, xp = 0, coin = 0, loot = 0 },
    { when = 1700000000, zone = "C", elapsed = 600, kills = 1, xp = 0, coin = 0, loot = 0 },
  }
  c.slash("history")
  check("short history: no 'more' line", not c.printedMatch("more: /gw history all"))
end

do
  -- /gw reprice while an item is still loading doesn't count it twice
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(2589, "Linen Cloth", 13)
  c.lootMsg(2589, "Linen Cloth", 60)
  local c2 = H.boot({ saved = c.saved() })
  c2.item(2589, "Linen Cloth", 13, false)   -- cold cache after the reload
  c2.login()
  c2.fire("PLAYER_REGEN_DISABLED")
  c2.lootMsg(2589, "Linen Cloth", 100)       -- waits for its price
  c2.slash("reprice")
  c2.cached[2589] = true
  c2.fire("ITEM_DATA_LOAD_RESULT", 2589, true)
  local l, la = 0, 0
  for _, b in pairs(c2.ns.S.buckets) do l = l + (b.l or 0); la = la + (b.la or 0) end
  check("buckets match totals after reprice + late load (vendor)", l == c2.ns.S.totals.l and l == 2080, l .. " vs " .. c2.ns.S.totals.l)
  check("buckets match totals after reprice + late load (AH)", la == c2.ns.S.totals.la, la .. " vs " .. c2.ns.S.totals.la)
  -- and a second reprice keeps them equal
  c2.ns.Reprice()
  l = 0
  for _, b in pairs(c2.ns.S.buckets) do l = l + (b.l or 0) end
  check("second reprice keeps buckets = totals", l == 2080, l)
end

do
  -- reset on the tick an item would give up still reports it
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(60)
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(c.ns.PENDING_MAX_TRIES - 1)     -- one try short of giving up
  c.slash("reset")
  check("reset on the last try still reports the item", c.printedMatch("20 looted item%(s%) had no price yet"))
  -- an item that gave up loading earlier in the session is reported too
  local c2 = H.boot()
  c2.login()
  c2.fire("PLAYER_REGEN_DISABLED")
  c2.item(4306, "Silk Cloth", 150, false)
  c2.lootMsg(4306, "Silk Cloth", 5)
  c2.tick(c2.ns.PENDING_MAX_TRIES + 40)  -- gave up, session long enough to save
  c2.fire("PLAYER_REGEN_DISABLED"); c2.tick(5)
  c2.slash("reset")
  check("reset reports items that gave up earlier", c2.printedMatch("5 looted item%(s%) had no price yet"))
  -- a priced 0-value item (quest item) isn't reported
  local c3 = H.boot()
  c3.login()
  c3.fire("PLAYER_REGEN_DISABLED")
  c3.item(777, "Quest Thing", 0); c3.lootMsg(777, "Quest Thing", 1)
  c3.tick(90)
  c3.slash("reset")
  check("worthless but priced items aren't reported", not c3.printedMatch("had no price yet"))
end
do
  -- a given-up item is booked in the minute it was looted
  local c = H.boot()
  c.login()
  for _ = 1, 5 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  c.tick(55); c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  local lootBucket = math.floor(c.ns.Elapsed() / 60)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)    -- gives up in a later minute
  c.cached[4306] = true
  c.ns.Reprice()
  check("given-up item valued in its loot minute", c.ns.S.buckets[lootBucket] and c.ns.S.buckets[lootBucket].l == 3000,
    c.ns.S.buckets[lootBucket] and c.ns.S.buckets[lootBucket].l)
end

do
  -- the reset notice counts exactly the units with no value
  -- D: 20 Silk give up, then 1 Silk is priced -> 20 still unvalued
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.cached[4306] = true
  c.lootMsg(4306, "Silk Cloth", 1)
  c.tick(60)
  c.slash("reset")
  check("mixed entry: the 20 unvalued are reported", c.printedMatch("20 looted item%(s%) had no price yet"))
  -- E: AH mode, given-up Silk valued by Auctionator via reprice -> no notice
  local prices = { [4306] = 1000 }
  local c2 = H.boot({ auctionator = prices })
  c2.login()
  c2.fire("PLAYER_REGEN_DISABLED")
  c2.item(4306, "Silk Cloth", 150, false)
  c2.lootMsg(4306, "Silk Cloth", 20)
  c2.tick(c2.ns.PENDING_MAX_TRIES + 1)
  c2.slash("price ah")
  c2.slash("reprice")
  c2.tick(60)
  c2.slash("reset")
  check("AH-valued after reprice: no notice", not c2.printedMatch("had no price yet") and c2.ns.DB.history[1].lootAH == 19000)
  -- F: an old-build session with a priced worthless item -> no notice
  local c3 = H.boot()
  c3.login()
  c3.fire("PLAYER_REGEN_DISABLED")
  c3.item(777, "Quest Trinket", 0); c3.lootMsg(777, "Quest Trinket", 3)
  c3.ns.S.items[777].unit = nil   -- as saved by an earlier build
  c3.tick(90)
  c3.slash("reset")
  check("old-build worthless item: no notice", not c3.printedMatch("had no price yet"))
  -- repricing once vendor data loads clears it
  local c4 = H.boot()
  c4.login()
  c4.fire("PLAYER_REGEN_DISABLED")
  c4.item(4306, "Silk Cloth", 150, false)
  c4.lootMsg(4306, "Silk Cloth", 20)
  c4.tick(c4.ns.PENDING_MAX_TRIES + 1)
  c4.cached[4306] = true
  c4.slash("reprice")
  c4.tick(60)
  c4.slash("reset")
  check("valued by reprice: no notice", not c4.printedMatch("had no price yet") and c4.ns.DB.history[1].loot == 3000)
end

do
  local function givenUp(opts)
    local c = H.boot(opts)
    c.login()
    c.fire("PLAYER_REGEN_DISABLED")
    c.item(4306, "Silk Cloth", 150, false)   -- vendor data never loads
    c.lootMsg(4306, "Silk Cloth", 20)
    c.tick(c.ns.PENDING_MAX_TRIES + 1)
    return c
  end
  -- H: vendor mode, Auctionator has a price, vendor data never loads -> notice
  local c = givenUp({ auctionator = { [4306] = 1000 } })
  c.slash("reprice"); c.tick(60); c.slash("reset")
  check("vendor mode, only an AH price: notice", c.printedMatch("20 looted item%(s%) had no price yet"))
  -- J: AH mode, Auctionator has no data, vendor never loads -> notice
  local c2 = givenUp({ auctionator = {} })
  c2.slash("price ah"); c2.slash("reprice"); c2.tick(60); c2.slash("reset")
  check("AH mode, no AH data: notice", c2.printedMatch("20 looted item%(s%) had no price yet"))
  -- G: AH reprice, then switch to vendor before the reset -> notice
  local c3 = givenUp({ auctionator = { [4306] = 1000 } })
  c3.slash("price ah"); c3.slash("reprice"); c3.slash("price vendor"); c3.tick(60); c3.slash("reset")
  check("AH-valued but reset in vendor mode: notice", c3.printedMatch("20 looted item%(s%) had no price yet"))
end

do
  -- K: AH mode, 20 given up + 1 priced, no reprice -> the 20 are reported
  local c = H.boot({ auctionator = { [4306] = 1000 } })
  c.login()
  c.slash("price ah")
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.cached[4306] = true
  c.lootMsg(4306, "Silk Cloth", 1)
  c.tick(60)
  c.slash("reset")
  check("AH mode mixed entry: the 20 are reported", c.printedMatch("20 looted item%(s%) had no price yet"))
end

do
  -- P: AH mode, no AH data; vendor data loads and you reprice -> AH value = vendor, no notice
  local c = H.boot({ auctionator = {} })
  c.login()
  c.slash("price ah")
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.cached[4306] = true
  c.slash("reprice")
  c.tick(60)
  c.slash("reset")
  check("vendor price also clears the AH count", not c.printedMatch("had no price yet")
    and c.ns.DB.history[1].lootAH == 3000, c.ns.DB.history[1] and c.ns.DB.history[1].lootAH)
end

do
  -- 10 Silk at AH 950 + 10 given up; vendor loads, AH data gone, reprice:
  -- the given-up ones get the vendor floor (150), not a share of the others
  local prices = { [4306] = 1000 }
  local c = H.boot({ auctionator = prices })
  c.login()
  c.slash("price ah")
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150)
  c.lootMsg(4306, "Silk Cloth", 10)                -- 9500 AH
  c.cached[4306] = false
  c.lootMsg(4306, "Silk Cloth", 10)                -- waits, then gives up
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.cached[4306] = true
  prices[4306] = nil
  c.slash("reprice")
  check("given-up units get the vendor floor in AH value", c.ns.S.totals.la == 11000, c.ns.S.totals.la)
  c.tick(60)
  c.slash("reset")
  check("saved AH value includes them", c.ns.DB.history[1].lootAH == 11000, c.ns.DB.history[1].lootAH)
end

do
  -- Reprice is idempotent and keeps buckets = totals, across 32 combinations of:
  -- AH price at loot, old-build entry (no unit price), units given up, item data
  -- loaded later, AH price later. Each repriced three times.
  local bad = {}
  for _, ahAtLoot in ipairs({ true, false }) do for _, oldBuild in ipairs({ true, false }) do
  for _, giveUp in ipairs({ true, false }) do for _, cachedAfter in ipairs({ true, false }) do
  for _, ahAfter in ipairs({ "high", "none", "low" }) do
    local prices = { [4306] = ahAtLoot and 1000 or nil }
    local c = H.boot({ auctionator = prices })
    c.login(); c.slash("price ah"); c.fire("PLAYER_REGEN_DISABLED")
    c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 10)
    if oldBuild then c.ns.S.items[4306].unit = nil end
    if giveUp then
      c.cached[4306] = false; c.lootMsg(4306, "Silk Cloth", 10); c.tick(c.ns.PENDING_MAX_TRIES + 1)
    end
    c.cached[4306] = cachedAfter
    prices[4306] = (ahAfter == "high" and 800) or (ahAfter == "low" and 100) or nil  -- low: below vendor
    c.ns.Reprice()
    local l1, a1 = c.ns.S.totals.l, c.ns.S.totals.la
    c.ns.Reprice(); c.ns.Reprice()
    local sl, sa = 0, 0
    for _, b in pairs(c.ns.S.buckets) do sl = sl + (b.l or 0); sa = sa + (b.la or 0) end
    if c.ns.S.totals.l ~= l1 or c.ns.S.totals.la ~= a1 or math.abs(sl - l1) > 1e-6
        or math.abs(sa - a1) > 1e-6 or a1 < l1 then
      bad[#bad + 1] = string.format("ahAtLoot=%s old=%s giveUp=%s cached=%s ahAfter=%s: la %s -> %s",
        tostring(ahAtLoot), tostring(oldBuild), tostring(giveUp), tostring(cachedAfter), tostring(ahAfter),
        a1, c.ns.S.totals.la)
    end
  end end end end end
  check("reprice is idempotent and consistent in all 48 cases", #bad == 0, bad[1])
end

do
  -- q18: AH Silk at minute 0, given-up Silk at minute 30; AH data gone, vendor loads, reprice:
  -- the minute-30 bucket gets the vendor floor only (1500), minute 0 keeps 9500
  local prices = { [4306] = 1000 }
  local c = H.boot({ auctionator = prices })
  c.login()
  c.slash("price ah")
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150)
  c.lootMsg(4306, "Silk Cloth", 10)
  local first = math.floor(c.ns.Elapsed() / 60)
  for _ = 1, 30 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  c.cached[4306] = false
  c.lootMsg(4306, "Silk Cloth", 10)
  local late = math.floor(c.ns.Elapsed() / 60)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.cached[4306] = true
  prices[4306] = nil
  local first0 = c.ns.S.buckets[first]  -- may be pruned by now; keep a reference
  c.ns.Reprice()
  check("q18: total 11000", c.ns.S.totals.la == 11000, c.ns.S.totals.la)
  check("q18: minute-30 bucket gets the vendor floor only", c.ns.S.buckets[late].la == 1500, c.ns.S.buckets[late].la)
  check("q18: minute-0 bucket keeps its AH value", first0 == nil or first0.la == 9500, first0 and first0.la)
end
do
  -- q19: nothing changed, AH data gone, reprice -> 15m AH rate unchanged
  local prices = { [4306] = 2000 }
  local c = H.boot({ auctionator = prices })
  c.login()
  c.slash("price ah")
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150)
  c.lootMsg(4306, "Silk Cloth", 10)          -- 19000 at minute 0
  for _ = 1, 30 do c.fire("PLAYER_REGEN_DISABLED"); c.tick(60) end
  prices[4306] = 100                          -- AH crashed; vendor floor applies
  c.lootMsg(4306, "Silk Cloth", 10)          -- 1500 at minute 30
  c.tick(60)
  local before = c.ns.RecentRate({ "la" })
  prices[4306] = nil
  c.ns.Reprice()
  check("q19: reprice with no AH data leaves the 15m rate alone", math.abs(c.ns.RecentRate({ "la" }) - before) < 1e-6,
    c.ns.RecentRate({ "la" }) .. " vs " .. before)
  check("q19: totals unchanged", c.ns.S.totals.la == 20500, c.ns.S.totals.la)
end

do
  -- reprice at an AH price below vendor: AH value floors at vendor
  local prices = { [4306] = 1000 }
  local c = H.boot({ auctionator = prices })
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 20)
  prices[4306] = 100
  c.ns.Reprice()
  check("AH below vendor at reprice: floors at vendor", c.ns.S.totals.la == 3000, c.ns.S.totals.la)
end
do
  -- given up -> AH reprice -> AH gone + vendor loads -> reprice: no double value
  local prices = { [4306] = 1000 }
  local c = H.boot({ auctionator = prices })
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 20)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.ns.Reprice()                       -- AH price: 19000
  prices[4306] = nil
  c.cached[4306] = true
  c.ns.Reprice()                       -- vendor loads, no AH
  local la = 0
  for _, b in pairs(c.ns.S.buckets) do la = la + (b.la or 0) end
  check("AH then vendor reprice: buckets = total", la == c.ns.S.totals.la and la == 19000, la .. " vs " .. c.ns.S.totals.la)
end
do
  -- a minute saved by an older build keeps its value when new loot lands in it
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 20)
  local idx = math.floor(c.ns.Elapsed() / 60)
  local b = c.ns.S.buckets[idx]
  b.vl, b.va, b.ua = nil, nil, nil       -- as the older build saved it (b.q, b.l, b.la only)
  c.item(2589, "Linen Cloth", 13); c.lootMsg(2589, "Linen Cloth", 1)
  c.ns.Reprice()
  check("older minute keeps its value after new loot + reprice", c.ns.S.buckets[idx].l == 3013,
    c.ns.S.buckets[idx].l)
  -- and a v2-style minute with values but no detail at all
  local c2 = H.boot()
  c2.login()
  c2.fire("PLAYER_REGEN_DISABLED")
  local idx2 = math.floor(c2.ns.Elapsed() / 60)
  c2.ns.S.buckets[idx2] = { l = 500, la = 900, c = 10 }
  c2.item(2589, "Linen Cloth", 13); c2.lootMsg(2589, "Linen Cloth", 1)
  c2.ns.Reprice()
  check("v2-style minute keeps its value", c2.ns.S.buckets[idx2].l == 513 and c2.ns.S.buckets[idx2].la == 913,
    c2.ns.S.buckets[idx2].l .. "/" .. c2.ns.S.buckets[idx2].la)
end

do
  -- older-build entry (no unit price), 10 valued + 10 given up, item data cold:
  -- the vendor price comes from the valued units (150), so all 20 are worth 3000
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 10)
  c.ns.S.items[4306].unit = nil
  c.cached[4306] = false
  c.lootMsg(4306, "Silk Cloth", 10)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.ns.Reprice()
  check("no real price: given-up units stay unvalued", c.ns.S.totals.l == 1500 and c.ns.S.items[4306].unpriced == 10,
    c.ns.S.totals.l)
  check("a derived price isn't saved", c.ns.S.items[4306].unit == nil)
  c.cached[4306] = true
  c.ns.Reprice()
  check("real price values them", c.ns.S.totals.l == 3000 and c.ns.S.items[4306].unpriced == nil, c.ns.S.totals.l)
end

do
  -- q22: an older-build entry whose count includes given-up units it doesn't track:
  -- the cold-cache reprice uses a diluted guess, but once the data loads it's exact
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.ns.S.items[4306] = { name = "Silk Cloth", count = 21, value = 150, valueAH = 150 }  -- 20 gave up
  c.ns.S.totals.l, c.ns.S.totals.la = 150, 150
  c.item(4306, "Silk Cloth", 150, false)
  c.ns.Reprice()
  c.cached[4306] = true
  c.ns.Reprice()
  check("q22: real price wins once the item data loads", c.ns.S.items[4306].unit == 150 and c.ns.S.totals.l == 3150,
    tostring(c.ns.S.items[4306].unit) .. " / " .. c.ns.S.totals.l)
end

do
  -- q23: older entry (hidden given-up units) + 10 more given up after the update;
  -- cold-cache reprice must not value them at the diluted guess or hide the notice
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.ns.S.items[4306] = { name = "Silk Cloth", count = 21, value = 150, valueAH = 150 }
  c.ns.S.totals.l, c.ns.S.totals.la = 150, 150
  c.item(4306, "Silk Cloth", 150, false)
  c.lootMsg(4306, "Silk Cloth", 10)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.slash("reprice")
  check("q23: vendor value not set from a diluted guess", c.ns.S.totals.l == 150, c.ns.S.totals.l)
  c.tick(60)
  c.slash("reset")
  check("q23: the 10 are still reported", c.printedMatch("10 looted item%(s%) had no price yet"))
  -- and with an AH price, the derived floor applies (AH >= the known vendor value)
  local c2 = H.boot({ auctionator = { [4306] = 100 } })
  c2.login()
  c2.fire("PLAYER_REGEN_DISABLED")
  c2.ns.S.items[4306] = { name = "Silk Cloth", count = 10, value = 1500, valueAH = 1500 }
  c2.ns.S.totals.l, c2.ns.S.totals.la = 1500, 1500
  c2.item(4306, "Silk Cloth", 150, false)
  c2.ns.Reprice()
  check("derived price floors a low AH price", c2.ns.S.totals.la == 1500 and c2.ns.S.totals.l == 1500,
    c2.ns.S.totals.la)
end

do
  -- q24: 10 priced + 10 given up, no unit saved, cold cache, AH below vendor:
  -- the floor comes from the priced units only (150), so AH = 20 x 150
  local prices = {}
  local c = H.boot({ auctionator = prices })
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 10)
  c.cached[4306] = false
  c.lootMsg(4306, "Silk Cloth", 10)
  c.tick(c.ns.PENDING_MAX_TRIES + 1)
  c.ns.S.items[4306].unit = nil
  prices[4306] = 100
  c.ns.Reprice()
  check("q24: floor ignores given-up units", c.ns.S.totals.la == 3000, c.ns.S.totals.la)
end

do
  -- a minute saved by a development build (b.q but no per-item values), repriced
  -- before any new loot lands in it: no error, value unchanged
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 20)
  local idx = math.floor(c.ns.Elapsed() / 60)
  local b = c.ns.S.buckets[idx]
  b.vl, b.va, b.ua = nil, nil, nil
  c.slash("reprice")
  noErrors(c, "reprice on a dev-build minute")
  check("dev-build minute keeps its value", c.ns.S.buckets[idx].l == 3000, c.ns.S.buckets[idx].l)
end

os.exit(H.summary() and 0 or 1)
