-- GrindWatch 3.1: widget integrity for the gear menu, settings window and
-- options page. The mock client ignores sizes, anchors and frame flags; the
-- real client needs them for anything to be visible or clickable. These checks
-- came from a full mutation sweep of SettingsUI.lua and the gear code.
package.path = assert(os.getenv("GW_TESTS"), "GW_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check

local function boot(opts)
  local c = H.boot(opts)
  c.login()
  return c, c.ns
end
local function noErrors(c, name)
  local errs = c.errors()
  check(name .. ": no runtime errors", #errs == 0, errs[1])
end
local function button(c, text)
  for _, f in ipairs(c.frames) do if rawget(f, "text") == text then return f end end
end
local function childrenOf(c, parent)
  local out = {}
  for _, f in ipairs(c.frames) do if f.parent == parent then out[#out + 1] = f end end
  return out
end

---------------------------------------------------------------------------
-- Settings window: frame flags
---------------------------------------------------------------------------
do
  local c, ns = boot()
  c.slash("settings")
  local p = ns.settingsPanel
  check("panel sized", p.w == 560 and p.h == 520, p.w .. "x" .. p.h)
  check("panel anchored (centered by default)", p.lastPoint and p.lastPoint[1] == "CENTER")
  check("panel keeps on top when clicked", rawget(p, "SetToplevel") == true)
  check("panel can't be dragged off screen", rawget(p, "SetClampedToScreen") == true)
  check("panel movable and draggable with the left button", rawget(p, "SetMovable") == true
    and rawget(p, "dragButtons") and rawget(p, "dragButtons")[1] == "LeftButton")
  check("panel takes the mouse (doesn't click through)", p.mouseEnabled == true)
  p.scripts.OnDragStart(p, "LeftButton")
  check("drag starts moving", rawget(p, "moving") == true)
  p.scripts.OnDragStop(p)
  check("drag stop stops moving", rawget(p, "moving") == false)
  check("panel has a backdrop colour", rawget(p, "bgColor") ~= nil and p.template == "BackdropTemplate")
  local texts = {}
  for _, fs in ipairs(p.fontstrings) do texts[tostring(fs.text)] = fs end
  check("title", texts["GrindWatch settings"] and texts["GrindWatch settings"].point)
  for _, header in ipairs({ "Window", "Clock", "Loot value", "Alerts", "Duo", "Diagnostics" }) do
    check("section header '" .. header .. "' shown and placed", texts[header] and texts[header].point ~= nil)
  end
  check("footer hint", texts["/gw set lists these by name"] and texts["/gw set lists these by name"].point)
  -- every font string on the panel is placed
  local unplaced = 0
  for _, fs in ipairs(p.fontstrings) do if not fs.point then unplaced = unplaced + 1 end end
  check("every label on the panel is anchored", unplaced == 0, unplaced)
  noErrors(c, "panel flags")
end

---------------------------------------------------------------------------
-- Settings window: every widget is visible, clickable and tidy
---------------------------------------------------------------------------
do
  local c, ns = boot()
  c.slash("settings")
  local p = ns.settingsPanel
  local kids = childrenOf(c, p)
  check("panel has its widgets", #kids >= 40, #kids)
  for i, w in ipairs(kids) do
    local name = (w.ftype or "?") .. " " .. tostring(rawget(w, "text") or i)
    -- (the Blizzard close-button template brings its own size)
    check(name .. ": sized", w.template == "UIPanelCloseButton" or (w.w > 0 and w.h > 0), w.w .. "x" .. w.h)
    check(name .. ": anchored", rawget(w, "lastPoint") ~= nil)
    if w.scripts.OnEnter then
      local ok, err = pcall(w.scripts.OnEnter, w)
      check(name .. ": tooltip opens without error", ok and c.tooltip.shown == true, err)
      check(name .. ": tooltip has a leave handler", w.scripts.OnLeave ~= nil)
      if w.scripts.OnLeave then
        w.scripts.OnLeave(w)
        check(name .. ": tooltip closes on leave", c.tooltip.shown == false)
      end
    end
  end
  -- tooltips wrap their long text
  ns.settingControls.idleMinutes.widget.scripts.OnEnter(ns.settingControls.idleMinutes.widget)
  check("tooltip body wraps", c.tooltipWrap[2] == true)
  check("tooltip default line wraps", c.tooltipWrap[3] == true)
  -- labels: every setting's label is shown, next to its control
  for key, ctl in pairs(ns.settingControls) do
    if ctl.label then
      check(key .. ": label text", ctl.label.text == ns.SettingDef(key).label, ctl.label.text)
      check(key .. ": label placed", ctl.label.point ~= nil)
    end
    if ctl.radios then
      for _, r in ipairs(ctl.radios) do
        check(key .. " " .. r.choice .. ": radio label", r.label.text == ns.SettingDef(key).choiceLabels[r.choice]
          and r.label.point ~= nil)
      end
    end
  end
  -- sliders: thumb, step, orientation, value text placed
  for key, ctl in pairs(ns.settingControls) do
    if ctl.kind == "number" then
      local s, def = ctl.widget, ns.SettingDef(key)
      check(key .. ": slider thumb", tostring(rawget(s, "SetThumbTexture")):find("SliderBar%-Button"))
      check(key .. ": slider step", rawget(s, "valueStep") == def.step)
      check(key .. ": slider snaps while dragging", rawget(s, "SetObeyStepOnDrag") == true)
      check(key .. ": slider horizontal", rawget(s, "SetOrientation") == "HORIZONTAL")
      check(key .. ": slider has a backdrop (its track)", s.template == "BackdropTemplate")
      check(key .. ": value text placed", ctl.valueText.point ~= nil)
      check(key .. ": -/+ sized and placed", ctl.minus.w > 0 and ctl.plus.w > 0
        and rawget(ctl.minus, "lastPoint") and rawget(ctl.plus, "lastPoint"))
    end
  end
  -- warning on a greyed slider's tooltip
  c.slash("alert")
  local cd = ns.settingControls.alertCooldownMinutes.widget
  cd.scripts.OnEnter(cd)
  check("greyed slider tooltip says why", table.concat(c.tooltip, "\n"):find("Turn on 'Slowing%-down alert' first"))
  c.slash("alert")
  cd.scripts.OnEnter(cd)
  check("no warning once enabled", not table.concat(c.tooltip, "\n"):find("Turn on"))
  -- the vendor radio tooltip (no refusal reason) works
  local vendor = ns.settingControls.priceSource.radios[1]
  local ok = pcall(vendor.widget.scripts.OnEnter, vendor.widget)
  check("vendor radio tooltip", ok and c.tooltip[1] == "Vendor price")
  noErrors(c, "widgets")
end

---------------------------------------------------------------------------
-- Spell box: never steals the keyboard
---------------------------------------------------------------------------
do
  local c, ns = boot()
  c.slash("settings")
  local box = ns.spellBox
  check("spell box doesn't grab the keyboard when the window opens", rawget(box, "SetAutoFocus") == false)
  check("spell box takes digits only", rawget(box, "SetNumeric") == true)
  check("spell box length limited", rawget(box, "SetMaxLetters") == 9)
  local before = rawget(box, "focusCleared") or 0
  box.scripts.OnEscapePressed(box)
  check("Escape in the spell box gives the keyboard back", (rawget(box, "focusCleared") or 0) == before + 1)
  box:SetText("1")
  c.click(button(c, "Gather"))
  check("spell ID 1 is a real ID and can be taught", ns.DB.customSpells[1] == "gather")
  noErrors(c, "spell box")
end

---------------------------------------------------------------------------
-- Close button, reset position
---------------------------------------------------------------------------
do
  local c, ns = boot({ noTemplates = true })
  c.slash("settings")
  local close
  for _, f in ipairs(childrenOf(c, ns.settingsPanel)) do
    if tostring(rawget(f, "normalTexture")):find("MinimizeButton") then close = f end
  end
  check("fallback close button sized and placed", close and close.w == 24 and rawget(close, "lastPoint")
    and rawget(close, "lastPoint")[1] == "TOPRIGHT")
  c.click(close)
  check("close button closes", not ns.settingsPanel.shown)
end
do
  local c, ns = boot()
  c.slash("settings")
  ns.DB.point = { "TOPLEFT", "TOPLEFT", 11, -22 }
  ns.ApplyPosition()
  c.click(button(c, "Reset position"))
  check("Reset position moves the window now", c.ui.lastPoint[1] == "CENTER" and c.ui.lastPoint[4] == 300,
    c.ui.lastPoint[4])
end

---------------------------------------------------------------------------
-- Gear menu
---------------------------------------------------------------------------
do
  local c, ns = boot()
  local menu = ns.menu
  check("menu clamped to the screen", rawget(menu, "SetClampedToScreen") == true)
  c.click(ns.gear)
  check("menu takes the mouse", menu.mouseEnabled == true)
  check("menu has a backdrop", rawget(menu, "bgColor") ~= nil and menu.template == "BackdropTemplate")
  local ys, ok = {}, true
  for i, row in ipairs(ns.menuRows) do
    check("menu row " .. i .. " has height", row.h == 16, row.h)
    local lp = rawget(row, "lastPoint")
    ok = ok and lp ~= nil and lp[5] == -6 - (i - 1) * 16
    ys[#ys + 1] = lp and lp[5]
    check("menu row " .. i .. " text placed and left-aligned", row.text.point and row.text.justifyH == "LEFT")
  end
  check("menu rows stacked one under another", ok, table.concat(ys, ","))
  -- re-anchoring clears the old anchor (two anchors would stretch the menu)
  c.click(ns.gear)
  local cleared = 0
  rawset(menu, "ClearAllPoints", function() cleared = cleared + 1 end)
  ns.gear.bottom = 20
  c.click(ns.gear)
  check("old anchor cleared before re-anchoring", cleared == 1)
  c.click(ns.gear)
  ns.gear.bottom = 900
  c.click(ns.gear)
  check("opens below the gear", menu.lastPoint[1] == "TOPRIGHT" and menu.lastPoint[3] == "BOTTOMRIGHT")
  noErrors(c, "menu")
end
do
  -- fallback auto-close: pointing at the menu restarts the 3 seconds
  local c, ns = boot({ unknownEvents = { GLOBAL_MOUSE_DOWN = true } })
  c.click(ns.gear)
  ns.menu.scripts.OnUpdate(ns.menu, 2.5)
  ns.menu.mouseOver = true
  ns.menu.scripts.OnUpdate(ns.menu, 0.1)
  ns.menu.mouseOver = false
  ns.menu.scripts.OnUpdate(ns.menu, 2.9)
  check("hovering resets the auto-close fully", ns.menu.shown)
end

---------------------------------------------------------------------------
-- Gear button and window cells
---------------------------------------------------------------------------
do
  local c, ns = boot()
  local g = ns.gear
  check("gear sized", g.w == 14 and g.h == 14)
  check("gear anchored top right", g.lastPoint and g.lastPoint[1] == "TOPRIGHT")
  check("gear takes left and right clicks", rawget(g, "clickButtons") and #rawget(g, "clickButtons") == 2)
  g.scripts.OnEnter(g)
  check("gear tooltip shown", c.tooltip.shown == true and c.tooltip[2]:find("Settings"))
  local title
  for _, fs in ipairs(c.ui.fontstrings) do if fs.text == "GrindWatch" then title = fs end end
  check("window title shown and placed", title and title.point)
  check("status placed left of the gear", c.ui.fontstrings[2].point and c.ui.fontstrings[2].point[2] == -28)
  -- cells: labels left, numbers right; header row dimmer
  local kills, perHour, header
  for _, fs in ipairs(c.ui.fontstrings) do
    if fs.text == "Total" then header = fs end
    if fs.text == "Kills" then kills = fs end
    if fs.text == "/hr" then perHour = fs end
  end
  check("row labels left-aligned, columns right-aligned", kills and kills.justifyH == "LEFT"
    and perHour and perHour.justifyH == "RIGHT")
  check("header row in the dim font", header and header.font == "GameFontDisableSmall")
end

---------------------------------------------------------------------------
-- Options > AddOns page
---------------------------------------------------------------------------
do
  local c = boot({ blizzSettings = true })
  local canvas = c.categories[1].frame
  local title, body
  for _, fs in ipairs(canvas.fontstrings) do
    if fs.text == "GrindWatch" then title = fs end
    if tostring(fs.text):find("own window") then body = fs end
  end
  check("options page title", title and title.point)
  check("options page text placed and wrapped", body and body.point and body.width == 500)
  local b = button(c, "Open GrindWatch settings")
  check("options page button sized and placed", b and b.w == 180 and rawget(b, "lastPoint"))
end

do
  -- fallback check boxes show a tick when checked
  local c, ns = boot({ noTemplates = true })
  c.slash("settings")
  check("fallback checkbox has a check mark", tostring(rawget(ns.settingControls.locked.widget, "checkedTexture"))
    :find("UI%-CheckBox%-Check$"))
  check("fallback radio has a check mark", rawget(ns.settingControls.priceSource.radios[1].widget, "checkedTexture") ~= nil)
end

---------------------------------------------------------------------------
-- Twelfth review
---------------------------------------------------------------------------
do -- lock stops dragging the main window
  local c = boot()
  c.slash("lock"); c.ui.scripts.OnDragStart(c.ui, "LeftButton")
  check("locked window can't be dragged", rawget(c.ui, "moving") ~= true)
  c.slash("unlock"); c.ui.scripts.OnDragStart(c.ui, "LeftButton")
  check("unlocked window drags", rawget(c.ui, "moving") == true)
  c.ui.scripts.OnDragStop(c.ui)
  check("drag stop", rawget(c.ui, "moving") == false)
end
do -- saved-position repairs
  local c, ns = boot({ saved = { db = { point = { "CENTER", "CENTER", "x", 0 }, history = {} } } })
  check("bad x offset repaired", ns.DB.point[3] == 300 and c.printedMatch("repaired.-point"))
  local _, ns2 = boot({ saved = { db = { panelPoint = { "NOPE", "TOP", 0, 0 }, history = {} } } })
  check("bad panel anchor dropped", ns2.DB.panelPoint == nil)
end
do -- /gw price with a bad word shows usage
  local c = boot()
  c.slash("price foo")
  check("/gw price foo: usage", c.printed[#c.printed]:find("Use /gw price vendor or /gw price ah"))
end
do -- numbers act at exactly the value set
  -- zone hint 1 min
  local c, ns = boot()
  for _ = 1, 5 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(100); c.tick(60) end
  c.slash("set zoneHintMinutes 1")
  c.zone = "Duskwood"
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(55)
  check("zone hint not before 1 min", not c.printedMatch("you've farmed Duskwood"))
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(10)  -- (zone time is committed at each pull)
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(10)
  check("zone hint at 1 min", c.printedMatch("you've farmed Duskwood for 1%+ min"))
  -- idle 2 min
  c.slash("idle 2")
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(1)
  c.tick(118)
  check("idle 2: still running at 119s", ns.ClockState() == "running")
  c.tick(3)
  check("idle 2: idle at 122s", ns.ClockState() == "idle")
end
do -- alert cooldown in minutes
  local c, ns = boot()
  c.level = 60; c.effectiveMax = true
  for _ = 1, 30 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  c.slash("set alertCooldownMinutes 5")
  ns.Trend = function() return -0.9, 100, 1000 end
  check("first alert", ns.CheckAlert())
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(298)
  check("no second alert at 299s", not ns.CheckAlert())
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(3)
  check("second alert after 300s", ns.CheckAlert())
end
do -- -/+ from an off-step value go to the neighbouring step
  local c, ns = boot(); c.slash("settings")
  local ctl = ns.settingControls.alertPercent
  c.slash("set alertPercent 47"); c.click(ctl.minus)
  check("47 - -> 45", ns.DB.alertPercent == 45, ns.DB.alertPercent)
  c.slash("set alertPercent 48"); c.click(ctl.plus)
  check("48 + -> 50", ns.DB.alertPercent == 50, ns.DB.alertPercent)
  c.click(ctl.plus)
  check("on-step + -> next step", ns.DB.alertPercent == 55)
  c.click(ctl.minus)
  check("on-step - -> previous step", ns.DB.alertPercent == 50)
  local s = ns.settingControls.scale
  c.slash("scale 1.3"); c.click(s.plus)
  check("1.30 + -> 1.35 (float-safe)", ns.DB.scale == 1.35, ns.DB.scale)
  c.click(s.minus); c.click(s.minus)
  check("1.35 - - -> 1.25", ns.DB.scale == 1.25, ns.DB.scale)
end

---------------------------------------------------------------------------
-- Thirteenth review
---------------------------------------------------------------------------
do -- the thumb follows -/+ and Defaults from an off-step value
  local c, ns = boot(); c.slash("settings")
  local ctl = ns.settingControls
  c.slash("set windowMinutes 8"); c.click(ctl.windowMinutes.plus)
  check("8 + : thumb moves to 10", ns.DB.windowMinutes == 10 and ctl.windowMinutes.widget.value == 10,
    ctl.windowMinutes.widget.value)
  c.slash("set windowMinutes 12"); c.click(ctl.windowMinutes.minus)
  check("12 - : thumb moves to 10", ctl.windowMinutes.widget.value == 10, ctl.windowMinutes.widget.value)
  c.slash("set alertCooldownMinutes 13"); c.slash("defaults yes")
  check("defaults: thumb moves to 15", ctl.alertCooldownMinutes.widget.value == 15, ctl.alertCooldownMinutes.widget.value)
  c.slide(ctl.idleMinutes.widget, 9.3)
  c.slash("lock")
  check("a thumb the user left between steps stays put", ctl.idleMinutes.widget.value == 9.3 and ns.DB.idleMinutes == 9)
end
do -- every grid value of every slider: + one step up, - one step down
  local c, ns = boot(); c.slash("settings")
  local bad = {}
  for key, ctl in pairs(ns.settingControls) do
    if ctl.kind == "number" then
      local def = ns.SettingDef(key)
      local n = math.floor((def.max - def.min) / def.step + 0.5)
      for i = 0, n do
        local v = ns.SnapSetting(def, def.min + i * def.step)
        if i < n then
          ns.SetSetting(key, v); c.click(ctl.plus)
          if ns.DB[key] ~= ns.SnapSetting(def, def.min + (i + 1) * def.step) then bad[#bad + 1] = key .. " " .. v .. "+" end
        end
        if i > 0 then
          ns.SetSetting(key, v); c.click(ctl.minus)
          if ns.DB[key] ~= ns.SnapSetting(def, def.min + (i - 1) * def.step) then bad[#bad + 1] = key .. " " .. v .. "-" end
        end
      end
    end
  end
  check("-/+ step exactly one grid step from every value", #bad == 0, bad[1])
end
do -- a second, different window mismatch is explained too
  local c = boot()
  c.inGroup = true
  for _ = 1, 10 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|10", "PARTY", "Mirel")
  check("first mismatch explained", c.printedMatch("Mirel's recent window is 10 min and yours is 15"))
  c.slash("set windowMinutes 10")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7230|10|0|200000|160000|500000|120000|90000|200000|20", "PARTY", "Mirel")
  check("new mismatch explained", c.printedMatch("Mirel's recent window is 20 min and yours is 10"))
end

---------------------------------------------------------------------------
-- Fourteenth review
---------------------------------------------------------------------------
do -- X8: tooltip default line for an on/off setting whose default is off
  local c, ns = boot(); c.slash("settings"); c.slash("lock")
  local cb = ns.settingControls.locked.widget
  cb.scripts.OnEnter(cb)
  local found
  for _, l in ipairs(c.tooltip) do if tostring(l):find("^Default:") then found = l end end
  check("X8 locked tooltip says Default: off", found and found:find("^Default: off"), found)
end
do -- X2: a release between steps commits the snapped value (non-obeying client)
  local c, ns = boot(); c.slash("settings")
  local s = ns.settingControls.windowMinutes.widget
  c.drag(s, { 22.7 })
  check("X2 window drag to 22.7 commits 25", ns.DB.windowMinutes == 25, ns.DB.windowMinutes)
end
do -- X3: snapping client, off-step value: - goes to the neighbouring step
  local c, ns = boot({ sliderSnaps = true }); c.slash("settings")
  local ctl = ns.settingControls.bgAlpha
  c.slash("set bgAlpha 47%")
  check("X3 thumb snapped by the client", ctl.widget.value ~= 0.47, ctl.widget.value)
  c.click(ctl.minus)
  check("X3 47% - -> 45% on a snapping client", ns.DB.bgAlpha == 0.45, ns.DB.bgAlpha)
  c.slash("set bgAlpha 48%"); c.click(ctl.plus)
  check("X3 48% + -> 50% on a snapping client", ns.DB.bgAlpha == 0.5, ns.DB.bgAlpha)
end
do -- X3b: thumb left between steps (non-obeying client), - still steps down
  local c, ns = boot(); c.slash("settings")
  local ctl = ns.settingControls.idleMinutes
  c.drag(ctl.widget, { 9.3 })
  c.click(ctl.minus)
  check("X3b idle 9 (thumb 9.3) - -> 8", ns.DB.idleMinutes == 8, ns.DB.idleMinutes)
end

---------------------------------------------------------------------------
-- Fifteenth review
---------------------------------------------------------------------------
local function last(c) return c.printed[#c.printed] or "" end
do -- K1
  local c, ns = boot(); c.slash("debug echo")
  check("K1 on", ns.DB.debugEcho and last(c):find("also printed to chat", 1, true), last(c))
  c.slash("debug echo")
  check("K1 off", not ns.DB.debugEcho and last(c):find("no longer printed to chat", 1, true), last(c))
end
do -- K2
  local c, ns = boot(); c.slash("idle 12"); c.slash("idle abc")
  check("K2", ns.DB.idleMinutes == 12 and last(c):find("idle cutoff is 12 min", 1, true), last(c))
end
do -- K3
  local c, ns = boot(); c.slash("scale 1.234")
  check("K3", ns.DB.scale == 1.23 and last(c):find("set to 1.23.", 1, true), last(c))
end
for _, how in ipairs({ "slash", "button" }) do -- K4
  local c, ns = boot({ auctionator = {} })
  local odd = { locked = true, compact = true, showTrend = false, scale = 1.5, bgAlpha = 0.3, autoAFKPause = false,
    idleMinutes = 12, windowMinutes = 30, priceSource = "auction", alerts = false, alertSound = false,
    alertPercent = 45, alertMinMinutes = 40, alertCooldownMinutes = 30, zoneHintMinutes = 0, sync = false,
    debug = true, debugEcho = true }
  for _, def in ipairs(ns.SETTING_DEFS) do
    check("K4 covers " .. def.key, odd[def.key] ~= nil and odd[def.key] ~= def.default)
    ns.SetSetting(def.key, odd[def.key])
  end
  if how == "slash" then c.slash("defaults yes") else
    c.slash("settings")
    local btn = button(c, "Defaults")
    c.click(btn); c.click(btn)
  end
  for _, def in ipairs(ns.SETTING_DEFS) do
    check("K4 " .. how .. " " .. def.key, ns.DB[def.key] == def.default, tostring(ns.DB[def.key]))
  end
  if how == "button" then
    local r = ns.settingControls.priceSource.radios
    check("K4 vendor radio", r[1].widget.checked and not r[2].widget.checked)
  end
end
do -- K5
  local c, ns = boot()
  for _, t in ipairs({ { "sync", "sync", "duo sync on.", "duo sync off." },
      { "afk", "autoAFKPause", "pause while AFK on.", "pause while AFK off." },
      { "compact", "compact", "compact window.", "full window." },
      { "alert", "alerts", "slowing-down alert on.", "slowing-down alert off." } }) do
    for _ = 1, 2 do
      c.slash(t[1])
      local want = ns.DB[t[2]] and t[3] or t[4]
      check("K5 /gw " .. t[1] .. " says " .. want, last(c):find(want, 1, true), last(c))
    end
  end
  c.slash("lock");   check("K5 lock", ns.DB.locked and last(c):find("window locked.", 1, true), last(c))
  c.slash("unlock"); check("K5 unlock", not ns.DB.locked and last(c):find("window unlocked.", 1, true), last(c))
  c.slash("debug on"); c.slash("debug off")
  check("K5 debug off", not ns.DB.debug and last(c):find("diagnostics off", 1, true), last(c))
end
do -- K6
  local c, ns = boot({ auctionator = {} }); c.slash("price")
  check("K6 vendor", last(c):find("loot is valued at vendor price", 1, true), last(c))
  c.slash("price ah"); c.slash("price")
  check("K6 AH", ns.DB.priceSource == "auction" and last(c):find("loot is valued at AH price", 1, true), last(c))
end
do -- K7
  local c, ns = boot({ auctionator = {} }); c.inGroup = true; c.slash("price ah")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|15", "PARTY", "Mirel")
  check("K7 value", ns.PartnerRecentGold(ns.partners.Mirel) == 320000, ns.PartnerRecentGold(ns.partners.Mirel))
  check("K7 AH row", c.cellText():find("Mirel | 70g 0s | 35g 0s | 32g 0s", 1, true), c.cellText())
  c.slash("price vendor")
  check("K7 vendor row", c.cellText():find("Mirel | 36g 0s | 18g 0s | 21g 0s", 1, true), c.cellText())
end
do -- K8
  local c = boot(); c.fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 20 do c.xpKill("Boar", 100); c.tick(60) end
  local st
  for _, fs in ipairs(c.ui.fontstrings) do if tostring(fs.text):find("Running") then st = fs end end
  check("K8 running has trend", st and st.text:find("%%"), st and st.text)
  c.slash("pause"); c.tick(1)
  check("K8 paused has none", st and st.text:find("Paused") and not st.text:find("%%"), st and st.text)
end

---------------------------------------------------------------------------
-- Sixteenth review
---------------------------------------------------------------------------
local function menuRow(ns, pattern)
  for _, row in ipairs(ns.menuRows) do
    local t = tostring(row.text.text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if t:find(pattern) then return row end
  end
end
do -- A16-1
  local c, ns = boot()
  ns.SetSetting("debug", true)
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(500); c.tick(300)
  c.click(ns.gear); c.click(menuRow(ns, "^Export history"))
  local f = _G.VulcanGrindWatchCopyFrame
  check("A16-1 menu Export opens the history CSV", f and f.shown and f.title.text:find("history %(CSV%)")
    and not f.title.text:find("diagnostics"), f and f.title.text)
end
do -- A16-2
  local c, ns = boot({ auctionator = {} })
  c.slash("price auction")
  check("A16-2 /gw price auction switches to AH", ns.DB.priceSource == "auction", ns.DB.priceSource)
  check("A16-2 and says so", c.printedMatch("loot now valued at AH price"))
end
do -- A16-3
  local c = boot()
  c.printed = {}
  c.slash("set")
  check("A16-3 /gw set prints its usage line first", c.printed[1] and c.printed[1]:find("/gw set <name> <value>", 1, true)
    and c.printed[1]:find("/gw settings", 1, true), c.printed[1])
end

---------------------------------------------------------------------------
-- Seventeenth review: confirmations and feedback the player relies on
---------------------------------------------------------------------------
local function says(c, n, pat)
  for i = n + 1, #c.printed do if c.printed[i]:find(pat, 1, true) then return true end end
  return false
end
do
  local c, ns = boot()
  local n = #c.printed; ns.DB.idleMinutes = 30; c.slash("defaults yes")
  check("/gw defaults yes confirms", ns.DB.idleMinutes == 5 and says(c, n, "settings back to defaults"))
  n = #c.printed; c.slash("debug on")
  check("/gw debug on confirms", says(c, n, "diagnostics on"))
  n = #c.printed; c.slash("debug")
  check("/gw debug status: on", says(c, n, "diagnostics are on"))
  c.slash("debug off"); n = #c.printed; c.slash("debug")
  check("/gw debug status: off", says(c, n, "diagnostics are off"))
  ns.DB.debugLog[1] = "x"; n = #c.printed; c.slash("debug clear")
  check("/gw debug clear confirms", #ns.DB.debugLog == 0 and says(c, n, "diagnostics log cleared"))
  c.slash("settings")
  ns.DB.debugLog[1] = "x"; n = #c.printed
  local clear = button(c, "Clear log"); c.click(clear); c.click(clear)
  check("Clear log button confirms", #ns.DB.debugLog == 0 and says(c, n, "diagnostics log cleared"))
end
do
  local c = boot()
  local title
  local real = c.ns.ShowCopy
  c.ns.ShowCopy = function(t, lines) title = t return real(t, lines) end
  c.slash("export DEBUG")
  check("/gw export DEBUG opens the log", title == "GrindWatch diagnostics", title)
end
do
  local c, ns = boot()
  c.slash("settings")
  local n = #c.printed
  ns.spellBox:SetText("12345"); c.click(button(c, "Gather"))
  check("Gather button confirms", says(c, n, "spell 12345 now counts as gathering"))
  n = #c.printed; c.slash("spell gather 8613"); c.slash("spell remove 8613")
  check("removing a built-in you also added says so", says(c, n, "your own entry for it was removed"))
  ns.DB.customSpells = {}; n = #c.printed; c.slash("spell list")
  check("/gw spell list with none", says(c, n, "no added spells"))
end
do -- only a right-click pauses
  local c, ns = boot()
  c.ui.scripts.OnDragStart(c.ui, "LeftButton"); c.ui.scripts.OnDragStop(c.ui)
  c.ui.scripts.OnMouseUp(c.ui, "LeftButton")
  check("a left click / drag release doesn't pause", not ns.S.paused)
  c.ui.scripts.OnMouseUp(c.ui, "MiddleButton")
  check("a middle click doesn't pause", not ns.S.paused)
  c.ui.scripts.OnMouseUp(c.ui, "RightButton")
  check("right-click pauses", ns.S.paused)
  local n = #c.printed; c.slash("resume")
  check("/gw resume says so", says(c, n, "resumed."))
  n = #c.printed; c.slash("pause")
  check("/gw pause says so", says(c, n, "paused."))
end
do -- tooltips that point at the controls
  local c = boot()
  _G.VulcanGrindWatch_OnAddonCompartmentEnter("VulcanGrindWatch", nil)
  check("addon-menu tooltip: left-click line", table.concat(c.tooltip, "\n"):find("Left-click: show/hide", 1, true))
  c.ui.scripts.OnEnter(c.ui)
  check("window tooltip mentions the gear", table.concat(c.tooltip, "\n"):find("Gear: settings", 1, true))
end
do -- other command feedback
  local c, ns = boot()
  local n = #c.printed; c.slash("report w")
  check("/gw report w usage", says(c, n, "usage: /gw report w <name>"))
  n = #c.printed; c.slash("report party")
  check("/gw report party solo explains and falls back", says(c, n, "you're not in a party") and says(c, n, "Session"))
  n = #c.printed; c.slash("history")
  check("empty /gw history", says(c, n, "no saved sessions yet"))
  n = #c.printed; c.slash("spots")
  check("empty /gw spots", says(c, n, "no sessions of 3+ minutes"))
  n = #c.printed; c.slash("loot")
  check("empty /gw loot", says(c, n, "nothing looted this session yet"))
  n = #c.printed; c.slash("note murlocs")
  check("/gw note labels", ns.S.note == "murlocs" and says(c, n, 'session labelled "murlocs"'))
  n = #c.printed; c.slash("note")
  check("/gw note clears", ns.S.note == nil and says(c, n, "session label cleared"))
  for _ = 1, 3 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(100); c.tick(60) end
  c.slash("reset")
  n = #c.printed; c.slash("history clear yes")
  check("/gw history clear yes confirms", #ns.DB.history == 0 and says(c, n, "deleted 1 saved session"))
end
do
  local c = boot({ auctionator = {} })
  local n = #c.printed; c.slash("reprice")
  check("/gw reprice with Auctionator reports AH values", says(c, n, "loot re-valued at current prices: AH value"))
end

---------------------------------------------------------------------------
-- Eighteenth review
---------------------------------------------------------------------------
do -- recording without echo stays out of chat
  local c, ns = boot()
  c.slash("debug on"); local n = #c.printed; c.gainMoney(150)
  check("recording only: logged", tostring(ns.DB.debugLog[#ns.DB.debugLog]):find("money"))
  check("recording only: nothing new in chat", #c.printed == n, c.printed[#c.printed])
  c.slash("debug echo"); c.gainMoney(150)
  check("echo on: printed", c.printedMatch("%[money%]"))
end
do -- slider range and step match each setting
  local c, ns = boot(); c.slash("settings")
  for key, ctl in pairs(ns.settingControls) do
    if ctl.kind == "number" then
      local def = ns.SettingDef(key)
      local lo, hi = ctl.widget:GetMinMaxValues()
      check(key .. ": slider range", lo == def.min and hi == def.max, lo .. "-" .. hi)
      check(key .. ": slider step", rawget(ctl.widget, "valueStep") == def.step)
    end
  end
end
do -- one past the spell-list cap
  local c, ns = boot()
  for id = 1, 5 do ns.DB.customSpells[id] = "gather" end
  c.slash("settings")
  local text = ns.spellListText.text
  check("5 spells: 4 listed, +1 more", text:find("%+1 more %(/gw spell list%)") and not text:find(" 5 "), text)
end
do -- trailing spaces are ignored
  local c, ns = boot()
  c.slash("set sync off ")
  check("/gw set sync off<space>", ns.DB.sync == false)
  ns.DB.idleMinutes = 30
  c.slash("defaults yes  ")
  check("/gw defaults yes<spaces>", ns.DB.idleMinutes == 5)
end
do
  local c, ns = boot()
  c.slash("opt")
  check("/gw opt opens settings", ns.settingsPanel and ns.settingsPanel.shown)
end

---------------------------------------------------------------------------
-- Nineteenth and twentieth reviews
---------------------------------------------------------------------------
do -- greyed controls still show their "why" tooltip on the real client
  local c, ns = boot(); c.slash("settings"); c.slash("alert")
  local ctl = ns.settingControls
  check("greyed checkbox still gets hover", rawget(ctl.alertSound.widget, "SetMotionScriptsWhileDisabled") == true)
  check("greyed radio still gets hover", rawget(ctl.priceSource.radios[2].widget, "SetMotionScriptsWhileDisabled") == true)
  check("greyed slider still gets hover", rawget(ctl.alertCooldownMinutes.widget, "SetMotionScriptsWhileDisabled") == true)
  local missing = 0
  for _, cc in pairs(ctl) do
    local ws = cc.radios and {} or { cc.widget }
    for _, r in ipairs(cc.radios or {}) do ws[#ws + 1] = r.widget end
    for _, w in ipairs(ws) do if rawget(w, "SetMotionScriptsWhileDisabled") ~= true then missing = missing + 1 end end
  end
  check("every setting control gets hover while greyed", missing == 0, missing)
end
do -- copy window shares the settings window's layer and comes forward
  local c, ns = boot(); c.slash("settings"); ns.RunCommand("export", "debug")
  local f = _G.VulcanGrindWatchCopyFrame
  check("copy window in the dialog layer", rawget(f, "strata") == "DIALOG")
  check("copy window comes to the front when clicked", rawget(f, "SetToplevel") == true)
end
do -- fallback auto-close: pointing at the gear keeps the menu open
  local _, ns = boot({ unknownEvents = { GLOBAL_MOUSE_DOWN = true } })
  ns.ToggleMenu(ns.gear)
  rawset(ns.gear, "mouseOver", true)
  for _ = 1, 5 do ns.menu.scripts.OnUpdate(ns.menu, 1) end
  check("pointing at the gear keeps the menu", ns.menu:IsShown())
end
do -- K19-1
  local c, ns = boot()
  local n = #c.printed
  local ok1, e1 = pcall(c.slash, "spell gather")
  local ok2, e2 = pcall(c.slash, "spell pickpocket")
  local errs = c.errors()
  check("K19-1 /gw spell gather|pickpocket without an ID: no error", ok1 and ok2 and #errs == 0, e1 or e2 or errs[1])
  check("K19-1 and explains the usage", says(c, n, "use /gw spell gather <id>"))
  check("K19-1 and teaches nothing", next(ns.DB.customSpells) == nil)
end
do -- K19-2
  local c, ns = boot()
  c.slash("spell GATHER 424242")
  check("K19-2 /gw spell GATHER works", ns.DB.customSpells[424242] == "gather")
  local n = #c.printed
  c.slash("spell pickpocket 77")
  check("K19-2 pickpocket confirmed as pickpocketing", says(c, n, "spell 77 now counts as pickpocketing"))
end
do -- K19-3
  local _, ns = boot()
  ns.DB.idleMinutes = 5
  SlashCmdList.VULCANGRINDWATCH("idle OFF")
  check("K19-3 /gw idle OFF turns it off", ns.DB.idleMinutes == 0, ns.DB.idleMinutes)
end
do -- K19-4
  local c, ns = boot({ auctionator = {} })
  c.slash("price AH")
  check("K19-4 /gw price AH switches to AH", ns.DB.priceSource == "auction", ns.DB.priceSource)
end

---------------------------------------------------------------------------
-- Twenty-first and twenty-second reviews
---------------------------------------------------------------------------
do -- the diagnostics log keeps the newest entries
  local c, ns = boot()
  c.slash("debug on")
  for i = 1, ns.DEBUG_MAX + 5 do ns.Log("t", "entry %d", i) end
  local log = ns.DB.debugLog
  check("log cap keeps newest", log[#log]:find("t: entry " .. (ns.DEBUG_MAX + 5) .. "$"), log[#log])
  check("log cap drops oldest", not table.concat(log, "\n"):find("t: entry 5\n", 1, true))
end
do -- /gw debug updates an open window
  local c, ns = boot(); c.slash("settings"); local cb = ns.settingControls.debug.widget
  c.slash("debug on")
  check("/gw debug on ticks the open window's box", rawget(cb, "checked") == true)
  c.slash("debug off")
  check("/gw debug off clears it", not rawget(cb, "checked"))
end
do local c, ns = boot(); c.slash("settings")                          -- K1
  local v = ns.settingControls.priceSource.radios[1]; c.click(v.widget)
  check("K1 re-clicking the selected radio keeps it selected", v.widget.checked and ns.DB.priceSource == "vendor") end
do local c, ns = boot(); c.slash("settings"); c.click(button(c, "Close"))  -- K2
  check("K2 Close button closes the window", not ns.settingsPanel.shown) end
do local c, ns = boot(); c.slash("settings")                          -- K3
  local defaults, clear = button(c, "Defaults"), button(c, "Clear log")
  ns.DB.debugLog[1] = "x"; ns.SetSetting("compact", true)
  c.click(defaults); c.click(clear)
  check("K3 Defaults armed + one Clear log click: nothing deleted", #ns.DB.debugLog == 1 and ns.DB.compact)
  c.tick(5); c.click(clear); c.click(defaults)
  check("K3 Clear log armed + one Defaults click: nothing reset", #ns.DB.debugLog == 1 and ns.DB.compact) end
do local c, ns = boot({ saved = { db = { bgAlpha = 0, history = {} } } }); c.slash("settings")  -- K4
  local ctl = ns.settingControls
  for _ = 1, 3 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(100); c.tick(20) end
  c.click(ns.gear); local n = #c.printed; c.click(menuRow(ns, "^Pause$"))
  check("K4 menu Pause says so", says(c, n, "paused."))
  c.click(ns.gear); c.click(menuRow(ns, "^Lock position$"))
  check("K4 menu Lock ticks the open settings window", ctl.locked.widget.checked)
  check("K4 menu Lock at 0% is click-through at once", c.ui.mouseEnabled == false)
  c.click(ns.gear); c.click(menuRow(ns, "^Compact window$"))
  check("K4 menu Compact ticks the settings window", ctl.compact.widget.checked)
  check("K4 menu Compact redraws at once", not c.cellText():find("Coin"), c.cellText())
  c.click(ns.gear); c.click(menuRow(ns, "^Hide window$"))
  check("K4 menu Hide is remembered (like /gw)", ns.DB.shown == false) end
do local c = boot()                                                   -- K5
  check("K5 window drags with the left button", rawget(c.ui, "dragButtons") and rawget(c.ui, "dragButtons")[1] == "LeftButton")
  check("K5 window movable", rawget(c.ui, "SetMovable") == true)
  check("K5 window clamped to the screen", rawget(c.ui, "SetClampedToScreen") == true) end
do local _, ns = boot(); ns.RunCommand("settings")                    -- K6
  ns.spellBox.scripts.OnEscapePressed(ns.spellBox)
  check("K6 Escape in the spell box keeps the window open", ns.settingsPanel.shown) end
do local c, ns = boot(); ns.RunCommand("export")                      -- K7
  local f, box = _G.VulcanGrindWatchCopyFrame, nil
  for _, fr in ipairs(c.frames) do if fr.ftype == "EditBox" and fr.parent == _G.VulcanGrindWatchCopyScroll then box = fr end end
  local hl, focus = 0, 0
  rawset(box, "HighlightText", function() hl = hl + 1 end); rawset(box, "SetFocus", function() focus = focus + 1 end)
  f:Hide(); ns.RunCommand("export", "debug")
  check("K7 copy text selected", hl == 1); check("K7 copy box has the keyboard", focus == 1)
  ;(box.scripts.OnEscapePressed or function() end)(box)
  check("K7 Escape in the copy box closes it", not f.shown)
  check("K7 copy window movable by dragging", rawget(f, "SetMovable") == true and rawget(f, "dragButtons")
    and rawget(f, "dragButtons")[1] == "LeftButton") end
do local c, ns = boot()
  ns.gear.scripts.OnEnter(ns.gear)
  check("gear tooltip lists the menu", c.tooltip[2]:find("report") and c.tooltip[2]:find("hide")) end

---------------------------------------------------------------------------
-- Twenty-third and twenty-fourth reviews
---------------------------------------------------------------------------
do -- sync payload round trip: every field lands where the partner reads it
  local function farmer(mode)
    local a = H.boot({ auctionator = { [2589] = 1000 } }); a.login()
    a.item(2589, "Linen Cloth", 100)
    if mode == "auction" then a.slash("price ah") end
    a.fire("PLAYER_REGEN_DISABLED"); a.gainMoney(5000); a.lootMsg(2589, "Linen Cloth", 2); a.xpKill("Boar", 100); a.tick(60)
    return a
  end
  local a = farmer("vendor")
  check("no recent rate yet is sent as -1", a.ns.SyncPayload():match("|%-1|%-1|%-1|%d+$"), a.ns.SyncPayload())
  for _, mode in ipairs({ "vendor", "auction" }) do
    a = farmer(mode)
    for _ = 1, 9 do
      a.fire("PLAYER_REGEN_DISABLED"); a.gainMoney(5000); a.lootMsg(2589, "Linen Cloth", 2); a.xpKill("Boar", 100); a.tick(60)
    end
    local payload = a.ns.SyncPayload()
    local b = H.boot({ auctionator = { [2589] = 1000 } }); b.login(); b.inGroup = true
    if mode == "auction" then b.slash("price ah") end
    b.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", payload, "PARTY", "Mirel")
    local p = b.ns.partners.Mirel
    local A = a.ns
    check(mode .. ": partner elapsed", p and p.elapsed == math.floor(A.Elapsed()))
    check(mode .. ": partner kills and XP", p and p.kills == A.Total({ "k" }) and p.xp == A.Total({ "x" }))
    check(mode .. ": partner gold in this price mode", p and b.ns.PartnerGold(p) == A.Total(A.GoldFields()),
      p and b.ns.PartnerGold(p) .. " vs " .. A.Total(A.GoldFields()))
    local lf = A.LootField()
    local want = math.floor(A.RecentRate({ "c" }) + 0.5) + math.floor(A.RecentRate({ lf }) + 0.5)
    check(mode .. ": partner recent gold", p and b.ns.PartnerRecentGold(p) == want, p and b.ns.PartnerRecentGold(p))
  end
end
do -- leveling but farming only gold: no NaN trend, no fake alert
  local c, ns = boot()
  for _ = 1, 25 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  check("running", ns.ClockState() == "running")
  check("no trend without XP", ns.Trend() == nil)
  check("no alert", not ns.CheckAlert() and not c.printedMatch("slowing down"))
  check("no % in the window", not c.cellText():find("%%"), c.cellText())
end
do -- pruning during a break keeps what the window needs afterwards
  local c, ns = boot()
  c.level = 60; c.effectiveMax = true
  c.slash("set windowMinutes 30"); c.slash("idle 10")
  for _ = 1, 40 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  local before = ns.RecentRate({ "c" })
  c.tick(11 * 60)
  check("idle after the break", ns.ClockState() == "idle")
  check("recent rate unchanged by the break", math.abs(ns.RecentRate({ "c" }) - 600000) < 1 and
    math.abs(ns.RecentRate({ "c" }) - before) < 1, ns.RecentRate({ "c" }))
end
do -- the alert's percentage
  local c, ns = boot()
  c.level = 60; c.effectiveMax = true
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(30000); c.tick(60) end
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(5000); c.tick(60) end
  ns.S.lastAlertAt = nil
  local pct = math.floor(ns.Trend() * 100 + 0.5)
  ns.CheckAlert()
  local msgs = {}
  for _, p in ipairs(c.printed) do if p:find("slowing down") then msgs[#msgs + 1] = p end end
  check("alert shows the trend %", msgs[#msgs] and msgs[#msgs]:find("(" .. pct .. "%)", 1, true), msgs[#msgs])
end
do -- changing your own window to a new mismatch explains again
  local c, ns = boot()
  c.inGroup = true
  for _ = 1, 10 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  local msg = "4|7200|10|0|200000|160000|500000|120000|90000|200000|10"
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", msg, "PARTY", "Mirel")
  check("first notice", c.printedMatch("10 min and yours is 15"))
  ns.SetSetting("windowMinutes", 20)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", msg, "PARTY", "Mirel")
  check("new notice after changing yours", c.printedMatch("10 min and yours is 20"))
end
do -- copy window contents and wiring
  local c, ns = boot(); c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(500); c.tick(60)
  ns.RunCommand("export")
  local box
  for _, fr in ipairs(c.frames) do if fr.ftype == "EditBox" and fr.parent == _G.VulcanGrindWatchCopyScroll then box = fr end end
  check("copy box shows the CSV", (rawget(box, "text") or ""):find("^date,character,zone"))
  check("copy box is multi-line", rawget(box, "SetMultiLine") == true)
  check("copy box is inside the scroll area", rawget(_G.VulcanGrindWatchCopyScroll, "SetScrollChild") == box)
  local f = _G.VulcanGrindWatchCopyFrame
  f.scripts.OnDragStart(f); check("copy window drag moves", rawget(f, "moving") == true)
  f.scripts.OnDragStop(f); check("copy window release stops", rawget(f, "moving") == false)
  local lines = ns.ExportLines("history")
  check("a short live session has no per-hour rates", lines[2] and lines[2]:find(",,,$"), lines[2])
end
do -- main window position round trip with different anchors
  local c, ns = boot()
  rawset(c.ui, "GetPoint", function() return "TOPLEFT", nil, "BOTTOMLEFT", 50, 700 end)
  c.ui.scripts.OnDragStart(c.ui); c.ui.scripts.OnDragStop(c.ui)
  check("saved anchors", ns.DB.point[1] == "TOPLEFT" and ns.DB.point[2] == "BOTTOMLEFT")
  local c2 = H.boot({ saved = c.saved() }); c2.login()
  local lp = c2.ui.lastPoint
  check("restored where it was", lp[1] == "TOPLEFT" and lp[2] == _G.UIParent and lp[3] == "BOTTOMLEFT"
    and lp[4] == 50 and lp[5] == 700)
end
do -- window tooltip follows the clock state
  local c, ns = boot()
  ns.SetPaused(true); c.ui.scripts.OnEnter(c.ui)
  check("paused tooltip", tostring(c.tooltip[2]):find("^Paused"), c.tooltip[2])
end

---------------------------------------------------------------------------
-- Twenty-fifth and twenty-sixth reviews
---------------------------------------------------------------------------
for _, opts in ipairs({ {}, { noTemplates = true }, { silentTemplates = true } }) do
  local c, ns = boot(opts); ns.OpenSettings()
  local bad = 0
  for _, f in ipairs(c.frames) do
    if rawget(f, "bgColor") and f.template ~= "BackdropTemplate" then bad = bad + 1 end
  end
  check("everything styled with a backdrop is a BackdropTemplate frame ("
    .. (opts.noTemplates and "no templates" or opts.silentTemplates and "silent" or "normal") .. ")", bad == 0, bad)
  noErrors(c, "backdrop fallback")
end
do -- bare /gw defaults asks and changes nothing
  local c, ns = boot()
  c.slash("set idleMinutes 30"); c.slash("set alertPercent 50"); c.slash("set compact on")
  c.slash("defaults")
  check("bare /gw defaults asks", c.printedMatch("/gw defaults yes"))
  check("bare /gw defaults changes nothing", ns.DB.idleMinutes == 30 and ns.DB.alertPercent == 50 and ns.DB.compact == true)
  c.slash("defaults no")
  check("/gw defaults no changes nothing", ns.DB.idleMinutes == 30 and ns.DB.compact == true)
  c.slash("defaults yes")
  check("/gw defaults yes resets", ns.DB.idleMinutes == 5 and ns.DB.alertPercent == 60 and ns.DB.compact == false)
end
do -- refused /gw scale
  local c, ns = boot()
  c.printed = {}; c.slash("scale 9")
  check("refused scale not reported as set", ns.DB.scale == 1 and not c.printedMatch("set to"))
  check("refused scale shows value and usage", c.printedMatch("window scale is 1.00x%. Use /gw scale <0.5%-2>"))
end
do -- colour stripping
  local _, ns = boot()
  check("strips every code", ns.StripColors("|cffff0000a|r and |cff00ff00b|r") == "a and b")
  check("keeps the text", ns.StripColors("|cffff0000red|r spot") == "red spot")
end
do
  local c = boot(); c.slash("help")
  check("help lists /gw set", c.printedMatch("/gw set <name> <value>"))
end
do -- compact window wide enough for its header
  local c, ns = boot()
  ns.SetSetting("compact", true); ns.UpdateDisplay(true)
  local title, status = c.ui.fontstrings[1], c.ui.fontstrings[2]
  check("compact header fits", c.ui.w - 28 - status:GetStringWidth() >= 10 + title:GetStringWidth() + 12, c.ui.w)
end
do -- copy box has a width
  local c, ns = boot(); ns.RunCommand("export")
  local box
  for _, fr in ipairs(c.frames) do if fr.ftype == "EditBox" and fr.parent == _G.VulcanGrindWatchCopyScroll then box = fr end end
  check("copy box has a width", box.w > 0)
end
do -- CSV columns, exactly
  local c, ns = boot({ auctionator = { [4306] = 1000 } })
  c.item(4306, "Silk Cloth", 150)
  c.slash("price ah")
  for _ = 1, 10 do
    c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("Boar", 50); c.lootMsg(4306, "Silk Cloth", 2); c.gainMoney(1000); c.tick(60)
  end
  c.slash('note "east" camp')
  ns.DB.history = {
    { when = 1700100000, char = "Tavlius", zone = "Duskwood", elapsed = 1800, kills = 30, xp = 6000, coin = 20000,
      loot = 10000, lootAH = 40000 },
    { when = 1700000000, char = "Tavlius", zone = "Westfall", elapsed = 3600, kills = 60, xp = 9000, coin = 30000,
      loot = 5000 },
    { when = 0, note = "v1", zone = "Elwynn", elapsed = 600, kills = 1, xp = 2, coin = 3, loot = 4 },
  }
  local lines = ns.ExportLines("history")
  local live = ns.CurrentAsHistory()
  local hrs = live.elapsed / 3600
  local want = {
    "date,character,zone,label,minutes,kills,xp,coin_copper,loot_vendor_copper,loot_ah_copper,gold_per_hour,kills_per_hour,xp_per_hour",
    string.format('%s,Tavlius,Westfall,"""east"" camp",%.1f,10,500,10000,3000,19000,%.2f,%.1f,%.1f',
      os.date("!%Y-%m-%d %H:%M", ns.S.startedAt), live.elapsed / 60, (10000 + 19000) / hrs / 10000, 10 / hrs, 500 / hrs),
    "2023-11-16 02:00,Tavlius,Duskwood,,30.0,30,6000,20000,10000,40000,12.00,60.0,12000.0",
    "2023-11-14 22:13,Tavlius,Westfall,,60.0,60,9000,30000,5000,5000,3.50,60.0,9000.0",
    "v1,,Elwynn,,10.0,1,2,3,4,4,0.00,6.0,12.0",
  }
  check("CSV line count", #lines == #want, #lines)
  for i = 1, #want do check("CSV line " .. i, lines[i] == want[i], lines[i]) end
  c.slash("reset")
  ns.DB.history = {}  -- (the reset saved the session; drop it too)
  local only = ns.ExportLines("history")
  check("nothing tracked: header only", #only == 1)
  ns.DB.debugLog = { "a", "b", "c" }
  check("debug export header counts", ns.ExportLines("debug")[1] == "GrindWatch diagnostics (3 entries)")
end

---------------------------------------------------------------------------
-- Twenty-seventh and twenty-eighth reviews
---------------------------------------------------------------------------
do -- goodbye from a realm-qualified sender
  local c, ns = boot(); c.inGroup = true
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|15", "PARTY", "Mirel-Realm")
  check("realm-qualified partner stored by short name", ns.partners.Mirel ~= nil)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|bye", "PARTY", "Mirel-Realm")
  check("realm-qualified goodbye drops the partner", ns.partners.Mirel == nil)
end
do -- bare frames from missing templates are hidden, never left shown
  local c, ns = boot({ silentTemplates = true }); ns.OpenSettings()
  local bare, shown = 0, 0
  for _, f in ipairs(c.frames) do
    if f.template ~= "BackdropTemplate" and rawget(f, "Left") == false then
      bare = bare + 1
      if f.shown then shown = shown + 1 end
    end
  end
  check("bare frames found", bare >= 10, bare)
  check("none left shown", shown == 0, shown)
  check("the real spell box is shown", ns.spellBox.shown and ns.spellBox.template == "BackdropTemplate")
end
do -- templates without a Left piece are recognised by their textures
  local c, ns = boot()
  local real = _G.CreateFrame
  _G.CreateFrame = function(kind, name, parent, template)
    local f = real(kind, name, parent, template)
    if template and template ~= "BackdropTemplate" and template ~= "UIPanelButtonTemplate" and template ~= "InputBoxTemplate" then
      rawset(f, "Left", false)
    end
    if template == "UICheckButtonTemplate" or template == "UIRadioButtonTemplate" or template == "UIPanelCloseButton" then
      rawset(f, "normalTexture", {})
    end
    return f
  end
  ns.OpenSettings()
  _G.CreateFrame = real
  check("checkbox template kept", ns.settingControls.locked.widget.template == "UICheckButtonTemplate")
  check("radio template kept", ns.settingControls.priceSource.radios[1].widget.template == "UIRadioButtonTemplate")
  local _ = c
end
do -- the trend line in the tooltip follows the setting
  local c, ns = boot()
  c.slash("set showTrend off"); c.ui.scripts.OnEnter(c.ui)
  check("no trend line when the trend is hidden", not table.concat(c.tooltip, "\n"):find("%% next to the status"))
  c.slash("set showTrend on"); c.ui.scripts.OnEnter(c.ui)
  check("trend line back", table.concat(c.tooltip, "\n"):find("%% next to the status"))
  local _ = ns
end

---------------------------------------------------------------------------
-- Thirtieth review
---------------------------------------------------------------------------
do -- right-click toggles both ways
  local c = boot()
  c.ui.scripts.OnMouseUp(c.ui, "RightButton"); check("right-click pauses", c.ns.S.paused == true)
  c.ui.scripts.OnMouseUp(c.ui, "RightButton"); check("second right-click resumes", c.ns.S.paused == false)
end
do -- hidden stays hidden across a reload
  local c = boot(); c.slash("")
  local c2 = H.boot({ saved = c.saved() }); c2.login(); check("still hidden after reload", c2.ui.shown == false)
  c2.slash(""); local c3 = H.boot({ saved = c2.saved() }); c3.login(); check("shown again after reload", c3.ui.shown == true)
end
do -- unchanged settings don't claim "you changed this"
  local c, ns = boot(); c.slash("settings")
  local w = ns.settingControls.alertPercent.widget; w.scripts.OnEnter(w)
  local tip = table.concat(c.tooltip, "\n")
  check("default slider tooltip", tip:find("Default: 60%% of session") and not tip:find("you changed this"), tip)
  w = ns.settingControls.locked.widget; w.scripts.OnEnter(w)
  check("default checkbox tooltip", not table.concat(c.tooltip, "\n"):find("you changed this"))
end
do -- copy window's scroll area has two anchors (it has no size of its own)
  local c, ns = boot()
  local real, points = _G.CreateFrame, {}
  _G.CreateFrame = function(kind, name, ...)
    local f = real(kind, name, ...)
    if name == "VulcanGrindWatchCopyScroll" then
      rawset(f, "SetPoint", function(_, p) points[#points + 1] = p end)
    end
    return f
  end
  ns.RunCommand("export")
  _G.CreateFrame = real
  local has = {}
  for _, p in ipairs(points) do has[p] = true end
  check("scroll area anchored top-left and bottom-right", has.TOPLEFT and has.BOTTOMRIGHT, table.concat(points, ","))
  local _ = c
end
do -- compact at max level drops the XP row
  local c, ns = boot()
  c.level = 60; c.effectiveMax = true
  ns.SetSetting("compact", true); ns.UpdateDisplay(true)
  check("compact at 60: no XP row", ns.AtMaxLevel() and not c.cellText():find("XP"), c.cellText())
  check("compact at 60: gold and kills stay", c.cellText():find("Gold") and c.cellText():find("Kills"))
end

---------------------------------------------------------------------------
-- Thirty-first and thirty-second reviews
---------------------------------------------------------------------------
local function cells(c)
  local t = {}
  for v in (c.cellText() .. " | "):gmatch("(.-) | ") do t[#t + 1] = v end
  return t
end
local function rowAfter(t, label, n)
  for i, v in ipairs(t) do
    if v == label then
      local out = {}
      for j = 1, n do out[j] = t[i + j] end
      return out
    end
  end
end
do -- compact cells match the full window's
  local c, ns = boot()
  c.item(2589, "Linen Cloth", 10)
  c.slash("idle 0"); c.slash("set windowMinutes 5")
  for m = 1, 14 do
    c.fire("PLAYER_REGEN_DISABLED")
    local n = m <= 8 and 3 or 1
    for _ = 1, n do c.xpKill("Boar", 40 * n); c.gainMoney(100 * n) end
    c.lootMsg(2589, "Linen Cloth", n * 2)
    c.tick(60)
  end
  local full = cells(c)
  local want = {}
  for _, label in ipairs({ "XP", "Gold", "Kills" }) do
    local r = rowAfter(full, label, 3)  -- total, /hr, last
    check(label .. ": /hr and Last differ (test is meaningful)", r and r[2] ~= r[3], r and (r[2] .. " vs " .. r[3]))
    want[label] = r
  end
  c.slash("compact")
  local compact = cells(c)
  for _, label in ipairs({ "XP", "Gold", "Kills" }) do
    local r = rowAfter(compact, label, 2)
    check("compact " .. label .. " /hr matches", r and r[1] == want[label][2], r and r[1])
    check("compact " .. label .. " Last matches", r and r[2] == want[label][3], r and r[2])
  end
  local _ = ns
end
do -- Loot (AH) total
  local c, ns = boot({ auctionator = { [4306] = 1000 } })
  c.fire("PLAYER_REGEN_DISABLED"); c.item(4306, "Silk Cloth", 150); c.lootMsg(4306, "Silk Cloth", 10)
  c.slash("price ah"); c.tick(1)
  local r = rowAfter(cells(c), "Loot (AH)", 1)
  local want = ns.Money(ns.Total({ "la" }), true):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  check("Loot (AH) total is the AH value", r and r[1] == want and ns.Total({ "la" }) ~= ns.Total({ "l" }), r and r[1])
end
do -- partner /hr waits for 3 minutes of their data
  local c, ns = boot()
  c.inGroup = true; ns.SetSetting("idleMinutes", 0)
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(5000); c.tick(400)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|60|1|1|20000|0|0|-1|-1|-1|15", "PARTY", "Mirel")
  check("partner with 60s: no /hr yet", c.cellText():find("Mirel | 2g 0s | -- | --", 1, true), c.cellText())
  check("duo /hr waits too", c.cellText():find("Duo gold | [^|]+ | %-%- |"), c.cellText())
end
do -- old history entries on AH pricing fall back to vendor loot
  local db = { priceSource = "auction", history = { { when = 1700000000, zone = "Westfall", elapsed = 3600,
    kills = 10, coin = 10000, loot = 10000 } } }
  local c = H.boot({ auctionator = {}, saved = { db = db } })
  c.level = 60; c.effectiveMax = true
  c.login()
  c.slash("history"); c.slash("spots")
  check("history AH, old entry: loot falls back to vendor", c.printedMatch("Westfall %(1h 00m%): 2g 0s gold/hr"))
  check("spots AH, old entry: loot falls back to vendor", c.printedMatch("Westfall: 2g 0s gold/hr"))
end
do -- a stray key in the copy box doesn't wipe the export
  local c, ns = boot(); c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(500); c.tick(60)
  local text = ns.ShowCopy("t", ns.ExportLines("history"))
  local box
  for _, fr in ipairs(c.frames) do if fr.ftype == "EditBox" and fr.parent == _G.VulcanGrindWatchCopyScroll then box = fr end end
  box:SetText("w"); box.scripts.OnTextChanged(box, true)
  check("typing puts the export back", box:GetText() == text)
  box:SetText("other"); box.scripts.OnTextChanged(box, false)
  check("our own SetText is left alone", box:GetText() == "other")
end

---------------------------------------------------------------------------
-- Thirty-third and thirty-fourth reviews
---------------------------------------------------------------------------
local function plainMoney(ns, v) return (ns.Money(v, true):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
do -- Coin/Loot Last cells, Gold total
  local c, ns = boot()
  c.slash("idle 0"); c.item(2589, "Linen Cloth", 100)
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(6000); c.lootMsg(2589, "Linen Cloth", 30); c.tick(1800)
  local t = cells(c)
  local coin, loot, gold = rowAfter(t, "Coin", 3), rowAfter(t, "Loot", 3), rowAfter(t, "Gold", 3)
  check("Coin /hr", coin[2] == plainMoney(ns, 12000), coin[2])
  check("Coin Last (spot dried up)", coin[3] == plainMoney(ns, 0), coin[3])
  check("Loot /hr", loot[2] == plainMoney(ns, 6000), loot[2])
  check("Loot Last", loot[3] == plainMoney(ns, 0), loot[3])
  check("Gold total = coin + loot", gold[1] == plainMoney(ns, 9000), gold[1])
end
do -- Loot (AH) /hr
  local c, ns = boot({ auctionator = { [4306] = 1000 } })
  c.item(4306, "Silk Cloth", 150); c.slash("price ah"); c.slash("idle 0")
  c.fire("PLAYER_REGEN_DISABLED"); c.lootMsg(4306, "Silk Cloth", 10); c.tick(1200)
  local r = rowAfter(cells(c), "Loot (AH)", 3)
  check("Loot (AH) /hr uses AH value", ns.Total({ "la" }) ~= ns.Total({ "l" }) and r[2] == plainMoney(ns, ns.Total({ "la" }) * 3), r[2])
end
do -- Duo Last
  local c, ns = boot()
  c.slash("idle 0"); c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(6000); c.tick(1800)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|1800|1|1|20000|0|0|5000|0|0|15", "PARTY", "Mirel")
  local r = rowAfter(cells(c), "Duo gold", 3)
  check("Duo /hr", r[2] == plainMoney(ns, 52000), r[2])
  check("Duo Last = my recent + theirs", r[3] == plainMoney(ns, 5000), r[3])
end
do -- trend number and sign
  local function status(c) return tostring(c.ui.fontstrings[2].text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end
  local c = boot(); c.level = 60; c.effectiveMax = true
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(10000); c.tick(60) end
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(6000); c.tick(60) end
  local pct = tonumber(status(c):match("(%-%d+)%%"))
  check("falling trend number", pct and pct <= -20 and pct >= -30, status(c))
  local c2 = boot(); c2.level = 60; c2.effectiveMax = true
  for _ = 1, 15 do c2.fire("PLAYER_REGEN_DISABLED"); c2.gainMoney(6000); c2.tick(60) end
  for _ = 1, 15 do c2.fire("PLAYER_REGEN_DISABLED"); c2.gainMoney(10000); c2.tick(60) end
  check("rising trend shows +", status(c2):match("Running%s+%+%d+%%"), status(c2))
end
do -- diagnostics export is complete
  local c, ns = boot()
  c.slash("debug on")
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(5); c.gainMoney(7); c.cast(116)
  local log = ns.DB.debugLog
  local lines = ns.ExportLines("debug")
  check("debug export has every log line", #log >= 2 and #lines == #log + 1 and lines[#lines] == log[#log], #lines)
end
do -- re-select after a stray key
  local c, ns = boot()
  ns.ShowCopy("t", { "a", "b" })
  local box
  for _, fr in ipairs(c.frames) do if fr.ftype == "EditBox" and fr.parent == _G.VulcanGrindWatchCopyScroll then box = fr end end
  local hl = 0
  rawset(box, "HighlightText", function() hl = hl + 1 end)
  box:SetText("w"); box.scripts.OnTextChanged(box, true)
  check("restored export is selected again", hl == 1)
end
do -- To level placeholder and number formats
  local c, ns = boot()
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(30)
  check("To level -- without a rate", rowAfter(cells(c), "To level", 1)[1] == "--")
  ns.S.totals.k = 1234; ns.S.totals.x = 13400; c.rested = 54321
  ns.UpdateDisplay(true)
  local t = cells(c)
  check("kills with separators", rowAfter(t, "Kills", 1)[1] == "1,234", rowAfter(t, "Kills", 1)[1])
  check("XP total short", rowAfter(t, "XP", 1)[1] == ns.Short(13400))
  check("rested shown short", tostring(rowAfter(t, "To level", 2)[2]):find("rested " .. ns.Short(54321), 1, true))
end
do -- sync version notices at the boundaries
  local c, ns = boot(); c.inGroup = true
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "3|7200|10|0|200000|160000|500000|120000|90000|200000", "PARTY", "Mirel")
  check("v3 partner accepted", ns.partners.Mirel ~= nil)
  check("v3 partner: told they can't see us", c.printedMatch("Mirel runs an older GrindWatch"))
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "5|7200|10|0|200000|160000|500000|120000|90000|200000|15|1", "PARTY", "Next")
  check("next protocol: ignored", ns.partners.Next == nil)
  check("next protocol: told to update", c.printedMatch("Next runs a newer GrindWatch"))
end
do -- corpse memory lasts 15 minutes
  local c, ns = boot()
  c.corpse("Creature-0-1-2-3-100-Q"); c.tick(600)
  check("corpse remembered at 10 min", ns.S.seen["Creature-0-1-2-3-100-Q"] ~= nil)
  c.corpse("Creature-0-1-2-3-100-Q")
  check("re-opening it isn't a new kill", ns.Total({ "k" }) == 1)
end
do -- nested non-table values repaired
  local c = H.boot({ saved = { db = { point = "CENTER", history = 5, customSpells = "none", debugLog = true } } })
  c.login()
  local ns = c.ns
  check("loads with junk nested values", #c.errors() == 0)
  check("point default", type(ns.DB.point) == "table" and ns.DB.point[3] == 300)
  check("tables restored", type(ns.DB.history) == "table" and type(ns.DB.customSpells) == "table"
    and type(ns.DB.debugLog) == "table")
  c.slash("history")
  check("/gw history works", c.printedMatch("no saved sessions yet"))
end
for _, bad in ipairs({ 0, "x", true }) do -- top-level junk
  local c = H.boot()
  _G.VulcanGrindWatchDB = bad
  c.login()
  check("VulcanGrindWatchDB = " .. tostring(bad) .. ": loads", #c.errors() == 0 and c.ns.S ~= nil and type(c.ns.DB) == "table", c.errors()[1])
  local c2 = H.boot()
  _G.VulcanGrindWatchCharDB = { session = bad }
  c2.login()
  check("session = " .. tostring(bad) .. ": loads", #c2.errors() == 0 and c2.ns.S ~= nil, c2.errors()[1])
  local c3 = H.boot()
  _G.VulcanGrindWatchCharDB = bad
  c3.login()
  check("VulcanGrindWatchCharDB = " .. tostring(bad) .. ": loads", #c3.errors() == 0 and c3.ns.S ~= nil, c3.errors()[1])
  local c4 = H.boot()
  _G.VulcanGrindWatchDB = { session = bad, history = {} }
  c4.login()
  check("v1 session = " .. tostring(bad) .. ": loads", #c4.errors() == 0 and c4.ns.S ~= nil, c4.errors()[1])
end

---------------------------------------------------------------------------
-- Thirty-fifth and thirty-sixth reviews
---------------------------------------------------------------------------
local function grid(c, ns, name)
  local lines, ys = {}, {}
  for i, fs in ipairs(c.ui.fontstrings) do
    if i > 3 and fs.shown and fs.point then
      local y = fs.point[5]
      if not lines[y] then lines[y] = {} ys[#ys + 1] = y end
      table.insert(lines[y], fs)
    end
  end
  table.sort(ys, function(a, b) return a > b end)
  check(name .. ": one line per row", #ys == #ns.BuildRows(), #ys .. " vs " .. #ns.BuildRows())
  local colX = {}
  for li, y in ipairs(ys) do
    local row = lines[y]
    check(name .. ": line " .. li .. " has 4 cells", #row == 4, #row)
    if li > 1 then check(name .. ": lines spaced", ys[li - 1] - y >= 12) end
    table.sort(row, function(a, b) return a.point[4] < b.point[4] end)
    local label = row[1]
    check(name .. ": label left-anchored", label.point[1] == "TOPLEFT")
    local edge = label.point[4] + label:GetStringWidth()
    for ci = 2, 4 do
      local fs = row[ci]
      check(name .. ": value right-anchored", fs.point[1] == "TOPRIGHT")
      if fs.text ~= "" then
        check(name .. ": no overlap line " .. li .. " col " .. ci, fs.point[4] - fs:GetStringWidth() >= edge, fs.text)
        edge = fs.point[4]
      end
      colX[ci] = colX[ci] or fs.point[4]
      check(name .. ": column " .. ci .. " aligned", fs.point[4] == colX[ci])
    end
  end
  local hint = c.ui.fontstrings[3]
  local hintH = hint.shown and 12 or 0
  if hint.shown then check(name .. ": hint at the bottom", hint.point and hint.point[1] == "BOTTOMLEFT") end
  check(name .. ": last row inside the window", -ys[#ys] + 12 <= c.ui.h - 8 - hintH, -ys[#ys] .. " / " .. c.ui.h)
  return c.ui.h
end
do
  local c, ns = boot()
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(5000); c.xpKill("Boar", 120); c.tick(300)
  local full = grid(c, ns, "full")
  c.inGroup = true
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|7200|100|50000|200000|160000|500000", "PARTY", "Mirel"); c.tick(1)
  local withPartner = grid(c, ns, "partner")
  check("taller with a partner", withPartner > full)
  c.slash("lock"); grid(c, ns, "locked")
  c.slash("compact")
  local compact = grid(c, ns, "compact")
  check("shorter in compact", compact < withPartner)
end
do -- no Duo row solo or after the partner goes stale
  local c = boot()
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(30000); c.tick(300)
  check("solo: no Duo row", not c.cellText():find("Duo gold"))
  c.inGroup = true
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|7200|100|50000|200000|160000|500000", "PARTY", "Mirel"); c.tick(1)
  check("partner: Duo row", c.cellText():find("Duo gold"))
  c.tick(100)
  check("partner kept at 100s without news", c.cellText():find("Mirel"))
  c.tick(30)
  check("stale partner: no Duo row", not c.cellText():find("Duo gold") and not c.cellText():find("Mirel"))
end
do -- 5-minute window between minute marks
  local c, ns = boot(); c.level = 60; c.effectiveMax = true
  c.slash("idle 0"); c.slash("set windowMinutes 5")
  for _ = 1, 6 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(100); c.tick(60) end
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(100); c.tick(30)
  local r = ns.RecentRate({ "c" })
  check("5-min window mid-minute has a rate", r and math.abs(r - 500 / 270 * 3600) < 1, r)
end
do -- prefix already registered counts as success
  local c = H.boot({ prefixResult = 1 }); c.login(); c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(30)
  check("sync sends when the prefix was already registered", #c.addonSent > 0)
end
do -- v1 migration subtracts quest coin
  local c = H.boot({ saved = { db = { session = { started = true, elapsed = 600, coin = 20000, questCoin = 5000,
    xp = 0, questXP = 0, lootValue = 0, xpKills = 1, corpses = 1 } } } })
  c.login()
  check("migrated coin excludes quest coin", c.ns.DB.history[1] and c.ns.DB.history[1].coin == 15000,
    c.ns.DB.history[1] and c.ns.DB.history[1].coin)
end
do -- broken history entries are repaired, the rest kept
  for _, bad in ipairs({ 5, "x", {}, { zone = "W" }, { elapsed = "abc" }, { elapsed = 600, when = "x", zone = {} } }) do
    local good = { when = 1700000000, zone = "Westfall", elapsed = 3600, kills = 10, coin = 10000, loot = 0 }
    local c = H.boot({ saved = { db = { history = { bad, good } } } })
    c.login()
    local name = "history entry " .. (type(bad) == "table" and "table" or tostring(bad))
    local ok1 = pcall(c.slash, "history")
    local ok2 = pcall(c.slash, "spots")
    local ok3 = pcall(c.slash, "export")
    check(name .. ": history/spots/export work", ok1 and ok2 and ok3 and #c.errors() == 0, c.errors()[1])
    check(name .. ": good session still listed", c.printedMatch("Westfall"))
  end
  local c = H.boot({ saved = { db = { history = { 5, {}, { elapsed = 60 } } } } })
  c.login()
  check("repair reported", c.printedMatch("history %(2 broken session%(s%) removed%)"))
  check("valid one kept", #c.ns.DB.history == 1)
end

---------------------------------------------------------------------------
-- Thirty-seventh and thirty-eighth reviews
---------------------------------------------------------------------------
do -- copy window: sized, anchored, clickable, titled, closable
  local c, ns = boot()
  ns.RunCommand("export")
  local f = _G.VulcanGrindWatchCopyFrame
  check("copy window sized", f.w > 0 and f.h > 0, f.w .. "x" .. f.h)
  check("copy window anchored", rawget(f, "lastPoint") ~= nil)
  check("copy window takes the mouse", rawget(f, "mouseEnabled") == true)
  check("copy title placed", f.title.point ~= nil)
  check("copy title says how to copy and close", f.title.text:find("Ctrl%+C") and f.title.text:find("Esc"), f.title.text)
  local close
  for _, fr in ipairs(c.frames) do if fr.parent == f and fr.template == "UIPanelCloseButton" then close = fr end end
  check("copy window has a close button", close and rawget(close, "lastPoint") ~= nil)
end
do
  local _, ns = boot({ noTemplates = true }); ns.OpenSettings()
  check("fallback spell box has a backdrop", rawget(ns.spellBox, "bgColor") ~= nil)
end
for _, bad in ipairs({ { char = {} }, { note = {} }, { label = {} }, { kills = "x" }, { xp = "x" }, { coin = "x" },
    { loot = "x" }, { lootAH = "x" } }) do
  local field = next(bad)
  for _, price in ipairs({ "vendor", "auction" }) do
    local entry = { elapsed = 600 }
    entry[field] = bad[field]
    local c = H.boot({ saved = { db = { priceSource = price, history = { entry } } } }); c.login()
    check(field .. " (" .. price .. "): history/spots/export work",
      pcall(c.slash, "history") and pcall(c.slash, "spots") and pcall(c.slash, "export") and #c.errors() == 0, c.errors()[1])
    check(field .. " (" .. price .. "): field dropped, session kept", #c.ns.DB.history == 1 and c.ns.DB.history[1][field] == nil)
  end
end
do
  local c = H.boot({ saved = { db = { history = { { elapsed = -60, zone = "Nowhere" } } } } }); c.login()
  check("negative-length session removed and reported", #c.ns.DB.history == 0 and c.printedMatch("history %(1 broken"))
end
do -- v1 migration keeps loot as the AH floor
  local c = H.boot({ saved = { db = { session = { started = true, elapsed = 600, lootValue = 30000 } } } })
  c.login()
  check("migrated v1 AH loot = vendor loot", c.ns.DB.history[1] and c.ns.DB.history[1].lootAH == 30000)
end
do -- too-old sync version
  local c = boot(); c.inGroup = true
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "1|600|5|100|200|300", "PARTY", "Mirel")
  check("v1 partner: sync off notice", c.printedMatch("duo sync is off between you") and not c.printedMatch("you see their numbers"))
end
do -- diagnostics log repaired
  for _, junk in ipairs({ {}, true }) do
    local c = H.boot({ saved = { db = { debugLog = { "a", junk, "b" } } } }); c.login()
    local ok = pcall(c.slash, "export debug")
    check("junk log line (" .. type(junk) .. "): export works", ok and #c.errors() == 0)
    check("junk log line (" .. type(junk) .. "): text lines kept", #c.ns.DB.debugLog == 2)
  end
  local big = {}
  for i = 1, 500 do big[i] = "line " .. i end
  local c = H.boot({ saved = { db = { debugLog = big } } }); c.login()
  check("oversized log trimmed to newest", #c.ns.DB.debugLog == c.ns.DEBUG_MAX and c.ns.DB.debugLog[#c.ns.DB.debugLog] == "line 500")
end

---------------------------------------------------------------------------
-- Thirty-ninth and fortieth reviews
---------------------------------------------------------------------------
do -- spell list wraps inside the window
  local _, ns = boot()
  ns.OpenSettings()
  for i = 1, 6 do ns.AddCustomSpell(100000 + i, "gather") end
  local fs = ns.spellListText
  local x = fs.point and fs.point[2]
  check("spell list wraps inside the settings window", fs.width and fs.width > 0 and x
    and x + fs.width <= ns.settingsPanel.w - 4, tostring(fs.width) .. " at " .. tostring(x))
end
do -- gear tooltip hides on leave
  local c, ns = boot()
  rawset(ns.gear, "mouseOver", true); ns.gear.scripts.OnEnter(ns.gear)
  check("gear tooltip shows", c.tooltip.shown == true)
  rawset(ns.gear, "mouseOver", false); ns.gear.scripts.OnLeave(ns.gear)
  check("gear tooltip hides when the pointer leaves", c.tooltip.shown == false)
end
do -- history with a gap
  local c = H.boot({ saved = { db = { history = { { elapsed = 600, zone = "A" }, [3] = "junk",
    [4] = { elapsed = 900, zone = "B" } } } } })
  c.login(); local ns = c.ns
  check("gap: valid sessions after it kept", #ns.DB.history == 2 and ns.DB.history[2].zone == "B")
  check("gap: junk reported", c.printedMatch("history %(1 broken"))
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(120); c.slash("reset")
  check("gap: history/spots/export work after a reset", pcall(c.slash, "history") and pcall(c.slash, "spots")
    and pcall(c.slash, "export") and #c.errors() == 0, c.errors()[1])
  check("gap: 3 sessions listed", #ns.DB.history == 3 and #ns.HistoryLines() == 3)
  local c2 = H.boot({ saved = { db = { history = { { elapsed = 60 }, foo = { elapsed = 60 } } } } }); c2.login()
  check("non-numeric history key dropped", #c2.ns.DB.history == 1 and c2.ns.DB.history.foo == nil
    and c2.printedMatch("history %(1 broken"))
end
local function lastAlert(c)
  local m
  for _, p in ipairs(c.printed) do if p:find("slowing down") then m = p end end
  return m or ""
end
do -- alert numbers at max level (money)
  local c, ns = boot(); c.level = 60; c.effectiveMax = true
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(30000); c.tick(60) end
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(5000); c.tick(60) end
  ns.S.lastAlertAt = nil
  local _, recent, session = ns.Trend()
  ns.CheckAlert()
  check("alert numbers in gold, recent then session", lastAlert(c):find(string.format(
    "slowing down: %s/hr over the last %d min vs %s/hr for the session", ns.Money(recent), ns.DB.windowMinutes,
    ns.Money(session)), 1, true), lastAlert(c))
end
do -- alert numbers while leveling (XP)
  local c, ns = boot(); c.xpMax = 1e8
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("Boar", 3000); c.tick(60) end
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("Boar", 500); c.tick(60) end
  ns.S.lastAlertAt = nil
  local _, recent, session = ns.Trend()
  ns.CheckAlert()
  local m = lastAlert(c)
  check("alert numbers in XP short form", m:find(ns.Short(recent) .. "/hr", 1, true)
    and m:find("vs " .. ns.Short(session) .. "/hr", 1, true), m)
end
do -- a known partner's updates aren't answered
  local c = boot(); c.inGroup = true
  for _ = 1, 3 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(1000); c.tick(60) end
  local msg = "4|600|10|0|200000|160000|500000|-1|-1|-1|15"
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", msg, "PARTY", "Mirel"); c.tick(10)
  local n = #c.addonSent
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", msg, "PARTY", "Mirel"); c.tick(10)
  check("known partner's update not answered", #c.addonSent == n)
end
do -- migrated v1 entry labelled v1
  local c = H.boot({ saved = { db = { session = { started = true, elapsed = 600, xp = 3000, lootValue = 30000 } } } }); c.login()
  check("v1 entry labelled v1 in /gw history", (c.ns.HistoryLines()[1] or ""):find("^1%. v1 "), c.ns.HistoryLines()[1])
  check("v1 entry labelled v1 in the export", (c.ns.ExportLines("history")[2] or ""):find("^v1,"))
end

---------------------------------------------------------------------------
-- Forty-second review
---------------------------------------------------------------------------
do -- a reset right after a routine send still reaches the partner
  local c = H.boot(); c.login(); c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED")
  local t0 = #c.addonSent
  for _ = 1, 60 do c.tick(1); if #c.addonSent > t0 then break end end
  check("a routine send went out", #c.addonSent > t0)
  local before = #c.addonSent
  c.now = c.now + 1; c.slash("reset")
  local sent = c.addonSent[#c.addonSent]
  check("reset 1s after a routine send still broadcasts the zeroed session",
    #c.addonSent == before + 1 and sent.msg:match("^4|0|0|0|0|0|0|"), sent and sent.msg)
end
do -- sparse history kept in key order
  local keys = { 9, 2, 17, 5, 33, 12, 7, 25, 3, 64, 40, 11 }
  local hist = {}
  for _, key in ipairs(keys) do hist[key] = { elapsed = 600, zone = "Z" .. key } end
  local c = H.boot({ saved = { db = { history = hist } } }); c.login()
  local sorted = { unpack(keys) }; table.sort(sorted)
  local ok = #c.ns.DB.history == #keys
  for i, key in ipairs(sorted) do ok = ok and c.ns.DB.history[i].zone == "Z" .. key end
  check("sparse history kept in key order", ok)
  local c2 = H.boot({ saved = { db = { history = { [0] = { elapsed = 60 }, [1.5] = { elapsed = 60 },
    [-1] = { elapsed = 60 }, [1] = { elapsed = 60, zone = "Kept" } } } } }); c2.login()
  check("only positive whole-number keys kept", #c2.ns.DB.history == 1 and c2.ns.DB.history[1].zone == "Kept"
    and c2.printedMatch("history %(3 broken"))
end

---------------------------------------------------------------------------
-- Forty-third and forty-fourth reviews
---------------------------------------------------------------------------
do -- at 60 with AH pricing, trend and alert follow AH gold
  local c = H.boot({ auctionator = { [4306] = 10000 } })
  c.item(4306, "Silk Cloth", 0)
  c.level = 60; c.effectiveMax = true; c.login(); local ns = c.ns
  check("AH pricing on", ns.SetSetting("priceSource", "auction") and ns.DB.priceSource == "auction")
  c.combat = true; c.fire("PLAYER_REGEN_DISABLED")
  for i = 1, 20 do
    c.corpse("Creature-0-1-2-3-" .. (5000 + i) .. "-A"); c.lootMsg(4306, "Silk Cloth", 1); c.tick(60)
  end
  c.tick(15 * 60)
  local trend = ns.Trend()
  check("trend follows AH gold", trend and trend < -0.9, trend)
  check("slowing-down alert fires", c.printedMatch("slowing down") ~= nil)
end
do -- Trend returns recent then session; alert shows them in that order
  local c = H.boot(); c.level = 60; c.effectiveMax = true; c.login(); local ns = c.ns
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(30000); c.tick(60) end
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(5000); c.tick(60) end
  ns.S.lastAlertAt = nil
  local recent, session = ns.RecentRate({ "c" }), ns.SessionRate({ "c" })
  local _, tR, tS = ns.Trend()
  check("Trend returns recent then session", tR == recent and tS == session)
  ns.CheckAlert()
  local msg
  for _, p in ipairs(c.printed) do if p:find("slowing down") then msg = p end end
  check("alert: recent first, session second", recent < session and msg and msg:find(string.format(
    "%s/hr over the last 15 min vs %s/hr for the session", ns.Money(recent), ns.Money(session)), 1, true), msg)
end
do -- each clock state shows its own label and tooltip line
  local c = H.boot(); c.login(); c.tick(1)
  local ns = c.ns
  local function status()
    for _, fs in ipairs(c.ui.fontstrings) do
      local t = tostring(fs.text)
      if fs.shown and (t:find("Running") or t:find("Waiting") or t:find("Paused") or t:find("AFK") or t:find("Idle")) then
        return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
      end
    end
    return ""
  end
  local function tip() c.ui.scripts.OnEnter(c.ui) return tostring(c.tooltip[2]) end
  check("waiting label", ns.ClockState() == "waiting" and status() == "Waiting for first pull", status())
  check("waiting tip", tip():find("first pull"), tip())
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(1)
  check("running label", status():find("^Running"), status())
  check("running tip", tip():find("Counting time"), tip())
  c.afk = true; c.fire("PLAYER_FLAGS_CHANGED", "player"); c.tick(1)
  check("afk label", ns.ClockState() == "afk" and status() == "AFK", status())
  check("afk tip", tip():find("AFK"), tip())
  c.afk = false; c.fire("PLAYER_FLAGS_CHANGED", "player")
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(400)
  check("idle label", ns.ClockState() == "idle" and status() == "Idle", status())
  check("idle tip", tip():find("No activity"), tip())
end

---------------------------------------------------------------------------
-- Full line sweep of UI.lua, Insights.lua, Sync.lua, Export.lua
---------------------------------------------------------------------------
do -- row order, full and compact
  local c, ns = boot()
  c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("Boar", 100); c.gainMoney(1234); c.tick(300)
  local function labels()
    local out = {}
    for _, row in ipairs(ns.BuildRows()) do
      out[#out + 1] = (tostring(row[1]):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub(" .*", ""))
    end
    return table.concat(out, ",")
  end
  check("full row order", labels() == ",Time,Kills,XP,Coin,Loot,Gold,To", labels())
  c.slash("compact")
  check("compact row order", labels() == "Time,XP,Gold,Kills", labels())
end
do -- first row sits below the title
  local c, ns = boot()
  ns.UpdateDisplay(true)
  local top
  for i, fs in ipairs(c.ui.fontstrings) do
    if i > 3 and fs.shown and fs.point and (not top or fs.point[5] > top) then top = fs.point[5] end
  end
  check("header row below the title", top and -top >= 8 + 14, top)
end
do -- repositioning clears the old anchor first
  local c, ns = boot()
  local cleared = 0
  rawset(c.ui, "ClearAllPoints", function() cleared = cleared + 1 end)
  ns.DB.point = { "TOPLEFT", "TOPLEFT", 10, -10 }
  ns.ApplyPosition()
  check("old anchor cleared before re-anchoring", cleared == 1)
end
do -- gear icon fills its button
  local c, ns = boot()
  local filled = 0
  for _, t in ipairs(c.textures) do
    if rawget(t, "path") == ns.gearTexture and rawget(t, "allPoints") then filled = filled + 1 end
  end
  check("gear icon and glow sized to the gear", filled == 2, filled)
end
do -- long tooltip lines wrap
  local c, ns = boot()
  c.ui.scripts.OnEnter(c.ui)
  local all = true
  for i = 2, #c.tooltip do if c.tooltip[i] ~= " " and c.tooltipWrap[i] ~= true then all = false end end
  check("window tooltip lines wrap", all)
  ns.gear.scripts.OnEnter(ns.gear)
  check("gear tooltip line wraps", c.tooltipWrap[2] == true)
end
do -- money cells use the coloured coin letters
  local c = boot()
  c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(123456); c.tick(300)
  local raw = {}
  for _, fs in ipairs(c.ui.fontstrings) do raw[#raw + 1] = tostring(fs.text) end
  local s = table.concat(raw, "\n")
  check("coin total coloured", s:find("12|cffffd700g|r 34|cffc7c7cfs|r", 1, true), s)
end
do -- the alert is written to the diagnostics log
  local c, ns = boot(); c.level = 60; c.effectiveMax = true
  c.slash("debug on")
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(30000); c.tick(60) end
  for _ = 1, 15 do c.fire("PLAYER_REGEN_DISABLED"); c.gainMoney(5000); c.tick(60) end
  ns.S.lastAlertAt = nil; ns.CheckAlert()
  local logged = false
  for _, l in ipairs(ns.DB.debugLog) do if l:find("alert: trend") then logged = true end end
  check("alert logged", logged)
end
do -- partner rows sorted; sync logged; short-name fallback; goodbye channel
  local c, ns = boot(); c.inGroup = true
  c.slash("debug on")
  for _, n in ipairs({ "Zed", "Abe", "Mo" }) do
    c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|7200|100|50000|200000|160000|500000", "PARTY", n)
  end
  c.tick(1)
  local order = {}
  for _, p in ipairs(ns.ActivePartners()) do order[#order + 1] = p.name end
  check("partners sorted by name", table.concat(order, ",") == "Abe,Mo,Zed", table.concat(order, ","))
  local fromLogged, byeLogged = false, false
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|bye", "PARTY", "Mo")
  for _, l in ipairs(ns.DB.debugLog) do
    if l:find("sync: from Zed") then fromLogged = true end
    if l:find("sync: Mo turned sync off") then byeLogged = true end
  end
  check("sync messages logged", fromLogged and byeLogged)
  c.slash("sync")
  check("goodbye in a party goes to PARTY", c.addonSent[#c.addonSent].msg == "4|bye" and c.addonSent[#c.addonSent].ch == "PARTY")
end
do
  local c, ns = boot(); c.inGroup = true
  _G.Ambiguate = nil
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "2|7200|100|50000|200000|160000|500000", "PARTY", "Mirel-Realm")
  check("without Ambiguate the realm is still stripped", ns.partners.Mirel ~= nil and ns.partners["Mirel-Realm"] == nil)
end
do -- copy window backdrop; missing kills export as 0
  local c, ns = boot()
  ns.RunCommand("export")
  local f = _G.VulcanGrindWatchCopyFrame
  check("copy window is a backdrop frame with a colour", f.template == "BackdropTemplate" and rawget(f, "bgColor") ~= nil)
  ns.DB.history = { { when = 1700000000, elapsed = 600, zone = "W" } }
  local line = ns.ExportLines("history")[2]
  check("missing numbers export as 0", line:find(",10.0,0,0,0,0,0,"), line)
  local _ = c
end

---------------------------------------------------------------------------
-- Util formatters (full line sweep of Util.lua)
---------------------------------------------------------------------------
do -- a localized single-item loot line
  local c = H.boot({ locale = { single = "Beute: %s.", multiple = "Beute: %2$dx %1$s." } }); c.login()
  c.item(2589, "Leinenstoff", 13)
  c.fire("CHAT_MSG_LOOT", "Beute: |cffffffff|Hitem:2589::::|h[Leinenstoff]|h|r.")
  check("localized single loot counted", c.ns.S.items[2589] and c.ns.S.items[2589].count == 1)
end
do -- special characters in a client format are matched literally
  local _, ns = boot()
  local p = ns.FormatToPattern("Got %s (x%d).")
  check("parentheses and dot escaped", ("Got [Cloth] (x3)."):match(p) == "[Cloth]")
  check("not a wildcard", not ("Got [Cloth] Ax3)Z"):match(p))
end
do -- debug log cap drops the very first line too
  local c, ns = boot()
  c.slash("debug on")
  for i = 1, ns.DEBUG_MAX + 2 do ns.Log("t", "n%d", i) end
  check("first log line dropped", not ns.DB.debugLog[1]:find("t: n1$"), ns.DB.debugLog[1])
end
do -- money and duration edge cases
  local _, ns = boot()
  check("Money silver without gold", ns.Money(105) == "1s 5c", ns.Money(105))
  check("Money copper only", ns.Money(5) == "5c")
  check("Money gold drops copper", ns.Money(1234567) == "123g 45s", ns.Money(1234567))
  check("Money rounds", ns.Money(104.6) == "1s 5c", ns.Money(104.6))
  check("Money negative", ns.Money(-12345) == "-1g 23s", ns.Money(-12345))
  check("Money nil", ns.Money(nil) == "0c")
  check("Duration negative is 0", ns.Duration(-5) == "0m 00s", ns.Duration(-5))
  check("Duration hours", ns.Duration(3725) == "1h 02m")
  check("Duration fraction floored", ns.Duration(59.9) == "0m 59s")
  check("Commas rounds", ns.Commas(1234.6) == "1,235", ns.Commas(1234.6))
  check("Short nil", ns.Short(nil) == "0")
end

do -- routine sync messages use the right channel
  local c = boot(); c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(30)
  check("party: routine send to PARTY", #c.addonSent > 0 and c.addonSent[#c.addonSent].ch == "PARTY")
  c.inRaid = true; c.tick(30)
  check("raid: routine send to RAID", c.addonSent[#c.addonSent].ch == "RAID")
end

---------------------------------------------------------------------------
-- Forty-fifth and forty-sixth reviews (semantic mutants)
---------------------------------------------------------------------------
do -- compact Time keeps moving between pulls
  local c, ns = boot()
  c.slash("idle 0"); c.fire("PLAYER_REGEN_DISABLED"); c.tick(120); c.slash("compact")
  check("compact Time includes uncommitted time", ns.S.elapsed < ns.Elapsed()
    and c.cellText():find("Time " .. ns.Duration(ns.Elapsed()), 1, true), c.cellText())
end
do -- menu attaches to the gear in both directions
  local c, ns = boot()
  ns.gear.bottom = 40; c.click(ns.gear)
  local lp = ns.menu.lastPoint
  check("upward menu sits above the gear", lp[1] == "BOTTOMRIGHT" and lp[2] == ns.gear and lp[3] == "TOPRIGHT")
  c.click(ns.gear); ns.gear.bottom = 500; c.click(ns.gear)
  lp = ns.menu.lastPoint
  check("downward menu sits below the gear", lp[1] == "TOPRIGHT" and lp[2] == ns.gear and lp[3] == "BOTTOMRIGHT")
end
do -- copy text is selected after it's set
  local c, ns = boot()
  ns.RunCommand("export")
  local box
  for _, fr in ipairs(c.frames) do if fr.ftype == "EditBox" and fr.parent == _G.VulcanGrindWatchCopyScroll then box = fr end end
  local log, realSet = {}, box.SetText
  rawset(box, "SetText", function(self, t) log[#log + 1] = "set"; return realSet(self, t) end)
  rawset(box, "HighlightText", function() log[#log + 1] = "hl" end)
  ns.ShowCopy("t", { "a" })
  check("export: set then select", log[1] == "set" and log[#log] == "hl", table.concat(log, ","))
  log = {}
  box.scripts.OnTextChanged(box, true)
  check("restore: set then select", log[1] == "set" and log[#log] == "hl", table.concat(log, ","))
end
do -- partner /hr from 3 minutes
  local c = boot(); c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(600)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|240|1|1|4000|0|0|0|0|0|15", "PARTY", "Mirel")
  local r = rowAfter(cells(c), "Mirel", 3)
  check("partner at 4 min has a /hr", r and r[2] ~= "--", r and r[2])
end
do -- no trend while idle
  local c, ns = boot()
  for _ = 1, 20 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("Boar", 100); c.tick(60) end
  c.tick(400)
  check("idle with a trend available", ns.ClockState() == "idle" and ns.Trend() ~= nil)
  check("idle status shows no %", not tostring(c.ui.fontstrings[2].text):find("%%"), c.ui.fontstrings[2].text)
end
do -- default-on checkbox is white until changed
  local c, ns = boot(); c.slash("settings")
  local ctl = ns.settingControls.showTrend
  check("default-on checkbox white", ctl.label.color[1] == 1 and ctl.label.color[2] == 1)
  c.click(ctl.widget)
  check("turned off: light blue", ctl.label.color[1] == 0.4 and ctl.label.color[3] == 1)
end
do -- greyed checkbox names the setting to turn on
  local c, ns = boot(); c.slash("settings"); c.slash("alert")
  local w = ns.settingControls.alertSound.widget; w.scripts.OnEnter(w)
  check("greyed checkbox names its dependency", table.concat(c.tooltip, "\n"):find("Turn on 'Slowing%-down alert' first"))
end
do -- each taught spell shows its own kind
  local c, ns = boot()
  c.slash("spell gather 116"); c.slash("spell pickpocket 1"); c.slash("settings")
  local t = ns.spellListText.text
  check("spell kinds listed per spell", t:find("1 ? (pickpocket)", 1, true) and t:find("116 Frostbolt (gather)", 1, true), t)
end
do -- menu Report stays in your own chat
  local c, ns = boot(); c.inGroup = true
  c.click(ns.gear); c.click(menuRow(ns, "^Report"))
  check("menu Report doesn't post to the group", #c.sent == 0 and c.printedMatch("Session"))
end
do -- scale change re-anchors with the rescaled offsets
  local c, ns = boot()
  ns.DB.point = { "CENTER", "CENTER", 100, 50 }; ns.ApplyPosition()
  c.slash("scale 2")
  local lp = rawget(c.ui, "lastPoint")
  check("scale 2 anchors at rescaled offsets", c.ui.scale == 2 and lp[4] == 50 and lp[5] == 25, lp[4] .. "," .. lp[5])
  c.slash("defaults yes")
  lp = rawget(c.ui, "lastPoint")
  check("defaults back to scale 1 in place", c.ui.scale == 1 and lp[4] == 100 and lp[5] == 50, lp[4] .. "," .. lp[5])
end
do -- a goodbye drops only its sender
  local c, ns = boot(); c.inGroup = true
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|600|10|0|200|100|100|-1|-1|-1|15", "PARTY", "Mirel")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|600|10|0|200|100|100|-1|-1|-1|15", "PARTY", "Bob")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|bye", "PARTY", "Bob")
  check("bye drops only the sender", ns.partners.Bob == nil and ns.partners.Mirel ~= nil)
end
do -- v1 message only when something was saved
  local c = H.boot()
  _G.VulcanGrindWatchDB = { session = { started = true, elapsed = 30, xp = 500, coin = 100 }, history = {} }
  c.login()
  check("too-short v1 session: no 'saved' message", #c.ns.DB.history == 0 and not c.printedMatch("updated from v1"))
end
do -- broken settings-window position recenters quietly
  local c, ns = boot({ saved = { db = { panelPoint = { "TOP", "TOP", "x", 0 }, history = {} } } })
  check("bad panel offset dropped quietly", ns.DB.panelPoint == nil and not c.printedMatch("were invalid"))
end
do -- infinities in history fields dropped
  local c = H.boot({ saved = { db = { history = { { elapsed = 600, coin = math.huge, xp = -math.huge, kills = 0 / 0,
    loot = 5 } } } } }); c.login()
  local h = c.ns.DB.history[1]
  check("inf/nan history fields dropped", h and h.coin == nil and h.xp == nil and h.kills == nil and h.loot == 5)
end

---------------------------------------------------------------------------
-- Forty-seventh and forty-eighth reviews
---------------------------------------------------------------------------
do -- full-window Time includes uncommitted time
  local c, ns = boot()
  c.slash("idle 0"); c.fire("PLAYER_REGEN_DISABLED"); c.tick(120)
  local r = rowAfter(cells(c), "Time", 1)
  check("full Time includes uncommitted time", ns.S.elapsed < ns.Elapsed() and r and r[1] == ns.Duration(ns.Elapsed()), r and r[1])
end
do -- Loot (AH) Last uses the AH value
  local c, ns = boot({ auctionator = { [4306] = 1000 } })
  c.item(4306, "Silk Cloth", 150); c.slash("price ah"); c.slash("idle 0")
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(600); c.lootMsg(4306, "Silk Cloth", 10); c.tick(600)
  local r = rowAfter(cells(c), "Loot (AH)", 3)
  local ah, vendor = ns.RecentRate({ "la" }), ns.RecentRate({ "l" })
  check("Loot (AH) Last uses AH value", ah and vendor and ah ~= vendor and r and r[3] == plainMoney(ns, ah), r and r[3])
end
do -- rested that outlasts the level: no "ends in"
  local c = H.boot(); c.xp, c.xpMax, c.rested = 1000, 4000, 50000; c.login()
  c.fire("PLAYER_REGEN_DISABLED")
  for _ = 1, 5 do
    c.fire("CHAT_MSG_COMBAT_XP_GAIN", "Murloc dies, you gain 200 experience.")
    c.xp = c.xp + 200; c.rested = c.rested - 100
    c.fire("PLAYER_XP_UPDATE", "player"); c.tick(60)
  end
  local _, ends = c.ns.TimeToLevel()
  check("rested shown, no end in sight", ends == nil and c.cellText():find("rested ", 1, true)
    and not c.cellText():find("ends in", 1, true), c.cellText())
end
do -- greyed labels stay grey even when changed
  local _, ns = boot(); ns.OpenSettings()
  ns.SetSetting("alertSound", false); ns.SetSetting("alertMinMinutes", 30); ns.SetSetting("alerts", false)
  local cs = ns.settingControls
  local function grey(key) local col = cs[key].label.color; return col and col[1] == 0.5 and col[2] == 0.5 and col[3] == 0.5 end
  check("greyed changed checkbox label is grey", grey("alertSound"))
  check("greyed changed slider label is grey", grey("alertMinMinutes"))
  ns.SetSetting("alerts", true)
  check("re-enabled: changed label light blue again", cs.alertSound.label.color[1] == 0.4)
end
do -- /gw report raid while only in a party
  local c = H.boot(); c.login()
  c.inGroup, c.inRaid = true, false
  local n = #c.printed
  c.slash("report raid")
  local said = false
  for i = n + 1, #c.printed do if c.printed[i]:find("you're not in a raid") then said = true end end
  check("/gw report raid in a party: explains, falls back, sends nothing", said and #c.sent == 0, #c.sent)
end
do -- exactly 10 sessions: no "more" hint
  local hist = {}
  for i = 1, 10 do hist[i] = { elapsed = 600, zone = "Z" .. i } end
  local c = H.boot({ saved = { db = { history = hist, welcomed = true } } }); c.login()
  local n = #c.printed
  c.slash("history")
  local lines, more = 0, false
  for i = n + 1, #c.printed do lines = lines + 1; if c.printed[i]:find("more:") then more = true end end
  check("10 sessions: 10 lines, no 'more'", lines == 10 and not more, lines)
end

---------------------------------------------------------------------------
-- Forty-ninth review
---------------------------------------------------------------------------
do -- the live CSV row's minutes match the window's Time
  local c, ns = boot()
  for _ = 1, 3 do c.fire("PLAYER_REGEN_DISABLED"); c.xpKill("Boar", 50); c.tick(60) end
  check("setup: some time is still uncommitted", ns.Elapsed() > ns.S.elapsed)
  local row = ns.ExportLines("history")[2]
  local minutes = row and row:match("^[^,]*,[^,]*,[^,]*,[^,]*,([^,]*),")
  check("live CSV minutes = window time", minutes == string.format("%.1f", ns.Elapsed() / 60), row)
end
do -- opening the menu clears the gear's tooltip
  local c, ns = boot()
  rawset(ns.gear, "mouseOver", true); ns.gear.scripts.OnEnter(ns.gear)
  check("gear tooltip up", c.tooltip.shown == true)
  c.click(ns.gear)
  check("menu open hides the gear tooltip", ns.menu.shown and c.tooltip.shown == false)
end

local ok = H.summary()
os.exit(ok and 0 or 1)
