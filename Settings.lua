-- GrindWatch: every adjustable setting in one place. Defaults, ranges,
-- validation and side effects live here, so slash commands, the settings
-- window and saved-data repair all agree. (The window is in SettingsUI.lua.)
local _, ns = ...

-- kind: "bool" | "number" | "choice"
-- number: min, max, step (slider step), decimals (stored precision)
-- apply(new, old, before): runs after a change (only when the value actually
--   changed); `before` is what the optional before() returned just ahead of it
-- check(new): returns an error message to refuse the change
-- commitOnRelease: a slider drag only applies when the mouse is released (for
--   settings whose in-between values have side effects: the clock, sync)
local DEFS = {
  -- Window
  { key = "locked", kind = "bool", default = false, section = "Window",
    label = "Lock window position", tip = "Stops the window being dragged and hides the 'drag to move' hint.",
    apply = function()
      if ns.ApplyBackdrop then ns.ApplyBackdrop() end  -- click-through when locked at 0%
      if ns.UpdateDisplay then ns.UpdateDisplay(true) end
    end },
  { key = "compact", kind = "bool", default = false, section = "Window",
    label = "Compact window", tip = "Only the time plus XP, gold and kill rates.",
    apply = function() if ns.UpdateDisplay then ns.UpdateDisplay(true) end end },
  { key = "showTrend", kind = "bool", default = true, section = "Window",
    label = "Show trend %", tip = "The +/-% next to the status: your recent pace vs the whole session.",
    apply = function() if ns.UpdateDisplay then ns.UpdateDisplay(true) end end },
  { key = "scale", kind = "number", default = 1, min = 0.5, max = 2, step = 0.05, decimals = 2, section = "Window",
    label = "Window scale", fmt = function(v) return string.format("%.2fx", v) end,
    tip = "Size of the window. It stays where it is on screen.",
    apply = function(new, old)
      -- Offsets are in the frame's own scaled units: rescale them so the window
      -- stays put on screen.
      local p = ns.DB.point
      if type(p) == "table" and tonumber(p[3]) and tonumber(p[4]) and old and old > 0 then
        p[3], p[4] = p[3] * old / new, p[4] * old / new
      end
      if ns.ApplyPosition then ns.ApplyPosition() end
    end },
  { key = "bgAlpha", kind = "number", default = 0.75, min = 0, max = 1, step = 0.05, decimals = 2, percent = true,
    section = "Window",
    label = "Background opacity", fmt = function(v) return math.floor(v * 100 + 0.5) .. "%" end,
    tip = "How dark the window background is. 0% leaves just the text; if the window is also "
      .. "locked, clicks then go through it to the world (use the gear to pause).",
    apply = function() if ns.ApplyBackdrop then ns.ApplyBackdrop() end end },

  -- Clock
  { key = "autoAFKPause", kind = "bool", default = true, section = "Clock",
    label = "Pause while AFK", tip = "Typing /afk (or going AFK) stops the clock at once.",
    apply = function() if ns.UpdateAFK then ns.UpdateAFK() end end },
  { key = "idleMinutes", kind = "number", default = 5, min = 0, max = 60, step = 1, decimals = 0, offValue = 0,
    section = "Clock", commitOnRelease = true,
    label = "Idle cutoff", fmt = function(v) return v == 0 and "off" or (v .. " min") end,
    tip = "Stop the clock after this long with no pull, kill or loot. The time since your last activity "
      .. "is dropped except one minute for looting and drinking. 0 = off.",
    -- Raising the cutoff (or turning it off) while idle mustn't restart the clock
    -- without you doing anything: stay stopped until the next pull, kill or loot.
    -- (The clock's last ticked state, so dragging the slider past your idle time
    -- and back within a second doesn't count as having been idle.)
    before = function() return ns.LastClockState and ns.LastClockState() == "idle" end,
    apply = function(_, _, wasIdle) if wasIdle and ns.SetAwaiting then ns.SetAwaiting() end end },
  { key = "windowMinutes", kind = "number", default = 15, min = 5, max = 30, step = 5, decimals = 0, section = "Clock",
    commitOnRelease = true,
    label = "Recent window", fmt = function(v) return v .. " min" end,
    tip = "Length of the 'Last' column and the trend. Shorter reacts faster, longer is steadier. "
      .. "You and your partner need the same length to see each other's recent rate.",
    apply = function()
      if ns.UpdateDisplay then ns.UpdateDisplay(true) end
      if ns.RequestSync then ns.RequestSync() end  -- tell the partner now, not in up to 30s
    end },

  -- Loot value
  { key = "priceSource", kind = "choice", default = "vendor", section = "Loot value",
    choices = { "vendor", "auction" }, aliases = { ah = "auction" },
    choiceLabels = { vendor = "Vendor price", auction = "Auction house (Auctionator)" },
    label = "Value loot at", tip = "AH price is after the 5% cut and never below vendor price.",
    check = function(v)
      if v == "auction" and not (ns.HasAuctionator and ns.HasAuctionator()) then
        return "Auctionator isn't loaded, so AH prices aren't available"
      end
    end,
    apply = function() if ns.UpdateDisplay then ns.UpdateDisplay(true) end end },

  -- Alerts
  { key = "alerts", kind = "bool", default = true, section = "Alerts",
    label = "Slowing-down alert", tip = "Warns when your recent pace drops well below your session average." },
  { key = "alertSound", kind = "bool", default = true, section = "Alerts",
    label = "Alert sound", tip = "Play the raid-warning sound with the alert." },
  { key = "alertPercent", kind = "number", default = 60, min = 30, max = 90, step = 5, decimals = 0, section = "Alerts",
    label = "Alert below", fmt = function(v) return v .. "% of session" end,
    tip = "Alert when the recent rate falls below this share of the session rate. Also sets when the trend turns red.",
    apply = function() if ns.UpdateDisplay then ns.UpdateDisplay(true) end end },
  { key = "alertMinMinutes", kind = "number", default = 20, min = 10, max = 60, step = 5, decimals = 0, section = "Alerts",
    label = "Judge after", fmt = function(v)
      -- The trend needs more than one window of data, so a shorter wait does nothing.
      local window = ns.DB and ns.DB.windowMinutes or 15
      if v < window then return v .. " min (waits " .. window .. ")" end
      return v .. " min"
    end,
    tip = "No alert until the session is this long (and longer than the recent window)." },
  { key = "alertCooldownMinutes", kind = "number", default = 15, min = 5, max = 60, step = 5, decimals = 0, section = "Alerts",
    label = "At most one alert per", fmt = function(v) return v .. " min" end,
    tip = "Minimum time between two alerts." },
  { key = "zoneHintMinutes", kind = "number", default = 10, min = 0, max = 30, step = 1, decimals = 0, offValue = 0,
    section = "Alerts",
    label = "Zone hint after", fmt = function(v) return v == 0 and "off" or (v .. " min") end,
    tip = "After this long farming a different zone, suggest /gw reset so each spot gets its own numbers. 0 = off." },

  -- Duo
  { key = "sync", kind = "bool", default = true, section = "Duo",
    label = "Share rates with my group", tip = "Shows your partner's gold/hr and a duo total if they run GrindWatch too.",
    apply = function(new)
      if not new and ns.SyncBye then ns.SyncBye() end  -- so your partner's window drops you now
      if not new and ns.partners then wipe(ns.partners) end
      if new and ns.RequestSync then ns.RequestSync() end
      if ns.UpdateDisplay then ns.UpdateDisplay(true) end
    end },

  -- Diagnostics
  { key = "debug", kind = "bool", default = false, section = "Diagnostics",
    label = "Record diagnostics log", tip = "Logs what the addon sees (loot windows, casts, money). Export it with /gw export debug.",
    apply = function(new) if not new and ns.DB.debugEcho then ns.SetSetting("debugEcho", false) end end },
  { key = "debugEcho", kind = "bool", default = false, section = "Diagnostics",
    label = "Also print it to chat", tip = "Shows each diagnostics line as it happens (turns recording on).",
    apply = function(new) if new and not ns.DB.debug then ns.SetSetting("debug", true) end end },
}

ns.SETTING_DEFS = DEFS
local BY_KEY = {}  -- lower-case name -> definition (names are case-insensitive)
for _, def in ipairs(DEFS) do BY_KEY[def.key:lower()] = def end

function ns.SettingDef(key)
  if type(key) ~= "string" then return nil end
  return BY_KEY[key:lower()]
end

local function Round(v, decimals)
  local m = 10 ^ (decimals or 0)
  return math.floor(v * m + 0.5) / m
end

-- Snaps a slider position to its step, without float junk (0.1+0.2 style).
function ns.SnapSetting(def, v)
  local step = def.step or 1
  local snapped = def.min + math.floor((v - def.min) / step + 0.5) * step
  return Round(math.max(def.min, math.min(def.max, snapped)), def.decimals or 2)
end

local TRUE = { ["true"] = true, on = true, yes = true, ["1"] = true, enable = true, enabled = true }
local FALSE = { ["false"] = true, off = true, no = true, ["0"] = true, disable = true, disabled = true }

-- Turns user input (slash text or a widget value) into a valid value, or nil + why.
function ns.NormalizeSetting(def, value)
  if def.kind == "bool" then
    if type(value) == "boolean" then return value end
    local s = tostring(value):lower()
    if TRUE[s] then return true end
    if FALSE[s] then return false end
    return nil, "use on or off"
  elseif def.kind == "number" then
    local n
    if type(value) == "number" then
      n = value
    else
      -- Accept what the window shows: "off" where 0 means off, "75%" for a percentage.
      local s = tostring(value):lower():gsub("%s", "")
      if s == "off" and def.offValue then return def.offValue end
      local pct = s:match("^(.-)%%$")
      n = tonumber(pct or s)
      -- Percent settings: "50%" or 50 both mean 50%; 0-1 is a fraction. 1.5 is
      -- ambiguous (150%? 1.5%?), so it's refused.
      if n and def.percent and not pct and n > def.max and n < 2 then
        return nil, "use 0-1, or a percentage like 50%"
      end
      if n and def.percent and (pct or n > def.max) then n = n / 100 end
    end
    if not n or n ~= n then return nil, "not a number" end  -- n ~= n: "nan"
    if n < def.min or n > def.max then
      if def.percent then
        return nil, string.format("must be %d%% to %d%%", def.min * 100, def.max * 100)
      end
      return nil, string.format("must be %s to %s", def.min, def.max)
    end
    return Round(n, def.decimals or 2)
  elseif def.kind == "choice" then
    local s = tostring(value):lower()
    s = (def.aliases and def.aliases[s]) or s
    for _, choice in ipairs(def.choices) do
      if s == choice then return choice end
    end
    return nil, "use " .. table.concat(def.choices, " or ")
  end
  return nil, "unknown kind"
end

-- The one way settings change. Returns true, value, old  or  false, message.
-- Fires "SETTING" (key, value, old) so the settings window and display follow
-- changes made from anywhere (slash command, window, reset to defaults).
function ns.SetSetting(key, value)
  local def = ns.SettingDef(key)
  if not def then return false, "unknown setting '" .. tostring(key) .. "'" end
  local v, err = ns.NormalizeSetting(def, value)
  if v == nil then return false, err end
  local old = ns.DB[def.key]
  if v == old then return true, v, old end  -- nothing to do (and nothing to refuse)
  if def.check then
    local why = def.check(v)
    if why then return false, why end
  end
  local before = def.before and def.before()
  ns.DB[def.key] = v
  if def.apply then def.apply(v, old, before) end
  if ns.Fire then ns.Fire("SETTING", def.key, v, old) end
  return true, v, old
end

-- Display text for a setting's current value.
function ns.SettingText(def, v)
  if v == nil then v = ns.DB[def.key] end
  if def.kind == "bool" then return v and "on" or "off" end
  if def.kind == "choice" then return (def.choiceLabels and def.choiceLabels[v]) or tostring(v) end
  return def.fmt and def.fmt(v) or tostring(v)
end

-- Repairs saved settings (hand-edited or from an older version): a wrong type
-- goes back to the default, an out-of-range number is clamped. Returns the
-- keys that were changed.
function ns.SanitizeSettings(db)
  local fixed = {}
  for _, def in ipairs(DEFS) do
    local v = db[def.key]
    local good
    if def.kind == "bool" then
      if type(v) == "boolean" then good = v else good = def.default end
    elseif def.kind == "number" then
      local n = type(v) == "number" and v or nil
      if not n or n ~= n or n == math.huge or n == -math.huge then
        good = def.default
      else
        good = Round(math.max(def.min, math.min(def.max, n)), def.decimals or 2)
      end
    else
      good = def.default
      for _, choice in ipairs(def.choices) do
        if v == choice then good = v end
      end
    end
    if good ~= v then
      -- Rounding a valid value to the setting's precision isn't worth a message.
      local rounded = def.kind == "number" and type(v) == "number" and v >= def.min and v <= def.max
      if v ~= nil and not rounded then fixed[#fixed + 1] = def.key end
      db[def.key] = good
    end
  end
  -- Echo without recording can only come from a hand edit; keep the pair consistent.
  if db.debugEcho and not db.debug then db.debugEcho = false end
  return fixed
end

-- Back to defaults. Position, history and added spells are kept.
function ns.ResetSettings()
  for _, def in ipairs(DEFS) do ns.SetSetting(def.key, def.default) end
end

-- Values read by the rest of the addon.
function ns.RecentWindow() return (ns.DB and ns.DB.windowMinutes or 15) * 60 end
function ns.RecentLabel() return "Last " .. (ns.DB and ns.DB.windowMinutes or 15) .. "m" end
function ns.AlertRatio() return (ns.DB and ns.DB.alertPercent or 60) / 100 end
