-- GrindWatch 3.1: settings registry, gear menu, settings window, and the
-- behavior each new setting controls.
package.path = assert(os.getenv("GW_TESTS"), "GW_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check

local function noErrors(c, name)
  local errs = c.errors()
  check(name .. ": no runtime errors", #errs == 0, errs[1])
end

local function boot(opts)
  local c = H.boot(opts)
  c.login()
  return c, c.ns
end

local function menuRow(ns, pattern)
  for _, row in ipairs(ns.menuRows) do
    local t = tostring(row.text.text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if t:find(pattern) then return row, t end
  end
end

local function openPanel(c)
  c.slash("settings")
  return c.ns.settingControls
end

-- Farm `minutes` minutes, one pull and `copper` coin per minute.
local function farm(c, minutes, copper)
  for _ = 1, minutes do
    c.fire("PLAYER_REGEN_DISABLED")
    c.gainMoney(copper)
    c.tick(60)
  end
end

---------------------------------------------------------------------------
-- 1. Registry
---------------------------------------------------------------------------
do
  local c, ns = boot()
  local keys = {}
  for _, def in ipairs(ns.SETTING_DEFS) do
    keys[def.key] = true
    check("def " .. def.key .. " complete", def.label and def.tip and def.section and def.default ~= nil)
    check("fresh default for " .. def.key, ns.DB[def.key] == def.default, tostring(ns.DB[def.key]))
    if def.kind == "number" then
      check(def.key .. " default in range and on a step",
        def.default >= def.min and def.default <= def.max and ns.SnapSetting(def, def.default) == def.default)
    end
  end
  for _, k in ipairs({ "locked", "compact", "scale", "autoAFKPause", "idleMinutes", "priceSource", "sync",
      "alerts", "debug", "debugEcho", "windowMinutes", "alertPercent", "alertMinMinutes", "alertCooldownMinutes",
      "zoneHintMinutes", "alertSound", "bgAlpha", "showTrend" }) do
    check("setting exists: " .. k, keys[k])
  end
  local def = ns.SettingDef("IDLEMINUTES")
  check("lookup is case-insensitive", def and def.key == "idleMinutes")
  check("normalize: on/off", ns.NormalizeSetting(ns.SettingDef("locked"), "ON") == true
    and ns.NormalizeSetting(ns.SettingDef("locked"), "off") == false)
  check("normalize: junk bool refused", ns.NormalizeSetting(ns.SettingDef("locked"), "maybe") == nil)
  check("normalize: nan refused", ns.NormalizeSetting(def, "nan") == nil)
  check("normalize: inf refused", ns.NormalizeSetting(def, "inf") == nil)
  check("normalize: out of range refused", ns.NormalizeSetting(def, 61) == nil and ns.NormalizeSetting(def, -1) == nil)
  check("normalize: rounded to precision", ns.NormalizeSetting(ns.SettingDef("scale"), "1.234") == 1.23)
  check("normalize: choice alias", ns.NormalizeSetting(ns.SettingDef("priceSource"), "AH") == "auction")
  check("snap: no float junk", ns.SnapSetting(ns.SettingDef("bgAlpha"), 0.1 + 0.2) == 0.3)
  check("snap: clamps", ns.SnapSetting(ns.SettingDef("scale"), 9) == 2)
  local ok, why = ns.SetSetting("nope", 1)
  check("unknown setting refused", ok == false and why:find("unknown"))
  ok, why = ns.SetSetting("priceSource", "auction")
  check("AH refused without Auctionator", ok == false and why:find("Auctionator") and ns.DB.priceSource == "vendor")
  local fired = 0
  ns.Listen("SETTING", function() fired = fired + 1 end)
  ns.SetSetting("locked", false)
  check("no SETTING event without a change", fired == 0)
  ns.SetSetting("locked", true)
  check("SETTING event on a change", fired == 1)
  noErrors(c, "registry")
end
do
  local _, ns = boot({ auctionator = { [1] = 100 } })
  check("AH allowed with Auctionator", ns.SetSetting("priceSource", "ah") and ns.DB.priceSource == "auction")
end
do
  -- debug and echo stay consistent
  local c, ns = boot()
  ns.SetSetting("debugEcho", true)
  check("echo turns recording on", ns.DB.debug == true)
  ns.SetSetting("debug", false)
  check("recording off turns echo off", ns.DB.debugEcho == false)
  c.slash("debug echo")
  check("/gw debug echo still works", ns.DB.debug and ns.DB.debugEcho)
  c.slash("debug off")
  check("/gw debug off still clears both", not ns.DB.debug and not ns.DB.debugEcho)
end

---------------------------------------------------------------------------
-- 2. Saved-data repair
---------------------------------------------------------------------------
do
  local bad = {
    scale = "big", idleMinutes = 999, windowMinutes = 0 / 0, alertSound = "yes", priceSource = "gold",
    alertPercent = math.huge, locked = 1, bgAlpha = -3, point = { "X" },
    customSpells = { abc = "gather", [123] = "bogus", [456] = "gather", [789] = "pickpocket" },
    panelPoint = "middle", history = {},
  }
  bad.windowMinutes = 17.6  -- in range but not whole minutes: rounded, so it matches a partner's
  bad.alertCooldownMinutes = 0 / 0
  local c, ns = boot({ saved = { db = bad } })
  check("saved fractions rounded to the setting's precision", ns.DB.windowMinutes == 18)
  check("wrong type -> default", ns.DB.scale == 1 and ns.DB.alertSound == true and ns.DB.locked == false)
  check("out of range -> clamped", ns.DB.idleMinutes == 60 and ns.DB.bgAlpha == 0)
  check("nan/inf -> default", ns.DB.alertCooldownMinutes == 15 and ns.DB.alertPercent == 60)
  check("bad choice -> default", ns.DB.priceSource == "vendor")
  check("bad point -> default", ns.DB.point[1] == "CENTER" and ns.DB.point[3] == 300)
  check("bad taught spells dropped, good kept", ns.DB.customSpells.abc == nil and ns.DB.customSpells[123] == nil
    and ns.DB.customSpells[456] == "gather" and ns.DB.customSpells[789] == "pickpocket")
  check("bad panel position dropped", ns.DB.panelPoint == nil)
  local msg = c.printedMatch("were invalid and were repaired")
  local count = 0
  for _, p in ipairs(c.printed) do if p:find("were invalid") then count = count + 1 end end
  check("repair is reported once", count == 1 and msg:find("scale") and msg:find("point") and msg:find("customSpells"), msg)
  c.fire("PLAYER_LOGIN")
  check("and not again", count == 1)
  noErrors(c, "repair")
end
do
  local saved = { db = { scale = 1.5, idleMinutes = 2.5, windowMinutes = 10, history = {} } }
  local c, ns = boot({ saved = saved })
  check("valid saved values kept", ns.DB.scale == 1.5 and ns.DB.windowMinutes == 10)
  check("a 3.0 fractional idle is rounded to whole minutes", ns.DB.idleMinutes == 3)
  check("no repair message for valid data (rounding is silent)", not c.printedMatch("were invalid"))
end

---------------------------------------------------------------------------
-- 3. Gear and menu
---------------------------------------------------------------------------
do
  local c, ns = boot()
  local gear = ns.gear
  check("gear on the window", gear and gear.parent == c.ui)
  check("gear is low profile (dim)", gear.alpha < 0.5)
  check("gear falls back to an icon every client has", ns.gearTexture:find("INV_Misc_Gear_01"))
  c.ui.scripts.OnEnter(c.ui)
  check("pointing at the window brightens the gear", gear.alpha == 1)
  c.ui.scripts.OnLeave(c.ui)
  check("leaving dims it again", gear.alpha < 0.5)
  gear.scripts.OnEnter(gear)
  check("gear tooltip", c.tooltip[1] == "GrindWatch menu")
  gear.mouseOver = true
  c.ui.scripts.OnLeave(c.ui)
  check("moving onto the gear keeps it bright", gear.alpha == 1)
  gear.mouseOver = false

  c.click(gear)
  check("gear opens the menu", ns.menu.shown)
  gear.scripts.OnLeave(gear)
  check("gear stays bright while its menu is open", gear.alpha == 1)
  check("menu listens for outside clicks while open", ns.menu.events.GLOBAL_MOUSE_DOWN)
  check("menu labels show what a click does", menuRow(ns, "^Pause$") and menuRow(ns, "^Lock position$")
    and menuRow(ns, "^Compact window$") and menuRow(ns, "^Settings"))
  c.click(gear)
  check("gear again closes it", not ns.menu.shown and not ns.menu.events.GLOBAL_MOUSE_DOWN)
  check("and the gear dims once the menu closes", gear.alpha < 0.5)

  c.click(gear)
  c.click(menuRow(ns, "^Pause$"))
  check("Pause item pauses and closes the menu", ns.S.paused and not ns.menu.shown)
  c.click(gear)
  check("label flips to Resume", menuRow(ns, "^Resume$"))
  c.click(menuRow(ns, "^Resume$"))
  check("Resume item resumes", not ns.S.paused)

  c.click(gear); c.click(menuRow(ns, "^Lock position$"))
  check("Lock item locks", ns.DB.locked)
  c.click(gear); c.click(menuRow(ns, "^Unlock position$"))
  check("Unlock item unlocks", not ns.DB.locked)
  c.click(gear); c.click(menuRow(ns, "^Compact window$"))
  check("Compact item", ns.DB.compact)
  c.click(gear); c.click(menuRow(ns, "^Full window$"))
  check("Full window item", not ns.DB.compact)

  c.click(gear); c.click(menuRow(ns, "^Export history"))
  check("Export item opens the copy box", _G.VulcanGrindWatchCopyFrame.shown)
  c.click(gear); c.click(menuRow(ns, "^Report"))
  check("Report item prints the report", c.printedMatch("^.-Session"))

  -- outside click closes; a click inside doesn't
  c.click(gear)
  ns.menu.mouseOver = true
  ns.menu.scripts.OnEvent(ns.menu, "GLOBAL_MOUSE_DOWN", "LeftButton")
  check("click inside keeps the menu", ns.menu.shown)
  ns.menu.mouseOver = false
  ns.menu.scripts.OnEvent(ns.menu, "GLOBAL_MOUSE_DOWN", "LeftButton")
  check("click outside closes the menu", not ns.menu.shown)

  local listed = {}
  for _, n in ipairs(_G.UISpecialFrames) do listed[n] = true end
  check("Escape closes the menu", listed.VulcanGrindWatchMenu)

  c.click(gear)
  c.slash("hide")
  check("hiding the window closes the menu", not ns.menu.shown)
  c.slash("show")
  noErrors(c, "menu")
end
do
  -- Reset needs two clicks; the arming wears off
  local c, ns = boot()
  farm(c, 5, 1000)
  local before = ns.Total({ "c" })
  c.click(ns.gear)
  local row = menuRow(ns, "^Reset session$")
  c.click(row)
  check("first click only arms reset", ns.Total({ "c" }) == before and ns.menu.shown
    and row.text.text:find("Click again"))
  c.tick(5)
  check("arming wears off", row.text.text:find("Reset session"))
  c.click(row)
  check("a late second click just re-arms", ns.Total({ "c" }) == before)
  c.click(row)
  check("two quick clicks reset", ns.Total({ "c" }) == 0 and #ns.DB.history == 1 and not ns.menu.shown)
  check("reset message shared with /gw reset", c.printedMatch("session saved to /gw history and reset"))
  c.click(ns.gear)
  c.click(menuRow(ns, "^Reset session$"))
  c.click(ns.gear)  -- close while armed
  c.click(ns.gear)
  check("closing the menu disarms reset", menuRow(ns, "^Reset session$"))
  c.click(menuRow(ns, "^Hide window$"))
  check("Hide item hides and says how to get it back", not c.ui.shown and c.printedMatch("brings it back"))
  noErrors(c, "reset item")
end
do
  -- clients without GLOBAL_MOUSE_DOWN: close a few seconds after the pointer leaves
  local c, ns = boot({ unknownEvents = { GLOBAL_MOUSE_DOWN = true } })
  c.click(ns.gear)
  check("menu opens without GLOBAL_MOUSE_DOWN", ns.menu.shown)
  ns.menu.mouseOver = true
  ns.menu.scripts.OnUpdate(ns.menu, 5)
  check("stays while pointed at", ns.menu.shown)
  ns.menu.mouseOver = false
  ns.menu.scripts.OnUpdate(ns.menu, 2)
  check("not instantly", ns.menu.shown)
  ns.menu.scripts.OnUpdate(ns.menu, 2)
  check("closes after 3s away", not ns.menu.shown)
  noErrors(c, "menu fallback")
end
do
  -- near the bottom of the screen the menu opens upward
  local c, ns = boot()
  ns.gear.bottom = 500
  c.click(ns.gear)
  check("opens downward with room", ns.menuOpensUp == false)
  c.click(ns.gear)
  ns.gear.bottom = 40
  c.click(ns.gear)
  check("opens upward near the bottom", ns.menuOpensUp == true and ns.menu.lastPoint[1] == "BOTTOMRIGHT")
end
do
  local _, ns = boot({ fileIDs = { ["Interface\\WorldMap\\Gear_64Grey"] = 123 } })
  check("clean gear used when the client has it", ns.gearTexture:find("Gear_64Grey"))
end

---------------------------------------------------------------------------
-- 4. Settings window
---------------------------------------------------------------------------
do
  local c, ns = boot()
  local ctl = openPanel(c)
  check("/gw settings opens the window", ns.settingsPanel and ns.settingsPanel.shown)
  local count = 0
  for _ in pairs(ctl) do count = count + 1 end
  for _, def in ipairs(ns.SETTING_DEFS) do
    check("window has a control for " .. def.key, ctl[def.key] ~= nil)
  end
  check("one control per setting", count == #ns.SETTING_DEFS, count)
  c.slash("settings")
  check("/gw settings again closes it", not ns.settingsPanel.shown)
  c.slash("options")
  check("/gw options opens it", ns.settingsPanel.shown)
  c.slash("config")
  check("/gw config toggles it", not ns.settingsPanel.shown)
  _G.VulcanGrindWatch_OnAddonCompartmentClick("VulcanGrindWatch", "RightButton")
  check("addon menu right-click opens settings", ns.settingsPanel.shown and c.ui.shown)
  _G.VulcanGrindWatch_OnAddonCompartmentClick("VulcanGrindWatch", "LeftButton")
  check("addon menu left-click still toggles the window", not c.ui.shown)
  c.slash("show")
  ns.settingsPanel:Hide()
  c.click(ns.gear)
  c.click(menuRow(ns, "^Settings"))
  check("menu Settings... opens it", ns.settingsPanel.shown and not ns.menu.shown)
  local listed = {}
  for _, n in ipairs(_G.UISpecialFrames) do listed[n] = true end
  check("Escape closes the settings window", listed.VulcanGrindWatchSettings)

  -- every checkbox writes its setting
  for key, cc in pairs(ctl) do
    if cc.kind == "bool" then
      if key ~= "alerts" and not cc.widget.enabled then c.click(ctl.alerts.widget) end
      local was = ns.DB[key]
      c.click(cc.widget)
      check("checkbox " .. key .. " toggles", ns.DB[key] == not was and cc.widget.checked == ns.DB[key])
      c.click(cc.widget)
      check("checkbox " .. key .. " toggles back", ns.DB[key] == was)
    end
  end
  -- every slider writes a snapped value and shows it
  for key, cc in pairs(ctl) do
    if cc.kind == "number" then
      local def = ns.SettingDef(key)
      c.slide(cc.widget, def.min + def.step * 1.4)  -- between steps
      check("slider " .. key .. " snaps", ns.DB[key] == ns.SnapSetting(def, def.min + def.step * 1.4), ns.DB[key])
      check("slider " .. key .. " shows its value", cc.valueText.text == ns.SettingText(def))
      c.slide(cc.widget, def.max)
      check("slider " .. key .. " max", ns.DB[key] == def.max)
      check("+ greyed at max for " .. key, not cc.plus.enabled and cc.minus.enabled)
      c.click(cc.minus)
      check("- steps " .. key .. " down", ns.DB[key] == ns.SnapSetting(def, def.max - def.step), ns.DB[key])
      check("thumb follows the - button for " .. key, cc.widget.value == ns.DB[key])
      c.click(cc.plus)
      check("+ steps " .. key .. " up", ns.DB[key] == def.max)
      check("no mouse wheel on " .. key .. " (camera zoom mustn't change settings)",
        rawget(cc.widget.scripts, "OnMouseWheel") == nil)
    end
  end
  check("idle 0 reads as off", ns.SettingText(ns.SettingDef("idleMinutes"), 0) == "off")
  noErrors(c, "window controls")
end
do
  -- the window follows changes made elsewhere, and dependent controls grey out
  local c, ns = boot()
  local ctl = openPanel(c)
  c.slash("lock")
  check("slash change shows in the window", ctl.locked.widget.checked)
  c.slash("idle 12")
  check("slider follows /gw idle", ctl.idleMinutes.widget.value == 12 and ctl.idleMinutes.valueText.text == "12 min")
  c.slash("set alertPercent 45")
  check("slider follows /gw set", ctl.alertPercent.widget.value == 45)
  check("changed setting is highlighted", ctl.alertPercent.label.color[1] ~= 1)
  check("default setting isn't", ctl.alertCooldownMinutes.label.color[1] == 1)
  c.click(ctl.alerts.widget)
  check("alert options grey out when alerts are off", not ctl.alertCooldownMinutes.widget.enabled
    and not ctl.alertSound.widget.enabled and ctl.alertCooldownMinutes.label.color[1] == 0.5)
  check("greyed slider ignores drags", not c.slide(ctl.alertCooldownMinutes.widget, 30)
    and ns.DB.alertCooldownMinutes == 15)
  check("greyed slider's buttons are off", not c.click(ctl.alertCooldownMinutes.plus) and ns.DB.alertCooldownMinutes == 15)
  check("greyed slider looks greyed", ctl.alertCooldownMinutes.widget.alpha < 1
    and ctl.alertCooldownMinutes.valueText.color[1] == 0.5 and ctl.alertCooldownMinutes.plus.alpha < 1)
  check("'Alert below' stays adjustable: it also colours the trend", ctl.alertPercent.widget.enabled
    and c.slide(ctl.alertPercent.widget, 50) and ns.DB.alertPercent == 50)
  ctl.alertSound.widget.scripts.OnEnter(ctl.alertSound.widget)
  local tip = table.concat(c.tooltip, "\n")
  check("tooltip says why it's greyed and the default", tip:find("Turn on") and tip:find("Default: on"), tip)
  c.slash("alert")
  check("re-enabled by /gw alert", ctl.alertPercent.widget.enabled)
  ctl.alertPercent.widget.scripts.OnEnter(ctl.alertPercent.widget)
  tip = table.concat(c.tooltip, "\n")
  check("tooltip flags a changed value", tip:find("Default: 60%% of session") and tip:find("you changed this"), tip)
  noErrors(c, "window sync")
end
do
  -- price choice
  local c, ns = boot()
  local ctl = openPanel(c)
  local vendor, ah = ctl.priceSource.radios[1], ctl.priceSource.radios[2]
  check("vendor selected", vendor.widget.checked and not ah.widget.checked)
  check("AH greyed without Auctionator", not ah.widget.enabled)
  check("greyed AH can't be clicked", not c.click(ah.widget) and ns.DB.priceSource == "vendor")
  ah.widget.scripts.OnEnter(ah.widget)
  check("AH tooltip explains", table.concat(c.tooltip, "\n"):find("Auctionator isn't loaded"))
  -- a refused change puts the control back
  ah.widget.enabled = true
  c.click(ah.widget)
  check("refused change reverted in the window", ns.DB.priceSource == "vendor" and not ah.widget.checked
    and vendor.widget.checked)
  check("refusal explained", c.printedMatch("Auctionator isn't loaded"))
end
do
  local c, ns = boot({ auctionator = { [1] = 100 } })
  local ctl = openPanel(c)
  local vendor, ah = ctl.priceSource.radios[1], ctl.priceSource.radios[2]
  c.click(ah.widget)
  check("AH selectable with Auctionator", ns.DB.priceSource == "auction" and ah.widget.checked and not vendor.widget.checked)
  check("header follows the price setting", c.cellText():find("Loot %(AH%)"))
  _G.Auctionator = nil
  ns.settingsPanel:Hide(); ns.settingsPanel:Show()
  check("AH stays switchable-off after Auctionator goes", ah.widget.enabled)
  c.click(vendor.widget)
  check("back to vendor", ns.DB.priceSource == "vendor")
  check("now AH is greyed", not ah.widget.enabled)
end
do
  -- defaults, buttons, spells, position
  local c, ns = boot()
  local ctl = openPanel(c)
  farm(c, 5, 1000)
  c.slash("reset")
  ns.DB.customSpells[999] = "gather"
  c.slide(ctl.idleMinutes.widget, 20)
  c.click(ctl.compact.widget)
  local point = { ns.DB.point[1], ns.DB.point[2], ns.DB.point[3], ns.DB.point[4] }
  local btn
  for _, f in ipairs(c.frames) do if rawget(f, "text") == "Defaults" then btn = f end end
  check("Defaults button exists", btn ~= nil)
  c.click(btn)
  check("Defaults needs a second click", ns.DB.idleMinutes == 20 and rawget(btn, "text") == "Click again")
  c.click(btn)
  check("Defaults resets settings", ns.DB.idleMinutes == 5 and not ns.DB.compact)
  check("window follows", ctl.idleMinutes.widget.value == 5 and not ctl.compact.widget.checked)
  check("defaults keep history, spells and position", #ns.DB.history == 1 and ns.DB.customSpells[999] == "gather"
    and ns.DB.point[3] == point[3])
  c.slash("defaults")
  check("/gw defaults asks first", c.printedMatch("/gw defaults yes"))
  ns.DB.idleMinutes = 30
  c.slash("defaults yes")
  check("/gw defaults yes resets", ns.DB.idleMinutes == 5)

  -- teach a spell from the window
  ns.spellBox:SetText("12345")
  local gather, remove, clear, reprice, resetPos
  for _, f in ipairs(c.frames) do
    local t = rawget(f, "text")
    if t == "Gather" then gather = f elseif t == "Remove" then remove = f
    elseif t == "Clear log" then clear = f elseif t == "Re-value loot now" then reprice = f
    elseif t == "Reset position" then resetPos = f end
  end
  c.click(gather)
  check("window teaches a spell", ns.DB.customSpells[12345] == "gather" and ns.spellBox:GetText() == "")
  check("spell list shows it", ns.spellListText.text:find("12345"))
  ns.spellBox:SetText("12345")
  c.click(remove)
  check("window removes a spell", ns.DB.customSpells[12345] == nil and not ns.spellListText.text:find("12345"))
  ns.spellBox:SetText("")
  c.click(gather)
  check("empty spell box explained", c.printedMatch("type a spell ID first"))

  local export
  for _, f in ipairs(c.frames) do if rawget(f, "text") == "Export log" then export = f end end
  c.click(export)
  check("Export log opens the copy box on top of the settings window", _G.VulcanGrindWatchCopyFrame.shown
    and c.raiseCount and rawget(_G.VulcanGrindWatchCopyFrame, "raisedAt") == c.raiseCount
    and _G.VulcanGrindWatchCopyFrame.title.text:find("diagnostics"))
  ns.DB.debugLog[1] = "x"
  c.click(clear)
  check("Clear log needs a second click", #ns.DB.debugLog == 1)
  c.click(clear)
  check("Clear log clears", #ns.DB.debugLog == 0)
  c.click(reprice)
  check("Re-value button runs reprice", c.printedMatch("loot re%-valued"))
  c.slash("scale 2")
  ns.DB.point[3] = 5
  c.click(resetPos)
  check("Reset position: default spot at the current scale", ns.DB.point[1] == "CENTER" and ns.DB.point[3] == 150
    and c.ui.lastPoint[4] == 150)
  noErrors(c, "window buttons")
end
do
  -- the window remembers where you left it
  local c, ns = boot()
  openPanel(c)
  ns.settingsPanel.scripts.OnDragStop(ns.settingsPanel)
  check("panel position saved", ns.DB.panelPoint and ns.DB.panelPoint[1] == "TOP")
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  openPanel(c2)
  check("panel reopens where it was", c2.ns.settingsPanel.lastPoint[1] == "TOP"
    and c2.ns.settingsPanel.lastPoint[4] == 10)
end
do
  -- clients missing the Blizzard templates still get a working window
  local c, ns = boot({ noTemplates = true })
  local ctl = openPanel(c)
  check("window builds without templates", ns.settingsPanel.shown and ctl.locked and ctl.scale)
  c.click(ctl.locked.widget)
  check("fallback checkbox works", ns.DB.locked)
  check("fallback edit box has a font", ns.spellBox and rawget(ns.spellBox, "font") ~= nil)
  ns.spellBox:SetText("12")
  check("fallback edit box takes text", ns.spellBox:GetText() == "12")
  noErrors(c, "no templates")
end
do
  local c, ns = boot({ blizzSettings = true })
  check("page added under Options > AddOns", #c.categories == 1 and c.categories[1].name == "Vulcan GrindWatch"
    and ns.optionsRegistered)
  local canvas = c.categories[1].frame
  check("canvas has the handlers some clients call", type(rawget(canvas, "OnCommit")) == "function"
    and type(rawget(canvas, "OnDefault")) == "function" and type(rawget(canvas, "OnRefresh")) == "function")
  local open
  for _, f in ipairs(c.frames) do if rawget(f, "text") == "Open GrindWatch settings" then open = f end end
  c.click(open)
  check("its button opens the window", ns.settingsPanel and ns.settingsPanel.shown)
  c.slash("check")
  check("/gw check reports the options page and gear", c.printedMatch("page in Options > AddOns: yes")
    and c.printedMatch("Gear icon: "))
end
do
  local c, ns = boot({ blizzSettings = "throws" })
  check("a changed options API doesn't break loading", not ns.optionsRegistered and ns.frame ~= nil)
  noErrors(c, "options API throws")
end

---------------------------------------------------------------------------
-- 5. /gw set
---------------------------------------------------------------------------
do
  local c, ns = boot()
  c.slash("set")
  local listed = 0
  for _, def in ipairs(ns.SETTING_DEFS) do
    if c.printedMatch("^.-" .. def.key .. " = ") then listed = listed + 1 end
  end
  check("/gw set lists every setting", listed == #ns.SETTING_DEFS, listed)
  c.slash("set idleMinutes")
  check("/gw set <name> shows the value and help", c.printedMatch("idleMinutes is 5 min%."))
  c.slash("set ALERTPERCENT 45")
  check("/gw set is case-insensitive", ns.DB.alertPercent == 45 and c.printedMatch("Alert below: 45%% of session"))
  c.slash("set alertPercent banana")
  check("/gw set rejects junk", ns.DB.alertPercent == 45 and c.printedMatch("couldn't set alertPercent: not a number"))
  c.slash("set alertPercent 5")
  check("/gw set rejects out of range", ns.DB.alertPercent == 45 and c.printedMatch("must be 30 to 90"))
  c.slash("set nonsense 1")
  check("/gw set unknown name", c.printedMatch("no setting called 'nonsense'"))
  c.slash("set priceSource ah")
  check("/gw set price without Auctionator refused", ns.DB.priceSource == "vendor"
    and c.printedMatch("couldn't set priceSource: Auctionator"))
  c.slash("set locked on")
  check("/gw set bool", ns.DB.locked)
  c.slash("help")
  check("help mentions the settings window", c.printedMatch("/gw settings"))
  noErrors(c, "/gw set")
end

---------------------------------------------------------------------------
-- 6. What the settings do
---------------------------------------------------------------------------
do
  -- recent window
  local c, ns = boot()
  c.level = 60; c.effectiveMax = true
  farm(c, 20, 10000)  -- 1g/min
  farm(c, 10, 30000)  -- 3g/min
  check("15m label by default", c.cellText():find("Last 15m"))
  local r15 = ns.RecentRate({ "c" })
  c.slash("set windowMinutes 10")
  check("label follows the window", c.cellText():find("Last 10m") and not c.cellText():find("Last 15m"))
  local r10 = ns.RecentRate({ "c" })
  check("10 min window: only the fast part", math.abs(r10 - 30000 * 60) < 1, r10)
  check("15 min window blended", r15 < r10, r15)
  c.slash("set windowMinutes 30")
  local r30 = ns.RecentRate({ "c" })
  ns.Prune()
  check("longer window has the older minutes right away", math.abs(r30 - (20 * 10000 + 10 * 30000) * 2) < 1, r30)
  check("pruning keeps the longest window", math.abs(ns.RecentRate({ "c" }) - r30) < 1e-6)
  check("trend waits for the window", ns.Trend() == nil)
  c.slash("set windowMinutes 5")
  check("trend with a short window", ns.Trend() ~= nil)
  c.slash("compact")
  check("compact label follows too", c.cellText():find("Last 5m"))
  c.slash("report")
  check("report says the window", c.printedMatch("last 5m"))
  noErrors(c, "window length")
end
do
  -- alert threshold, sound and cooldown
  local c, ns = boot()
  c.level = 60; c.effectiveMax = true
  farm(c, 15, 10000)
  farm(c, 15, 6000)  -- recent ~ 6/8 of the session = -25%
  local trend = ns.Trend()
  check("trend around -25%", trend and trend < -0.15 and trend > -0.35, trend)
  ns.CheckAlert()
  check("no alert at 60%", #c.sounds == 0 and not c.printedMatch("slowing down"))
  c.slash("set alertPercent 80")
  check("trend turns red below the threshold", tostring(c.ui.fontstrings[2].text):find("ff6060"))
  ns.CheckAlert()
  check("alert at 80%", #c.sounds == 1 and c.printedMatch("over the last 15 min"))
  local function alerts()
    local n = 0
    for _, p in ipairs(c.printed) do if p:find("slowing down") then n = n + 1 end end
    return n
  end
  c.slash("set alertCooldownMinutes 5")
  c.slash("set alertSound off")
  c.tick(200)
  check("cooldown holds", not ns.CheckAlert() and alerts() == 1)
  farm(c, 2, 6000)
  c.tick(60)
  check("alert again after the cooldown", alerts() == 2, alerts())
  check("sound off: message but no sound", #c.sounds == 1)
  c.slash("set showTrend off")
  check("trend hidden", not tostring(c.ui.fontstrings[2].text):find("%%"))
  c.slash("set showTrend on")
  check("trend back", tostring(c.ui.fontstrings[2].text):find("%%"))
  noErrors(c, "alert settings")
end
do
  -- judge-after shorter than the window says so
  local _, ns = boot()
  local def = ns.SettingDef("alertMinMinutes")
  check("min below window explained", ns.SettingText(def, 10) == "10 min (waits 15)")
  check("min above window plain", ns.SettingText(def, 20) == "20 min")
end
do
  -- zone hint minutes
  local c = boot()
  farm(c, 12, 100)
  c.zone = "Duskwood"
  c.slash("set zoneHintMinutes 0")
  farm(c, 12, 100)
  check("zone hint off", not c.printedMatch("you've farmed Duskwood"))
  c.slash("set zoneHintMinutes 3")
  c.tick(10)
  check("zone hint at the new length", c.printedMatch("you've farmed Duskwood for 3%+ min"))
  noErrors(c, "zone hint")
end
do
  -- background opacity
  local c, ns = boot()
  check("default opacity", c.ui.bgColor[4] == 0.75 and c.ui.borderColor[4] == 1)
  c.slash("set bgAlpha 0")
  check("0% is text only", c.ui.bgColor[4] == 0 and c.ui.borderColor[4] == 0)
  local ctl = openPanel(c)
  c.slide(ctl.bgAlpha.widget, 0.5)
  check("opacity slider", c.ui.bgColor[4] == 0.5 and ctl.bgAlpha.valueText.text == "50%")
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  check("opacity restored on login", c2.ui.bgColor[4] == 0.5)
  check("menu doesn't share it", ns.menu.bgColor[4] > 0.9)
end
do
  -- raising the idle cutoff while idle doesn't restart the clock
  local c, ns = boot()
  farm(c, 3, 100)
  c.tick(400)  -- 6+ min without activity: idle
  check("idle", ns.ClockState() == "idle")
  local before = ns.Elapsed()
  c.slash("idle 0")
  c.tick(120)
  check("turning the cutoff off while idle keeps the clock stopped", ns.ClockState() == "idle"
    and ns.Elapsed() == before, ns.ClockState())
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(5)
  check("next pull restarts it", ns.ClockState() == "running")
  -- lowering it while inactive drops the inactive time
  c.slash("idle 30")
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(1)
  local committed = ns.S.elapsed
  c.tick(600)
  check("still running under a 30 min cutoff", ns.ClockState() == "running")
  local ctl = openPanel(c)
  c.slide(ctl.idleMinutes.widget, 5)
  c.tick(1)
  check("lowering it while inactive goes idle", ns.ClockState() == "idle")
  check("and keeps only a minute of the inactive time", math.abs(ns.Elapsed() - (committed + 60)) <= 1,
    ns.Elapsed() - committed)
  noErrors(c, "idle change")
end
do
  -- scale from the window keeps the window in place
  local c, ns = boot()
  ns.DB.point = { "CENTER", "CENTER", 100, 50 }
  local ctl = openPanel(c)
  c.slide(ctl.scale.widget, 2)
  check("scale slider", c.ui.scale == 2 and ns.DB.point[3] == 50 and ns.DB.point[4] == 25)
  check("scale text", ctl.scale.valueText.text == "2.00x")
end

---------------------------------------------------------------------------
-- 7. Sync v4: window length and goodbye
---------------------------------------------------------------------------
do
  local c, ns = boot()
  c.inGroup = true
  farm(c, 10, 10000)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|15", "PARTY", "Mirel")
  c.tick(1)
  check("same window: partner recent shown", c.cellText():find("Mirel | 36g 0s | 18g 0s | 21g 0s"), c.cellText())
  check("no window notice when they match", not c.printedMatch("recent window is"))
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|10", "PARTY", "Mirel")
  c.tick(1)
  check("different window: partner recent hidden", c.cellText():find("Mirel | 36g 0s | 18g 0s | %-%-"), c.cellText())
  check("duo recent hidden too", c.cellText():find("Duo gold | [^|]+ | [^|]+ | %-%-"), c.cellText())
  check("window mismatch explained", c.printedMatch("Mirel's recent window is 10 min and yours is 15"))
  local n = #c.printed
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7210|10|0|200000|160000|500000|120000|90000|200000|10", "PARTY", "Mirel")
  check("explained once", #c.printed == n)
  c.slash("set windowMinutes 10")
  c.tick(1)
  check("matching the window shows it again", c.cellText():find("Mirel | 36g 0s | [^|]+ | 21g 0s"), c.cellText())
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|2000", "PARTY", "Mirel")
  check("nonsense window: no rate, no crash", ns.partners.Mirel.window == nil and ns.PartnerRecentGold(ns.partners.Mirel) == nil)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|1|1|1", "PARTY", "Bob")
  check("v4 with too few fields rejected", ns.partners.Bob == nil)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "3|7200|10|0|200000|160000|500000|120000|90000|200000", "PARTY", "Old")
  check("v3 partner read as a 15 min window", ns.partners.Old and ns.partners.Old.window == 15)

  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|bye", "PARTY", "Mirel")
  c.tick(1)
  check("goodbye removes the partner at once", ns.partners.Mirel == nil and not c.cellText():find("Mirel"))
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|10", "PARTY", "Mirel")
  local sentBefore = #c.addonSent
  c.slash("sync")
  check("turning sync off says goodbye", #c.addonSent == sentBefore + 1 and c.addonSent[#c.addonSent].msg == "4|bye")
  check("and drops partners", next(ns.partners) == nil)
  c.slash("sync")
  c.tick(5)  -- (the send gap may hold it a few seconds)
  check("turning it back on sends soon", #c.addonSent == sentBefore + 2
    and c.addonSent[#c.addonSent].msg:match("^4|%d"))
  noErrors(c, "sync v4")
end
do
  -- goodbye when solo does nothing
  local c = boot()
  c.slash("sync")
  check("no goodbye when not grouped", #c.addonSent == 0)
end

do
  -- one control failing to refresh doesn't freeze the others
  local c, ns = boot()
  local ctl = openPanel(c)
  ctl.compact.refresh = function() error("boom") end
  c.slash("lock")
  check("other controls still refresh", ctl.locked.widget.checked)
  c.click(ctl.idleMinutes.widget)  -- no-op click on a slider
  c.slide(ctl.idleMinutes.widget, 9)
  check("and still take input", ns.DB.idleMinutes == 9)
  local reported = 0
  for _, p in ipairs(c.printed) do if p:find("error in settings window %(compact%)") then reported = reported + 1 end end
  check("the failure is reported once, not thrown", reported == 1, reported)
end

---------------------------------------------------------------------------
-- 8. Gaps found by mutation testing (check names start with the mutant id)
---------------------------------------------------------------------------
local function button(c, text)
  for _, f in ipairs(c.frames) do if rawget(f, "text") == text then return f end end
end
local function printedSince(c, n, pat)
  for i = n + 1, #c.printed do if c.printed[i]:find(pat) then return c.printed[i] end end
end

-- ===== Settings.lua =====
do
  local _, ns = boot()
  local alpha = ns.SettingDef("bgAlpha")
  check("S03 opacity text rounds", ns.SettingText(alpha, 0.29) == "29%" and ns.SettingText(alpha, 0.57) == "57%",
    ns.SettingText(alpha, 0.29))
  check("S08 judge-after equal to the window reads plain", ns.SettingText(ns.SettingDef("alertMinMinutes"), 15) == "15 min")
  check("S18 snap clamps at the bottom too", ns.SnapSetting(ns.SettingDef("scale"), 0) == 0.5
    and ns.SnapSetting(ns.SettingDef("idleMinutes"), -3) == 0)
  check("S38 AlertRatio is the percent as a fraction", ns.AlertRatio() == 0.6)
  ns.SetSetting("alertPercent", 45)
  check("S38 AlertRatio follows the setting", ns.AlertRatio() == 0.45)
end
do
  -- S12/S13: turning sync back on sends at once; turning it off redraws at once
  local c = boot()
  c.inGroup = true
  farm(c, 5, 1000)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|15", "PARTY", "Mirel")
  c.tick(1)
  check("S13 partner shown", c.cellText():find("Mirel"))
  c.slash("sync")
  check("S13 turning sync off drops the partner row at once", not c.cellText():find("Mirel"), c.cellText())
  c.tick(6)
  local n = #c.addonSent
  c.slash("sync")
  check("S12 turning sync on sends right away", #c.addonSent == n + 1 and c.addonSent[#c.addonSent].msg:match("^4|%d"))
end
do
  -- S35: a valid saved price choice survives a reload
  local c, ns = boot({ auctionator = { [1] = 100 }, saved = { db = { priceSource = "auction", history = {} } } })
  check("S35 saved AH price kept", ns.DB.priceSource == "auction" and not c.printedMatch("were invalid"))
end

-- ===== SettingsUI.lua =====
do
  -- U03/U04/U36: Clear log confirmer
  local c, ns = boot()
  openPanel(c)
  local clear = button(c, "Clear log")
  ns.DB.debugLog[1] = "x"
  c.click(clear); c.click(clear)
  ns.DB.debugLog[1] = "y"
  c.click(clear)
  check("U04 after confirming, the next click only arms", #ns.DB.debugLog == 1 and rawget(clear, "text") == "Click again")
  c.tick(5)  -- disarmed by its timer
  -- old timer must not disarm a newer arming
  c.click(clear)            -- arm at t
  c.tick(1); c.click(clear) -- confirm at t+1 (clears)
  ns.DB.debugLog[1] = "z"
  c.tick(1); c.click(clear) -- arm again at t+2
  c.tick(3)                 -- t+5: the t+4 timer of the first arming has fired
  check("U03 an older arming's timer doesn't disarm a newer one", rawget(clear, "text") == "Click again")
  c.click(clear)
  check("U03 second click within 4s of the newer arming clears", #ns.DB.debugLog == 0)
  ns.DB.debugLog[1] = "w"
  c.click(clear)
  ns.settingsPanel:Hide(); ns.settingsPanel:Show()
  c.click(clear)
  check("U36 closing the window disarms Clear log", #ns.DB.debugLog == 1)
end
do
  -- U01 (only observable without C_Timer): a click exactly 4s later still confirms
  local c, ns = boot()
  openPanel(c)
  local clear = button(c, "Clear log")
  _G.C_Timer.After = nil
  ns.DB.debugLog[1] = "x"
  c.click(clear); c.tick(4); c.click(clear)
  check("U01 second click at exactly 4s confirms", #ns.DB.debugLog == 0)
end
do
  -- U05: closing the menu really disarms Reset
  local c, ns = boot()
  farm(c, 5, 1000)
  c.click(ns.gear)
  c.click(menuRow(ns, "^Reset session$"))
  c.click(ns.gear); c.click(ns.gear)  -- close, reopen
  c.click(menuRow(ns, "^Reset session$"))
  check("U05 reopened menu needs two clicks again", #ns.DB.history == 0 and ns.menu.shown)
end
do
  -- U10: mouse-down on the gear is left to the gear's own click
  local c, ns = boot()
  c.click(ns.gear)
  ns.gear.mouseOver = true
  ns.menu.scripts.OnEvent(ns.menu, "GLOBAL_MOUSE_DOWN", "LeftButton")
  check("U10 mouse-down on the gear doesn't close the menu", ns.menu.shown)
  c.click(ns.gear)
  check("U10 the gear click then closes it", not ns.menu.shown)
  ns.gear.mouseOver = false
end
do
  -- U12/U13: fallback timer
  local c, ns = boot({ unknownEvents = { GLOBAL_MOUSE_DOWN = true } })
  c.click(ns.gear)
  ns.menu.scripts.OnUpdate(ns.menu, 2)
  ns.menu.mouseOver = true
  ns.menu.scripts.OnUpdate(ns.menu, 0.1)
  ns.menu.mouseOver = false
  ns.menu.scripts.OnUpdate(ns.menu, 2)
  check("U12 returning to the menu restarts the 3s", ns.menu.shown)
  ns.menu.scripts.OnUpdate(ns.menu, 2)
  check("U12 (closes eventually)", not ns.menu.shown)
  c.click(ns.gear)
  ns.menu.scripts.OnUpdate(ns.menu, 0.1)
  check("U13 reopening starts a fresh 3s", ns.menu.shown)
end
do
  -- U15/U40: flip-up uses both effective scales
  local c, ns = boot()
  ns.gear.bottom = 200; ns.gear.effScale = 0.5
  c.click(ns.gear)
  check("U15 small window scale near the bottom opens up", ns.menuOpensUp == true)
  c.click(ns.gear)
  ns.gear.effScale = 1; ns.menu.effScale = 2
  c.click(ns.gear)
  check("U40 big menu scale opens up", ns.menuOpensUp == true)
  c.click(ns.gear)
end
do
  -- U16: a fractional value set by slash isn't snapped by the open window
  local c, ns = boot()
  openPanel(c)
  c.slash("idle 2.5")
  c.slash("scale 1.23")
  check("U16 idle is whole minutes", ns.DB.idleMinutes == 3, ns.DB.idleMinutes)
  check("U16 /gw scale 1.23 kept with the window open", ns.DB.scale == 1.23, ns.DB.scale)
end
do
  -- U19: every alert option greys out
  local c = boot()
  local ctl = openPanel(c)
  c.click(ctl.alerts.widget)
  for _, k in ipairs({ "alertSound", "alertMinMinutes", "alertCooldownMinutes" }) do
    check("U19 " .. k .. " greyed when alerts are off", not ctl[k].widget.enabled)
  end
end
do
  -- U24: mid-drag the thumb isn't yanked to the snapped value
  local c, ns = boot()
  local ctl = openPanel(c)
  c.slide(ctl.idleMinutes.widget, 9.3)
  check("U24 thumb left where it is", ctl.idleMinutes.widget.value == 9.3 and ns.DB.idleMinutes == 9)
end
do
  -- U26: price radio label shows "changed"
  local c = boot({ auctionator = { [1] = 100 } })
  local ctl = openPanel(c)
  local vendor, ah = ctl.priceSource.radios[1], ctl.priceSource.radios[2]
  c.click(ah.widget)
  check("U26 changed price highlighted", ah.label.color[1] == 0.4 and vendor.label.color[1] == 1)
end
do
  -- U27/U28: panel position round trip with full anchor info
  local c, ns = boot()
  openPanel(c)
  ns.settingsPanel.GetPoint = function() return "TOPLEFT", nil, "BOTTOMLEFT", 10, -20 end
  ns.settingsPanel.scripts.OnDragStop(ns.settingsPanel)
  check("U28 relative point saved", ns.DB.panelPoint[1] == "TOPLEFT" and ns.DB.panelPoint[2] == "BOTTOMLEFT")
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  openPanel(c2)
  local lp = c2.ns.settingsPanel.lastPoint
  check("U27 panel restored at x and y", lp[1] == "TOPLEFT" and lp[3] == "BOTTOMLEFT" and lp[4] == 10 and lp[5] == -20)
end
do
  -- U29: spell ID 0 refused
  local c, ns = boot()
  openPanel(c)
  ns.spellBox:SetText("0")
  local n = #c.printed
  c.click(button(c, "Gather"))
  check("U29 spell 0 refused", ns.DB.customSpells[0] == nil and printedSince(c, n, "type a spell ID first"))
end
do
  -- U41: opening settings from anywhere closes the gear menu
  local c, ns = boot()
  c.click(ns.gear)
  c.slash("settings")
  check("U41 /gw settings closes the menu", ns.settingsPanel.shown and not ns.menu.shown)
end

-- ===== UI.lua =====
do
  local c = boot()
  c.slash("set bgAlpha 1")
  check("I02 border alpha capped at 1", c.ui.borderColor[4] == 1, c.ui.borderColor[4])
end
do
  local c, ns = boot({ fileIDs = {} })  -- the lookup exists but doesn't know the file
  check("I04 unknown file falls back to the icon", ns.gearTexture:find("INV_Misc_Gear_01"))
  local cropped = 0
  for _, t in ipairs(c.textures) do
    if rawget(t, "path") == ns.gearTexture and rawget(t, "texCoord") and t.texCoord[1] == 0.08 then cropped = cropped + 1 end
  end
  check("I05 the icon is cropped (both layers)", cropped == 2, cropped)
end
do
  local c, ns = boot({ fileIDs = { ["Interface\\WorldMap\\Gear_64Grey"] = 1 } })
  local cropped = false
  for _, t in ipairs(c.textures) do
    if rawget(t, "path") == ns.gearTexture and rawget(t, "texCoord") then cropped = true end
  end
  check("I05 the clean gear isn't cropped", not cropped)
end
do
  -- I07/N05: exactly at the threshold is not "below" it
  local c, ns = boot()
  c.level = 60; c.effectiveMax = true
  farm(c, 25, 1000)
  ns.SetSetting("alertPercent", 50)
  ns.Trend = function() return -0.5, 500, 1000 end
  ns.UpdateDisplay(true)
  check("I07 at the threshold the trend is orange, not red", tostring(c.ui.fontstrings[2].text):find("ffa500"),
    c.ui.fontstrings[2].text)
  check("N05 no alert exactly at the threshold", ns.CheckAlert() == false)
end

-- ===== Sync.lua =====
do
  local c, ns = boot()
  c.inGroup = true
  farm(c, 10, 10000)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|0", "PARTY", "Low")
  check("Y02 a zero window is unknown", ns.partners.Low and ns.partners.Low.window == nil
    and not c.printedMatch("Low's recent window"))
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|60", "PARTY", "Long")
  check("Y02 a window this version can't pick (60) is still understood and explained",
    ns.partners.Long.window == 60 and c.printedMatch("Long's recent window is 60 min"))
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|120|0|0|0|0|0|-1|-1|-1|10", "PARTY", "Fresh")
  check("Y05 no window notice when the partner has no recent rate yet", ns.partners.Fresh
    and not c.printedMatch("Fresh's recent window"))
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|15", "PARTY", "Mirel")
  c.tick(1)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|bye", "PARTY", "Mirel")
  check("Y07 goodbye redraws at once", not c.cellText():find("Mirel"))
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|15", "PARTY", "Mirel")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "5|bye", "PARTY", "Mirel")
  check("Y08 a newer version's goodbye is honoured", ns.partners.Mirel == nil)
  c.slash("set windowMinutes 10")
  check("Y11 payload carries our window", ns.SyncPayload():match("|(%d+)$") == "10", ns.SyncPayload())
  c.inRaid = true
  c.slash("sync")
  check("Y10 goodbye goes to the raid in a raid", c.addonSent[#c.addonSent].msg == "4|bye"
    and c.addonSent[#c.addonSent].ch == "RAID")
end

-- ===== Insights.lua =====
do
  -- N06: alert text names the configured window
  local c, ns = boot()
  c.level = 60; c.effectiveMax = true
  c.slash("set windowMinutes 10")
  farm(c, 15, 10000)
  farm(c, 15, 4000)
  ns.CheckAlert()
  check("N06 alert names the window", c.printedMatch("over the last 10 min"))
end
do
  -- N08: the alert may fire once the session is exactly alertMinMinutes long
  local c, ns = boot()
  c.level = 60; c.effectiveMax = true
  farm(c, 5, 1000)
  ns.Trend = function() return -0.9, 100, 1000 end
  local realElapsed = ns.Elapsed
  ns.Elapsed = function() return 20 * 60 end
  local fired = ns.CheckAlert()
  ns.Elapsed = realElapsed
  check("N08 alert allowed at exactly the judge-after time", fired == true)
end

-- ===== Core.lua =====
do
  local c, ns = boot({ saved = { db = { point = { "CENTER", "BOGUS", 0, 0 }, history = {} } } })
  check("C01 bad relative anchor repaired", ns.DB.point[2] == "CENTER" and c.printedMatch("point"))
end
do
  local _, ns = boot({ saved = { db = { point = { "CENTER", "CENTER", 0, 0 / 0 }, history = {} } } })
  check("C02 NaN y offset repaired", ns.DB.point[4] == 0)
end
do
  local c, ns = boot({ saved = { db = { panelPoint = 5, history = {} } } })
  check("C03 non-table panel position dropped without errors", ns.DB.panelPoint == nil and #c.errors() == 0)
end
do
  local _, ns = boot({ saved = { db = { panelPoint = { "TOP", "NOPE", 0, 0 }, history = {} } } })
  check("C04 panel position with a bad relative anchor dropped", ns.DB.panelPoint == nil)
end
do
  local ok = true
  for _, a in ipairs({ "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }) do
    local c, ns = boot({ saved = { db = { point = { a, a, 12, 34 }, history = {} } } })
    if ns.DB.point[1] ~= a or c.printedMatch("were invalid") then ok = false end
  end
  check("C07 every valid anchor kept", ok)
end
do
  local c, ns = boot({ saved = { db = { point = { "X" }, history = {} } } })
  check("C14 repaired point is a copy", ns.DB.point ~= ns.DEFAULT_POINT)
  c.slash("scale 2")
  check("C14 default point untouched by later changes", ns.DEFAULT_POINT[3] == 300)
end

-- ===== Commands.lua =====
do
  local c, ns = boot()
  ns.DB.idleMinutes = 30
  c.slash("defaults YES")
  check("K03 /gw defaults YES works", ns.DB.idleMinutes == 5)
  c.slash("alert")
  check("K05 /gw alert off says off", c.printed[#c.printed]:find("slowing%-down alert off%."))
  c.slash("set")
  check("K07 /gw set lists the raw value", c.printedMatch("idleMinutes = 5 %(0%-60%)"))
  check("K12 /gw set lists the range", c.printedMatch("alertPercent = 60 %(30%-90%)"))
  c.slash("idle 0")
  check("K08 /gw idle 0 says off", c.printed[#c.printed]:find("idle cutoff off%."))
  c.slash("price ah")
  check("K11 /gw price ah without Auctionator explains", c.printed[#c.printed]:find("Staying on vendor prices"))
end


---------------------------------------------------------------------------
-- 9. Fixes from the second review
---------------------------------------------------------------------------
do
  -- dragging the idle slider past your idle time and back doesn't stop the clock
  local c, ns = boot()
  c.slash("idle 10")
  farm(c, 3, 100)
  c.tick(240)  -- 4 min drinking
  local ctl = openPanel(c)
  local before = ns.Elapsed()
  for _, v in ipairs({ 9, 6, 3, 4, 7, 10 }) do c.slide(ctl.idleMinutes.widget, v) end
  c.tick(1)
  check("drag down and back: clock still running", ns.ClockState() == "running", ns.ClockState())
  check("and no time thrown away", ns.Elapsed() >= before, ns.Elapsed() - before)
end
do
  -- a session saved by 3.0 (15 min of minutes kept) and a longer window
  local c0 = H.boot()
  c0.login()
  c0.level = 60; c0.effectiveMax = true
  farm(c0, 60, 10000)  -- an hour at a steady 6g/hr... 10000c/min
  local saved = c0.saved()
  local S = saved.char.session
  S.minBucket = nil  -- what a 3.0 session looks like
  for idx in pairs(S.buckets) do if idx < 44 then S.buckets[idx] = nil end end  -- 3.0 kept ~16 minutes
  local c = H.boot({ saved = saved })
  c.login()
  c.level = 60; c.effectiveMax = true
  local ns = c.ns
  check("old session gets a data floor", ns.S.minBucket == 44, ns.S.minBucket)
  c.slash("set windowMinutes 30")
  local recent = ns.RecentRate({ "c" })
  check("longer window on an old session: no fake slump", math.abs(recent - 10000 * 60) < 1, recent)
  c.fire("PLAYER_REGEN_DISABLED"); c.tick(1)
  check("clock running for the alert check", ns.ClockState() == "running")
  check("no false alert", not ns.CheckAlert())
  local fresh = H.boot()
  fresh.login()
  check("new sessions start with no floor", fresh.ns.S.minBucket == 0)
end
do
  -- what the window shows is what /gw set accepts
  local c, ns = boot()
  c.slash("set idleMinutes off")
  check("/gw set idleMinutes off", ns.DB.idleMinutes == 0)
  c.slash("idle 5"); c.slash("idle off")
  check("/gw idle off", ns.DB.idleMinutes == 0 and c.printed[#c.printed]:find("idle cutoff off"))
  c.slash("set zoneHintMinutes off")
  check("/gw set zoneHintMinutes off", ns.DB.zoneHintMinutes == 0)
  c.slash("set bgAlpha 50%")
  check("/gw set bgAlpha 50%", ns.DB.bgAlpha == 0.5)
  c.slash("set bgAlpha 75")
  check("/gw set bgAlpha 75 means 75%", ns.DB.bgAlpha == 0.75)
  c.slash("set bgAlpha 0.3")
  check("/gw set bgAlpha 0.3", ns.DB.bgAlpha == 0.3)
  c.slash("set scale off")
  check("off isn't a scale", ns.DB.scale == 1 and c.printedMatch("couldn't set scale"))
end
do
  -- re-choosing the current value is never refused
  local c, ns = boot({ saved = { db = { priceSource = "auction", history = {} } } })  -- no Auctionator now
  check("saved AH kept even without Auctionator", ns.DB.priceSource == "auction")
  local ctl = openPanel(c)
  local n = #c.printed
  c.click(ctl.priceSource.radios[2].widget)
  check("clicking the selected AH choice: no complaint", #c.printed == n and ns.DB.priceSource == "auction")
  c.slash("set priceSource auction")
  check("/gw set to the current value succeeds", c.printedMatch("Value loot at: Auction house"))
end
do
  -- locked at 0% opacity: clicks go through
  local c = boot()
  check("window takes clicks normally", c.ui.mouseEnabled == true)
  c.slash("set bgAlpha 0")
  check("0% but unlocked: still draggable", c.ui.mouseEnabled == true)
  c.slash("lock")
  check("0% and locked: click-through", c.ui.mouseEnabled == false)
  c.slash("set bgAlpha 0.5")
  check("visible again: takes clicks", c.ui.mouseEnabled == true)
  c.slash("set bgAlpha 0")
  c.slash("unlock")
  check("unlocking: takes clicks", c.ui.mouseEnabled == true)
  noErrors(c, "click-through")
end
do
  -- spell list stays short, sorted by number
  local c, ns = boot()
  for _, id in ipairs({ 9, 10, 100, 2, 3, 4, 5, 6 }) do ns.DB.customSpells[id] = "gather" end
  openPanel(c)
  local text = ns.spellListText.text
  check("spells sorted by number", text:find("^Added: 2 ") and text:find("2 .-3 .-4 .-5 "), text)
  check("long list capped", text:find("%+4 more") and not text:find("100 ") and not text:find(" 6 "), text)
  check("list kept to three lines", ns.spellListText.maxLines == 3)
  ns.spellBox:SetText("123")
  ns.spellBox.scripts.OnEnterPressed(ns.spellBox)
  check("Enter in the spell box says what to do", c.printedMatch("now click Gather, Pickpocket or Remove"))
  check("Pickpocket button spelled out", button(c, "Pickpocket") ~= nil)
end
do
  -- a client that silently returns bare frames for unknown templates
  local c, ns = boot({ silentTemplates = true })
  local ctl = openPanel(c)
  check("bare checkbox gets fallback textures", rawget(ctl.locked.widget, "normalTexture"):find("UI%-CheckBox%-Up"))
  check("bare edit box gets a font", rawget(ns.spellBox, "font") ~= nil)
  c.click(ctl.compact.widget)
  check("and works", ns.DB.compact)
  noErrors(c, "silent templates")
end
do
  -- Settings... from the menu never closes an open window
  local c, ns = boot()
  openPanel(c)
  c.click(ns.gear)
  c.click(menuRow(ns, "^Settings"))
  check("menu Settings... keeps the window open", ns.settingsPanel.shown)
end

---------------------------------------------------------------------------
-- 10. Fixes from the third review
---------------------------------------------------------------------------
do
  -- gear dims even when the window is click-through
  local c, ns = boot()
  c.slash("set bgAlpha 0"); c.slash("lock")
  ns.gear.scripts.OnEnter(ns.gear)
  c.ui.mouseOver = true  -- pointer over the (click-through) window's text
  ns.gear.scripts.OnLeave(ns.gear)
  check("click-through window doesn't keep the gear bright", ns.gear.alpha < 1)
  check("but a click-through window's gear is easier to see", ns.gear.alpha == 0.6, ns.gear.alpha)
  c.ui.mouseOver = false  -- pointer elsewhere
  c.slash("unlock")
  check("normal dim once the window takes clicks again", ns.gear.alpha == 0.35, ns.gear.alpha)
end
do
  -- menu above the settings window
  local c, ns = boot()
  openPanel(c)
  c.click(ns.gear)
  check("menu drawn above the settings window", ns.menu.strata == "FULLSCREEN_DIALOG"
    and ns.settingsPanel.strata == "DIALOG" and rawget(ns.menu, "raisedAt") ~= nil)
end
do
  -- buttons on a client without UIPanelButtonTemplate get a font (SetText would fail)
  local c, ns = boot({ noTemplates = true, blizzSettings = true })
  openPanel(c)
  local styled = 0
  for _, f in ipairs(c.frames) do
    if f.ftype == "Button" and rawget(f, "text") and rawget(f, "normalFont") then styled = styled + 1 end
  end
  check("fallback buttons styled", styled >= 10, styled)
  check("options page still registered", ns.optionsRegistered)
  noErrors(c, "fallback buttons")
  local c2 = boot({ silentTemplates = true, blizzSettings = true })
  openPanel(c2)
  noErrors(c2, "silent fallback buttons")
end
do
  -- the step buttons use stock icons, not a template
  local c = boot()
  local ctl = openPanel(c)
  check("-/+ are icon buttons", rawget(ctl.scale.minus, "normalTexture"):find("UI%-MinusButton%-Up")
    and rawget(ctl.scale.plus, "normalTexture"):find("UI%-PlusButton%-Up"))
end
do
  -- the game mustn't also save the window positions per character
  local c, ns = boot()
  c.ui.scripts.OnDragStop(c.ui)
  check("main window not user-placed", rawget(c.ui, "userPlaced") == false)
  openPanel(c)
  ns.settingsPanel.scripts.OnDragStop(ns.settingsPanel)
  check("settings window not user-placed", rawget(ns.settingsPanel, "userPlaced") == false)
end
do
  -- changing the window length tells the partner at once
  local c = boot()
  c.inGroup = true
  farm(c, 5, 1000)
  c.tick(10)
  local n = #c.addonSent
  c.slash("set windowMinutes 10")
  check("window change synced at once", #c.addonSent == n + 1 and c.addonSent[#c.addonSent].msg:match("|10$"))
end
do
  -- opacity input
  local c, ns = boot()
  c.slash("set bgAlpha 1.5")
  check("1.5 opacity is ambiguous: refused", ns.DB.bgAlpha == 0.75 and c.printedMatch("percentage like 50%%"))
  c.slash("set bgAlpha 1")
  check("1 = 100%", ns.DB.bgAlpha == 1)
  c.slash("set")
  check("/gw set lists opacity as a percentage", c.printedMatch("bgAlpha = 1 %(0%%%-100%%, or 0%-1%)"))
end
do
  -- Defaults at a non-default scale keeps the window in place; no sync noise
  local c, ns = boot()
  c.inGroup = true
  farm(c, 5, 1000)
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|15", "PARTY", "Mirel")
  c.slash("scale 2")
  ns.DB.point = { "CENTER", "CENTER", 50, 20 }
  c.tick(10)
  local sent = #c.addonSent
  c.slash("defaults yes")
  check("defaults: scale back to 1, window stays put", ns.DB.scale == 1 and ns.DB.point[3] == 100 and ns.DB.point[4] == 40)
  check("defaults: partner kept, no goodbye", ns.partners.Mirel ~= nil and #c.addonSent == sent)
end
do
  -- a client whose sliders snap programmatic values keeps fine values from slash commands
  local c, ns = boot({ sliderSnaps = true })
  local ctl = openPanel(c)
  c.slash("scale 1.23")
  check("snapping slider doesn't change /gw scale 1.23", ns.DB.scale == 1.23 and ctl.scale.valueText.text == "1.23x",
    ns.DB.scale)
  c.slide(ctl.scale.widget, 1.5)
  check("dragging still works", ns.DB.scale == 1.5)
end

---------------------------------------------------------------------------
-- 11. Fixes from the fourth review
---------------------------------------------------------------------------
do
  -- 11.0+ addon menu passes a table with the button name
  local c, ns = boot()
  _G.VulcanGrindWatch_OnAddonCompartmentClick("VulcanGrindWatch", { buttonName = "RightButton" })
  check("new-style right-click opens settings", ns.settingsPanel and ns.settingsPanel.shown and c.ui.shown)
  _G.VulcanGrindWatch_OnAddonCompartmentClick("VulcanGrindWatch", "RightButton")
  check("right-click again keeps it open (doesn't toggle it away)", ns.settingsPanel.shown)
  _G.VulcanGrindWatch_OnAddonCompartmentClick("VulcanGrindWatch", { buttonName = "LeftButton" })
  check("new-style left-click toggles the window", not c.ui.shown)
  local toc = io.open((assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh")) .. "VulcanGrindWatch.toc"):read("*a")
  check("TOC wires the addon-menu tooltip", toc:find("AddonCompartmentFuncOnEnter: VulcanGrindWatch_OnAddonCompartmentEnter")
    and toc:find("AddonCompartmentFuncOnLeave: VulcanGrindWatch_OnAddonCompartmentLeave"))
  _G.VulcanGrindWatch_OnAddonCompartmentEnter("VulcanGrindWatch", { buttonName = "x" })  -- not a frame
  check("tooltip explains both clicks", c.tooltip[1] == "GrindWatch" and table.concat(c.tooltip, "\n"):find("Right%-click: settings")
    and _G.GameTooltip.defaultAnchored)
  _G.VulcanGrindWatch_OnAddonCompartmentLeave()
  check("tooltip hides", c.tooltip.shown == false)
  noErrors(c, "compartment")
end
do
  local c = H.boot()
  c.login()
  check("first-run message points at the gear", c.printedMatch("Click the small gear"))
end
do
  local c = boot()
  c.slash("set bgAlpha 150%")
  check("percent range error in percent", c.printedMatch("must be 0%% to 100%%"))
  c.slash("scale")
  check("/gw scale shows the current value", c.printedMatch("window scale is 1.00x"))
end
do
  local c, ns = boot({ saved = { db = { priceSource = "auction", history = {} } } })
  c.slash("price ah")
  check("/gw price ah when already AH but Auctionator gone: honest", c.printedMatch("only vendor prices count")
    and not c.printedMatch("loot now valued at AH"))
  check("setting kept", ns.DB.priceSource == "auction")
end
do
  -- clicking back into the world gives the keyboard back
  local c, ns = boot()
  openPanel(c)
  local box = ns.spellBox
  box.scripts.OnEditFocusGained(box)
  check("box listens for outside clicks while focused", box.events.GLOBAL_MOUSE_DOWN)
  local cleared = false
  rawset(box, "ClearFocus", function() cleared = true end)
  box.mouseOver = true
  box.scripts.OnEvent(box, "GLOBAL_MOUSE_DOWN")
  check("click in the box keeps focus", not cleared)
  box.mouseOver = false
  box.scripts.OnEvent(box, "GLOBAL_MOUSE_DOWN")
  check("click elsewhere clears focus", cleared)
  box.scripts.OnEditFocusLost(box)
  check("stops listening once unfocused", not box.events.GLOBAL_MOUSE_DOWN)
end
do
  local c, ns = boot()
  c.slash("export")
  openPanel(c)
  check("settings window raised over the copy window", rawget(ns.settingsPanel, "raisedAt") == c.raiseCount
    and c.raiseCount ~= nil)
end
do
  -- click sounds
  local c, ns = boot()
  local ctl = openPanel(c)
  c.click(ctl.compact.widget)
  check("checkbox on sound", c.uiSounds[#c.uiSounds] == 856)
  c.click(ctl.compact.widget)
  check("checkbox off sound", c.uiSounds[#c.uiSounds] == 857)
  local function one(id)  -- exactly one new UI sound, and it's this one
    local n = #c.uiSounds
    return function() return #c.uiSounds == n + 1 and c.uiSounds[#c.uiSounds] == id end
  end
  local got = one(1115)
  c.click(ctl.scale.plus)
  check("step sound", got())
  c.click(ns.gear)
  got = one(1115)
  c.click(menuRow(ns, "^Lock position$"))
  check("menu click sound", got())
  got = one(856)
  c.click(ctl.priceSource.radios[1].widget)
  check("radio sound", got())
  got = one(852)
  c.click(button(c, "Export log"))
  check("button sound", got())
  check("no alert sound from clicks", #c.sounds == 0)
end

---------------------------------------------------------------------------
-- 12. Fixes from the sixth review
---------------------------------------------------------------------------
do
  -- idle cutoff: a drag only applies on release, even with the clock ticking mid-drag
  local c, ns = boot()
  c.slash("idle 10")
  farm(c, 3, 100)
  c.tick(240)  -- 4 min drinking
  local ctl = openPanel(c)
  local before = ns.Elapsed()
  c.drag(ctl.idleMinutes.widget, { 9, 6, 3, 3, 4, 7, 10 }, function(i)
    if i == 4 then
      check("mid-drag: value shown, not applied", ns.DB.idleMinutes == 10
        and ctl.idleMinutes.valueText.text == "3 min", ctl.idleMinutes.valueText.text)
      c.tick(1)  -- the clock ticks while the slider sits at 3
    end
  end)
  c.tick(1)
  check("drag through a short cutoff with a tick: clock still running", ns.ClockState() == "running", ns.ClockState())
  check("no drinking time thrown away", ns.Elapsed() >= before + 2, ns.Elapsed() - before)
  c.drag(ctl.idleMinutes.widget, { 8, 7 })
  check("released: applied", ns.DB.idleMinutes == 7 and ctl.idleMinutes.valueText.text == "7 min")
  -- another setting changing mid-drag refreshes the window, but leaves the dragged thumb alone
  c.drag(ctl.idleMinutes.widget, { 20 }, function()
    c.slash("lock")
    check("refresh mid-drag doesn't yank the thumb back", ctl.idleMinutes.widget.value == 20
      and ctl.idleMinutes.valueText.text == "20 min" and ctl.locked.widget.checked, ctl.idleMinutes.widget.value)
  end)
  check("and the drag still applies", ns.DB.idleMinutes == 20)
  c.slash("unlock")
  -- closed mid-drag: applied on close
  local w = ctl.idleMinutes.widget
  w.scripts.OnMouseDown(w, "LeftButton")
  w.value = 12; w.scripts.OnValueChanged(w, 12, true)
  ns.settingsPanel:Hide()
  check("window closed mid-drag applies the value", ns.DB.idleMinutes == 12)
end
do
  -- recent window: dragging there and back doesn't ping the partner
  local c = boot()
  c.inGroup = true
  farm(c, 5, 1000)
  c.tick(10)
  local ctl = openPanel(c)
  local n = #c.addonSent
  c.drag(ctl.windowMinutes.widget, { 20, 25, 15 })
  c.tick(6)
  local sentWindows = {}
  for i = n + 1, #c.addonSent do sentWindows[#sentWindows + 1] = c.addonSent[i].msg:match("|(%d+)$") end
  check("no in-between window sent", #sentWindows == 0, table.concat(sentWindows, ","))
  c.drag(ctl.windowMinutes.widget, { 20, 25 })
  check("final window sent once on release", #c.addonSent == n + 1 and c.addonSent[#c.addonSent].msg:match("|25$"))
end
do
  -- scale and opacity still apply live while dragging (you see the window change)
  local c = boot()
  local ctl = openPanel(c)
  c.drag(ctl.scale.widget, { 1.5 }, function()
    check("scale applies mid-drag", c.ui.scale == 1.5)
  end)
  c.drag(ctl.bgAlpha.widget, { 0.3 }, function()
    check("opacity applies mid-drag", c.ui.bgColor[4] == 0.3)
  end)
end
do
  -- the window's tooltip names the configured window length
  local c = boot()
  c.slash("set windowMinutes 10")
  c.ui.scripts.OnEnter(c.ui)
  local tip = table.concat(c.tooltip, "\n")
  check("tooltip says last 10 minutes", tip:find("Last 10m = your current pace") and tip:find("last 10 minutes"), tip)
end
do
  local c, ns = boot()
  c.slash("set bgAlpha 1.75")
  check("1.75 opacity is ambiguous too", ns.DB.bgAlpha == 0.75 and c.printedMatch("percentage like 50%%"))
  c.slash("set bgAlpha 2")
  check("2 means 2%", ns.DB.bgAlpha == 0.02)
end
do
  local c = boot({ saved = { db = { idleMinutes = 999, history = {} } } })
  check("repair message says repaired, not reset", c.printedMatch("were invalid and were repaired %(out%-of%-range values pulled into range"))
end

---------------------------------------------------------------------------
-- 13. Fixes from the seventh review
---------------------------------------------------------------------------
do
  -- a right-click mid-drag doesn't end the drag
  local c, ns = boot()
  local ctl = openPanel(c)
  local w = ctl.idleMinutes.widget
  w.scripts.OnMouseDown(w, "LeftButton")
  w.value = 1; w.scripts.OnValueChanged(w, 1, true)
  w.scripts.OnMouseDown(w, "RightButton"); w.scripts.OnMouseUp(w, "RightButton")
  check("right-click mid-drag: still not applied", ns.DB.idleMinutes == 5)
  w.value = 2; w.scripts.OnValueChanged(w, 2, true)
  check("drag continues pending", ns.DB.idleMinutes == 5 and ctl.idleMinutes.valueText.text == "2 min")
  w.scripts.OnMouseUp(w, "LeftButton")
  check("left release applies", ns.DB.idleMinutes == 2)
  -- a lone right-click on the slider doesn't leave it stuck "dragging"
  w.scripts.OnMouseDown(w, "RightButton"); w.scripts.OnMouseUp(w, "RightButton")
  c.slash("idle 25")
  check("after a right-click the slider still follows changes", w.value == 25)
  -- after a drag the slider follows other changes again, and a plain click doesn't re-apply the old drag
  c.drag(w, { 8, 7 })
  c.slash("idle 30")
  check("slider follows /gw idle after a drag", w.value == 30 and ctl.idleMinutes.valueText.text == "30 min")
  w.scripts.OnMouseDown(w, "LeftButton"); w.scripts.OnMouseUp(w, "LeftButton")
  check("a click without moving changes nothing", ns.DB.idleMinutes == 30)
  -- closed mid-drag, changed while closed, reopened: slider shows the new value
  w.scripts.OnMouseDown(w, "LeftButton")
  w.value = 12; w.scripts.OnValueChanged(w, 12, true)
  ns.settingsPanel:Hide()
  c.slash("idle 40")
  c.slash("settings")
  check("reopened slider follows changes made while closed", w.value == 40)
end
do
  -- repair message for taught spells says only bad entries went
  local c, ns = boot({ saved = { db = { customSpells = { [194174] = "gather", [5] = "bogus" }, history = {} } } })
  check("good spell kept", ns.DB.customSpells[194174] == "gather" and ns.DB.customSpells[5] == nil)
  check("message says only the bad entries", c.printedMatch("customSpells %(only the bad entries removed%)"))
end
do
  -- addon-menu tooltip on a real frame owner
  local c = boot()
  local owner = CreateFrame("Button")
  _G.GameTooltip.defaultAnchored = nil
  _G.VulcanGrindWatch_OnAddonCompartmentEnter("VulcanGrindWatch", owner)
  check("tooltip shown, anchored to the menu entry", c.tooltip.shown == true and not _G.GameTooltip.defaultAnchored)
  _G.GameTooltip_SetDefaultAnchor = nil
  check("no anchor helper: no error", pcall(_G.VulcanGrindWatch_OnAddonCompartmentEnter, "VulcanGrindWatch", { buttonName = "x" }))
end
do
  -- /gw price vendor never prints the AH message; explicit percents are never ambiguous
  local c, ns = boot()
  c.slash("price vendor")
  check("/gw price vendor message", c.printed[#c.printed]:find("loot now valued at vendor price"))
  c.slash("set bgAlpha 1.5%")
  check("1.5% is 1.5%", ns.DB.bgAlpha == 0.02)
end
do
  -- before login, the addon-menu click does nothing (no error)
  local c = H.boot()
  check("addon-menu click before login is harmless", pcall(_G.VulcanGrindWatch_OnAddonCompartmentClick, "VulcanGrindWatch", "LeftButton"))
  local _ = c
end
do
  -- click sounds can't break clicks
  local c, ns = boot()
  local ctl = openPanel(c)
  _G.PlaySound = function() error("sound system") end
  check("a failing PlaySound doesn't break a click", pcall(c.click, ctl.compact.widget) and ns.DB.compact and #c.errors() == 0)
  _G.SOUNDKIT = nil
  check("no SOUNDKIT: clicks still work", pcall(c.click, ctl.compact.widget) and not ns.DB.compact)
end

---------------------------------------------------------------------------
-- 14. Fixes from the eighth review
---------------------------------------------------------------------------
local function strip(s) return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
do -- the open menu follows changes made by key binding or slash command
  local c, ns = boot(); c.click(ns.gear)
  _G.VulcanGrindWatch_TogglePause()
  check("F1 menu open after a key-binding pause", ns.menu.shown)
  check("F1 pause row relabels to Resume", menuRow(ns, "^Resume$") ~= nil)
  c.click(menuRow(ns, "^Resume$") or menuRow(ns, "^Pause$"))
  check("F1 clicking it resumes", ns.S.paused == false)
  c.click(ns.gear); c.slash("lock")
  check("F1 lock row relabels after /gw lock", menuRow(ns, "^Unlock position$") ~= nil)
  local reset = menuRow(ns, "^Reset session$"); c.click(reset); c.slash("compact"); c.tick(1)
  check("F1 armed reset keeps its warning text", strip(reset.text.text):find("Click again"))
  c.click(ns.gear); c.click(ns.gear)
  check("F1 reopened menu shows Reset session", menuRow(ns, "^Reset session$") ~= nil)
  c.slash("pause")
  check("F1 menu still open, showing Resume", ns.menu.shown and menuRow(ns, "^Resume$") ~= nil)
  c.slash("reset")
  check("F1 pause row follows a /gw reset", ns.menu.shown and not ns.S.paused and menuRow(ns, "^Pause$") ~= nil)
  check("F1 no errors", #c.errors() == 0, c.errors()[1])
end
do -- S30/S40
  local c = boot(); local n = #c.printed
  c.slash("set locked maybe")
  check("S30 bool refusal says on or off", printedSince(c, n, "couldn't set locked: use on or off%."))
  n = #c.printed; c.slash("set priceSource xyz")
  check("S40 choice refusal lists the choices", printedSince(c, n, "couldn't set priceSource: use vendor or auction%."))
  c.slash("set")
  check("/gw set lists the price as you'd type it", c.printedMatch("priceSource = vendor %(vendor | auction%)"))
end
do -- U05/U07/U08
  local c, ns = boot(); c.click(ns.gear)
  local w, h = ns.menu:GetSize(); local rows = 0
  for _, row in ipairs(ns.menuRows) do
    rows = rows + 1
    check("U05 row leaves room right of its text: " .. strip(row.text.text), w - 12 >= row.text:GetStringWidth() + 12)
  end
  check("U07 menu tall enough for every row plus padding", h >= 6 + rows * 16 + 6, h)
  c.click(ns.gear); ns.gear.bottom = h + 1; c.click(ns.gear)
  check("U08 opens upward when the gap wouldn't fit", ns.menuOpensUp == true)
  c.click(ns.gear); ns.gear.bottom = h + 6; c.click(ns.gear)
  check("U08 downward with room for the gap", ns.menuOpensUp == false)
end
do -- U29
  local c, ns = boot({ auctionator = { [1] = 100 } }); c.slash("settings")
  local r = ns.settingControls.priceSource.radios
  local vendor = r[1].choice == "vendor" and r[1] or r[2]; local ah = r[1].choice == "auction" and r[1] or r[2]
  check("U29 vendor (default) label plain white", vendor.label.color[1] == 1 and vendor.label.color[2] == 1 and vendor.label.color[3] == 1)
  c.click(ah.widget)
  check("U29 AH selected: its label light blue", ah.label.color[1] == 0.4)
  check("U29 vendor label plain while not selected", vendor.label.color[1] == 1)
end
do -- U03/U37/U44
  local c, ns = boot(); c.slash("settings")
  local defaults = button(c, "Defaults"); ns.SetSetting("compact", true)
  c.click(defaults)
  check("U37 first click only arms", ns.DB.compact and rawget(defaults, "text") == "Click again")
  c.slash("settings")
  check("U03 closing restores the Defaults text", rawget(defaults, "text") == "Defaults")
  c.slash("settings"); c.click(defaults)
  check("U37 closing disarmed it: one click after reopening doesn't reset", ns.DB.compact == true)
  local n = #c.printed; c.click(defaults)
  check("U44 two clicks reset and say so", not ns.DB.compact and printedSince(c, n, "settings back to defaults%."))
end
do -- U46
  local c, ns = boot(); c.click(ns.gear)
  local reset = menuRow(ns, "^Reset session$")
  check("U46 reset item has a tooltip", reset.scripts.OnEnter ~= nil)
  ;(reset.scripts.OnEnter or function() end)(reset)
  check("U46 reset item tooltip says click twice", c.tooltip.shown and table.concat(c.tooltip, "\n"):find("Click twice"))
  ;(reset.scripts.OnLeave or function() end)(reset)
  check("U46 tooltip hides", c.tooltip.shown == false)
  local hide = menuRow(ns, "^Hide window$")
  ;(hide.scripts.OnEnter or function() end)(hide)
  check("U46 hide item tooltip says how to get it back", table.concat(c.tooltip, "\n"):find("/gw"))
end
do -- U64
  local c, ns = boot(); c.slash("scale 1.23"); c.slash("settings")
  local ctl = ns.settingControls.scale
  c.click(ctl.plus); check("U64 + from 1.23 lands on the next step, 1.25", ns.DB.scale == 1.25, ns.DB.scale)
  c.slash("scale 1.23"); c.click(ctl.minus); check("U64 - from 1.23 lands on 1.20", ns.DB.scale == 1.2, ns.DB.scale)
end
do -- hand-edited echo-without-recording is made consistent
  local _, ns = boot({ saved = { db = { debug = false, debugEcho = true, history = {} } } })
  check("echo without recording repaired", ns.DB.debugEcho == false)
end
do -- spell label fits its column
  local c, ns = boot(); openPanel(c)
  local found
  for _, fs in ipairs(ns.settingsPanel.fontstrings) do
    if tostring(fs.text):find("^Teach a spell") then found = fs end
  end
  check("spell label width-limited", found and found.width == 250)
end

local ok = H.summary()
os.exit(ok and 0 or 1)
