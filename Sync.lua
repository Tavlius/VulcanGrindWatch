-- GrindWatch: duo sync. If your group partner also runs GrindWatch, each of you
-- shares session totals every 30 seconds over the hidden addon channel, so the
-- window can show their gold/hr and your combined duo rate.
local _, ns = ...
local plain = ns.plain

local PREFIX = "VulcanGrindWatch"
-- v2: coin, vendor loot and AH loot sent separately
-- v3: adds the last-15m rates (coin, vendor loot, AH loot per hour; -1 = not yet)
-- v4: adds the sender's recent-window length in minutes (the rates above cover
--     that window), and "4|bye" when sync is turned off
local PROTOCOL = 4
local OLDEST_ACCEPTED = 2
local SEND_EVERY = 30   -- seconds between broadcasts
local MIN_GAP = 5       -- never send more often than this
local STALE_AFTER = 120 -- hide a partner we haven't heard from in this long

ns.partners = {}  -- [name] = { elapsed, kills, xp, coin, loot, lootAH, recent = {c,l,la}|nil, window, at }
local versionNoticed = {}  -- [name] = true once we've said their version differs
local windowNoticed = {}   -- [name] = "theirs/ours" once we've said the windows differ
local registered = false
local lastSent = -math.huge

-- force: send even before the clock starts (used right after a reset so the
-- partner's window drops our old numbers immediately).
local function CanSend(force)
  return registered and ns.DB and ns.DB.sync and ns.SendAddon and ns.S
    and (force or ns.S.started)
    and IsInGroup and IsInGroup()
end

-- Older clients return nothing/true; newer ones a result code where 0 = success.
-- Anything else (throttled, restricted in an encounter, ...) means retry later.
local function Sent(ok, result)
  return ok and (result == nil or result == true or result == 0)
end

local function RecentOrMinus(field)
  local r = ns.RecentRate({ field })
  return r and math.floor(r + 0.5) or -1
end

function ns.SyncPayload()
  return string.format("%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d", PROTOCOL, math.floor(ns.Elapsed()),
    ns.Total({ "k" }), ns.Total({ "x" }), ns.Total({ "c" }), ns.Total({ "l" }), ns.Total({ "la" }),
    RecentOrMinus("c"), RecentOrMinus("l"), RecentOrMinus("la"), ns.DB.windowMinutes)
end

function ns.SyncSend(force)
  if not CanSend(force) then return false end
  local now = GetTime()
  if now - lastSent < MIN_GAP and not force then return false end
  local channel = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
  local sent = Sent(pcall(ns.SendAddon, PREFIX, ns.SyncPayload(), channel))
  if sent then lastSent = now end
  return sent
end

-- Sent when you turn sync off, so the partner's window drops you right away
-- instead of after STALE_AFTER. (Older versions ignore it: it fails their format check.)
function ns.SyncBye()
  if not (registered and ns.SendAddon and IsInGroup and IsInGroup()) then return false end
  local channel = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
  return Sent(pcall(ns.SendAddon, PREFIX, PROTOCOL .. "|bye", channel))
end

-- A partner's gold, valued with *our* price setting so the duo row adds like with like.
function ns.PartnerGold(p)
  return p.coin + (ns.DB.priceSource == "auction" and p.lootAH or p.loot)
end

-- Their recent gold/hr in our price setting, or nil (older version, not enough
-- data, or measured over a different window than ours, which wouldn't add up).
function ns.PartnerRecentGold(p)
  local r = p.recent
  if not r or p.window ~= ns.DB.windowMinutes then return nil end
  return r.c + (ns.DB.priceSource == "auction" and r.la or r.l)
end

function ns.ActivePartners()
  local list, now = {}, GetTime()
  for name, p in pairs(ns.partners) do
    if now - p.at <= STALE_AFTER then
      list[#list + 1] = { name = name, data = p }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local function ShortName(sender)
  if Ambiguate then
    local ok, short = pcall(Ambiguate, sender, "short")
    if ok and type(short) == "string" then return short end
  end
  return (sender:match("^[^%-]+")) or sender
end

ns.On("CHAT_MSG_ADDON", function(prefix, text, _, sender)
  if not (ns.DB and ns.DB.sync) then return end
  prefix, text, sender = plain(prefix), plain(text), plain(sender)
  if prefix ~= PREFIX or type(text) ~= "string" or type(sender) ~= "string" then return end
  local name = ShortName(sender)
  if name == ns.PlayerName() then return end
  if text:match("^%d+|bye$") then
    ns.partners[name] = nil
    ns.Log("sync", "%s turned sync off", name)
    if ns.UpdateDisplay then ns.UpdateDisplay() end
    return
  end
  if not text:match("^%d+|[%d|%-]+$") or text:find("||", 1, true) then return end
  local ver = tonumber(text:match("^(%d+)|"))
  if ver < OLDEST_ACCEPTED or ver > PROTOCOL then
    if not versionNoticed[name] then
      versionNoticed[name] = true
      ns.Print(string.format("%s runs %s GrindWatch, so duo sync is off between you. "
        .. "Both of you need the latest version.", name, ver > PROTOCOL and "a newer" or "an older"))
    end
    return
  end
  if ver < PROTOCOL and not versionNoticed[name] then
    -- We can read theirs, but their older version ignores ours.
    versionNoticed[name] = true
    ns.Print(string.format("%s runs an older GrindWatch: you see their numbers, but they "
      .. "can't see yours until they update.", name))
  end
  local fields = {}
  for v in text:gmatch("(%-?%d+)") do fields[#fields + 1] = tonumber(v) end
  local needed = ({ [2] = 7, [3] = 10, [4] = 11 })[ver]
  if #fields ~= needed then return end
  for i = 2, 7 do if fields[i] < 0 then return end end
  local recent
  if ver >= 3 and fields[8] >= 0 and fields[9] >= 0 and fields[10] >= 0 then
    recent = { c = fields[8], l = fields[9], la = fields[10] }
  end
  -- v2/v3 always used 15 minutes. Any sane length is accepted (a later version
  -- may allow other lengths; the mismatch message then explains), 0 or a day+ isn't.
  local window = 15
  if ver >= 4 then
    window = fields[11]
    if window < 1 or window > 1440 then window = nil end
  end
  local ours = ns.DB.windowMinutes
  if recent and window and window ~= ours and windowNoticed[name] ~= window .. "/" .. ours then
    windowNoticed[name] = window .. "/" .. ours
    ns.Print(string.format("%s's recent window is %d min and yours is %d, so their recent rate and the "
      .. "duo's can't be shown. Set the same 'Recent window' (/gw settings) to see them.", name, window, ours))
  end
  local isNew = ns.partners[name] == nil
  ns.partners[name] = {
    elapsed = fields[2], kills = fields[3], xp = fields[4],
    coin = fields[5], loot = fields[6], lootAH = fields[7], recent = recent, window = window, at = GetTime(),
  }
  ns.Log("sync", "from %s: v%d, %ds tracked", name, ver, fields[2])
  -- Answer a newcomer soon (as soon as the send gap allows) so both windows fill
  -- in without waiting for the next 30s mark.
  if isNew then ns.RequestSync() end
  if ns.UpdateDisplay then ns.UpdateDisplay() end
end)

ns.On("GROUP_ROSTER_UPDATE", function()
  if not (IsInGroup and IsInGroup()) then wipe(ns.partners) end
end)

ns.Listen("READY", function()
  if ns.RegisterPrefix then
    -- Older clients return true/false; newer ones a result code where
    -- 0 = success and 1 = already registered (also fine).
    local ok, result = pcall(ns.RegisterPrefix, PREFIX)
    registered = ok and (result == nil or result == true or result == 0 or result == 1) or false
  end
end)

-- Every 30s a send becomes due; it's retried each second until it goes through
-- (e.g. after a restricted moment), so heavy farming can't starve the partner row.
local due = false
function ns.RequestSync()
  due = true
  if ns.SyncSend() then due = false end
end
ns.Listen("TICK", function(count)
  if count % SEND_EVERY == 0 then due = true end
  if due and ns.SyncSend() then due = false end
end)

ns.Listen("RESET", function()
  ns.SyncSend(true)
end)
