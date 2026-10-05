-- GrindWatch: session state, gain tracking, rates, and the event dispatcher.
-- Display-only: it reads what happens and shows rates. It never casts, moves or targets.
local _, ns = ...
local plain = ns.plain

---------------------------------------------------------------------------
-- Tunables
---------------------------------------------------------------------------
ns.BUCKET = 60               -- seconds per bucket for the rolling rate
ns.WINDOW = 900              -- default rolling window ("last 15m"); the live one is ns.RecentWindow()
-- ns.MAX_WINDOW (below): buckets are kept for the longest selectable window, so
-- lengthening it in settings applies at once
ns.MIN_RATE_SECONDS = 180    -- no per-hour rate off less data than this (one pickup = noise)
ns.MIN_ARCHIVE_SECONDS = 60  -- shorter sessions aren't worth keeping in history
ns.MIN_RECENT_SECONDS = 300  -- rolling rate needs 5 minutes of data
ns.KILL_MATCH_SECONDS = 300  -- an XP kill and its corpse loot must be this close
ns.CORPSE_MEMORY_SECONDS = 900
ns.PENDING_MAX_TRIES = 30    -- seconds to wait for item data before giving up
ns.HISTORY_MAX = 50         -- kept for /gw spots; /gw history shows the latest 10
ns.IDLE_KEEP_SECONDS = 60    -- on going idle, keep this much trailing time (loot, drink)
ns.DEAD_KEEPALIVE_SECONDS = 600  -- a corpse run counts as active for at most this long
ns.QUEST_MATCH_SECONDS = 3   -- a quest reward and its XP/money update land this close
ns.GATHER_CAST_SECONDS = 2   -- loot this soon after a cast-time spell is gathering
ns.DB_VERSION = 2

---------------------------------------------------------------------------
-- Saved data
--   VulcanGrindWatchDB      (account): settings + session history
--   VulcanGrindWatchCharDB  (per character): the live session
---------------------------------------------------------------------------
-- Totals fields: k = kills, x = farm XP, c = coin, l = loot at vendor price,
-- la = loot at best price (max of vendor and Auctionator AH price after the 5% cut),
-- r = rested XP consumed (the bonus part of x; drives the rested-aware level ETA).
local DEFAULT_SESSION = {
  started = false, paused = false, elapsed = 0, startedAt = 0, lastSeen = 0,
  totals = { k = 0, x = 0, c = 0, l = 0, la = 0, r = 0 },
  xpKills = 0, lootOnlyKills = 0, corpses = 0,
  questXP = 0, questCoin = 0, spent = 0,
  buckets = {},   -- [bucket index] = { k=, x=, c=, l=, la= }
  minBucket = 0,  -- oldest bucket index with complete data (later for sessions from before 3.1)
  zones = {},     -- [zone name] = active seconds
  mobs = {},      -- [mob name] = XP kills
  items = {},     -- [itemID] = { name, count, value, valueAH }
  unmatched = {}, -- { t = time(), mob = name } for XP kills not yet matched to a corpse
  seen = {},      -- [corpse GUID] = time() first looted
  pending = {},   -- [itemID] = { tries, name, parts = { [bucket] = qty } }: items whose
                  -- data hasn't loaded yet (saved, so a /reload doesn't lose them)
}

-- Adjustable settings (and their defaults) are defined in Settings.lua.
local DEFAULTS = {
  version = ns.DB_VERSION,
  shown = true, welcomed = false,
  debugLog = {},
  customSpells = {},  -- [spellID] = "gather" | "pickpocket", added with /gw spell
  point = { "CENTER", "CENTER", 300, 0 },  -- ns.DEFAULT_POINT
  -- panelPoint: where you last left the settings window (nil = centered)
  history = {},
}

local function CopyDefaults(src, dst)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      CopyDefaults(v, dst[k])
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

for _, def in ipairs(ns.SETTING_DEFS) do DEFAULTS[def.key] = def.default end
ns.DEFAULT_POINT = DEFAULTS.point
ns.MAX_WINDOW = ns.SettingDef("windowMinutes").max * 60
-- Valid anchor names (SetPoint errors on anything else).
ns.ANCHORS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
  BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

function ns.NewSession()
  return CopyDefaults(DEFAULT_SESSION, {})
end

---------------------------------------------------------------------------
-- Internal callbacks (UI and sync listen to these)
---------------------------------------------------------------------------
local callbacks = {}
function ns.Listen(name, fn)
  callbacks[name] = callbacks[name] or {}
  table.insert(callbacks[name], fn)
end
function ns.Fire(name, ...)
  for _, fn in ipairs(callbacks[name] or {}) do fn(...) end
end

---------------------------------------------------------------------------
-- Game event dispatcher (multiple listeners per event, errors reported once)
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}
local errorsShown, errorCount = {}, 0

function ns.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    -- Unknown events throw on some builds; skip them quietly.
    pcall(eventFrame.RegisterEvent, eventFrame, event)
  end
  table.insert(handlers[event], fn)
end

local function ReportError(where, err)
  err = tostring(err)
  if errorsShown[err] or errorCount >= 5 then return end
  errorsShown[err] = true
  errorCount = errorCount + 1
  ns.Print("error in " .. where .. ": " .. err)
end
ns.ReportError = ReportError

eventFrame:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then ReportError(event, err) end
  end
end)

---------------------------------------------------------------------------
-- Clock: committed vs provisional time
--
-- Time since your last activity is "provisional". The next activity (pull, kill,
-- loot, combat, corpse run) commits it. Going idle discards all but the last
-- IDLE_KEEP_SECONDS of it; going AFK discards all of it. That way a break never
-- inflates the clock, while normal gaps between pulls still count.
---------------------------------------------------------------------------
ns.autoPaused = false
local lastActivity = 0
local awaiting = true     -- after login, reload or AFK: wait for real activity
local provisional = 0
local provisionalZones = {}

function ns.Tracking()
  return ns.S ~= nil and not ns.S.paused
end

function ns.Elapsed()
  return ns.S.elapsed + provisional
end

local function Commit()
  local S = ns.S
  if S and provisional > 0 then
    S.elapsed = S.elapsed + provisional
    for zone, t in pairs(provisionalZones) do S.zones[zone] = (S.zones[zone] or 0) + t end
  end
  provisional = 0
  wipe(provisionalZones)
end

-- Keep at most `keep` seconds of provisional time, drop the rest.
local function Discard(keep)
  keep = keep or 0
  if keep > 0 and provisional > keep then
    local ratio = keep / provisional
    for zone, t in pairs(provisionalZones) do provisionalZones[zone] = t * ratio end
    provisional = keep
  end
  if keep > 0 then Commit() end
  provisional = 0
  wipe(provisionalZones)
end
ns.CommitTime = Commit
ns.DiscardTime = Discard

-- Real farming activity: starts the clock if it's waiting and commits time.
function ns.Touch()
  lastActivity = GetTime()
  awaiting = false
  local S = ns.S
  if S and not S.started and not S.paused then
    S.started = true
    S.startedAt = time()
  end
  Commit()
end

