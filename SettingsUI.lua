-- GrindWatch: the gear menu on the window and the settings window.
-- Every control goes through ns.SetSetting (Settings.lua), the same path as the
-- slash commands, and redraws from the saved value, so the two never disagree.
local _, ns = ...

local BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
local CONFIRM_SECONDS = 4  -- a destructive click must be repeated within this
local PANEL_W, PANEL_H = 560, 520

-- CreateFrame with a Blizzard template, falling back to plain styling if this
-- client doesn't have the template (they get renamed between versions). A
-- missing template may raise an error or just give a bare frame, so check what
-- the template should have built: textures (buttons) or a Left piece (edit box).
-- The fallback is made with BackdropTemplate: since 9.0 only those frames
-- have SetBackdrop, and the hand styling below needs it.
local function Make(kind, parent, template, name)
  if template then
    local ok, f = pcall(CreateFrame, kind, name, parent, template)
    if ok and f then
      if f.Left or (f.GetNormalTexture and f:GetNormalTexture()) then return f, true end
      f:Hide()  -- a bare frame from a missing template: replaced below
    end
  end
  return CreateFrame(kind, name, parent, BackdropTemplateMixin and "BackdropTemplate" or nil), false
end

local function Backdrop(f, alpha)
  if f.SetBackdrop then
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0.05, 0.05, 0.05, alpha or 0.95)
    f:SetBackdropBorderColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3], 1)
  end
end

-- Two-click confirmation: the first click arms the button and changes its
-- text; a second click within CONFIRM_SECONDS runs it.
local function Confirmer(setText, normal, armed)
  local armedAt
  local c = {}
  function c.click()
    local now = GetTime()
    if armedAt and now - armedAt <= CONFIRM_SECONDS then
      armedAt = nil
      setText(normal)
      return true
    end
    armedAt = now
    setText(armed)
    if C_Timer and C_Timer.After then
      C_Timer.After(CONFIRM_SECONDS, function()
        if armedAt == now then armedAt = nil setText(normal) end
      end)
    end
    return false
  end
  function c.disarm() armedAt = nil setText(normal) end
  return c
end

local function ShowTooltip(owner, title, body, warning, default)
  if not GameTooltip then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:AddLine(title)
  if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
  if default then GameTooltip:AddLine(default, 0.6, 0.8, 1, true) end
  if warning then GameTooltip:AddLine(warning, 1, 0.4, 0.4, true) end
  GameTooltip:Show()
end

-- "Default: 5 min" (plus "(changed)") for a setting's tooltip.
local function DefaultLine(def)
  local changed = ns.DB[def.key] ~= def.default
  return "Default: " .. ns.SettingText(def, def.default) .. (changed and "  (you changed this)" or "")
end
local CHANGED_COLOR = { 0.4, 0.8, 1 }  -- labels of settings you've changed from the default
local function HideTooltip() if GameTooltip then GameTooltip:Hide() end end

-- The usual UI click sounds (silent if this client names them differently).
local function Sound(name)
  local id = SOUNDKIT and SOUNDKIT[name]
  if id and PlaySound then pcall(PlaySound, id) end
end

