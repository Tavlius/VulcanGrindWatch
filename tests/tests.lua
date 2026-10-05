package.path = assert(os.getenv("GW_TESTS"), "GW_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check

local function noErrors(c, name)
  local errs = c.errors()
  check(name .. ": no runtime errors", #errs == 0, errs[1])
end

-- 1. Clock waits, starts at first pull, counts XP kills and gains
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.tick(5)
  check("waits before first pull", ns.Elapsed() == 0 and not ns.S.started)
  check("status waiting", ns.ClockState() == "waiting")
  c.fire("PLAYER_REGEN_DISABLED")
  check("pull starts clock", ns.S.started)
  c.tick(10)
  check("clock runs after pull", math.abs(ns.Elapsed() - 10) < 1e-9, ns.Elapsed())
  c.xpKill("Defias Thug", 120)
  check("xp kill counted", ns.Total({ "k" }) == 1 and ns.S.mobs["Defias Thug"] == 1)
  check("xp counted", ns.Total({ "x" }) == 120)
  noErrors(c, "basic")
end

-- 2. Kill matching: XP kill + looting same corpse = 1 kill; grey corpse = +1
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.xpKill("Murloc", 100)
  c.corpse("Creature-0-1-2-3-100-A")
  check("xp kill + its corpse = 1", ns.Total({ "k" }) == 1, ns.Total({ "k" }))
  c.corpse("Creature-0-1-2-3-100-A")
  check("re-looting same corpse ignored", ns.Total({ "k" }) == 1)
  c.corpse("Creature-0-1-2-3-100-B")  -- grey mob, no XP
  check("loot-only corpse adds kill", ns.Total({ "k" }) == 2 and ns.S.lootOnlyKills == 1)
  c.xpKill("Murloc", 100); c.xpKill("Murloc", 100); c.xpKill("Murloc", 100)
  c.corpse("Creature-0-1-2-3-100-C")
  check("AoE: 3 xp kills, 1 looted = 3 more", ns.Total({ "k" }) == 5, ns.Total({ "k" }))
  c.tick(400)  -- unmatched XP kills expire after 5 min
  c.corpse("Creature-0-1-2-3-100-D")
  check("stale unmatched expire -> new corpse is a kill", ns.Total({ "k" }) == 6, ns.Total({ "k" }))
  c.corpse("Vehicle-0-1-2-3-100-E")
  check("vehicle GUID counts", ns.Total({ "k" }) == 7)
  c.loot = { { "GameObject-0-1-2-3-100-F", 1 } }
  c.fire("LOOT_OPENED")
  check("game objects (herbs/chests) are not kills", ns.Total({ "k" }) == 7)
  noErrors(c, "kills")
end

-- 3. Loot value, pending items, give-up, AH pricing
do
  local c = H.boot({ auctionator = { [2589] = 100, [4306] = 50 } })
  c.login()
  local ns = c.ns
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(2589, "Linen Cloth", 13)
  c.item(4306, "Silk Cloth", 150)
  c.item(9999, "Slow Item", 500, false)
  c.item(8888, "Never Item", 700, false)
  c.lootMsg(2589, "Linen Cloth", 3)
  c.lootMsg(4306, "Silk Cloth")
  c.fire("CHAT_MSG_LOOT", "Mirel receives loot: |cffffffff|Hitem:4306::::|h[Silk Cloth]|h|r.")
  check("vendor value 3x13+150", ns.Total({ "l" }) == 189, ns.Total({ "l" }))
  -- AH: linen 100*0.95=95 each > 13 -> 285; silk AH 47 < vendor 150 -> 150
  check("AH value never below vendor", ns.Total({ "la" }) == 435, ns.Total({ "la" }))
  c.lootMsg(9999, "Slow Item", 2)
  check("pending not counted yet", ns.Total({ "l" }) == 189 and ns.PendingCount() == 1)
  c.cached[9999] = true
  c.fire("ITEM_DATA_LOAD_RESULT", 9999, true)
  check("pending resolved on load event", ns.Total({ "l" }) == 1189 and ns.PendingCount() == 0)
  c.lootMsg(8888, "Never Item")
  c.tick(ns.PENDING_MAX_TRIES + 1)
  check("never-loading item given up", ns.PendingCount() == 0 and ns.S.items[8888].count == 1
    and ns.S.items[8888].value == 0)
  check("item name from link", ns.S.items[8888].name == "Never Item")
  c.slash("price ah")
  check("price ah switches", ns.DB.priceSource == "auction")
  check("gold fields follow price", ns.GoldFields()[2] == "la")
  noErrors(c, "loot")
end

-- 4. Price ah refused without Auctionator
do
  local c = H.boot()
  c.login()
  c.slash("price ah")
  check("no auctionator -> stays vendor", c.ns.DB.priceSource == "vendor")
end

-- 5. Money: vendor/mail/trade excluded, grace window, spending, quest rewards
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.fire("PLAYER_REGEN_DISABLED")
  c.gainMoney(245)
  check("coin counted", ns.Total({ "c" }) == 245)
  c.fire("MERCHANT_SHOW"); c.gainMoney(10000); c.fire("MERCHANT_CLOSED")
  c.gainMoney(500)
  check("merchant + grace excluded", ns.Total({ "c" }) == 245)
  c.tick(5)
  c.gainMoney(-300)
  check("spending tracked", ns.S.spent == 300)
  c.gainMoney(100)
  check("coin after grace", ns.Total({ "c" }) == 345)
  c.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17); c.gainMoney(7777)
  c.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
  check("mail excluded", ns.Total({ "c" }) == 345)
  c.tick(5)
  c.fire("MERCHANT_SHOW")
  c.fire("PLAYER_REGEN_DISABLED")  -- attacked at the vendor: block must hold
  c.gainMoney(999)
  check("combat at vendor keeps block", ns.Total({ "c" }) == 345)
  c.fire("MERCHANT_CLOSED"); c.tick(5)
  c.fire("QUEST_TURNED_IN", 1, 1000, 5000)
  c.gainMoney(5000)
  c.xp = c.xp + 1000; c.fire("PLAYER_XP_UPDATE")
  check("quest coin excluded", ns.Total({ "c" }) == 345 and ns.S.questCoin == 5000)
  check("quest xp excluded (raw total, not clamped)", ns.S.totals.x == 0 and ns.S.questXP == 1000, ns.S.totals.x)
  noErrors(c, "money")
end

-- 6. Level-up XP math
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.xp = 4900; c.fire("PLAYER_XP_UPDATE")
  local before = ns.Total({ "x" })
  c.level = 21; c.xp = 100; c.xpMax = 5500; c.fire("PLAYER_XP_UPDATE")
  check("level-up adds rest of bar + new", ns.Total({ "x" }) - before == 200, ns.Total({ "x" }) - before)
end

-- 7. Pause, AFK, idle, dead
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.fire("PLAYER_REGEN_DISABLED")
  c.slash("pause")
  local e = ns.Elapsed()
  c.tick(10)
  c.xpKill("Thug", 50)
  check("paused: no time, no kills", ns.Elapsed() == e and ns.Total({ "k" }) == 0)
  c.slash("resume")
  check("resume runs", ns.ClockState() == "running")
  c.afk = true; c.fire("PLAYER_FLAGS_CHANGED", "player")
  e = ns.Elapsed(); c.tick(10)
  check("afk stops clock", ns.Elapsed() == e and ns.ClockState() == "afk")
  c.afk = false; c.fire("PLAYER_FLAGS_CHANGED", "player")
  c.fire("PLAYER_REGEN_DISABLED")
  e = ns.Elapsed()
  c.tick(400)
  -- 400s with no activity: idle after 5 min, and only 60s of the break is kept
  check("idle drops the break, keeps 60s", ns.ClockState() == "idle" and math.abs(ns.Elapsed() - e - 60) <= 1,
    ns.Elapsed() - e)
  c.fire("PLAYER_REGEN_DISABLED")
  check("pull wakes from idle", ns.ClockState() == "running")
  c.dead = true
  e = ns.Elapsed()
  c.tick(600)
  check("corpse run keeps clock running", math.abs(ns.Elapsed() - e - 600) < 1e-6)
  c.dead = false
  c.slash("idle 0")
  c.tick(700)
  check("idle 0 disables idle", ns.ClockState() == "running")
  c.slash("idle abc")
  check("bad idle value rejected", ns.DB.idleMinutes == 0)
  c.slash("pause")
  local beforePause = ns.Elapsed()
  c.tick(30)
  check("pause freezes clock", ns.Elapsed() == beforePause)
  c.slash("resume")
  c.tick(10)
  check("resume restarts clock", not ns.S.paused and math.abs(ns.Elapsed() - beforePause - 10) < 1e-6)
  noErrors(c, "clock")
end

-- 8. Resume before any activity must not start the clock
do
  local c = H.boot()
  c.login()
  c.slash("pause"); c.slash("resume"); c.tick(5)
  check("resume doesn't start clock", not c.ns.S.started and c.ns.Elapsed() == 0)
end

-- 9. Rolling 15-min rate vs session rate
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.fire("PLAYER_REGEN_DISABLED")
  -- 30 min slow spot: 1 gold per minute
  -- (a pull each minute: coin alone isn't activity)
  for _ = 1, 30 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  -- 15 min fast spot: 5 gold per minute
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(50000); c.tick(60) end
  local session = ns.SessionRate({ "c" })
  local recent = ns.RecentRate({ "c" })
  check("session rate blends spots", math.abs(session - (30 * 10000 + 15 * 50000) / 45 * 60) < 50, session)
  check("recent rate reflects new spot", math.abs(recent - 50000 * 60) < 50, recent)
  ns.Prune()
  local n = 0
  for _ in pairs(ns.S.buckets) do n = n + 1 end
  check("old buckets pruned (kept for the longest window, 30 min)", n <= 32 and n < 45, n)
  check("rate after prune unchanged", math.abs(ns.RecentRate({ "c" }) - recent) < 1e-6)
  check("no recent rate under 5 min", (function()
    local c2 = H.boot(); c2.login(); c2.fire("PLAYER_REGEN_DISABLED"); c2.tick(200)
    return c2.ns.RecentRate({ "c" }) == nil
  end)())
end

-- 10. Time to level and rested
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.rested = 2500
  c.fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 10 do c.xpKill("Mob", 100); c.tick(60) end
  local ttl = ns.TimeToLevel()
  -- 1000 XP in 600s = 6000/hr; 5000 - 2000 left = 3000 -> 0.5h
  check("time to level", ttl and math.abs(ttl - 1800) < 1, ttl)
  check("rested shown", ns.Rested() == 2500)
  c.level = 60; c.effectiveMax = true
  c.tick(1)
  check("max level: no ttl/rested", ns.TimeToLevel() == nil and ns.Rested() == nil)
  local text = c.cellText()
  check("max level hides XP row", not text:find("To level") and not text:find("| XP |"))
end

-- 11. History, reset, per-character session, migration
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.fire("PLAYER_REGEN_DISABLED")
  c.gainMoney(20000); c.tick(120)
  c.slash("reset")
  check("reset archived", #ns.DB.history == 1 and ns.DB.history[1].zone == "Westfall"
    and ns.DB.history[1].char == "Tavlius")
  check("fresh session", ns.Elapsed() == 0 and not ns.S.started)
  c.slash("reset")
  check("empty session not archived", #ns.DB.history == 1)
  c.slash("history")
  local found = false
  for _, p in ipairs(c.printed) do if p:find("1%. .*Westfall") and p:find("gold/hr") then found = true end end
  check("history lists session", found)
  for _ = 1, ns.HISTORY_MAX + 2 do
    c.fire("PLAYER_REGEN_DISABLED"); c.tick(61); c.slash("reset")
  end
  check("history capped at HISTORY_MAX", #ns.DB.history == ns.HISTORY_MAX, #ns.DB.history)

  -- reload keeps session
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(777); c.tick(100)
  local saved = c.saved()
  local c2 = H.boot({ saved = saved, gap = 3600 })  -- logged out for an hour
  c2.login()
  check("session survives reload", c2.ns.Total({ "c" }) == 777 and c2.ns.S.started)
  local continuing = false
  for _, p in ipairs(c2.printed) do if p:find("continuing session") then continuing = true end end
  check("login notice about continuing session", continuing)

  -- alt: separate character DB, shared account DB
  local c3 = H.boot({ saved = { db = saved.db, char = nil } })
  c3.login()
  check("alt gets its own session", c3.ns.Total({ "c" }) == 0 and #c3.ns.DB.history == ns.HISTORY_MAX)
end

do
  -- v1 saved data migrates into history
  local v1 = { shown = true, session = { started = true, elapsed = 3600, xpKills = 50, corpses = 60,
    xp = 9000, questXP = 1000, coin = 20000, questCoin = 0, lootValue = 5000, mobs = {}, items = {} } }
  local c = H.boot({ saved = { db = v1 } })
  c.login()
  local ns = c.ns
  check("v1 migrated to history", #ns.DB.history == 1 and ns.DB.history[1].kills == 60
    and ns.DB.history[1].xp == 8000 and ns.DB.history[1].note == "v1")
  check("v1 session removed", ns.DB.session == nil)
  local msg = false
  for _, p in ipairs(c.printed) do if p:find("updated from v1") then msg = true end end
  check("migration notice", msg)
  c.slash("history")
  noErrors(c, "migration")
end

-- 12. Corpse memory survives reload; pruned later
do
  local c = H.boot()
  c.login()
  c.corpse("Creature-0-1-2-3-100-Z")
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  c2.corpse("Creature-0-1-2-3-100-Z")
  check("corpse not double counted after reload", c2.ns.Total({ "k" }) == 1)
  c2.tick(1000)
  check("old corpse GUIDs pruned", c2.ns.S.seen["Creature-0-1-2-3-100-Z"] == nil)
end

-- 13. Reports and channels
do
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.item(2589, "Linen Cloth", 13)
  c.xpKill("Defias Thug", 120); c.lootMsg(2589, "Linen Cloth", 2); c.gainMoney(500); c.tick(120)
  c.slash("report")
  local full = table.concat(c.printed, "\n")
  check("full report has kills/top mobs/loot", full:find("Kills: 1 %(") and full:find("Top mobs: Defias Thug x1")
    and full:find("Top loot: Linen Cloth x2"))
  c.slash("report party")
  check("party not in group -> local report", #c.sent == 0)
  c.inGroup = true
  c.slash("report party")
  check("party report is 2 lines", #c.sent == 2 and c.sent[1].ch == "PARTY")
  check("chat lines have no color codes", not c.sent[1].msg:find("|c") and not c.sent[2].msg:find("|r"))
  c.slash("report w Mirel")
  check("whisper keeps name case", c.sent[3].ch == "WHISPER" and c.sent[3].target == "Mirel")
  c.slash("report w")
  check("whisper without name refused", #c.sent == 4)
  c.slash("report bogus")
  local unknown = false
  for _, p in ipairs(c.printed) do if p:find("unknown channel") then unknown = true end end
  check("unknown channel message", unknown and #c.sent == 4)
  c.chatFails = true
  c.slash("report guild")
  local failMsg = false
  for _, p in ipairs(c.printed) do if p:find("couldn't send") then failMsg = true end end
  check("send failure reported", failMsg)
  c.slash("nonsense")
  local unk = false
  for _, p in ipairs(c.printed) do if p:find("unknown command") then unk = true end end
  check("unknown command", unk)
  noErrors(c, "report")
end

-- 14. Duo sync
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED")
  c.gainMoney(30000)
  c.tick(28)  -- login tick + 28 = 29 ticks
  check("no send before 30s", #c.addonSent == 0)
  c.tick(2)
  check("sends every 30s", #c.addonSent == 1 and c.addonSent[1].prefix == "VulcanGrindWatch")
  c.addonResult = 9; c.tick(30)  -- send refused (throttled / restricted)
  check("refused send not counted", #c.addonSent == 1)
  c.addonResult = 0; c.tick(1)
  check("refused send retried next second", #c.addonSent == 2, #c.addonSent)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|7200|100|50000|200000|160000|500000", "PARTY", "Mirel-Realm")
  check("partner stored", ns.partners.Mirel and ns.partners.Mirel.coin == 200000
    and ns.partners.Mirel.lootAH == 500000)
  check("newcomer not answered inside the 5s send gap", #c.addonSent == 2, #c.addonSent)
  c.tick(5)
  check("newcomer answered once the gap passes", #c.addonSent == 3, #c.addonSent)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|10|1|1|1|1|1", "PARTY", "Tavlius-Realm")
  check("own echo ignored", ns.partners.Tavlius == nil)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "garbage", "PARTY", "Bob")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "9|1|1|1|1|1|1", "PARTY", "Bob")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "1|3600|100|50000|360000", "PARTY", "Bob")  -- old protocol
  c.fire("CHAT_MSG_ADDON", "Other", "1|1|1|1|1", "PARTY", "Bob")
  check("bad/foreign messages ignored", ns.partners.Bob == nil)
  local text = c.cellText()
  check("partner row shown", text:find("Mirel") and text:find("Duo gold"), text)
  -- 2h tracked: totals and rates differ, so each column is really checked
  check("partner total 36g, rate 18g/hr (vendor)", text:find("Mirel | 36g 0s | 18g 0s"), text)
  ns.DB.priceSource = "auction"; c.tick(1)
  check("partner valued with my AH setting: 70g, 35g/hr", c.cellText():find("Mirel | 70g 0s | 35g 0s"), c.cellText())
  ns.DB.priceSource = "vendor"
  c.tick(130)
  check("stale partner hidden", not c.cellText():find("Mirel"))
  c.inGroup = false; c.fire("GROUP_ROSTER_UPDATE")
  check("leaving group clears partners", next(ns.partners) == nil)
  c.inGroup = true
  local before = #c.addonSent
  c.slash("reset")
  check("reset broadcasts immediately", #c.addonSent == before + 1)
  c.slash("sync")
  check("sync off", ns.DB.sync == false)
  before = #c.addonSent
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(60)
  check("sync off sends nothing", #c.addonSent == before)
  noErrors(c, "sync")
end

-- 15. UI: rows, auto width, hint, scale, toggle, compartment
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.fire("PLAYER_REGEN_DISABLED")
  c.tick(1)
  local smallWidth = c.ui.w
  c.gainMoney(123456789); c.tick(100)
  local text = c.cellText()
  check("headers shown", text:find("Total") and text:find("/hr") and text:find("Last 15m"))
  check("gold value shown", text:find("12,345g 67s"), text)
  check("frame widened for big numbers", c.ui.w > smallWidth, c.ui.w .. " vs " .. smallWidth)
  check("status running", text:find("Running"))
  local hBefore = c.ui.h
  c.slash("lock")
  check("hint hidden when locked", c.ui.h < hBefore)
  c.slash("scale 1.5")
  check("scale applied", c.ui.scale == 1.5 and ns.DB.scale == 1.5)
  c.slash("scale 9")
  check("bad scale rejected", ns.DB.scale == 1.5)
  c.slash("")
  check("toggle hides", not c.ui.shown and ns.DB.shown == false)
  VulcanGrindWatch_OnAddonCompartmentClick()
  check("compartment toggles", c.ui.shown)
  c.ui.scripts.OnMouseUp(c.ui, "RightButton")
  check("right-click pauses", ns.S.paused)
  c.ui.scripts.OnDragStop(c.ui)
  check("position saved", ns.DB.point[1] == "TOP")
  noErrors(c, "ui")
end

-- 16. Secret values and unknown events never error
do
  local c = H.boot({ secretAware = true, unknownEvents = { GUILDBANKFRAME_OPENED = true, ITEM_DATA_LOAD_RESULT = true } })
  c.login()
  local ns = c.ns
  c.fire("PLAYER_REGEN_DISABLED")
  c.secret.money = true; c.gainMoney(100); c.secret.money = false
  c.secret.xp = true; c.fire("PLAYER_XP_UPDATE"); c.secret.xp = false
  c.fire("CHAT_MSG_LOOT", H.SECRET)
  c.fire("CHAT_MSG_COMBAT_XP_GAIN", H.SECRET)
  c.fire("CHAT_MSG_LOOT", nil)
  c.loot = { { H.SECRET, 1 } }; c.fire("LOOT_OPENED")
  c.fire("CHAT_MSG_ADDON", H.SECRET, H.SECRET, "PARTY", H.SECRET)
  c.tick(5)
  check("secret values ignored", ns.Total({ "c" }) == 0 and ns.Total({ "k" }) == 0)
  noErrors(c, "secrets")
end

-- 17. A handler error is reported once, not every second
do
  local c = H.boot()
  c.login()
  c.ns.On("TEST_EVENT", function() error("boom") end)
  for _ = 1, 5 do c.fire("TEST_EVENT") end
  check("error printed once", #c.errors() == 1, #c.errors())
end

-- 18. Help and welcome
do
  local c = H.boot()
  c.login()
  local welcome = false
  for _, p in ipairs(c.printed) do if p:find("/gw help") then welcome = true end end
  check("first-run welcome", welcome)
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  welcome = false
  for _, p in ipairs(c2.printed) do if p:find("/gw help") then welcome = true end end
  check("welcome only once", not welcome)
end

-- 19. Audit 1 regressions
do
  -- login/reload in town doesn't add clock time to a running session
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(200)
  local saved = c.saved()
  local c2 = H.boot({ saved = saved })
  c2.login()
  local e = c2.ns.Elapsed()
  c2.tick(120)
  check("reload doesn't run the clock", c2.ns.Elapsed() == e and c2.ns.ClockState() == "idle", c2.ns.ClockState())
  c2.fire("PLAYER_REGEN_DISABLED"); c2.tick(5)
  check("activity after reload resumes", c2.ns.Elapsed() > e)
  local notice = false
  for _, p in ipairs(c2.printed) do if p:find("continuing session") then notice = true end end
  check("no continuing notice on quick reload", not notice)
  -- coming back from AFK isn't activity
  c2.afk = true; c2.fire("PLAYER_FLAGS_CHANGED", "player"); c2.tick(400)
  c2.afk = false; c2.fire("PLAYER_FLAGS_CHANGED", "player")
  check("back from AFK stays idle until activity", c2.ns.ClockState() == "idle")
end

do
  -- early rates hidden until 3 minutes
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(61)
  check("no rate at 61s", c.ns.SessionRate({ "c" }) == nil)
  c.tick(120)
  check("rate at 181s", c.ns.SessionRate({ "c" }) ~= nil)
end

do
  -- quest reward right after closing a vendor: not counted, not subtracted
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(1000)
  c.fire("MERCHANT_SHOW"); c.fire("MERCHANT_CLOSED")
  c.fire("QUEST_TURNED_IN", 1, 0, 5000); c.gainMoney(5000)
  check("quest gold in vendor grace leaves coin intact", c.ns.Total({ "c" }) == 1000, c.ns.Total({ "c" }))
end

do
  -- LOOT_READY + LOOT_OPENED for the same corpse = one kill
  local c = H.boot()
  c.login()
  c.loot = { { "Creature-0-1-2-3-100-Q", 1 } }
  c.fire("LOOT_READY"); c.fire("LOOT_OPENED")
  check("loot ready + opened counted once", c.ns.Total({ "k" }) == 1)
end

-- 20. Audit 2 regressions
do
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.fire("TRADE_SHOW"); c.gainMoney(-5000); c.fire("TRADE_CLOSED")
  c.fire("MAIL_SHOW"); c.gainMoney(-3000); c.fire("MAIL_CLOSED")
  check("trade/mail gold not 'spent'", c.ns.S.spent == 0, c.ns.S.spent)
  c.fire("MERCHANT_SHOW"); c.gainMoney(-700); c.fire("MERCHANT_CLOSED")
  c.tick(5); c.gainMoney(-50)  -- flight path
  check("merchant + world spending counted", c.ns.S.spent == 750, c.ns.S.spent)
  -- clam opened at the mailbox must not unblock mail gold
  c.fire("MAIL_SHOW")
  c.loot = { { "Item-0-0-0-0-0-CLAM", 1 } }; c.fire("LOOT_READY")
  c.gainMoney(9999)
  check("container loot keeps mail block", c.ns.Total({ "c" }) == 0, c.ns.Total({ "c" }))
  -- corpse loot clears a stuck blocker
  c.corpse("Creature-0-1-2-3-100-STUCK"); c.gainMoney(100)
  check("corpse loot clears stuck block", c.ns.Total({ "c" }) == 100, c.ns.Total({ "c" }))
  for _ = 1, 6 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(1000); c.tick(60) end
  c.slash("report")
  local found = false
  for _, p in ipairs(c.printed) do if p:find("last 15m %d") then found = true end end
  check("report shows a real 15m rate", found)
  noErrors(c, "audit2")
end

-- 21. Audit 3 regressions
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(40000); c.tick(200)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|3600|100|50000|200000|160000|500000", "PARTY", "Mirel")
  c.tick(1)
  local text = c.cellText()
  -- my 4g + Mirel's 36g = 40g total
  check("duo total shown", text:find("Duo gold | 40g 0s"), text)
  c.slash("sync")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|3600|100|50000|200000|160000|500000", "PARTY", "Mirel")
  check("sync off ignores incoming", next(ns.partners) == nil)
  c.ui.scripts.OnEnter(c.ui)
  check("tooltip explains status", c.tooltip.shown and c.tooltip[2] and c.tooltip[2]:find("Counting"), c.tooltip[2])
  c.ui.scripts.OnLeave(c.ui)
  check("tooltip hides", c.tooltip.shown == false)
  noErrors(c, "audit3")
end
do
  local c = H.boot({ prefixResult = 3 })  -- e.g. too many prefixes
  c.login()
  c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(60)
  check("failed prefix registration -> no sends", #c.addonSent == 0)
end

-- 22. Audit 4 regressions
do
  -- client reports the retail cap (90) but you're 60
  local c = H.boot()
  c.maxLevel = 90; c.level = 60; c.effectiveMax = true; c.login()
  check("effective max level detected at 60", c.ns.AtMaxLevel())
  local c0 = H.boot({ noEffectiveMax = true })
  c0.maxLevel = 60; c0.level = 60; c0.login()
  check("level == GetMaxPlayerLevel detected", c0.ns.AtMaxLevel())
  local c2 = H.boot({ noEffectiveMax = true })
  c2.maxLevel = 90; c2.level = 60; c2.xpMax = 0; c2.login()
  check("empty XP bar = max level", c2.ns.AtMaxLevel())
  local c3 = H.boot({ noEffectiveMax = true })
  c3.maxLevel = 90; c3.level = 30; c3.xpDisabled = true; c3.login()
  check("XP turned off = treat as max", c3.ns.AtMaxLevel())
  local c4 = H.boot({ noEffectiveMax = true })
  c4.maxLevel = 90; c4.level = 30; c4.login()
  check("normal leveling not max", not c4.ns.AtMaxLevel())
end
do
  local c = H.boot({ secretAware = true })
  c.login()
  c.fire("PLAYER_FLAGS_CHANGED", H.SECRET)
  c.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", H.SECRET)
  c.fire("ITEM_DATA_LOAD_RESULT", H.SECRET, H.SECRET)
  c.fire("ADDON_LOADED", H.SECRET)
  noErrors(c, "secret event args")
  -- own echo filtered even if the name read turns secret later
  c.inGroup = true
  c.name = H.SECRET
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|10|1|1|1|1|1", "PARTY", "Tavlius")
  check("own echo filtered via cached name", c.ns.partners.Tavlius == nil)
end

-- 23. Audit 6: a long fight with no gains never goes idle
do
  local c = H.boot()
  c.login()
  c.combat = true; c.fire("PLAYER_REGEN_DISABLED")
  local e = c.ns.Elapsed()
  c.tick(480)  -- 8-minute elite fight
  check("long fight keeps clock running", math.abs(c.ns.Elapsed() - e - 480) < 1e-6 and c.ns.ClockState() == "running",
    c.ns.Elapsed() - e)
  c.combat = false
  c.tick(400)
  check("idle again after combat ends", c.ns.ClockState() == "idle")
end

-- 24. Audit 9 (independent review) regressions
do
  -- quest turn-ins in town don't start the clock
  local c = H.boot()
  c.login()
  c.fire("QUEST_TURNED_IN", 1, 500, 2000); c.gainMoney(2000); c.xp = c.xp + 500; c.fire("PLAYER_XP_UPDATE")
  c.tick(120)
  check("quest in town: clock still waiting", c.ns.ClockState() == "waiting" and c.ns.Elapsed() == 0)
  check("quest in town: nothing counted", c.ns.S.totals.c == 0 and c.ns.S.totals.x == 0)
  -- reward event AFTER the gain, and BEFORE it: both net to zero, never negative
  c.fire("PLAYER_REGEN_DISABLED")
  c.gainMoney(3000); c.fire("QUEST_TURNED_IN", 2, 0, 3000)
  check("reward after gain undone", c.ns.S.totals.c == 0, c.ns.S.totals.c)
  c.fire("QUEST_TURNED_IN", 3, 0, 4000); c.gainMoney(4000)
  check("reward before gain absorbed", c.ns.S.totals.c == 0, c.ns.S.totals.c)
  c.fire("QUEST_TURNED_IN", 4, 0, 9000)  -- coin never arrives
  c.tick(5); c.gainMoney(800)
  check("orphan reward can't swallow later coin", c.ns.S.totals.c == 800, c.ns.S.totals.c)
  noErrors(c, "quest order")
end
do
  -- pickpocket (living target) and skinning someone else's corpse aren't kills
  local c = H.boot()
  c.login()
  local ns = c.ns
  c.units.target = { guid = "Creature-0-1-2-3-100-PP", name = "Defias Thug", dead = false }
  c.cast(921)  -- Pick Pocket
  c.corpse("Creature-0-1-2-3-100-PP")
  check("pickpocket is not a kill", ns.Total({ "k" }) == 0)
  c.units.target.dead = true
  c.tick(3)
  c.xpKill("Defias Thug", 100)
  c.corpse("Creature-0-1-2-3-100-PP")
  check("same mob looted after death = 1 kill", ns.Total({ "k" }) == 1, ns.Total({ "k" }))
  c.units.target = { guid = "Creature-0-1-2-3-100-SK", name = "Boar", dead = true }
  c.cast(8613)  -- Skinning
  c.corpse("Creature-0-1-2-3-100-SK")
  check("skinning another's kill is not a kill", ns.Total({ "k" }) == 1, ns.Total({ "k" }))
  c.tick(3)
  c.corpse("Creature-0-1-2-3-100-SK")
  check("skinned corpse remembered", ns.Total({ "k" }) == 1)
  c.units.target = nil
  c.cast(116); c.corpse("Creature-0-1-2-3-100-INST")  -- Frostbolt kill, looted at once
  check("combat spell before looting still counts", ns.Total({ "k" }) == 2, ns.Total({ "k" }))
  noErrors(c, "pickpocket/skinning")
end
do
  -- matching by mob name: Mirel looted his XP kill, I loot a grey mob
  local c = H.boot()
  c.login()
  c.xpKill("Murloc Forager", 100)                    -- Mirel's kill, he loots it
  c.units.mouseover = { guid = "Creature-0-1-2-3-100-G", name = "Grey Crab", dead = true }
  c.corpse("Creature-0-1-2-3-100-G")
  check("different mob name = separate kill", c.ns.Total({ "k" }) == 2, c.ns.Total({ "k" }))
  c.units.mouseover = { guid = "Creature-0-1-2-3-100-M", name = "Murloc Forager", dead = true }
  c.corpse("Creature-0-1-2-3-100-M")
  check("same mob name matches the XP kill", c.ns.Total({ "k" }) == 2, c.ns.Total({ "k" }))
end
do
  -- dead keep-alive is capped
  local c = H.boot()
  c.login()
  c.slash("afk")  -- AFK pause off
  c.fire("PLAYER_REGEN_DISABLED")
  c.dead = true
  local e = c.ns.Elapsed()
  c.tick(3600)
  local gained = c.ns.Elapsed() - e
  check("dead for an hour counts at most 10 min (+1 kept)", gained <= 660 + 1 and gained >= 600, gained)
end
do
  -- idle 0: a reload still waits for activity
  local c = H.boot()
  c.login()
  c.slash("idle 0")
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(100)
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  local e = c2.ns.Elapsed()
  c2.tick(120)
  check("idle 0 + reload: clock waits", c2.ns.Elapsed() == e, c2.ns.Elapsed() - e)
end
do
  -- logout mid-farm keeps the last minute
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(200)
  local saved = c.saved()
  check("logout keeps last 60s of provisional time", math.abs(saved.char.session.elapsed - 60) < 1e-6,
    saved.char.session.elapsed)
end
do
  -- scale keeps the window in place on screen
  local c = H.boot()
  c.login()
  local p = c.ns.DB.point
  local sx, sy = p[3] * c.ns.DB.scale, p[4] * c.ns.DB.scale
  c.slash("scale 2")
  check("scale keeps screen position", math.abs(c.ns.DB.point[3] * 2 - sx) < 1e-9 and math.abs(c.ns.DB.point[4] * 2 - sy) < 1e-9)
end
do
  -- duo rate waits for both rates
  local c = H.boot()
  c.login()
  c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(10)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|7200|1|1|200000|160000|500000", "PARTY", "Mirel")
  check("duo rate '--' while mine is unavailable", c.cellText():find("Duo gold | 36g 0s | %-%-"), c.cellText())
end
do
  local c = H.boot()
  c.login()
  check("Short rounding: 999960 -> 1.0m", c.ns.Short(999960) == "1.0m", c.ns.Short(999960))
  check("Short rounding: 9999.6 -> 10.0k", c.ns.Short(9999.6) == "10.0k", c.ns.Short(9999.6))
  check("Short: 9999 stays", c.ns.Short(9999) == "9,999", c.ns.Short(9999))
end
do
  -- reset keeps corpse memory
  local c = H.boot()
  c.login()
  c.corpse("Creature-0-1-2-3-100-R")
  c.slash("reset")
  c.corpse("Creature-0-1-2-3-100-R")
  check("re-opened corpse after reset isn't a kill", c.ns.Total({ "k" }) == 0)
end
do
  -- enabling AFK pause while already AFK applies at once
  local c = H.boot()
  c.login()
  c.slash("afk")  -- off
  c.afk = true; c.fire("PLAYER_FLAGS_CHANGED", "player")
  check("afk pause off: not paused", c.ns.ClockState() ~= "afk")
  c.slash("afk")  -- on, while AFK
  check("afk pause on while AFK applies", c.ns.ClockState() == "afk")
end
do
  -- every secret-guarded read survives, and money recovers after a secret read
  local c = H.boot({ secretAware = true })
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  for _, k in ipairs({ "dead", "combat", "level", "rested", "xpMax", "guid" }) do c.secret[k] = true end
  c.units.target = { guid = "Creature-0-1-2-3-100-S", name = "X", dead = true }
  c.corpse("Creature-0-1-2-3-100-S")
  c.tick(5)
  c.slash("report")
  for k in pairs(c.secret) do c.secret[k] = false end
  noErrors(c, "all secrets")
  c.secret.money = true; c.gainMoney(500); c.secret.money = false
  c.gainMoney(100)
  check("money missed during a secret read is recovered", c.ns.S.totals.c == 600, c.ns.S.totals.c)
end

-- 25. Audit 10 regressions
do
  -- level-60 mage: Frostbolt kills looted right away all count
  local c = H.boot()
  c.level = 60; c.effectiveMax = true; c.login()
  for i = 1, 5 do c.cast(116); c.corpse("Creature-0-1-2-3-100-F" .. i); c.tick(3) end
  check("cast-time combat spells don't hide kills", c.ns.Total({ "k" }) == 5, c.ns.Total({ "k" }))
  -- skinning matched by name on a different rank/build ID
  c.cast(194174); c.corpse("Creature-0-1-2-3-100-SKR")
  check("skinning recognized by name on another spell ID", c.ns.Total({ "k" }) == 5, c.ns.Total({ "k" }))
  check("herb gathering recognized by name too", c.ns.ClassifySpell(265819) == "gather")
  check("combat spell not classified", c.ns.ClassifySpell(116) == nil)
  -- pickpocket with no target or mouseover
  c.tick(3)
  c.units = {}
  c.cast(921); c.corpse("Creature-0-1-2-3-100-PPX")
  check("pickpocket without target isn't a kill", c.ns.Total({ "k" }) == 5, c.ns.Total({ "k" }))
  noErrors(c, "spell classification")
end
do
  -- a break must not shrink the rolling rate
  local c = H.boot()
  c.login()
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  local before = c.ns.RecentRate({ "c" })
  c.tick(400)  -- break: prune runs during it
  local after = c.ns.RecentRate({ "c" })
  check("rolling rate unchanged by a break", math.abs(after - before) < 1, string.format("%.0f -> %.0f", before, after))
end
do
  -- quest matching by exact amount with an unrelated gain in between
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.gainMoney(5000)       -- quest gold arrives
  c.gainMoney(40)         -- corpse coin
  c.fire("QUEST_TURNED_IN", 1, 0, 5000)
  check("quest gold removed, corpse coin kept", c.ns.S.totals.c == 40, c.ns.S.totals.c)
  c.fire("QUEST_TURNED_IN", 2, 0, 9000)  -- orphan reward
  c.gainMoney(800)        -- unrelated coin within 3s
  check("orphan credit doesn't swallow other coin", c.ns.S.totals.c == 840, c.ns.S.totals.c)
  c.gainMoney(9000)       -- the reward finally lands
  check("late reward still cancelled", c.ns.S.totals.c == 840, c.ns.S.totals.c)
  -- reset clears pending matches
  c.gainMoney(700)
  c.slash("reset")
  c.fire("QUEST_TURNED_IN", 3, 0, 700)
  check("reset clears quest matching", c.ns.S.totals.c == 0 and c.ns.S.totals.c >= 0, c.ns.S.totals.c)
end
do
  -- a clam opened in town after a reload doesn't start the clock
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(100)
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  c2.item(5523, "Small Barnacled Clam", 0)
  c2.loot = { { "Item-0-0-0-0-0-CLAM", 1 } }; c2.fire("LOOT_READY")
  c2.lootMsg(5523, "Small Barnacled Clam")
  local e = c2.ns.Elapsed()
  c2.tick(240)
  check("clam in town keeps clock idle", c2.ns.Elapsed() == e, c2.ns.Elapsed() - e)
  -- herbing (a world node) is activity
  c2.loot = { { "GameObject-0-0-0-0-0-HERB", 1 } }; c2.fire("LOOT_READY")
  c2.tick(10)
  check("herb node wakes the clock", c2.ns.ClockState() == "running")
end
do
  -- dying again while paused gets a fresh corpse-run allowance
  local c = H.boot()
  c.login()
  c.slash("afk")
  c.fire("PLAYER_REGEN_DISABLED")
  c.dead = true; c.tick(500); c.dead = false; c.tick(1)
  c.slash("pause")
  c.dead = true; c.tick(5)
  c.slash("resume")
  local e = c.ns.Elapsed()
  c.tick(400)
  check("fresh death after pause: corpse run counts", c.ns.Elapsed() - e >= 399, c.ns.Elapsed() - e)
end
do
  local c = H.boot()
  c.login()
  c.ui.scripts.OnEnter(c.ui)
  check("waiting tooltip doesn't promise coin starts clock", not c.tooltip[2]:find("coin"), c.tooltip[2])
  local readme = io.open(assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh") .. "README.md"):read("*a")
  check("README: AFK wording matches code", readme:find("Typing /afk stops the clock at once"))
end

-- 26. Audit 11 regressions
do
  -- skin A, then loot boar B 1.2s later on an AoE pull: B still counts
  local c = H.boot()
  c.level = 60; c.effectiveMax = true; c.login()
  c.corpse("Creature-0-1-2-3-100-BA")
  c.tick(2); c.cast(8613); c.corpse("Creature-0-1-2-3-100-BA")  -- skinning takes a moment
  c.corpse("Creature-0-1-2-3-100-BB")                           -- boar B right away
  check("loot after a skin window closes counts", c.ns.Total({ "k" }) == 2, c.ns.Total({ "k" }))
  c.tick(2)
  c.cast(921); c.corpse("Creature-0-1-2-3-100-PPZ")
  c.corpse("Creature-0-1-2-3-100-DEAD")
  check("dead corpse looted right after a pickpocket counts", c.ns.Total({ "k" }) == 3, c.ns.Total({ "k" }))
end
do
  -- reward folded into one combined update
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.xp = c.xp + 1080; c.fire("PLAYER_XP_UPDATE")     -- 80 kill XP + 1000 quest XP in one update
  c.fire("QUEST_TURNED_IN", 1, 1000, 0)
  check("combined XP update: quest part removed", c.ns.S.totals.x == 80, c.ns.S.totals.x)
  c.fire("QUEST_TURNED_IN", 2, 0, 5000)
  c.gainMoney(5040)                                   -- reward + corpse coin together, after the event
  check("combined money update: quest part absorbed", c.ns.S.totals.c == 40, c.ns.S.totals.c)
  c.tick(5)
  c.gainMoney(30); c.fire("QUEST_TURNED_IN", 3, 0, 5000)  -- reward larger than any recent gain
  check("no oversized subtraction", c.ns.S.totals.c == 70, c.ns.S.totals.c)
end

-- 27. Audit 12 regressions
do
  -- two quests turned in before one combined update
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.fire("QUEST_TURNED_IN", 1, 1000, 3000)
  c.fire("QUEST_TURNED_IN", 2, 1000, 3000)
  c.xp = c.xp + 2000; c.fire("PLAYER_XP_UPDATE")
  c.gainMoney(6000)
  check("two credits cancel one combined XP update", c.ns.S.totals.x == 0, c.ns.S.totals.x)
  check("two credits cancel one combined money update", c.ns.S.totals.c == 0, c.ns.S.totals.c)
  c.tick(1)
  c.xp = c.xp + 1500; c.fire("PLAYER_XP_UPDATE")
  check("later kill XP keeps full value", c.ns.S.totals.x == 1500, c.ns.S.totals.x)
end
do
  -- a late LOOT_CLOSED from an older window doesn't cancel the pickpocket
  local c = H.boot()
  c.login()
  c.corpse("Creature-0-1-2-3-100-K1", true)  -- real kill, window still open
  c.tick(2)
  c.cast(921)                              -- Pick Pocket (sapped mob, no target)
  c.fire("LOOT_CLOSED")                    -- old window closes late
  c.corpse("Creature-0-1-2-3-100-SAP", true)  -- the pickpocket window
  check("late close doesn't turn a pickpocket into a kill", c.ns.Total({ "k" }) == 1, c.ns.Total({ "k" }))
  c.fire("LOOT_CLOSED")
  c.tick(2)
  c.corpse("Creature-0-1-2-3-100-K2")
  check("next real corpse counts", c.ns.Total({ "k" }) == 2, c.ns.Total({ "k" }))
end
do
  -- an orphan credit only ever trims a gain by its own size
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.fire("QUEST_TURNED_IN", 1, 0, 5000)
  c.tick(4)               -- credit expires (3s)
  c.gainMoney(7000)
  check("expired credit doesn't touch later coin", c.ns.S.totals.c == 7000, c.ns.S.totals.c)
end

-- 28. Audit 14 regressions and strengthened tests
do
  -- late LOOT_CLOSED orderings (repro C and E)
  local c = H.boot()
  c.login()
  c.cast(921)
  c.loot = { { "Creature-0-1-2-3-100-PC", 1 } }
  c.fire("LOOT_READY"); c.fire("LOOT_CLOSED"); c.fire("LOOT_OPENED")
  check("pickpocket: READY, late CLOSE, OPENED = no kill", c.ns.Total({ "k" }) == 0, c.ns.Total({ "k" }))
  c.tick(3)
  c.corpse("Creature-0-1-2-3-100-EA", true)        -- loot A, window open
  c.tick(2); c.cast(8613)
  c.loot = { { "Creature-0-1-2-3-100-EA", 1 } }; c.fire("LOOT_READY")  -- skin A
  c.tick(1)
  c.loot = { { "Creature-0-1-2-3-100-EB", 1 } }; c.fire("LOOT_READY")  -- loot B
  c.fire("LOOT_CLOSED")                              -- A's close arrives late
  c.fire("LOOT_OPENED")
  check("boar B after skinning A still counts", c.ns.Total({ "k" }) == 2, c.ns.Total({ "k" }))
end
do
  -- trade gold leaving just after the window closes isn't "spent"
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.fire("TRADE_SHOW"); c.fire("TRADE_CLOSED"); c.gainMoney(-50000)
  check("trade gold in grace not spent", c.ns.S.spent == 0, c.ns.S.spent)
  c.fire("MAIL_SHOW"); c.fire("MAIL_CLOSED"); c.fire("MERCHANT_SHOW"); c.gainMoney(-300)
  check("merchant purchase right after mailing is spent", c.ns.S.spent == 300, c.ns.S.spent)
end
do
  -- history uses the same 3-minute rule as the live window
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(50000); c.tick(125)
  c.slash("reset")
  c.slash("history")
  local line
  for _, p in ipairs(c.printed) do if p:find("^.-1%. ") then line = p end end
  check("short session: history rates are --", line and line:find("%-%- gold/hr") and line:find("%-%- kills/hr"), line)
end
do
  -- quest turned in at the end of the vendor grace; gold lands after it
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.fire("MERCHANT_SHOW"); c.fire("MERCHANT_CLOSED")
  c.now = c.now + 2.9; c.fire("QUEST_TURNED_IN", 1, 0, 5000)
  c.now = c.now + 0.2; c.gainMoney(5000)
  check("quest gold after grace end isn't farm coin", c.ns.S.totals.c == 0, c.ns.S.totals.c)
  check("blocked reward not booked as quest coin", c.ns.S.questCoin == 0, c.ns.S.questCoin)
  c.now = c.now + 3; c.gainMoney(250)
  check("coin after the stretched block counts", c.ns.S.totals.c == 250, c.ns.S.totals.c)
end
do
  -- manual /afk drops the time since the last activity
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(100)
  c.fire("PLAYER_REGEN_DISABLED")       -- last activity: elapsed is now committed
  local atActivity = c.ns.Elapsed()
  c.tick(120)
  c.afk = true; c.fire("PLAYER_FLAGS_CHANGED", "player")
  check("/afk drops time since last activity", math.abs(c.ns.Elapsed() - atActivity) < 1e-6, c.ns.Elapsed() - atActivity)
end
do
  -- resume after a pause longer than the idle cutoff runs right away
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  c.slash("pause"); c.tick(900); c.slash("resume")
  local e = c.ns.Elapsed(); c.tick(10)
  check("resume after long pause runs", c.ns.ClockState() == "running" and math.abs(c.ns.Elapsed() - e - 10) < 1e-6)
end
do
  -- rolling coverage at an elapsed that isn't a multiple of 60
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  for t = 1, 1000 do
    c.tick(1)
    if t % 10 == 0 then c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(100) end
  end
  -- elapsed 1000: window starts at bucket ceil(100/60) = 2 (t >= 120), covering 880s
  local expected = 89 * 100 / 880 * 3600
  local got = c.ns.RecentRate({ "c" })
  check("rolling rate exact at odd elapsed", math.abs(got - expected) < 1e-6, got .. " vs " .. expected)
end
do
  -- loading-screen gaps (10s+) aren't counted
  local c = H.boot()
  c.login()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(1)
  local e = c.ns.Elapsed()
  c.tick(1, 15)
  check("15s gap not counted", c.ns.Elapsed() == e, c.ns.Elapsed() - e)
end
do
  -- number-first locales
  local c = H.boot({ locale = {
    single = "Beute: %s.", multiple = "Beute: %2$dx %1$s.", xp = "Du erhältst %2$d Erfahrung, %1$s stirbt." } })
  c.login()
  c.item(2589, "Leinenstoff", 13)
  c.fire("CHAT_MSG_LOOT", "Beute: 3x |cffffffff|Hitem:2589::::|h[Leinenstoff]|h|r.")
  check("number-first loot quantity", c.ns.S.items[2589] and c.ns.S.items[2589].count == 3)
  c.fire("CHAT_MSG_COMBAT_XP_GAIN", "Du erhältst 120 Erfahrung, Eber stirbt. (+60 Erholungsbonus)")
  check("number-first XP kill counted", c.ns.Total({ "k" }) == 1)
  check("number-first XP keeps the mob name", c.ns.S.mobs["Eber"] == 1, tostring(next(c.ns.S.mobs)))
  c.units.target = { guid = "Creature-0-1-2-3-100-EBER", name = "Eber", dead = true }
  c.corpse("Creature-0-1-2-3-100-EBER")
  check("number-first: looting that mob still 1 kill", c.ns.Total({ "k" }) == 1, c.ns.Total({ "k" }))
  c.fire("CHAT_MSG_COMBAT_XP_GAIN", "Du erhältst 500 Erfahrung.")
  check("number-first: plain XP line isn't a kill", c.ns.Total({ "k" }) == 1, c.ns.Total({ "k" }))
  noErrors(c, "locale")
end

os.exit(H.summary() and 0 or 1)
