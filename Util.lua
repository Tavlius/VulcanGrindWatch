-- GrindWatch: shared helpers (compatibility shims, formatting, chat patterns).
local ADDON_NAME, ns = ...
ns.name = ADDON_NAME

---------------------------------------------------------------------------
-- Compatibility
---------------------------------------------------------------------------
-- Forever runs Midnight's addon restrictions: some values come back "secret" and
-- throw if compared or printed. plain() turns those into nil so callers just skip.
local issecret = issecretvalue or function() return false end

-- The secret check must come first: even `v == nil` on a secret value throws.
function ns.plain(v)
  if issecret(v) then return nil end
  return v
end
ns.IsSecret = issecret

ns.GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
ns.RequestItemLoad = (C_Item and C_Item.RequestLoadItemDataByID) or nil
ns.SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
ns.SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
ns.RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix

-- Vulcan Suite accent ("ember"), shared by all four add-ons: chat name, titles, borders.
ns.ACCENT = { 0.91, 0.47, 0.17 }
ns.ACCENT_CODE = "|cffe8792b"

function ns.Print(msg)
  print(ns.ACCENT_CODE .. "GrindWatch|r: " .. tostring(msg))
end

---------------------------------------------------------------------------
-- Diagnostics log (/gw debug). Off by default; when on, events the addon makes
-- decisions from are recorded so in-game behavior can be checked against the
-- design. Kept in SavedVariables (VulcanGrindWatchDB.debugLog) so it survives a
-- reload and can be shared from the WTF folder or /gw export debug.
---------------------------------------------------------------------------
ns.DEBUG_MAX = 300

function ns.Log(category, fmt, ...)
  local db = ns.DB
  if not db or not db.debug then return end
  local ok, text = pcall(string.format, fmt, ...)
  if not ok then text = tostring(fmt) end
  -- Wall-clock time so entries line up with what you remember doing; GetTime()
  -- seconds too, since several events often land in the same second.
  local clock = date and date("%H:%M:%S") or "?"
  local t = GetTime and GetTime() or 0
  local log = db.debugLog
  log[#log + 1] = string.format("%s (%.1f) %s: %s", clock, t, category, text)
  while #log > ns.DEBUG_MAX do table.remove(log, 1) end
  if db.debugEcho then ns.Print("|cff888888[" .. category .. "]|r " .. text) end
end

-- Short, safe description of a GUID for the log ("Creature-...-1234-ABCD").
function ns.GUIDTag(guid)
  if type(guid) ~= "string" then return tostring(guid) end
  local kind = guid:match("^(%a+)%-") or "?"
  return kind .. ":" .. (guid:match("([^%-]+%-[^%-]+)$") or guid)
end

-- Cached on first successful read so a later secret value can't make us
-- mistake our own echoed sync messages for a partner's.
local playerName
function ns.PlayerName()
  if not playerName then playerName = ns.plain(UnitName("player")) end
  return playerName
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
function ns.Commas(n)
  n = math.floor((n or 0) + 0.5)
  local sign = n < 0 and "-" or ""
  local digits = tostring(math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return sign .. (digits:gsub("^,", ""))
end

-- Thresholds sit just under the boundary so rounding can't produce "1000.0k".
function ns.Short(n)
  n = n or 0
  local a = math.abs(n)
  if a >= 999950 then return string.format("%.1fm", n / 1e6) end
  if a >= 9999.5 then return string.format("%.1fk", n / 1e3) end
  return ns.Commas(n)
end

function ns.Money(copper, colored)
  copper = math.floor((copper or 0) + 0.5)
  local sign = copper < 0 and "-" or ""
  copper = math.abs(copper)
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local G, Sv, C = "g", "s", "c"
  if colored then
    G, Sv, C = "|cffffd700g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"
  end
  if g > 0 then return string.format("%s%s%s %d%s", sign, ns.Commas(g), G, s, Sv) end
  if s > 0 then return string.format("%s%d%s %d%s", sign, s, Sv, c, C) end
  return string.format("%s%d%s", sign, c, C)
end

function ns.Duration(sec)
  sec = math.max(0, math.floor(sec or 0))
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  if h > 0 then return string.format("%dh %02dm", h, m) end
  return string.format("%dm %02ds", m, sec % 60)
end

-- Cuts text to at most maxBytes without splitting a UTF-8 character (accented
-- letters are 2+ bytes; a half character shows up as garbage).
function ns.Truncate(text, maxBytes)
  local out, used = {}, 0
  for ch in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if used + #ch > maxBytes then break end
    out[#out + 1] = ch
    used = used + #ch
  end
  return table.concat(out)
end

-- Chat can't carry color codes (the server rejects them), so reports strip
-- them before sending, in case a zone, note or name ever brings one along.
function ns.StripColors(text)
  return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

---------------------------------------------------------------------------
-- Chat message patterns, built from the client's own localized strings
---------------------------------------------------------------------------
-- "You receive loot: %sx%d." -> "^You receive loot: (.+)x(%d+)%."
function ns.FormatToPattern(fmt)
  if type(fmt) ~= "string" or fmt == "" then return nil end
  local p = fmt
  p = p:gsub("%%%d+%$s", "\001"):gsub("%%%d+%$d", "\002")
  p = p:gsub("%%s", "\001"):gsub("%%d", "\002")
  p = p:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("\001", "(.+)"):gsub("\002", "(%%d+)")
  return "^" .. p
end

-- Multi-quantity first: the single pattern would also match "...x3.".
ns.LOOT_PATTERNS = {}
for _, fmt in ipairs({
  LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d.",
  LOOT_ITEM_SELF or "You receive loot: %s.",
}) do
  local pat = ns.FormatToPattern(fmt)
  if pat then ns.LOOT_PATTERNS[#ns.LOOT_PATTERNS + 1] = pat end
end

-- "<mob> dies, you gain %d experience." The rested and group-bonus variants add
-- a suffix, so the pattern has no end anchor. When the name comes first, matching
-- up to the number is enough. When the number comes first, the whole format is
-- used so the mob name is still captured and a plain "you gain N experience"
-- (quest, exploration) can't pass for a kill.
do
  local fmt = COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience."
  local sPos = fmt:find("%%%d*%$?s")
  local dPos, dEnd = fmt:find("%%%d*%$?d")
  if sPos and dPos and sPos < dPos then
    ns.KILL_XP_PATTERN = ns.FormatToPattern(fmt:sub(1, dEnd))
  else
    ns.KILL_XP_PATTERN = ns.FormatToPattern(fmt)
  end
end
