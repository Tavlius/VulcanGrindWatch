-- GrindWatch: a copy window. WoW can't write files or touch the clipboard, so
-- exports open in a text box with everything selected: press Ctrl+C, then paste
-- anywhere (a spreadsheet, Discord, a bug report).
local _, ns = ...

local copyFrame, editBox

local function BuildCopyFrame()
  local f = CreateFrame("Frame", "VulcanGrindWatchCopyFrame", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(560, 360)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.9)
  end

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -10)
  f.title = title

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local scroll = CreateFrame("ScrollFrame", "VulcanGrindWatchCopyScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -32)
  scroll:SetPoint("BOTTOMRIGHT", -30, 12)

  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetAutoFocus(true)
  box:SetFontObject(ChatFontNormal)
  box:SetWidth(510)
  box:SetScript("OnEscapePressed", function() f:Hide() end)
  -- Read-only: a stray key (W to walk) would replace the selected export, so
  -- typing puts the text back. (userInput is false for our own SetText.)
  box:SetScript("OnTextChanged", function(self, userInput)
    if userInput and f.exportText then
      self:SetText(f.exportText)
      self:HighlightText()
    end
  end)
  scroll:SetScrollChild(box)

  -- Esc closes it even when the text box doesn't have focus.
  if UISpecialFrames then table.insert(UISpecialFrames, "VulcanGrindWatchCopyFrame") end
  copyFrame, editBox = f, box
end

-- Shows text ready to copy. Returns the text (handy for tests).
function ns.ShowCopy(titleText, lines)
  if not copyFrame then BuildCopyFrame() end
  local text = table.concat(lines, "\n")
  copyFrame.exportText = text
  copyFrame.title:SetText(titleText .. "  |cff888888(Ctrl+C to copy, Esc to close)|r")
  editBox:SetText(text)
  editBox:HighlightText()
  copyFrame:Show()
  copyFrame:Raise()  -- above the settings window when opened from it
  editBox:SetFocus()
  return text
end

local function CSVField(v)
  v = tostring(v == nil and "" or v)
  if v:find('[,"\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
  return v
end

local CSV_HEADER = "date,character,zone,label,minutes,kills,xp,coin_copper,loot_vendor_copper,"
  .. "loot_ah_copper,gold_per_hour,kills_per_hour,xp_per_hour"

local function CSVRow(h)
  -- Older history entries can lack fields; treat missing numbers as 0.
  local kills, xp, coin, loot = h.kills or 0, h.xp or 0, h.coin or 0, h.loot or 0
  local lootAH = h.lootAH or loot
  local hours = h.elapsed / 3600
  local enough = h.elapsed >= ns.MIN_RATE_SECONDS
  local gold = coin + (ns.DB.priceSource == "auction" and lootAH or loot)
  local when = (h.when and h.when > 0 and date) and date("%Y-%m-%d %H:%M", h.when) or (h.note or "")
  local function rate(v) return enough and string.format("%.1f", v / hours) or "" end
  return table.concat({
    CSVField(when), CSVField(h.char), CSVField(h.zone), CSVField(h.label),
    string.format("%.1f", h.elapsed / 60), kills, xp, coin, loot, lootAH,
    enough and string.format("%.2f", gold / hours / 10000) or "", rate(kills), rate(xp),
  }, ",")
end

-- The live session in the same shape as a history entry.
function ns.CurrentAsHistory()
  local S = ns.S
  return {
    when = S.startedAt, char = ns.PlayerName(), zone = ns.TopZone(), label = S.note,
    elapsed = ns.Elapsed(), kills = ns.Total({ "k" }), xp = ns.Total({ "x" }),
    coin = ns.Total({ "c" }), loot = ns.Total({ "l" }), lootAH = ns.Total({ "la" }),
  }
end

function ns.ExportLines(what)
  if what == "debug" then
    local lines = { "GrindWatch diagnostics (" .. #ns.DB.debugLog .. " entries)" }
    for _, l in ipairs(ns.DB.debugLog) do lines[#lines + 1] = l end
    return lines
  end
  local lines = { CSV_HEADER }
  if ns.S.started then lines[#lines + 1] = CSVRow(ns.CurrentAsHistory()) end
  for _, h in ipairs(ns.DB.history) do lines[#lines + 1] = CSVRow(h) end
  return lines
end
