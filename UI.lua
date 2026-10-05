-- GrindWatch: the on-screen window. A small grid: label | total | /hr | last N min,
-- plus the gear button that opens the settings menu (SettingsUI.lua).
local _, ns = ...

local PAD_X, PAD_TOP, PAD_BOTTOM, ROW_H, COL_GAP, MIN_WIDTH = 10, 28, 8, 14, 12, 190
local GEAR_SIZE, GEAR_GAP = 14, 4
local GOLD = "|cffffd700"
local DIM = "|cff888888"

local STATUS_TEXT = {
  running = "|cff60ff60Running|r",
  waiting = "|cffaaaaaaWaiting for first pull|r",
  paused = "|cffff6060Paused|r",
  afk = "|cffffa500AFK|r",
  idle = "|cffffa500Idle|r",
}

local frame = CreateFrame("Frame", "VulcanGrindWatchFrame", UIParent,
  BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetSize(MIN_WIDTH, 150)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()
if frame.SetBackdrop then
  frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
end
ns.frame = frame

-- Background opacity setting. The border fades with it, so 0% is text only.
-- Locked at 0%, the window lets clicks through to the world (you can't see its
-- edges, so it shouldn't steal a click on a mob); the gear still works.
function ns.ApplyBackdrop()
  local a = ns.DB and ns.DB.bgAlpha or 0.75
  if frame.SetBackdropColor then
    frame:SetBackdropColor(0, 0, 0, a)
    frame:SetBackdropBorderColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3], math.min(1, a / 0.75))
  end
  frame:EnableMouse(not (a == 0 and ns.DB and ns.DB.locked))
  if ns.DimGear then ns.DimGear() end
end

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", PAD_X, -8)
title:SetText("GrindWatch")
title:SetTextColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3])

local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
status:SetPoint("TOPRIGHT", -(PAD_X + GEAR_SIZE + GEAR_GAP), -9)

-- Low-profile gear: dim until you point at the window, opens the settings menu.
local gear = CreateFrame("Button", "VulcanGrindWatchGearButton", frame)
gear:SetSize(GEAR_SIZE, GEAR_SIZE)
gear:SetPoint("TOPRIGHT", -(PAD_X - 3), -7)
ns.gear = gear
do
  -- The clean grey gear if this client has it (checked with GetFileIDFromPath),
  -- else the gear item icon, which every client has (a missing file would show
  -- as a green square). Cropped: icons have a border.
  local CLEAN, ICON = "Interface\\WorldMap\\Gear_64Grey", "Interface\\Icons\\INV_Misc_Gear_01"
  local path = ICON
  if GetFileIDFromPath then
    local ok, id = pcall(GetFileIDFromPath, CLEAN)
    if ok and id then path = CLEAN end
  end
  ns.gearTexture = path
  for _, layer in ipairs({ "ARTWORK", "HIGHLIGHT" }) do
    local t = gear:CreateTexture(nil, layer)
    t:SetAllPoints()
    t:SetTexture(path)
    if path == ICON then t:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    if layer == "HIGHLIGHT" then t:SetBlendMode("ADD") end
  end