-- Clears "idle" without starting the clock (e.g. on /gw resume).
function ns.KeepAlive()
  lastActivity = GetTime()
  awaiting = false
end

function ns.SetAwaiting()
  awaiting = true
end

function ns.IsIdle()
  if awaiting then return true end
  local limit = (ns.DB and ns.DB.idleMinutes or 0) * 60
  if limit <= 0 then return false end
  return GetTime() - lastActivity > limit
end

-- One of: paused, afk, waiting, idle, running
function ns.ClockState()
  local S = ns.S
  if S.paused then return "paused" end
  if ns.autoPaused then return "afk" end
  if not S.started then return "waiting" end
  if ns.IsIdle() then return "idle" end
  return "running"
end

local function UpdateAFK()
  local afk = plain(UnitIsAFK("player"))
  local was = ns.autoPaused
  ns.autoPaused = (ns.DB and ns.DB.autoAFKPause and afk) and true or false
  if ns.autoPaused and not was then
    Discard(0)    -- drop time since the last activity (any idle-kept minute stays)
    awaiting = true
  end
end
ns.UpdateAFK = UpdateAFK

---------------------------------------------------------------------------
-- Gains and rates
---------------------------------------------------------------------------
local function BucketIndex()
  return math.floor(ns.Elapsed() / ns.BUCKET)
end

-- Returns the bucket index used, so a quest subtraction can undo exactly it.
-- idx: book into this bucket instead of the current one (a late-loading item
-- belongs to the minute it was looted).
function ns.AddGain(field, amount, idx)
  local S = ns.S
  S.totals[field] = (S.totals[field] or 0) + amount
  idx = idx or BucketIndex()
  local b = S.buckets[idx]
  if not b then
    b = {}
    S.buckets[idx] = b
  end
  b[field] = (b[field] or 0) + amount
  return idx
end

local function RemoveGain(field, amount, idx)
  local S = ns.S
  S.totals[field] = (S.totals[field] or 0) - amount
  local b = idx and S.buckets[idx]
  if b and b[field] then b[field] = b[field] - amount end
end

function ns.LootField()
  return ns.DB.priceSource == "auction" and "la" or "l"
end

function ns.GoldFields()
  return { "c", ns.LootField() }
end

local function Sum(tbl, fields)
  local total = 0
  for _, f in ipairs(fields) do total = total + (tbl[f] or 0) end
  return total
end

function ns.Total(fields)
  return math.max(0, Sum(ns.S.totals, fields))
end

function ns.SessionRate(fields)
  local elapsed = ns.Elapsed()
  if elapsed < ns.MIN_RATE_SECONDS then return nil end
  return ns.Total(fields) / elapsed * 3600
end

-- Rate over the last RecentWindow() seconds of active time, using whole buckets
-- so the covered time is exact.
function ns.RecentRate(fields)
  local elapsed = ns.Elapsed()
  if elapsed < ns.MIN_RECENT_SECONDS then return nil end
  local window = ns.RecentWindow()
  local startIdx = 0
  if elapsed > window then
    startIdx = math.ceil((elapsed - window) / ns.BUCKET)
  end
  startIdx = math.max(startIdx, ns.S.minBucket or 0)  -- no data before this
  local covered = elapsed - startIdx * ns.BUCKET
  if covered <= 0 then return nil end
  local total = 0
  for idx, b in pairs(ns.S.buckets) do
    if idx >= startIdx then total = total + Sum(b, fields) end
  end
  return math.max(0, total) / covered * 3600
end

-- Several signals, because Forever runs on the modern client where
-- GetMaxPlayerLevel() may report the retail cap instead of 60.
function ns.AtMaxLevel()
  if IsPlayerAtEffectiveMaxLevel and plain(IsPlayerAtEffectiveMaxLevel()) then return true end
  if IsXPUserDisabled and plain(IsXPUserDisabled()) then return true end
  local level = plain(UnitLevel("player"))
  local maxLevel = GetMaxPlayerLevel and plain(GetMaxPlayerLevel())
  if level and maxLevel and level >= maxLevel then return true end
  local xpMax = plain(UnitXPMax("player"))
  return xpMax == 0
end

