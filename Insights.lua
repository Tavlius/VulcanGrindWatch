-- GrindWatch: insights. The trend shown next to the status, a "spot is slowing
-- down" alert, and a hint when you've drifted into a different zone.
local _, ns = ...
local plain = ns.plain

-- Thresholds (alert %, minimum session, cooldown, zone hint) are settings:
-- see Settings.lua.

-- The number that matters right now: XP while leveling, gold at max level.
function ns.PrimaryMetric()
  if ns.AtMaxLevel() then return ns.GoldFields(), "gold", true end
  return { "x" }, "XP", false
end

-- Recent window vs whole session for the primary metric: +0.12 means 12% faster
-- now. Nil until the session is longer than the window (before that they're the same).
function ns.Trend()
  if ns.Elapsed() <= ns.RecentWindow() then return nil end
  local fields = ns.PrimaryMetric()
  local session, recent = ns.SessionRate(fields), ns.RecentRate(fields)
  if not session or not recent or session <= 0 then return nil end
  return recent / session - 1, recent, session
end

function ns.CheckAlert()
  if not ns.DB.alerts or ns.ClockState() ~= "running" then return false end
  if ns.Elapsed() < ns.DB.alertMinMinutes * 60 then return false end
  local trend, recent, session = ns.Trend()
  if not trend or trend >= ns.AlertRatio() - 1 then return false end
  -- Kept in the session (wall clock), so a /reload doesn't reset the cooldown.
  local S = ns.S
  if S.lastAlertAt and time() - S.lastAlertAt < ns.DB.alertCooldownMinutes * 60 then return false end
  S.lastAlertAt = time()
  local _, label, money = ns.PrimaryMetric()
  local fmt = money and ns.Money or ns.Short
  ns.Print(string.format("this spot is slowing down: %s/hr over the last %d min vs %s/hr for the session (%d%%). "
    .. "Time to move? (/gw alert turns this off)", fmt(recent), ns.DB.windowMinutes, fmt(session),
    math.floor(trend * 100 + 0.5)))
  if UIErrorsFrame and UIErrorsFrame.AddMessage then
    pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, "GrindWatch: " .. label .. " rate is dropping", 1, 0.6, 0)
  end
  if ns.DB.alertSound and PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
    pcall(PlaySound, SOUNDKIT.RAID_WARNING)
  end
  ns.Log("alert", "trend %.2f (recent %.0f vs session %.0f)", trend, recent, session)
  return true
end

function ns.CheckZone()
  local S = ns.S
  if not S.started or ns.ClockState() ~= "running" then return false end
  local zone = GetRealZoneText and plain(GetRealZoneText())
  local top = ns.TopZone()
  -- Hinted zones live in the session, so a /reload doesn't repeat the hint.
  S.hintedZones = S.hintedZones or {}
  if type(zone) ~= "string" or zone == "" or not top or zone == top or S.hintedZones[zone] then return false end
  local minutes = ns.DB.zoneHintMinutes
  if minutes <= 0 or (S.zones[zone] or 0) < minutes * 60 then return false end
  S.hintedZones[zone] = true
  ns.Print(string.format("you've farmed %s for %d+ min, but this session is mostly %s. "
    .. "/gw reset to track %s as its own spot.", zone, minutes, top, zone))
  return true
end

ns.Listen("TICK", function(count)
  if count % 10 ~= 0 then return end
  ns.CheckAlert()
  ns.CheckZone()
end)

-- The alert cooldown and hinted zones live in the session, so a reset clears them.