end
-- Brighter when the window is click-through: it gets no hover then, and the
-- gear is the only way left to the menu.
local GEAR_DIM, GEAR_DIM_CLICKTHROUGH, GEAR_BRIGHT = 0.35, 0.6, 1
gear:SetAlpha(GEAR_DIM)
-- Dim again unless you're pointing at the window or its menu is open.
function ns.DimGear()
  -- (A click-through window gets no OnLeave, so its hover doesn't count.)
  local overWindow = frame:IsMouseEnabled() and frame:IsMouseOver()
  if overWindow or gear:IsMouseOver() or (ns.menu and ns.menu:IsShown()) then return end
  gear:SetAlpha(frame:IsMouseEnabled() and GEAR_DIM or GEAR_DIM_CLICKTHROUGH)
end
gear:RegisterForClicks("LeftButtonUp", "RightButtonUp")
gear:SetScript("OnClick", function(self)
  if ns.ToggleMenu then ns.ToggleMenu(self) end
end)
gear:SetScript("OnEnter", function(self)
  self:SetAlpha(GEAR_BRIGHT)
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("GrindWatch menu")
  GameTooltip:AddLine("Settings, pause, lock, compact, report, export, hide, reset.", 1, 1, 1, true)
  GameTooltip:Show()
end)
gear:SetScript("OnLeave", function()
  ns.DimGear()
  if GameTooltip then GameTooltip:Hide() end
end)

local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("BOTTOMLEFT", PAD_X, PAD_BOTTOM)
hint:SetText("drag to move, right-click to pause")

-- cells[row][col], created on demand
local cells = {}
local function Cell(r, c)
  cells[r] = cells[r] or {}
  local fs = cells[r][c]
  if not fs then
    fs = frame:CreateFontString(nil, "OVERLAY", r == 1 and "GameFontDisableSmall" or "GameFontHighlightSmall")
    fs:SetJustifyH(c == 1 and "LEFT" or "RIGHT")
    cells[r][c] = fs
  end
  return fs
end

local function Rate(value, money)
  if not value then return DIM .. "--|r" end
  return money and ns.Money(value, true) or ns.Short(value)
end

-- Compact mode: just the rates that matter, for questing or small screens.
local function CompactRows()
  local gold = ns.GoldFields()
  local rows = { { "Time " .. ns.Duration(ns.Elapsed()), "/hr", ns.RecentLabel(), "" } }
  if not ns.AtMaxLevel() then
    rows[#rows + 1] = { "XP", Rate(ns.SessionRate({ "x" })), Rate(ns.RecentRate({ "x" })), "" }
  end
  rows[#rows + 1] = { GOLD .. "Gold|r", Rate(ns.SessionRate(gold), true), Rate(ns.RecentRate(gold), true), "" }
  rows[#rows + 1] = { "Kills", Rate(ns.SessionRate({ "k" })), Rate(ns.RecentRate({ "k" })), "" }
  return rows
end

-- Builds the table shown in the window. Each row: { label, total, perHour, recent }
function ns.BuildRows()
  if ns.DB.compact then return CompactRows() end
  local gold = ns.GoldFields()
  local lootLabel = ns.DB.priceSource == "auction" and "Loot (AH)" or "Loot"
  local rows = {
    { "", "Total", "/hr", ns.RecentLabel() },
    { "Time", ns.Duration(ns.Elapsed()), "", "" },
    { "Kills", ns.Commas(ns.Total({ "k" })), Rate(ns.SessionRate({ "k" })), Rate(ns.RecentRate({ "k" })) },
  }
  local maxLevel = ns.AtMaxLevel()
  if not maxLevel then
    rows[#rows + 1] = { "XP", ns.Short(ns.Total({ "x" })), Rate(ns.SessionRate({ "x" })), Rate(ns.RecentRate({ "x" })) }
  end
  rows[#rows + 1] = { "Coin", ns.Money(ns.Total({ "c" }), true), Rate(ns.SessionRate({ "c" }), true), Rate(ns.RecentRate({ "c" }), true) }
  rows[#rows + 1] = { lootLabel, ns.Money(ns.Total({ ns.LootField() }), true),
    Rate(ns.SessionRate({ ns.LootField() }), true), Rate(ns.RecentRate({ ns.LootField() }), true) }
  rows[#rows + 1] = { GOLD .. "Gold|r", ns.Money(ns.Total(gold), true), Rate(ns.SessionRate(gold), true), Rate(ns.RecentRate(gold), true) }

  if not maxLevel then
    local ttl, restedEnds = ns.TimeToLevel()
    local rested = ns.Rested()
    local restedText = ""
    if rested then
      restedText = "|cff4da6ffrested " .. ns.Short(rested)
        .. (restedEnds and (", ends in " .. ns.Duration(restedEnds)) or "") .. "|r"
    end
    rows[#rows + 1] = { "To level", ttl and ns.Duration(ttl) or (DIM .. "--|r"), restedText, "" }
  end

  local partners = ns.ActivePartners and ns.ActivePartners() or {}
  if #partners > 0 then
    -- No "duo kills": party XP kills appear in both windows, so summing double-counts.
    -- The duo rate only shows once every rate in it exists; a partial sum would
    -- just be one person's rate under a "duo" label.
    local duo = ns.SessionRate(gold)
    local duoRecent = ns.RecentRate(gold)
    local duoTotal = ns.Total(gold)
    for _, p in ipairs(partners) do
      local d = p.data
      local value = ns.PartnerGold(d)
      local pr = (d.elapsed or 0) >= ns.MIN_RATE_SECONDS and value / d.elapsed * 3600 or nil
      local precent = ns.PartnerRecentGold(d)
      duo = (duo and pr) and (duo + pr) or nil
      duoRecent = (duoRecent and precent) and (duoRecent + precent) or nil
      duoTotal = duoTotal + value
      rows[#rows + 1] = { "|cff66ccff" .. p.name .. "|r", ns.Money(value, true), Rate(pr, true), Rate(precent, true) }
    end
    rows[#rows + 1] = { GOLD .. "Duo gold|r", ns.Money(duoTotal, true), Rate(duo, true), Rate(duoRecent, true) }
  end
  return rows
end

-- Status plus the trend of the number that matters (XP while leveling, gold at
-- max level): recent window vs the session, e.g. "Running +12%". Red below the
-- alert threshold.
local function StatusText()
  local state = ns.ClockState()
  local text = STATUS_TEXT[state] or ""
  local trend = ns.DB.showTrend and ns.Trend and ns.Trend()
  if state == "running" and trend then
    local pct = math.floor(trend * 100 + 0.5)
    local color = pct >= 0 and "|cff60ff60" or (trend < ns.AlertRatio() - 1 and "|cffff6060" or "|cffffa500")
    text = text .. "  " .. color .. (pct >= 0 and "+" or "") .. pct .. "%|r"
  end
  return text
end

local lastSignature  -- skip relayout when nothing on screen changed

function ns.UpdateDisplay(force)
  if not ns.S or not frame:IsShown() then return end
  local statusText = StatusText()
  local rows = ns.BuildRows()
  local parts = { statusText, tostring(ns.DB.locked) }
  for _, row in ipairs(rows) do parts[#parts + 1] = table.concat(row, "\031", 1, 4) end
  local signature = table.concat(parts, "\030")
  if signature == lastSignature and not force then return end
  lastSignature = signature
  status:SetText(statusText)

  local widths = { 0, 0, 0, 0 }
  for r, row in ipairs(rows) do
    for c = 1, 4 do
      local fs = Cell(r, c)
      fs:SetText(row[c] or "")
      fs:Show()
      widths[c] = math.max(widths[c], fs:GetStringWidth() or 0)
    end
  end
  for r = #rows + 1, #cells do
    for c = 1, 4 do cells[r][c]:Hide() end
  end

  -- Column right edges (col 1 is left-aligned at PAD_X).
  local right, x = {}, PAD_X + widths[1]
  for c = 2, 4 do
    x = x + COL_GAP + widths[c]
    right[c] = x
  end
  for r = 1, #rows do
    local y = -(PAD_TOP + (r - 1) * ROW_H)
    for c = 1, 4 do
      local fs = cells[r][c]
      fs:ClearAllPoints()
      if c == 1 then
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD_X, y)
      else
        fs:SetPoint("TOPRIGHT", frame, "TOPLEFT", right[c], y)
      end
    end
  end

  local showHint = not ns.DB.locked
  hint:SetShown(showHint)
  local headerWidth = PAD_X * 2 + (title:GetStringWidth() or 0) + 12 + (status:GetStringWidth() or 0)
    + GEAR_SIZE + GEAR_GAP
  local width = math.max(MIN_WIDTH, right[4] + PAD_X, headerWidth)
  local height = PAD_TOP + #rows * ROW_H + PAD_BOTTOM + (showHint and ROW_H or 0)
  frame:SetSize(width, height)
end

function ns.ApplyPosition()
  local p = ns.DB.point
  frame:ClearAllPoints()
  frame:SetPoint(p[1] or "CENTER", UIParent, p[2] or "CENTER", p[3] or 0, p[4] or 0)
  frame:SetScale(ns.DB.scale or 1)
end

function ns.SetShown(show)
  ns.DB.shown = show and true or false
  frame:SetShown(ns.DB.shown)
  if not ns.DB.shown and ns.HideMenu then ns.HideMenu() end
  ns.UpdateDisplay(true)
end

frame:SetScript("OnDragStart", function(self)
  if not ns.DB.locked then self:StartMoving() end
end)
-- The position is ours (account-wide, in VulcanGrindWatchDB): keep the game from also
-- saving it per character, which could override it at login.
if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
frame:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  if self.SetUserPlaced then self:SetUserPlaced(false) end
  local point, _, relPoint, x, y = self:GetPoint()
  ns.DB.point = { point, relPoint, x, y }
end)
local STATUS_HELP = {
  running = "Counting time.",
  waiting = "The clock starts at your first pull, kill or loot.",
  paused = "Paused. Right-click or /gw resume to continue.",
  afk = "You're flagged AFK. The clock resumes when you're back and active.",
  idle = "No activity for a while, so the clock stopped. A pull, kill or loot restarts it.",
}
frame:SetScript("OnEnter", function(self)
  gear:SetAlpha(GEAR_BRIGHT)
  if not GameTooltip or not ns.S then return end
  local minutes = ns.DB.windowMinutes
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("GrindWatch")
  GameTooltip:AddLine(STATUS_HELP[ns.ClockState()] or "", 1, 1, 1, true)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("/hr = whole session. " .. ns.RecentLabel() .. " = your current pace.", 0.8, 0.8, 0.8, true)
  if ns.DB.showTrend then
    GameTooltip:AddLine("The % next to the status compares your last " .. minutes .. " minutes with the whole "
      .. "session (XP while leveling, gold at max level).", 0.8, 0.8, 0.8, true)
  end
  GameTooltip:AddLine("Right-click: pause/resume.  Gear: settings.  /gw help: all commands.", 0.8, 0.8, 0.8, true)
  GameTooltip:Show()
end)
frame:SetScript("OnLeave", function()
  ns.DimGear()
  if GameTooltip then GameTooltip:Hide() end
end)

frame:SetScript("OnMouseUp", function(_, button)
  if button == "RightButton" and ns.S then ns.SetPaused(not ns.S.paused) end
end)

ns.Listen("READY", function()
  ns.ApplyPosition()
  ns.ApplyBackdrop()
  frame:SetShown(ns.DB.shown)
  ns.UpdateDisplay()
end)
-- Wrapped: callbacks pass arguments (the tick count), which must not be read
-- as UpdateDisplay's "force" flag.
ns.Listen("TICK", function() ns.UpdateDisplay() end)
ns.Listen("RESET", function() ns.UpdateDisplay(true) end)