-- Rested-aware time to level, in seconds, plus when rested XP runs out (or nil).
-- Rates prefer the rolling window (the current spot) and fall back to session.
--   x = XP/hr now (including the rested bonus), r = rested consumed per hour.
--   While rested lasts you earn x; after it, x - r. So the ETA is piecewise.
function ns.TimeToLevel()
  if ns.AtMaxLevel() then return nil end
  local cur, max = plain(UnitXP("player")), plain(UnitXPMax("player"))
  if not cur or not max then return nil end
  local recent = ns.RecentRate({ "x" })
  local x = recent or ns.SessionRate({ "x" })
  if not x or x <= 0 then return nil end
  local r = (recent and ns.RecentRate({ "r" }) or ns.SessionRate({ "r" })) or 0
  local needed = max - cur
  local rested = ns.Rested() or 0
  if r <= 0 then return needed / x * 3600, nil end    -- no rested bonus in play
  if rested <= 0 then
    -- Rested just ran out (or can't be read): from here you earn the base rate.
    local base = x - r
    if base <= 0 then return nil end
    return needed / base * 3600, nil
  end
  local restedHours = rested / r
  if needed <= x * restedHours then return needed / x * 3600, nil end  -- level before it runs out
  local base = x - r
  if base <= 0 then return nil, restedHours * 3600 end
  return (restedHours + (needed - x * restedHours) / base) * 3600, restedHours * 3600
end

function ns.Rested()
  if ns.AtMaxLevel() or not GetXPExhaustion then return nil end
  local rested = plain(GetXPExhaustion())
  if type(rested) == "number" and rested > 0 then return rested end
  return nil
end

function ns.TopZone(S)
  local best, bestTime
  for zone, t in pairs((S or ns.S).zones) do
    if not bestTime or t > bestTime then best, bestTime = zone, t end
  end
  return best
end

---------------------------------------------------------------------------
-- Quest rewards aren't farming income. QUEST_TURNED_IN and the matching XP/money
-- update can arrive in either order, so:
--   reward after the gain  -> undo up to the reward from that recent gain
--   reward before the gain -> leave a short-lived credit that cancels the gain
-- Either way we never subtract more than we added, so totals can't go negative.
---------------------------------------------------------------------------
-- Matching is by exact amount (quest rewards are exact), so an unrelated gain
-- that lands in between is never mistaken for the reward.
local recentGains = { x = {}, c = {} }   -- { amt, t, idx } within the match window
local questCredits = { x = {}, c = {} }  -- { amt, t } rewards still waiting for their gain

local function PruneWindow(list, now)
  for i = #list, 1, -1 do
    if now - list[i].t > ns.QUEST_MATCH_SECONDS then table.remove(list, i) end
  end
end

-- Pick the entry to match: an exact amount first; otherwise (one update that
-- carried the reward plus something else) the smallest entry that's big enough.
local function FindMatch(list, amount, key)
  local best
  for i, e in ipairs(list) do
    local v = e[key]
    if v == amount then return i end
    if v > amount and (not best or v < list[best][key]) then best = i end
  end
  return best
end

local function AddFarmGain(field, delta)
  local now = GetTime()
  local credits = questCredits[field]
  PruneWindow(credits, now)
  -- Credits cancel the gain while it lasts (two quests turned in before one
  -- combined update): exact amount first, then the largest credit that fits.
  while delta > 0 and credits[1] do
    local best
    for i, cr in ipairs(credits) do
      if cr.amt == delta then best = i break end
      if cr.amt < delta and (not best or cr.amt > credits[best].amt) then best = i end
    end
    if not best then break end
    delta = delta - credits[best].amt
    table.remove(credits, best)
  end
  if delta <= 0 then return end
  local gains = recentGains[field]
  PruneWindow(gains, now)
  table.insert(gains, { amt = delta, t = now, idx = ns.AddGain(field, delta) })
end

local function QuestReward(field, amount)
  local now = GetTime()
  local gains = recentGains[field]
  PruneWindow(gains, now)
  local i = FindMatch(gains, amount, "amt")
  if i then
    RemoveGain(field, amount, gains[i].idx)
    gains[i].amt = gains[i].amt - amount
    if gains[i].amt <= 0 then table.remove(gains, i) end
    return
  end
  table.insert(questCredits[field], { amt = amount, t = now })
end

local function ResetQuestMatching()
  for _, t in pairs(recentGains) do wipe(t) end
  for _, t in pairs(questCredits) do wipe(t) end
end

---------------------------------------------------------------------------
-- Kills: XP messages matched against looted corpses
--   XP kill           -> +1 kill, remembered as "unmatched" for 5 minutes
--   new corpse looted -> consumes an unmatched XP kill of the same mob (by name,
--                        when the corpse is your target or under the mouse; else
--                        the oldest), otherwise it's a kill that gave no XP:
--                        grey mobs, level 60.
-- Not kills: pickpocketing (living target) and gathering casts such as
-- skinning someone else's corpse.
---------------------------------------------------------------------------
local function EntryTime(e) return type(e) == "table" and e.t or e end
local function EntryMob(e) return type(e) == "table" and e.mob or nil end

local function PruneUnmatched(now)
  local list = ns.S.unmatched
  while list[1] and now - (EntryTime(list[1]) or 0) > ns.KILL_MATCH_SECONDS do
    table.remove(list, 1)
  end
end

-- The GUID of a dead target/mouseover with this name: when the XP line arrives
-- the mob you just killed is usually still targeted, which pins the kill to its
-- corpse exactly.
-- Mobs we've seen alive as target/mouseover (GUID -> GetTime()). A corpse can
-- only claim an XP kill if that mob was alive moments ago (the mob you're
-- fighting is re-checked every second until it dies). A corpse that died
-- earlier, like a stranger's kill you target to skin, never qualifies.
local seenAlive = {}
ns.SEEN_ALIVE_SECONDS = 600   -- memory cleanup only
ns.JUST_DIED_SECONDS = 2      -- "alive moments ago"

function ns.NoteAlive()
  if not UnitGUID or not UnitIsDead then return end
  for _, unit in ipairs({ "target", "mouseover" }) do
    local g = plain(UnitGUID(unit))
    if type(g) == "string" and plain(UnitIsDead(unit)) == false then seenAlive[g] = GetTime() end
  end
end

function ns.PruneSeenAlive()
  local now = GetTime()
  for g, t in pairs(seenAlive) do
    if now - t > ns.SEEN_ALIVE_SECONDS then seenAlive[g] = nil end
  end
end

-- Pins an XP kill to a dead target/mouseover with the mob's name, but only one we
-- saw alive, that isn't looted yet and isn't already pinned by another XP kill
-- (e.g. you left Boar 1 targeted while Mirel killed Boar 2). Otherwise unpinned.
local function DeadUnitGUID(name)
  if not name or not UnitGUID or not UnitIsDead then return nil end
  local S = ns.S
  for _, unit in ipairs({ "target", "mouseover" }) do
    if plain(UnitIsDead(unit)) == true and plain(UnitName(unit)) == name then
      local g = plain(UnitGUID(unit))
      if type(g) == "string" and seenAlive[g] and GetTime() - seenAlive[g] <= ns.JUST_DIED_SECONDS
          and not S.seen[g] then
        for _, e in ipairs(S.unmatched) do
          if type(e) == "table" and e.guid == g then return nil end
        end
        return g
      end
    end
  end
  return nil
end

function ns.RecordXPKill(mob)
  local S = ns.S
  S.xpKills = S.xpKills + 1
  ns.AddGain("k", 1)
  table.insert(S.unmatched, { t = time(), mob = mob, guid = DeadUnitGUID(mob) })
  if mob then S.mobs[mob] = (S.mobs[mob] or 0) + 1 end
  ns.Log("kill", "XP kill: %s", tostring(mob))
  ns.Touch()
end

-- Uses up one unmatched XP kill for the corpse `guid` (name may be nil). How
-- sure we must be depends on the caller:
--   "exact": only a kill pinned to this very corpse (skinning: may be a stranger's)
--   "named": that, or a kill of the same mob name (looting while paused)
--   "any":   that, or the oldest kill (looting: name unknown)
-- A kill pinned to a *different* corpse is never used. Returns true if one was.
local function EntryGUID(e) return type(e) == "table" and e.guid or nil end

function ns.ConsumeUnmatched(guid, name, mode)
  local list = ns.S.unmatched
  PruneUnmatched(time())
  local match
  for i, e in ipairs(list) do
    if guid and EntryGUID(e) == guid then match = i break end
  end
  if not match and mode ~= "exact" then
    for i, e in ipairs(list) do
      local g = EntryGUID(e)
      if (g == nil or g == guid) and (name and EntryMob(e) == name or (not name and mode == "any")) then
        match = i
        break
      end
    end
  end
  if match then table.remove(list, match) return true end
  return false
end

-- name: the corpse's mob name if we could read it, else nil
function ns.RecordCorpse(guid, name)
  local S = ns.S
  if S.seen[guid] then return false end
  S.seen[guid] = time()
  S.corpses = S.corpses + 1
  if ns.ConsumeUnmatched(guid, name, "any") then
    ns.Log("kill", "corpse %s matched an XP kill", ns.GUIDTag(guid))
  else
    S.lootOnlyKills = S.lootOnlyKills + 1
    ns.AddGain("k", 1)
    -- Level 60 / grey mobs give no XP line, so the corpse name is the only source.
    if name then S.mobs[name] = (S.mobs[name] or 0) + 1 end
    ns.Log("kill", "corpse %s (%s) = loot-only kill", ns.GUIDTag(guid), tostring(name))
  end
  ns.Touch()
  return true
end

-- Finds a unit token (target/mouseover) currently showing this GUID.
local function UnitForGUID(guid)
  if not UnitGUID then return nil end
  for _, unit in ipairs({ "target", "mouseover" }) do
    local g = plain(UnitGUID(unit))
    if g and g == guid then return unit end
  end
  return nil
end

-- Gathering and pickpocketing are recognized by the spell actually cast (by ID,
-- or by name so other ranks and client builds match too). Combat spells never are.
local SPELLS = {
  gather = { 8613, 8617, 8618, 10768,   -- Skinning
             2366, 2368, 3570, 11993,   -- Herb Gathering
             2575, 2576, 3564, 10248 }, -- Mining
  pickpocket = { 921 },                 -- Pick Pocket
}
local spellKind      -- [spellID] = kind
local spellKindByName -- [localized name] = kind

local function SpellName(id)
  if type(id) ~= "number" then return nil end
  if C_Spell and C_Spell.GetSpellName then return plain(C_Spell.GetSpellName(id)) end
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(id)
    return info and plain(info.name) or nil
  end
  if GetSpellInfo then return plain((GetSpellInfo(id))) end
  return nil
end
ns.SpellName = SpellName
ns.KNOWN_SPELLS = SPELLS

function ns.ClassifySpell(spellID)
  if not spellKind then
    spellKind, spellKindByName = {}, {}
    for kind, ids in pairs(SPELLS) do
      for _, id in ipairs(ids) do
        spellKind[id] = kind
        local ok, name = pcall(SpellName, id)
        if ok and type(name) == "string" then spellKindByName[name] = kind end
      end
    end
  end
  local custom = ns.DB and ns.DB.customSpells and ns.DB.customSpells[spellID]
  if custom then return custom end
  if spellKind[spellID] then return spellKind[spellID] end
  local ok, name = pcall(SpellName, spellID)
  return ok and type(name) == "string" and spellKindByName[name] or nil
end

local lastGatherAt, lastPickpocketAt = -math.huge, -math.huge
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
  if plain(unit) ~= "player" then return end
  spellID = plain(spellID)
  if type(spellID) ~= "number" then return end
  local kind = ns.ClassifySpell(spellID)
  if ns.DB and ns.DB.debug then
    local ok, name = pcall(SpellName, spellID)
    ns.Log("cast", "spell %d (%s) -> %s", spellID, ok and tostring(name) or "?", kind or "combat/other")
  end
  if kind == "gather" then lastGatherAt = GetTime()
  elseif kind == "pickpocket" then lastPickpocketAt = GetTime() end
end)

---------------------------------------------------------------------------
-- Loot value
---------------------------------------------------------------------------
-- Items waiting for their data to load live in the session (S.pending).
local function Pending() return ns.S.pending end

function ns.AuctionPrice(itemID)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not api or not api.GetAuctionPriceByItemID then return nil end
  local ok, price = pcall(api.GetAuctionPriceByItemID, ns.name, itemID)
  if ok and type(price) == "number" and price > 0 then return price end
  return nil
end

function ns.HasAuctionator()
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  return (api and api.GetAuctionPriceByItemID) and true or false
end

local function ItemEntry(itemID, name)
  local entry = ns.S.items[itemID]
  if not entry then
    entry = { name = name or ("item:" .. itemID), count = 0, value = 0, valueAH = 0 }
    ns.S.items[itemID] = entry
  end
  if name and entry.name:match("^item:") then entry.name = name end
  return entry
end

-- idx: the bucket the loot belongs to (defaults to now).
function ns.AddLoot(itemID, qty, name, idx)
  local info = { ns.GetItemInfo(itemID) }
  local itemName, sellPrice = plain(info[1]), plain(info[11])
  if sellPrice == nil then
    -- Not cached yet: queue it (remembering which minute it was looted in) and
    -- ask the client to load it.
    local pending = Pending()
    local p = pending[itemID]
    if not p then
      p = { tries = 0, name = name, parts = {} }
      pending[itemID] = p
    end
    idx = idx or BucketIndex()
    p.parts[idx] = (p.parts[idx] or 0) + qty
    if ns.RequestItemLoad then pcall(ns.RequestItemLoad, itemID) end
    return
  end
  local vendor = sellPrice * qty
  local best = vendor
  local ah = ns.AuctionPrice(itemID)
  if ah then best = math.max(vendor, math.floor(ah * 0.95) * qty) end
  local entry = ItemEntry(itemID, itemName or name)
  entry.unit = sellPrice  -- vendor price per item, for /gw reprice
  entry.count = entry.count + qty
  entry.value = entry.value + vendor
  entry.valueAH = (entry.valueAH or 0) + best
  idx = idx or math.floor(ns.Elapsed() / ns.BUCKET)
  ns.DetailBucket(idx)  -- before AddGain, so an older minute's values are kept as "legacy"
  ns.AddGain("l", vendor, idx)
  ns.AddGain("la", best, idx)
  ns.BookLoot(itemID, qty, idx, vendor, best, false)
end

function ns.ResolvePending(onlyID)
  local pending = Pending()
  for itemID, p in pairs(pending) do
    if not onlyID or onlyID == itemID then
      local sellPrice = plain(select(11, ns.GetItemInfo(itemID)))
      if sellPrice ~= nil then
        pending[itemID] = nil
        for idx, qty in pairs(p.parts) do ns.AddLoot(itemID, qty, p.name, idx) end
      elseif not onlyID then
        p.tries = p.tries + 1
        if p.tries >= ns.PENDING_MAX_TRIES then
          -- Give up on the price but keep the count so the loot list stays honest
          -- (/gw reprice can value it later).
          pending[itemID] = nil
          ns.GiveUpPending(itemID, p)
        end
      end
    end
  end
end

function ns.GiveUpPending(itemID, p)
  local entry = ItemEntry(itemID, p.name)
  for idx, qty in pairs(p.parts) do
    entry.count = entry.count + qty
    -- How many have no value yet, per price setting (vendor / AH).
    entry.unpriced = (entry.unpriced or 0) + qty
    entry.unpricedAH = (entry.unpricedAH or 0) + qty
    ns.DetailBucket(idx)
    ns.BookLoot(itemID, qty, idx, 0, 0, true)  -- booked at 0 for now; /gw reprice can value it
  end
end

-- Total queued item stacks, for the report.
function ns.PendingCount()
  local n = 0
  for _ in pairs(Pending()) do n = n + 1 end
  return n
end

-- Per-minute item detail, so /gw reprice can change exactly what changed:
--   b.q[item]  units booked in this minute
--   b.vl[item] their vendor value      b.va[item] their AH value
--   b.ua[item] units with no AH value yet (gave up loading)
-- Recorded only when a value is booked (priced, or given up at 0), never for
-- items still loading: those aren't in the bucket's values yet.

-- Makes sure a minute has the detail tables. A minute saved by an older build
-- has loot values but no (or partial) detail: its existing values are kept as
-- one "legacy" entry that /gw reprice never touches. Call before booking.
function ns.DetailBucket(idx)
  local S = ns.S
  local b = S.buckets[idx]
  if not b then
    b = {}
    S.buckets[idx] = b
  end
  if not b.vl then
    b.vl = { legacy = b.l or 0 }
    b.va = { legacy = b.la or 0 }
    if b.q then b.qOld, b.q = b.q, nil end  -- detail without values: not repriceable
  end
  b.q = b.q or {}
  return b
end

function ns.BookLoot(itemID, qty, idx, vendorValue, ahValue, unpriced)
  local b = ns.DetailBucket(idx or math.floor(ns.Elapsed() / ns.BUCKET))
  b.q[itemID] = (b.q[itemID] or 0) + qty
  b.vl[itemID] = (b.vl[itemID] or 0) + vendorValue
  b.va[itemID] = (b.va[itemID] or 0) + ahValue
  if unpriced then
    b.ua = b.ua or {}
    b.ua[itemID] = (b.ua[itemID] or 0) + qty
  end
end

-- Re-values this session's loot at today's prices. Per item:
--   vendor price known (loaded now if it wasn't): every unit gets it
--   AH price now: every unit gets max(vendor, AH after the 5% cut), i.e. the
--     current market, as /gw reprice promises
--   no AH price now: what each unit was already worth is kept (no averaging
--     across minutes); units that never had an AH value get the vendor price
--     once it's known
-- The same rules run on the item totals and on each minute's per-item detail,
-- so totals and the rolling window agree and old loot stays in its minute.
-- Repeating it changes nothing. Returns old and new AH-value totals.
function ns.Reprice()
  local S = ns.S
  local oldTotal = S.totals.la or 0
  local plan = {}
  for itemID, entry in pairs(S.items) do
    local unit = entry.unit  -- a real vendor price (from item data), or nil
    local floor = unit       -- the vendor floor for AH values
    if unit == nil then
      local sp = plain(select(11, ns.GetItemInfo(itemID)))
      if type(sp) == "number" then
        unit, floor = sp, sp
        entry.unit = sp
      else
        if ns.RequestItemLoad then pcall(ns.RequestItemLoad, itemID) end  -- maybe next time
        -- No real price (an entry saved by an older build, cache still cold):
        -- derive one from the units that have a vendor value, but use it only
        -- as the floor under an AH price. It never values units, clears the
        -- "no price yet" counts or gets saved: an older entry's count can hide
        -- given-up units, which would make it wrong.
        local valued = entry.count - (entry.unpriced or 0)
        if valued > 0 and entry.value > 0 then floor = entry.value / valued end
      end
    end
    local ah = ns.AuctionPrice(itemID)
    local best = ah and math.max(floor or 0, math.floor(ah * 0.95)) or nil
    plan[itemID] = { unit = unit, best = best }
    if unit then
      entry.value = unit * entry.count
      entry.unpriced = nil
    end
    if best then
      entry.valueAH = best * entry.count
      entry.unpricedAH = nil
    elseif unit and (entry.unpricedAH or 0) > 0 then
      entry.valueAH = (entry.valueAH or 0) + unit * entry.unpricedAH
      entry.unpricedAH = nil
    end
  end
  local l, la = 0, 0
  for _, entry in pairs(S.items) do
    l = l + entry.value
    la = la + (entry.valueAH or 0)
  end
  S.totals.l, S.totals.la = l, la

  for _, b in pairs(S.buckets) do
    if b.q and b.vl and b.va then
      for itemID, qty in pairs(b.q) do
        local p = plan[itemID]
        if p then
          if p.unit then b.vl[itemID] = p.unit * qty end
          if p.best then
            b.va[itemID] = p.best * qty
            if b.ua then b.ua[itemID] = nil end
          elseif p.unit and b.ua and b.ua[itemID] then
            b.va[itemID] = (b.va[itemID] or 0) + p.unit * b.ua[itemID]
            b.ua[itemID] = nil
          end
        end
      end
      local bl, bla = 0, 0
      for _, v in pairs(b.vl) do bl = bl + v end
      for _, v in pairs(b.va) do bla = bla + v end
      b.l, b.la = bl, bla
    end
  end
  return oldTotal, la
end


---------------------------------------------------------------------------
-- Money: vendor/mail/trade/bank/AH money isn't farm income
---------------------------------------------------------------------------
local moneyBlockers = {}
local moneyBlockUntil = 0
local lastClosedWindow             -- which window's grace period moneyBlockUntil belongs to
local lastWorldLootAt = -math.huge  -- last loot window from the world (not a bag item)
-- Current loot window: its first source GUID, when it opened, and gather/pickpocket.
local windowKey, windowAt, windowKind = nil, -math.huge, nil
local lastMoney
local lastXP, lastXPMax
local lastRested

function ns.SetMoneyWindow(key, open)
  if open then
    moneyBlockers[key] = true
  elseif moneyBlockers[key] then
    moneyBlockers[key] = nil
    moneyBlockUntil = GetTime() + 3  -- sale/mail money can land just after closing
    lastClosedWindow = key
  end
end

function ns.MoneyBlocked()
  return next(moneyBlockers) ~= nil or GetTime() < moneyBlockUntil
end

-- Spending is a farming cost only in the world or at a merchant (repairs, ammo,
-- food, flights, training). Gold handed over by trade, mail, AH deposits or bank
-- moves is just gold moving around.
local NOT_SPENDING = { mail = true, trade = true, auction = true, bank = true, guildbank = true }
function ns.SpendingCounts()
  -- An open window decides: a merchant purchase counts even right after mailing.
  if next(moneyBlockers) ~= nil then
    for key in pairs(moneyBlockers) do
      if NOT_SPENDING[key] then return false end
    end
    return true
  end
  -- Gold can also leave just after the window closes (same 3s grace as income).
  if GetTime() < moneyBlockUntil and NOT_SPENDING[lastClosedWindow] then return false end
  return true
end

local function ReadRested()
  if not GetXPExhaustion then return nil end
  local raw = GetXPExhaustion()
  if ns.IsSecret(raw) then return nil end  -- unknown, not zero (check before comparing)
  if raw == nil then return 0 end          -- the API returns nil when you have no rested XP
  return type(raw) == "number" and raw or nil
end

function ns.ResetBaselines()
  lastXP, lastXPMax = plain(UnitXP("player")), plain(UnitXPMax("player"))
  lastMoney = plain(GetMoney())
  lastRested = ReadRested()
end

-- Rested XP consumed = the bonus part of kill XP. Increases (resting in an inn)
-- aren't farming and are ignored.
local function OnRestedChange()
  local rested = ReadRested()
  if rested == nil then return end
  if lastRested and rested < lastRested and ns.Tracking() and ns.S.started then
    ns.AddGain("r", lastRested - rested)
  end
  lastRested = rested
end

-- XP and money changes don't count as activity by themselves (a quest turn-in in
-- town shouldn't start the clock); the kill, loot or pull that caused them does.
local function OnMoney()
  local money = plain(GetMoney())
  if not money then return end
  if lastMoney and ns.Tracking() then
    local delta = money - lastMoney
    if delta > 0 and not ns.MoneyBlocked() then
      AddFarmGain("c", delta)
      ns.Log("money", "+%d copper (farm)", delta)
    elseif delta > 0 then
      ns.Log("money", "+%d copper ignored (vendor/mail/trade/bank/AH)", delta)
    elseif delta < 0 and ns.S.started and ns.SpendingCounts() then
      ns.S.spent = ns.S.spent + (-delta)
      ns.Log("money", "%d copper spent", delta)
    elseif delta < 0 then
      ns.Log("money", "%d copper moved (not spending)", delta)
    end
  end
  lastMoney = money
end

local function OnXPUpdate()
  local cur, max = plain(UnitXP("player")), plain(UnitXPMax("player"))
  if not cur or not max then return end
  if lastXP and ns.Tracking() then
    local gained
    if cur >= lastXP then
      gained = cur - lastXP
    else
      gained = (lastXPMax or 0) - lastXP + cur  -- leveled: rest of the old bar + new progress
    end
    if gained > 0 then
      AddFarmGain("x", gained)
      ns.Log("xp", "+%d XP", gained)
    end
  end
  lastXP, lastXPMax = cur, max
  OnRestedChange()
end

local function OnQuestTurnedIn(_, xpReward, moneyReward)
  if not ns.Tracking() then return end
  xpReward, moneyReward = plain(xpReward), plain(moneyReward)
  ns.Log("quest", "turned in: %s XP, %s copper, money blocked: %s",
    tostring(xpReward), tostring(moneyReward), tostring(ns.MoneyBlocked()))
  if type(xpReward) == "number" and xpReward > 0 then
    ns.S.questXP = ns.S.questXP + xpReward
    QuestReward("x", xpReward)
  end
  if type(moneyReward) == "number" and moneyReward > 0 then
    if ns.MoneyBlocked() then
      -- The reward's coin is blocked anyway; stretch the block over the time it
      -- may take to land, so it can't slip in just after the grace period ends.
      moneyBlockUntil = math.max(moneyBlockUntil, GetTime() + ns.QUEST_MATCH_SECONDS)
    else
      ns.S.questCoin = ns.S.questCoin + moneyReward
      QuestReward("c", moneyReward)
    end
  end
end

local function OnLootMessage(msg)
  msg = plain(msg)
  if type(msg) ~= "string" or not ns.Tracking() then return end
  for _, pat in ipairs(ns.LOOT_PATTERNS) do
    local a, b = msg:match(pat)
    if a then
      -- "<item>x3" gives (item, 3); a few locales put the number first.
      local qty = 1
      if b then qty = tonumber(b) or tonumber(a) or 1 end
      local itemID = tonumber(msg:match("|Hitem:(%d+)"))
      if itemID then
        -- Loot right after a world loot window is farming activity; a clam opened
        -- in town or a late roll win still counts as value but doesn't wake the clock.
        if GetTime() - lastWorldLootAt <= 5 then ns.Touch() end
        local name = msg:match("|h%[(.-)%]|h")
        ns.Log("loot", "item %d (%s) x%d", itemID, tostring(name), qty)
        ns.AddLoot(itemID, qty, name)
      end
      return
    end
  end
end

local function OnXPMessage(msg)
  msg = plain(msg)
  if type(msg) ~= "string" or not ns.Tracking() or not ns.KILL_XP_PATTERN then return end
  local a, b = msg:match(ns.KILL_XP_PATTERN)
  if not a then
    -- Quest/exploration XP lines; logged so the kill pattern can be checked in-game.
    ns.Log("xp", "XP line, not a kill: %s", msg)
    return
  end
  local mob = a
  if tonumber(a) then mob = b end  -- some locales put the number first
  ns.RecordXPKill(mob)
end

local function OnLootOpened()
  if not GetNumLootItems or not GetLootSourceInfo then return end
  local n = plain(GetNumLootItems()) or 0
  local now = GetTime()
  -- Identify the window by its first source GUID. LOOT_READY and LOOT_OPENED of
  -- one window share a key and arrive together, so they share one decision; any
  -- other window gets its own, and a skin/pickpocket cast is used up by the first
  -- window after it. LOOT_CLOSED isn't used: it can arrive late, out of order.
  local key
  for slot = 1, n do
    local g = plain((GetLootSourceInfo(slot)))
    if type(g) == "string" then key = g break end
  end
  if key == nil or key ~= windowKey or now - windowAt > 1 then
    windowKey, windowAt, windowKind = key, now, nil
    if now - lastGatherAt <= ns.GATHER_CAST_SECONDS then windowKind = "gather"
    elseif now - lastPickpocketAt <= ns.GATHER_CAST_SECONDS then windowKind = "pickpocket" end
    if windowKind then lastGatherAt, lastPickpocketAt = -math.huge, -math.huge end
    if ns.DB and ns.DB.debug then
      local tags = {}
      for slot = 1, n do
        local g = plain((GetLootSourceInfo(slot)))
        tags[#tags + 1] = ns.GUIDTag(g)
      end
      ns.Log("loot", "window [%s] kind=%s", table.concat(tags, ", "), windowKind or "normal")
    end
  end
  local fromGather = windowKind == "gather"
  local fromPickpocket = windowKind == "pickpocket"
  local fromCorpse, fromWorld = false, false
  for slot = 1, n do
    local sources = { GetLootSourceInfo(slot) }
    for i = 1, #sources, 2 do
      local guid = plain(sources[i])
      if type(guid) == "string" then
        -- Anything but a bag item (corpse, herb, ore, chest, fishing) is farming.
        if not guid:match("^Item%-") then fromWorld = true end
        if guid:match("^Creature%-") or guid:match("^Vehicle%-") then
          fromCorpse = true
          local unit = UnitForGUID(guid)
          -- Pickpocket: the mob is still alive, so it's no kill (yet). Skip it
          -- without remembering it, so looting the real corpse later still counts.
          local alive = fromPickpocket or (unit and UnitIsDead and plain(UnitIsDead(unit)) == false)
          if not alive then
            local name = unit and plain(UnitName(unit)) or nil
            if not ns.Tracking() then
              -- Paused: remember it (re-opening it after resuming isn't a kill) and
              -- use up its XP kill so a later corpse can't take it.
              if not ns.S.seen[guid] then
                ns.S.seen[guid] = time()
                ns.ConsumeUnmatched(guid, name, "named")
              end
            elseif fromGather then
              -- Skinning: never a new kill (it may be someone else's). Only an XP
              -- kill pinned to this exact corpse is used up.
              if not ns.S.seen[guid] then
                ns.S.seen[guid] = time()
                ns.ConsumeUnmatched(guid, name, "exact")
              end
            else
              ns.RecordCorpse(guid, name)
            end
          end
        end
      end
    end
  end
  if fromWorld and ns.Tracking() then
    lastWorldLootAt = now
    ns.Touch()
  end
  -- Standing over a corpse means no vendor/mail/trade window can be open, so clear
  -- any blocker that missed its close event. (Bag containers don't count: you can
  -- open a clam at the mailbox.)
  if fromCorpse then
    wipe(moneyBlockers)
    moneyBlockUntil = 0
  end
end

---------------------------------------------------------------------------
-- Maintenance
---------------------------------------------------------------------------
function ns.Prune()
  local S = ns.S
  local now = time()
  PruneUnmatched(now)
  for guid, t in pairs(S.seen) do
    if now - t > ns.CORPSE_MEMORY_SECONDS then S.seen[guid] = nil end
  end
  -- Committed time only: provisional time can still be discarded, which would pull
  -- the window back over buckets we'd already have dropped.
  -- The longest selectable window, so lengthening it in settings doesn't find
  -- the older minutes already gone.
  local keepFrom = math.floor(math.max(0, S.elapsed - ns.MAX_WINDOW) / ns.BUCKET) - 1
  for idx in pairs(S.buckets) do
    if idx < keepFrom then S.buckets[idx] = nil end
  end
end

---------------------------------------------------------------------------
-- Sessions and history
---------------------------------------------------------------------------
function ns.Archive(S, note)
  S = S or ns.S
  if not S.started or (S.elapsed or 0) < ns.MIN_ARCHIVE_SECONDS then return false end
  local t = S.totals or {}
  table.insert(ns.DB.history, 1, {
    when = S.startedAt, char = ns.PlayerName(), zone = ns.TopZone(S), note = note, label = S.note,
    elapsed = S.elapsed, kills = math.max(0, t.k or 0), xp = math.max(0, t.x or 0),
    coin = math.max(0, t.c or 0), loot = math.max(0, t.l or 0), lootAH = math.max(0, t.la or 0),
  })
  while #ns.DB.history > ns.HISTORY_MAX do table.remove(ns.DB.history) end
  return true
end

function ns.ResetSession()
  Discard(ns.IDLE_KEEP_SECONDS)  -- trailing time after the last kill, like going idle
  -- Items still loading belong to this session: one last try so their value
  -- reaches its history entry (per item, which only resolves; the full pass would
  -- also count a give-up attempt). Anything still unknown, plus units that gave up
  -- loading earlier and haven't been priced since (entry.unpriced), can't be
  -- valued (history keeps totals only); the count is returned so the user is told.
  local ids = {}
  for itemID in pairs(ns.S.pending) do ids[#ids + 1] = itemID end
  for _, itemID in ipairs(ids) do ns.ResolvePending(itemID) end
  local unvalued = 0
  for _, p in pairs(ns.S.pending) do
    for _, qty in pairs(p.parts) do unvalued = unvalued + qty end
  end
  local field = ns.DB.priceSource == "auction" and "unpricedAH" or "unpriced"
  for _, entry in pairs(ns.S.items) do unvalued = unvalued + (entry[field] or 0) end
  local archived = ns.Archive()
  -- Keep corpse memory and pending XP kills: a corpse from before the reset is
  -- neither a new kill nor unmatched (its kill was counted in the old session).
  local seen, unmatched = ns.S.seen, ns.S.unmatched
  VulcanGrindWatchCharDB.session = ns.NewSession()
  ns.S = VulcanGrindWatchCharDB.session
  ns.S.seen, ns.S.unmatched = seen, unmatched
  ResetQuestMatching()
  ns.ResetBaselines()
  awaiting = true
  ns.Fire("RESET", archived)
  return archived, unvalued
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
local function LoadSavedData()
  -- Saved-data safety (Persist.lua): look at what the client loaded before defaults fill it in.
  if ns.Persist then ns.Persist.CheckLoad(VulcanGrindWatchDB, VulcanGrindWatchCharDB) end
  -- (A hand-edited file can hold anything: only tables are used.)
  local db = type(VulcanGrindWatchDB) == "table" and VulcanGrindWatchDB or {}
  local legacy
  if type(db.session) == "table" then legacy = db.session end  -- v1 kept the session account-wide
  db.session = nil
  VulcanGrindWatchDB = CopyDefaults(DEFAULTS, db)
  ns.DB = VulcanGrindWatchDB
  -- Hand-edited or corrupted values would otherwise break the window or the math.
  ns.repairedSettings = ns.SanitizeSettings(ns.DB)
  local p = ns.DB.point
  local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end
  local function anchor(a) return ns.ANCHORS[a] == true end
  if not anchor(p[1]) or not anchor(p[2]) or not finite(p[3]) or not finite(p[4]) then
    ns.DB.point = { DEFAULTS.point[1], DEFAULTS.point[2], DEFAULTS.point[3], DEFAULTS.point[4] }
    ns.repairedSettings[#ns.repairedSettings + 1] = "point"
  end
  local pp = ns.DB.panelPoint
  if pp ~= nil and (type(pp) ~= "table" or not anchor(pp[1]) or not anchor(pp[2])
      or not finite(pp[3]) or not finite(pp[4])) then
    ns.DB.panelPoint = nil  -- just recenters; not worth a message
  end
  -- Taught spells: numeric IDs mapped to a kind the addon knows.
  local spellsFixed = false
  for id, kind in pairs(ns.DB.customSpells) do
    if type(id) ~= "number" or (kind ~= "gather" and kind ~= "pickpocket") then
      ns.DB.customSpells[id] = nil
      spellsFixed = true
    end
  end
  if spellsFixed then ns.repairedSettings[#ns.repairedSettings + 1] = "customSpells (only the bad entries removed)" end
  -- Diagnostics log: text lines only, at most DEBUG_MAX of them (newest kept).
  local logKept = {}
  for _, line in ipairs(ns.DB.debugLog) do
    if type(line) == "string" then logKept[#logKept + 1] = line end
  end
  while #logKept > ns.DEBUG_MAX do table.remove(logKept, 1) end
  ns.DB.debugLog = logKept
  -- History: a session that isn't a table or has no usable length would break
  -- /gw history, spots and export; bad optional fields are just dropped.
  -- Every positive whole-number key in order (ipairs would stop at a gap and
  -- leave what's after it unchecked); anything else counts as broken.
  local keys, kept, dropped = {}, {}, 0
  for i in pairs(ns.DB.history) do
    if type(i) == "number" and i >= 1 and i == math.floor(i) then keys[#keys + 1] = i else dropped = dropped + 1 end
  end
  table.sort(keys)
  for _, i in ipairs(keys) do
    local h = ns.DB.history[i]
    if type(h) == "table" and finite(h.elapsed) and h.elapsed >= 0 then
      for _, k in ipairs({ "when", "kills", "xp", "coin", "loot", "lootAH" }) do
        if h[k] ~= nil and not finite(h[k]) then h[k] = nil end
      end
      for _, k in ipairs({ "char", "zone", "note", "label" }) do
        if h[k] ~= nil and type(h[k]) ~= "string" then h[k] = nil end
      end
      kept[#kept + 1] = h
    else
      dropped = dropped + 1
    end
  end
  ns.DB.history = kept
  if dropped > 0 then
    ns.repairedSettings[#ns.repairedSettings + 1] = string.format("history (%d broken session(s) removed)", dropped)
  end
  ns.DB.version = ns.DB_VERSION

  if type(VulcanGrindWatchCharDB) ~= "table" then VulcanGrindWatchCharDB = {} end
  local saved = type(VulcanGrindWatchCharDB.session) == "table" and VulcanGrindWatchCharDB.session or nil
  if saved and saved.minBucket == nil and type(saved.elapsed) == "number" then
    -- A session from before 3.1 kept only 15 minutes of per-minute data, so a
    -- longer recent window mustn't reach back past it (it would read as a slump).
    saved.minBucket = math.max(0, math.floor((saved.elapsed - 900) / ns.BUCKET) - 1)
  end
  VulcanGrindWatchCharDB.session = CopyDefaults(DEFAULT_SESSION, saved or {})
  ns.S = VulcanGrindWatchCharDB.session
  ns.previousLastSeen = ns.S.lastSeen or 0  -- captured before the clock overwrites it

  if legacy then
    -- Convert v1 fields into an archived history entry rather than mixing formats.
    local old = {
      started = legacy.started, elapsed = legacy.elapsed or 0, startedAt = 0,
      zones = {},
      totals = {
        k = math.max(legacy.xpKills or 0, legacy.corpses or 0),
        x = (legacy.xp or 0) - (legacy.questXP or 0),
        c = (legacy.coin or 0) - (legacy.questCoin or 0),
        l = legacy.lootValue or 0, la = legacy.lootValue or 0,
      },
    }
    if ns.Archive(old, "v1") then
      ns.migrated = true
    end
  end
end

ns.On("ADDON_LOADED", function(name)
  if plain(name) ~= ns.name then return end
  LoadSavedData()
  ns.Fire("READY")
end)

ns.On("PLAYER_LOGIN", function()
  -- A login or /reload in town isn't farming: the clock waits ("awaiting") until
  -- a pull, kill, loot or corpse run, whatever the idle setting.
  awaiting = true
  ns.PlayerName()  -- cache our name while it's readable (sync echo filter)
  ns.ResetBaselines()
  UpdateAFK()
  ns.Fire("LOGIN")
end)

-- Logging out or reloading mid-farm keeps the last minute, like going idle.
ns.On("PLAYER_LOGOUT", function()
  if ns.S then Discard(ns.IDLE_KEEP_SECONDS) end
end)

ns.On("PLAYER_ENTERING_WORLD", function()
  ns.ResetBaselines()
end)

ns.On("PLAYER_TARGET_CHANGED", function() ns.NoteAlive() end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() ns.NoteAlive() end)
ns.On("PLAYER_XP_UPDATE", OnXPUpdate)
ns.On("UPDATE_EXHAUSTION", OnRestedChange)
ns.On("PLAYER_MONEY", OnMoney)
ns.On("CHAT_MSG_LOOT", OnLootMessage)
ns.On("CHAT_MSG_COMBAT_XP_GAIN", OnXPMessage)
ns.On("QUEST_TURNED_IN", OnQuestTurnedIn)
ns.On("LOOT_OPENED", OnLootOpened)
ns.On("LOOT_READY", OnLootOpened)  -- fires with autoloot too; corpses are de-duplicated

-- Pulling a mob is activity: starts the clock at the first pull, not the first kill.
ns.On("PLAYER_REGEN_DISABLED", function()
  if ns.Tracking() then ns.Touch() end
end)

ns.On("ITEM_DATA_LOAD_RESULT", function(itemID, success)
  itemID, success = plain(itemID), plain(success)
  if itemID and success then ns.ResolvePending(itemID) end
end)

ns.On("PLAYER_FLAGS_CHANGED", function(unit)
  if plain(unit) ~= "player" then return end
  UpdateAFK()
end)

local MONEY_WINDOW_EVENTS = {
  MERCHANT_SHOW = { "merchant", true },          MERCHANT_CLOSED = { "merchant", false },
  MAIL_SHOW = { "mail", true },                  MAIL_CLOSED = { "mail", false },
  TRADE_SHOW = { "trade", true },                TRADE_CLOSED = { "trade", false },
  AUCTION_HOUSE_SHOW = { "auction", true },      AUCTION_HOUSE_CLOSED = { "auction", false },
  BANKFRAME_OPENED = { "bank", true },           BANKFRAME_CLOSED = { "bank", false },
  GUILDBANKFRAME_OPENED = { "guildbank", true }, GUILDBANKFRAME_CLOSED = { "guildbank", false },
}
for event, info in pairs(MONEY_WINDOW_EVENTS) do
  ns.On(event, function() ns.SetMoneyWindow(info[1], info[2]) end)
end

-- Newer clients report these windows through the interaction manager instead.
local INTERACTION_KEYS = {}
if Enum and Enum.PlayerInteractionType then
  local T = Enum.PlayerInteractionType
  for key, name in pairs({
    Merchant = "merchant", MailInfo = "mail", TradePartner = "trade", Auctioneer = "auction",
    Banker = "bank", GuildBanker = "guildbank", AccountBanker = "bank",
  }) do
    if T[key] then INTERACTION_KEYS[T[key]] = name end
  end
end
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
  local key = INTERACTION_KEYS[plain(kind) or false]
  if key then ns.SetMoneyWindow(key, true) end
end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
  local key = INTERACTION_KEYS[plain(kind) or false]
  if key then ns.SetMoneyWindow(key, false) end
end)

---------------------------------------------------------------------------
-- Clock: once a second
---------------------------------------------------------------------------
local lastTick
local tickCount = 0
local lastState
-- The state the clock was last ticked in (settings use it: the live state can
-- flip mid-drag of a slider without the clock ever having stopped).
function ns.LastClockState() return lastState end
local deadSince

local function Tick()
  local now = GetTime()
  local dt = lastTick and (now - lastTick) or 0
  lastTick = now
  local S = ns.S
  if not S then return end
  tickCount = tickCount + 1

  -- Combat (a long elite fight with no gains yet) and a corpse run (capped, so a
  -- character left dead doesn't farm the clock) are activity.
  local dead = plain(UnitIsDeadOrGhost("player"))
  if dead then deadSince = deadSince or now else deadSince = nil end  -- even while paused
  if S.started and not S.paused and not ns.autoPaused then
    local inCombat = UnitAffectingCombat and plain(UnitAffectingCombat("player"))
    if inCombat or (dead and now - deadSince <= ns.DEAD_KEEPALIVE_SECONDS) then
      ns.Touch()
    end
  end

  local state = ns.ClockState()
  -- dt >= 10 means a loading screen or a client stall; don't count it.
  if state == "running" and dt > 0 and dt < 10 then
    provisional = provisional + dt
    local zone = GetRealZoneText and plain(GetRealZoneText())
    if type(zone) == "string" and zone ~= "" then
      provisionalZones[zone] = (provisionalZones[zone] or 0) + dt
    end
  end
  if lastState == "running" and state == "idle" then
    Discard(ns.IDLE_KEEP_SECONDS)
  end
  if state ~= lastState then ns.Log("clock", "%s -> %s", tostring(lastState), state) end
  lastState = state

  S.lastSeen = time()
  ns.NoteAlive()  -- also catches a target that was alive all along
  if tickCount % 30 == 0 then
    ns.Prune()
    ns.PruneSeenAlive()
  end
  ns.ResolvePending()
  ns.Fire("TICK", tickCount)
end
ns.Tick = Tick

C_Timer.NewTicker(1, function()
  local ok, err = pcall(Tick)
  if not ok then ReportError("clock", err) end
end)