---------------------------------------------------------------------------
-- Gear menu
---------------------------------------------------------------------------
local menu = CreateFrame("Frame", "VulcanGrindWatchMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
menu:SetFrameStrata("FULLSCREEN_DIALOG")  -- above the settings window (DIALOG)
menu:SetClampedToScreen(true)
menu:EnableMouse(true)
menu:Hide()
Backdrop(menu)
ns.menu = menu
if UISpecialFrames then table.insert(UISpecialFrames, "VulcanGrindWatchMenu") end  -- Escape closes it

local MENU_ROW, MENU_PAD, MENU_MIN = 16, 6, 130
local menuRows = {}
ns.menuRows = menuRows  -- (for tests)
local resetConfirm

-- Labels are functions so they show what a click will do right now.
local MENU_ITEMS = {
  { label = function() return "Settings..." end, run = function() ns.OpenSettings() end },
  { label = function() return ns.S.paused and "Resume" or "Pause" end,
    run = function() ns.SetPaused(not ns.S.paused) end },
  { label = function() return ns.DB.locked and "Unlock position" or "Lock position" end,
    run = function() ns.SetSetting("locked", not ns.DB.locked) end },
  { label = function() return ns.DB.compact and "Full window" or "Compact window" end,
    run = function() ns.SetSetting("compact", not ns.DB.compact) end },
  { label = function() return "Report (to your chat)" end, run = function() ns.RunCommand("report") end },
  { label = function() return "Export history" end, run = function() ns.RunCommand("export") end },
  { label = function() return "Hide window" end,
    run = function()
      ns.SetShown(false)
      ns.Print("window hidden. /gw (or the addon menu by the minimap) brings it back.")
    end,
    tip = "Bring it back with /gw or the addon menu by the minimap." },
  { label = function() return "|cffff8080Reset session|r" end, confirm = true,
    run = function() ns.RunCommand("reset") end,
    tip = "Saves this session to history and starts a new one. Click twice to confirm." },
}

-- Menu items added by optional modules (Persist.lua), before "Hide window".
for i, item in ipairs(ns.extraMenuItems or {}) do table.insert(MENU_ITEMS, 6 + i, item) end

local function MenuRow(i)
  local row = menuRows[i]
  if row then return row end
  row = CreateFrame("Button", nil, menu)
  row:SetHeight(MENU_ROW)
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  hl:SetBlendMode("ADD")
  local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT", 6, 0)
  text:SetJustifyH("LEFT")
  row.text = text
  menuRows[i] = row
  return row
end

local function LayoutMenu()
  local width = MENU_MIN
  for i, item in ipairs(MENU_ITEMS) do
    local row = MenuRow(i)
    -- (Relabelling an open menu mustn't hide an armed reset's warning.)
    if not (item.confirm and menu:IsShown()) then row.text:SetText(item.label()) end
    width = math.max(width, (row.text:GetStringWidth() or 0) + 20)
  end
  for i = 1, #MENU_ITEMS do
    local row = menuRows[i]
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", menu, "TOPLEFT", MENU_PAD, -MENU_PAD - (i - 1) * MENU_ROW)
    row:SetWidth(width)
  end
  menu:SetSize(width + MENU_PAD * 2, #MENU_ITEMS * MENU_ROW + MENU_PAD * 2)
end

for i, item in ipairs(MENU_ITEMS) do
  local row = MenuRow(i)
  local confirm
  if item.confirm then
    confirm = Confirmer(function(t) row.text:SetText(t) end, item.label(), "|cffff4040Click again to reset|r")
    resetConfirm = confirm
  end
  row:SetScript("OnClick", function()
    if not ns.S then return end
    Sound("U_CHAT_SCROLL_BUTTON")
    if confirm and not confirm.click() then return end  -- first click only arms it
    menu:Hide()
    item.run()
  end)
  if item.tip then
    row:SetScript("OnEnter", function(self) ShowTooltip(self, item.label(), item.tip) end)
    row:SetScript("OnLeave", HideTooltip)
  end
end

-- Closing on a click anywhere else. GLOBAL_MOUSE_DOWN is only registered while
-- the menu is open; clients without it fall back to closing a few seconds
-- after the pointer leaves the menu.
local globalClicks = false
menu:SetScript("OnShow", function(self)
  globalClicks = pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN") and true or false
end)
menu:SetScript("OnHide", function(self)
  if globalClicks then pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN") end
  if resetConfirm then resetConfirm.disarm() end
  if ns.DimGear then ns.DimGear() end  -- it stayed bright while the menu was open
end)
menu:SetScript("OnEvent", function(self)
  if not self:IsMouseOver() and not (ns.gear and ns.gear:IsMouseOver()) then self:Hide() end
end)
local awayFor = 0
menu:SetScript("OnUpdate", function(self, elapsed)
  if globalClicks then return end
  if self:IsMouseOver() or (ns.gear and ns.gear:IsMouseOver()) then
    awayFor = 0
  else
    awayFor = awayFor + (elapsed or 0)
    if awayFor > 3 then self:Hide() end
  end
end)

function ns.HideMenu() menu:Hide() end

-- Labels say what a click will do, so they follow changes made while the menu
-- is open (a key binding, a slash command): "Pause" must not resume.
function ns.RelabelMenu() if menu:IsShown() then LayoutMenu() end end
ns.Listen("SETTING", ns.RelabelMenu)
ns.Listen("RESET", ns.RelabelMenu)

function ns.ToggleMenu(anchor)
  if menu:IsShown() then menu:Hide() return end
  if not ns.S then return end
  awayFor = 0
  LayoutMenu()
  anchor = anchor or ns.frame
  menu:ClearAllPoints()
  -- Open downward unless that would run off the bottom of the screen (clamping
  -- would then push the menu up over the gear).
  local bottom = anchor.GetBottom and anchor:GetBottom()
  local scale = anchor.GetEffectiveScale and anchor:GetEffectiveScale() or 1
  local menuScale = menu.GetEffectiveScale and menu:GetEffectiveScale() or 1
  local _, height = menu:GetSize()
  if type(bottom) == "number" and type(height) == "number" and bottom * scale < (height + 4) * menuScale then
    menu:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 2)
    ns.menuOpensUp = true
  else
    menu:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
    ns.menuOpensUp = false
  end
  menu:Show()
  menu:Raise()
  HideTooltip()  -- the gear's tooltip would sit over the menu's rows
end

---------------------------------------------------------------------------
-- Settings window (built the first time it opens)
---------------------------------------------------------------------------
local panel
local controls = {}  -- [settingKey] = { kind, widget(s), refresh }
local refreshing = false
local extras = {}    -- other things Refresh updates (the spell list)
local commits = {}   -- finish slider drags (when the window closes mid-drag)

-- Puts every control in line with the saved settings. Each control is
-- refreshed on its own (one failing can't leave the rest stuck), and the
-- guard is restored, not just cleared, in case of nesting.
local function Refresh()
  if not panel or not ns.DB then return end
  local was = refreshing
  refreshing = true
  for key, c in pairs(controls) do
    local ok, err = pcall(c.refresh)
    if not ok then ns.ReportError("settings window (" .. key .. ")", err) end  -- shown once
  end
  for _, fn in ipairs(extras) do
    local ok, err = pcall(fn)
    if not ok then ns.ReportError("settings window", err) end
  end
  refreshing = was
end

local function Change(key, value)
  local ok, why = ns.SetSetting(key, value)
  if not ok then ns.Print(why .. ".") end
  Refresh()  -- also puts a refused value back, and updates greyed-out controls
end

-- Greyed out (with the reason in the tooltip) when another setting makes it moot.
-- (Not alertPercent: it also sets when the trend turns red, alerts or not.)
local DEPENDS = {
  alertSound = "alerts", alertMinMinutes = "alerts", alertCooldownMinutes = "alerts",
}

-- Greyed out when disabled; light blue when changed from the default, so you
-- can see at a glance what you've customized.
local function SetEnabled(widget, label, on, changed)
  if on then widget:Enable() else widget:Disable() end
  if label then
    if not on then
      label:SetTextColor(0.5, 0.5, 0.5)
    elseif changed then
      label:SetTextColor(CHANGED_COLOR[1], CHANGED_COLOR[2], CHANGED_COLOR[3])
    else
      label:SetTextColor(1, 1, 1)
    end
  end
end

local function Column(x)
  return { x = x, y = -36 }
end

local function Header(col, text)
  local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("TOPLEFT", col.x, col.y)
  fs:SetText(text)
  col.y = col.y - 18
end

local function CheckButton(col, x, template)
  local cb, templated = Make("CheckButton", panel, template)
  cb:SetSize(22, 22)
  if not templated then
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    cb:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
  end
  cb:SetPoint("TOPLEFT", col.x + (x or 0), col.y)
  -- A disabled button gets no OnEnter/OnLeave unless told to, and the tooltip
  -- is where a greyed option says why (Blizzard's own settings do the same).
  if cb.SetMotionScriptsWhileDisabled then cb:SetMotionScriptsWhileDisabled(true) end
  -- Own label: templates name their text region differently across clients.
  local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  return cb, label
end

local function Check(col, key)
  local def = ns.SettingDef(key)
  local cb, label = CheckButton(col, 0, "UICheckButtonTemplate")
  label:SetText(def.label)
  cb:SetHitRectInsets(0, -((label:GetStringWidth() or 0) + 4), 0, 0)  -- the label is clickable too
  cb:SetScript("OnClick", function(self)
    if refreshing then return end
    Sound(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
    Change(key, self:GetChecked() and true or false)
  end)
  cb:SetScript("OnEnter", function(self)
    local dep = DEPENDS[key]
    ShowTooltip(self, def.label, def.tip,
      dep and not ns.DB[dep] and ("Turn on '" .. ns.SettingDef(dep).label .. "' first.") or nil, DefaultLine(def))
  end)
  cb:SetScript("OnLeave", HideTooltip)
  controls[key] = { kind = "bool", widget = cb, label = label, refresh = function()
    cb:SetChecked(ns.DB[key] and true or false)
    local dep = DEPENDS[key]
    SetEnabled(cb, label, not dep or ns.DB[dep], ns.DB[key] ~= def.default)
  end }
  col.y = col.y - 22
  return cb
end

local SLIDER_W = 200  -- leaves room for the -/+ buttons in a 260px column
local function Slider(col, key)
  local def = ns.SettingDef(key)
  local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", col.x + 4, col.y)
  label:SetText(def.label)
  local valueText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  valueText:SetPoint("TOPRIGHT", panel, "TOPLEFT", col.x + 4 + SLIDER_W, col.y)
  local s = CreateFrame("Slider", nil, panel, BackdropTemplateMixin and "BackdropTemplate" or nil)
  s:SetOrientation("HORIZONTAL")
  s:SetSize(SLIDER_W, 15)
  s:SetPoint("TOPLEFT", col.x + 4, col.y - 14)
  s:SetHitRectInsets(0, 0, -4, -4)
  if s.SetMotionScriptsWhileDisabled then pcall(s.SetMotionScriptsWhileDisabled, s, true) end  -- (see CheckButton)
  if s.SetBackdrop then
    s:SetBackdrop({
      bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
      edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
      tile = true, tileSize = 8, edgeSize = 8,
      insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
  end
  s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  s:SetMinMaxValues(def.min, def.max)
  s:SetValueStep(def.step)
  if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
  -- Most sliders apply as you drag (you see the window change). commitOnRelease
  -- ones (idle cutoff, recent window) only show the value until you let go:
  -- in-between values would stop the clock or ping your partner.
  local dragging, pending = false, nil
  local userAt  -- where the user last put the thumb (may be between steps)
  local function Commit()
    if pending ~= nil and pending ~= ns.DB[key] then Change(key, pending) end
    pending = nil
    valueText:SetText(ns.SettingText(def))
  end
  s:SetScript("OnValueChanged", function(_, value)
    if refreshing then return end
    userAt = value
    local v = ns.SnapSetting(def, value)
    if def.commitOnRelease and dragging then
      pending = v
      valueText:SetText(ns.SettingText(def, v))
      return
    end
    if v ~= ns.DB[key] then Change(key, v) end
    valueText:SetText(ns.SettingText(def))
  end)
  -- (Left button only: a right-click mid-drag mustn't end the drag early.)
  s:SetScript("OnMouseDown", function(_, button) if button == "LeftButton" then dragging = true end end)
  s:SetScript("OnMouseUp", function(_, button)
    if button ~= "LeftButton" then return end
    dragging = false
    Commit()
  end)
  commits[#commits + 1] = function()  -- window closed mid-drag
    if dragging then dragging = false Commit() end
  end
  -- No mouse wheel: the window stays open while you play, and zooming the camera
  -- with the pointer over a slider would change it. Small -/+ buttons step instead.
  local function Step(dir)
    return function()
      if not s:IsEnabled() then return end
      Sound("U_CHAT_SCROLL_BUTTON")
      -- To the next step strictly above/below, so an off-step value set by
      -- /gw set (47%) goes to its neighbour (45 or 50), never skipping one.
      local k = (ns.DB[key] - def.min) / def.step
      k = dir > 0 and math.floor(k + 1e-6) + 1 or math.ceil(k - 1e-6) - 1
      Change(key, ns.SnapSetting(def, def.min + k * def.step))
    end
  end
  -- The game's own round -/+ icons (quest log style): legible at this size and
  -- no template needed.
  local function StepButton(kind, dir)
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(14, 14)
    b:SetNormalTexture("Interface\\Buttons\\UI-" .. kind .. "Button-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-" .. kind .. "Button-Down")
    b:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    b:SetScript("OnClick", Step(dir))
    return b
  end
  local minus = StepButton("Minus", -1)
  minus:SetPoint("LEFT", s, "RIGHT", 6, 0)
  local plus = StepButton("Plus", 1)
  plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
  s:SetScript("OnEnter", function(self)
    local dep = DEPENDS[key]
    ShowTooltip(self, def.label .. ": " .. ns.SettingText(def), def.tip,
      dep and not ns.DB[dep] and ("Turn on '" .. ns.SettingDef(dep).label .. "' first.") or nil, DefaultLine(def))
  end)
  s:SetScript("OnLeave", HideTooltip)
  controls[key] = { kind = "number", widget = s, label = label, valueText = valueText, minus = minus, plus = plus,
    refresh = function()
      -- Leave the thumb alone mid-drag, or if it already sits on the saved value.
      -- The thumb follows the saved value, except mid-drag, or where the user
      -- left it between steps on the value it stands for.
      local at = s:GetValue()
      local sits = at == ns.DB[key] or (at == userAt and ns.SnapSetting(def, at) == ns.DB[key])
      if not dragging and not sits then s:SetValue(ns.DB[key]) end
      valueText:SetText(ns.SettingText(def, pending))
      local dep = DEPENDS[key]
      local on = not dep or ns.DB[dep]
      SetEnabled(s, label, on, ns.DB[key] ~= def.default)
      for b, ok in pairs({ [minus] = on and ns.DB[key] > def.min, [plus] = on and ns.DB[key] < def.max }) do
        SetEnabled(b, nil, ok)
        b:SetAlpha(ok and 1 or 0.35)
      end
      -- A greyed slider should look it, not just its label.
      s:SetAlpha(on and 1 or 0.4)
      if on then valueText:SetTextColor(1, 0.82, 0) else valueText:SetTextColor(0.5, 0.5, 0.5) end
    end }
  col.y = col.y - 36
  return s
end

-- A standard button, styled by hand where the template is missing (a bare
-- button has no font, and SetText would fail).
local function PanelButton(parent)
  local b, templated = Make("Button", parent, "UIPanelButtonTemplate")
  if not templated then
    b:SetNormalFontObject("GameFontNormalSmall")
    b:SetHighlightFontObject("GameFontHighlightSmall")
    b:SetDisabledFontObject("GameFontDisableSmall")
    if b.SetBackdrop then Backdrop(b, 0.8) end
  end
  return b
end

local function Button(col, x, width, text, onClick, tip)
  local b = PanelButton(panel)
  b:SetSize(width, 20)
  b:SetPoint("TOPLEFT", col.x + x, col.y)
  b:SetText(text)
  b:SetScript("OnClick", function(self)
    Sound("IG_MAINMENU_OPTION")
    onClick(self)
  end)
  if tip then
    b:SetScript("OnEnter", function(self) ShowTooltip(self, text, tip) end)
    b:SetScript("OnLeave", HideTooltip)
  end
  return b
end

local function PriceChoice(col)
  local def = ns.SettingDef("priceSource")
  local radios = {}
  for i, choice in ipairs(def.choices) do
    local rb, label = CheckButton(col, 0, "UIRadioButtonTemplate")
    rb:SetSize(16, 16)
    label:SetText(def.choiceLabels[choice])
    rb:SetHitRectInsets(0, -((label:GetStringWidth() or 0) + 4), 0, 0)
    rb:SetScript("OnClick", function()
      if refreshing then return end
      Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
      Change("priceSource", choice)
    end)
    rb:SetScript("OnEnter", function(self)
      local why = def.check(choice)
      ShowTooltip(self, def.choiceLabels[choice], def.tip, why and (why .. ".") or nil, DefaultLine(def))
    end)
    rb:SetScript("OnLeave", HideTooltip)
    radios[i] = { widget = rb, label = label, choice = choice }
    col.y = col.y - 20
  end
  controls.priceSource = { kind = "choice", radios = radios, refresh = function()
    for _, r in ipairs(radios) do
      r.widget:SetChecked(ns.DB.priceSource == r.choice)
      -- AH stays selectable while it's the current value, so it can be switched off.
      SetEnabled(r.widget, r.label, not def.check(r.choice) or ns.DB.priceSource == r.choice,
        ns.DB.priceSource == r.choice and r.choice ~= def.default)
    end
  end }
end

-- Taught spells, by ID, capped so a long list can't run into the buttons below
-- (/gw spell list shows them all).
local SPELL_LIST_MAX = 4
local function SpellList()
  local ids = {}
  for id in pairs(ns.DB.customSpells) do ids[#ids + 1] = id end
  table.sort(ids)
  if #ids == 0 then return "Added: none" end
  local parts = {}
  for i = 1, math.min(#ids, SPELL_LIST_MAX) do
    local id = ids[i]
    local ok, name = pcall(ns.SpellName, id)
    parts[i] = string.format("%d %s (%s)", id, ok and name and tostring(name) or "?", ns.DB.customSpells[id])
  end
  local more = #ids > SPELL_LIST_MAX and string.format(", +%d more (/gw spell list)", #ids - SPELL_LIST_MAX) or ""
  return "Added: " .. table.concat(parts, ", ") .. more
end

local function BuildPanel()
  panel = CreateFrame("Frame", "VulcanGrindWatchSettings", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  ns.settingsPanel = panel
  panel:SetSize(PANEL_W, PANEL_H)
  local pp = ns.DB.panelPoint
  if pp then
    panel:SetPoint(pp[1], UIParent, pp[2], pp[3], pp[4])
  else
    panel:SetPoint("CENTER")
  end
  panel:SetFrameStrata("DIALOG")
  panel:SetToplevel(true)
  panel:SetClampedToScreen(true)
  panel:SetMovable(true)
  panel:EnableMouse(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
  if panel.SetDontSavePosition then panel:SetDontSavePosition(true) end  -- ours, in VulcanGrindWatchDB
  panel:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if self.SetUserPlaced then self:SetUserPlaced(false) end
    local point, _, relPoint, x, y = self:GetPoint()
    ns.DB.panelPoint = { point, relPoint, x, y }  -- reopens where you left it
  end)
  panel:Hide()
  Backdrop(panel, 0.95)
  if UISpecialFrames then table.insert(UISpecialFrames, "VulcanGrindWatchSettings") end

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -12)
  title:SetText("GrindWatch settings")
  title:SetTextColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3])
  local close, closeTemplated = Make("Button", panel, "UIPanelCloseButton")
  if not closeTemplated then
    close:SetSize(24, 24)
    close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
  end
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() panel:Hide() end)

  -- Left column
  local L = Column(16)
  Header(L, "Window")
  Check(L, "locked")
  Check(L, "compact")
  Check(L, "showTrend")
  Slider(L, "scale")
  Slider(L, "bgAlpha")
  Button(L, 4, 120, "Reset position", function() ns.ResetPosition() end,
    "Moves the window back to where it starts on a new install (right of the screen's center).")
  L.y = L.y - 30
  Header(L, "Clock")
  Check(L, "autoAFKPause")
  Slider(L, "idleMinutes")
  Slider(L, "windowMinutes")
  L.y = L.y - 4
  Header(L, "Loot value")
  PriceChoice(L)
  Button(L, 4, 140, "Re-value loot now", function() ns.RunCommand("reprice") end,
    "Re-values this session's loot at current prices (after an Auctionator scan, or for items whose price hadn't loaded).")

  -- Right column
  local R = Column(296)
  Header(R, "Alerts")
  Check(R, "alerts")
  Check(R, "alertSound")
  Slider(R, "alertPercent")
  Slider(R, "alertMinMinutes")
  Slider(R, "alertCooldownMinutes")
  Slider(R, "zoneHintMinutes")
  R.y = R.y - 4
  Header(R, "Duo")
  Check(R, "sync")
  R.y = R.y - 6
  Header(R, "Diagnostics")
  Check(R, "debug")
  Check(R, "debugEcho")
  Button(R, 4, 100, "Export log", function() ns.RunCommand("export", "debug") end,
    "Opens the diagnostics log in a copy box (Ctrl+C).")
  local clearLog
  local clearConfirm = Confirmer(function(t) clearLog:SetText(t) end, "Clear log", "Click again")
  clearLog = Button(R, 110, 100, "Clear log", function()
    if clearConfirm.click() then ns.RunCommand("debug", "clear") end
  end, "Deletes the diagnostics log. Click twice to confirm.")
  R.y = R.y - 26

  local spellLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  spellLabel:SetPoint("TOPLEFT", R.x + 4, R.y)
  spellLabel:SetWidth(250)
  spellLabel:SetJustifyH("LEFT")
  spellLabel:SetText("Teach a spell (IDs show with 'Also print it'):")
  R.y = R.y - 16
  local box, boxTemplated = Make("EditBox", panel, "InputBoxTemplate")
  box:SetSize(52, 20)
  box:SetPoint("TOPLEFT", R.x + 6, R.y)
  box:SetAutoFocus(false)
  box:SetNumeric(true)
  box:SetMaxLetters(9)
  -- A plain EditBox has no font (SetText would error) and no visible box.
  if ChatFontNormal then box:SetFontObject(ChatFontNormal) end
  if not boxTemplated then
    box:SetTextInsets(4, 4, 0, 0)
    if box.SetBackdrop then Backdrop(box, 0.8) end
  end
  box:SetScript("OnEscapePressed", box.ClearFocus)
  -- The window stays open while you play: clicking back into the world gives
  -- the keyboard back (otherwise WASD would keep typing into the box).
  box:SetScript("OnEditFocusGained", function(self) pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
  box:SetScript("OnEditFocusLost", function(self) pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
  box:SetScript("OnEvent", function(self)
    if not self:IsMouseOver() then self:ClearFocus() end
  end)
  box:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    if self:GetText() ~= "" then ns.Print("now click Gather, Pickpocket or Remove for that spell.") end
  end)
  ns.spellBox = box
  local function Teach(kind)
    local id = tonumber(box:GetText())
    if not id or id <= 0 then ns.Print("type a spell ID first (/gw debug echo shows them as you cast).") return end
    if kind == "remove" then ns.RemoveCustomSpell(id) else ns.AddCustomSpell(id, kind) end
    box:SetText("")
    box:ClearFocus()
  end
  Button(R, 60, 54, "Gather", function() Teach("gather") end, "Count this spell as skinning/gathering (not a kill).")
  Button(R, 116, 76, "Pickpocket", function() Teach("pickpocket") end, "Count this spell as pickpocketing (not a kill).")
  Button(R, 194, 58, "Remove", function() Teach("remove") end, "Forget a spell you added.")
  R.y = R.y - 24
  local spells = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  spells:SetPoint("TOPLEFT", R.x + 4, R.y)
  spells:SetWidth(250)
  spells:SetHeight(36)  -- three lines, clear of the bottom row
  if spells.SetMaxLines then spells:SetMaxLines(3) end
  spells:SetJustifyH("LEFT")
  spells:SetJustifyV("TOP")
  extras[#extras + 1] = function() spells:SetText(SpellList()) end
  ns.spellListText = spells

  -- Bottom row
  local B = { x = 16, y = -(PANEL_H - 32) }
  local defaults
  local defaultsConfirm = Confirmer(function(t) defaults:SetText(t) end, "Defaults", "Click again")
  defaults = Button(B, 0, 110, "Defaults", function()
    if defaultsConfirm.click() then
      ns.ResetSettings()
      ns.Print("settings back to defaults.")
    end
  end, "Every setting back to its default. Position, history and added spells are kept. Click twice to confirm.")
  Button(B, PANEL_W - 32 - 90, 90, "Close", function() panel:Hide() end)
  local help = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  help:SetPoint("BOTTOM", 0, 18)
  help:SetText("/gw set lists these by name")

  panel:SetScript("OnShow", function()
    ns.HideMenu()
    Refresh()
  end)
  panel:SetScript("OnHide", function()
    for _, fn in ipairs(commits) do fn() end
    defaultsConfirm.disarm()
    clearConfirm.disarm()
    box:ClearFocus()
  end)
  ns.settingControls = controls
end

function ns.OpenSettings()
  if not ns.S then return end
  if not panel then BuildPanel() end
  panel:Show()
  panel:Raise()  -- in front of the copy window if it's already open
  Refresh()
end

function ns.ToggleSettings()
  if panel and panel:IsShown() then panel:Hide() else ns.OpenSettings() end
end

function ns.ResetPosition()
  local p, d = ns.DB.point, ns.DEFAULT_POINT
  -- Default offsets are at scale 1; divide so it lands in the same screen spot.
  p[1], p[2], p[3], p[4] = d[1], d[2], d[3] / (ns.DB.scale or 1), d[4] / (ns.DB.scale or 1)
  ns.ApplyPosition()
  ns.Print("window moved back to its starting spot.")
end

-- Follow changes made anywhere (slash commands, the menu, defaults).
ns.Listen("SETTING", function()
  if panel and panel:IsShown() then Refresh() end
end)
ns.Listen("SPELLS", function()
  if panel and panel:IsShown() then Refresh() end
end)

---------------------------------------------------------------------------
-- Game Menu > Options > AddOns: a pointer to the window. The window itself
-- stays separate so it can be open while you play.
---------------------------------------------------------------------------
local function RegisterOptionsCategory()
  if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
  local canvas = CreateFrame("Frame")
  local title = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("GrindWatch")
  title:SetTextColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3])
  local text = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("TOPLEFT", 16, -44)
  text:SetWidth(500)
  text:SetJustifyH("LEFT")
  text:SetText("Settings are in their own window, so you can tweak them while you farm. "
    .. "Open it with the button below, the gear on the GrindWatch window, or /gw settings.")
  local b = PanelButton(canvas)
  b:SetSize(180, 22)
  b:SetPoint("TOPLEFT", 16, -90)
  b:SetText("Open GrindWatch settings")
  b:SetScript("OnClick", function() ns.OpenSettings() end)
  -- Some clients call these on a canvas page; nothing to do (changes apply at once).
  canvas.OnCommit, canvas.OnDefault, canvas.OnRefresh = function() end, function() end, function() end
  local ok = pcall(function()
    local category = Settings.RegisterCanvasLayoutCategory(canvas, "Vulcan GrindWatch")
    Settings.RegisterAddOnCategory(category)
  end)
  ns.optionsRegistered = ok
end
RegisterOptionsCategory()
