-- GrindWatch 3.1: tests for the gaps found by the second round of mutation
-- testing (settings code). Check names start with the mutant id.
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

local function openPanel(c)
  c.slash("settings")
  return c.ns.settingControls
end

local function button(c, text)
  for _, f in ipairs(c.frames) do if rawget(f, "text") == text then return f end end
end

local function printedSince(c, n, pat)
  for i = n + 1, #c.printed do if c.printed[i]:find(pat) then return c.printed[i] end end
end

-- Farm `minutes` minutes, one pull and `copper` coin per minute.
local function farm(c, minutes, copper)
  for _ = 1, minutes do
    c.fire("PLAYER_REGEN_DISABLED")
    c.gainMoney(copper)
    c.tick(60)
  end
end

-- Frames created from now on record calls the mock client ignores: hit rects,
-- position saving, button fonts, focus, and where font strings are anchored.
local function spyFrames()
  local orig = _G.CreateFrame
  _G.CreateFrame = function(...)
    local f = orig(...)
    rawset(f, "SetHitRectInsets", function(self, l, r, t, b) rawset(self, "hitRect", { l, r, t, b }) end)
    rawset(f, "SetDontSavePosition", function(self, v) rawset(self, "dontSave", v) end)
    rawset(f, "SetHighlightFontObject", function(self, v) rawset(self, "highlightFont", v) end)
    rawset(f, "SetDisabledFontObject", function(self, v) rawset(self, "disabledFont", v) end)
    rawset(f, "ClearFocus", function(self) rawset(self, "blurs", (rawget(self, "blurs") or 0) + 1) end)
    local createFS = f.CreateFontString
    rawset(f, "CreateFontString", function(self, ...)
      local fs = createFS(self, ...)
      fs.SetPoint = function(s, ...) s.point = { ... } end
      return fs
    end)
    return f
  end
end

---------------------------------------------------------------------------
-- Settings.lua
---------------------------------------------------------------------------
do
  local _, ns = boot()
  local function text(key, v) return ns.SettingText(ns.SettingDef(key), v) end
  check("V11 zone hint 0 reads as off, 1 as a minute", text("zoneHintMinutes", 0) == "off"
    and text("zoneHintMinutes", 1) == "1 min", text("zoneHintMinutes", 1))
  check("V14 recent window shows minutes", text("windowMinutes", 10) == "10 min", text("windowMinutes", 10))
  check("V17 alert cooldown shows minutes", text("alertCooldownMinutes", 15) == "15 min", text("alertCooldownMinutes", 15))
  ns.SetSetting("windowMinutes", 30)
  check("V19 judge-after waits for the configured window", text("alertMinMinutes", 20) == "20 min (waits 30)",
    text("alertMinMinutes", 20))
end
do
  -- V05: going back up from the smallest scale keeps the window in place
  local c, ns = boot()
  c.slash("scale 0.5")
  ns.DB.point = { "CENTER", "CENTER", 100, 50 }
  c.slash("scale 1")
  check("V05 from scale 0.5 the offsets are rescaled", ns.DB.point[3] == 50 and ns.DB.point[4] == 25,
    ns.DB.point[3] .. "," .. ns.DB.point[4])
end
do
  -- percentage input
  local c, ns = boot()
  c.slash("set bgAlpha 2")
  check("V22 opacity 2 means 2%", ns.DB.bgAlpha == 0.02, ns.DB.bgAlpha)
  c.slash("set bgAlpha 1%")
  check("V24 an explicit 1% is 1%, not 100%", ns.DB.bgAlpha == 0.01, ns.DB.bgAlpha)
  c.slash("set alertPercent 50%")
  check("V25 '50%' for a whole-percent setting is 50", ns.DB.alertPercent == 50, ns.DB.alertPercent)
  noErrors(c, "percent input")
end
do
  -- V33: an out-of-range saved number is clamped AND reported
  local c, ns = boot({ saved = { db = { idleMinutes = 999, history = {} } } })
  local msg = c.printedMatch("were invalid and were repaired")
  check("V33 clamped value is reported", ns.DB.idleMinutes == 60 and msg and msg:find("idleMinutes"), msg)
end

---------------------------------------------------------------------------
-- SettingsUI.lua: templates and fallbacks
---------------------------------------------------------------------------
do
  -- W02: a templated edit box isn't restyled as a bare one
  local c, ns = boot()
  openPanel(c)
  check("W02 templated spell box keeps its template look", rawget(ns.spellBox, "bgColor") == nil)
end
do
  -- W04/W05/W13: fallback styling on a client without the templates
  local c = boot({ noTemplates = true })
  spyFrames()
  openPanel(c)
  local styled, complete = 0, 0
  for _, f in ipairs(c.frames) do
    if f.ftype == "Button" and rawget(f, "normalFont") then
      styled = styled + 1
      if rawget(f, "highlightFont") and rawget(f, "disabledFont") then complete = complete + 1 end
    end
  end
  check("W04 fallback buttons get highlight and disabled fonts", styled >= 9 and complete == styled,
    complete .. "/" .. styled)
  local defaults = button(c, "Defaults")
  check("W05 fallback buttons get a backdrop", rawget(defaults, "bgColor") and defaults.bgColor[4] == 0.8)
  local close
  for _, f in ipairs(c.frames) do
    local t = rawget(f, "normalTexture")
    if type(t) == "string" and t:find("UI%-Panel%-MinimizeButton%-Up") then close = f end
  end
  check("W13 fallback close button has the X icon", close ~= nil)
  noErrors(c, "fallback styling")
end
do
  -- W14: the X closes the window
  local c, ns = boot()
  openPanel(c)
  local close
  for _, f in ipairs(c.frames) do if f.template == "UIPanelCloseButton" then close = f end end
  c.click(close)
  check("W14 close button hides the window", not ns.settingsPanel.shown)
end

---------------------------------------------------------------------------
-- SettingsUI.lua: -/+ buttons and greying
---------------------------------------------------------------------------
do
  local c, ns = boot()
  local ctl = openPanel(c)
  c.slide(ctl.scale.widget, 0.5)
  check("W06 - greyed at min", ns.DB.scale == 0.5 and not ctl.scale.minus.enabled and ctl.scale.minus.alpha < 1
    and ctl.scale.plus.enabled)
  check("W06 - at min ignores clicks", not c.click(ctl.scale.minus) and ns.DB.scale == 0.5)
  c.click(ctl.alerts.widget)  -- alerts off
  local cd = ctl.alertCooldownMinutes
  check("W07 greyed slider's - is off too", not cd.minus.enabled and cd.minus.alpha < 1)
  c.click(ctl.alerts.widget)  -- back on
  check("W11 value text colour restored when re-enabled", cd.valueText.color[1] == 1 and cd.valueText.color[2] == 0.82,
    cd.valueText.color[1])
  check("W07 - usable again", cd.minus.enabled and cd.widget.alpha == 1)
  noErrors(c, "step buttons")
end

---------------------------------------------------------------------------
-- SettingsUI.lua: refresh errors and the spell list
---------------------------------------------------------------------------
do
  -- W17: a failing extra (spell list) is reported, not silently swallowed
  local c, ns = boot()
  ns.DB.customSpells.junk = "gather"  -- can't be formatted as a spell ID
  local ctl = openPanel(c)
  check("W17 spell-list failure reported", c.printedMatch("error in settings window:"))
  check("W17 rest of the window still works", ns.settingsPanel.shown and ctl.locked.widget.checked == false)
  ns.DB.customSpells.junk = nil
end
do
  local c, ns = boot()
  openPanel(c)
  check("W22 empty list says none", ns.spellListText.text == "Added: none", ns.spellListText.text)
  ns.spellBox:SetText("12345")
  c.click(button(c, "Gather"))
  check("W20/W21 unknown spell: ID, ? and its kind", ns.spellListText.text == "Added: 12345 ? (gather)",
    ns.spellListText.text)
  ns.spellBox:SetText("8613")
  c.click(button(c, "Pickpocket"))
  check("W40 Pickpocket button teaches pickpocket", ns.DB.customSpells[8613] == "pickpocket")
  check("W20 known spell: name and kind", ns.spellListText.text:find("8613 Skinning %(pickpocket%)"),
    ns.spellListText.text)
  ns.DB.customSpells[1], ns.DB.customSpells[2] = "gather", "gather"
  c.slash("settings"); c.slash("settings")  -- close and reopen
  check("W19 exactly at the cap: no '+0 more'", not ns.spellListText.text:find("more"), ns.spellListText.text)
  noErrors(c, "spell list")
end

---------------------------------------------------------------------------
-- SettingsUI.lua: the spell box and focus
---------------------------------------------------------------------------
do
  local c, ns = boot()
  spyFrames()
  openPanel(c)
  local box = ns.spellBox
  local n = #c.printed
  box:SetText("")
  box.scripts.OnEnterPressed(box)
  check("W23 Enter on an empty box says nothing", not printedSince(c, n, "now click"))
  local blurs = rawget(box, "blurs") or 0
  box:SetText("123")
  box.scripts.OnEnterPressed(box)
  check("W24 Enter releases the keyboard", (rawget(box, "blurs") or 0) > blurs)
  blurs = rawget(box, "blurs") or 0
  c.click(button(c, "Gather"))
  check("W48 teaching releases the keyboard", ns.DB.customSpells[123] == "gather" and (rawget(box, "blurs") or 0) > blurs)
  blurs = rawget(box, "blurs") or 0
  ns.settingsPanel:Hide()
  check("W42 closing the window releases the keyboard", (rawget(box, "blurs") or 0) > blurs)
end

---------------------------------------------------------------------------
-- SettingsUI.lua: position saving, hit rects, layout
---------------------------------------------------------------------------
do
  local c, ns = boot()
  spyFrames()
  local ctl = openPanel(c)
  check("W25 settings window position not saved by the game", rawget(ns.settingsPanel, "dontSave") == true)
  local cb = ctl.locked
  local hr = rawget(cb.widget, "hitRect")
  check("W28 checkbox label is clickable", hr and hr[2] == -(cb.label:GetStringWidth() + 4), hr and hr[2])
  local rb = ctl.priceSource.radios[2]
  hr = rawget(rb.widget, "hitRect")
  check("W29 radio label is clickable", hr and hr[2] == -(rb.label:GetStringWidth() + 4), hr and hr[2])

  -- Layout: nothing in the window overlaps anything else.
  local items = {}
  local function add(name, x, top, w, h) items[#items + 1] = { name = name, x = x, top = top, w = w, h = h } end
  local panel = ns.settingsPanel
  for _, fs in ipairs(panel.fontstrings) do
    local p = rawget(fs, "point")
    local h = fs.height or 12
    local w = fs.width or fs:GetStringWidth()
    if p and p[1] == "TOPLEFT" and type(p[2]) == "number" then
      add("text '" .. tostring(fs.text) .. "'", p[2], p[3], w, h)
    elseif p and p[1] == "TOPRIGHT" and p[2] == panel then  -- slider value text
      add("value '" .. tostring(fs.text) .. "'", p[4] - w, p[5], w, h)
    elseif p and p[1] == "LEFT" and type(p[2]) == "table" and rawget(p[2], "lastPoint") then  -- checkbox label
      local f = p[2]
      local fp = rawget(f, "lastPoint")
      add("label '" .. tostring(fs.text) .. "'", fp[2] + f.w + p[4], fp[3] - (f.h - h) / 2, w, h)
    end
  end
  for _, f in ipairs(c.frames) do
    local p = rawget(f, "lastPoint")
    if f.parent == panel and p and p[1] == "TOPLEFT" and type(p[2]) == "number" then
      add(f.ftype .. " '" .. tostring(rawget(f, "text") or "") .. "'", p[2], p[3], f.w, f.h)
    end
  end
  local overlap
  for i = 1, #items do
    for j = i + 1, #items do
      local a, b = items[i], items[j]
      if a.x < b.x + b.w and b.x < a.x + a.w and a.top > b.top - b.h and b.top > a.top - a.h then
        overlap = a.name .. " / " .. b.name
      end
    end
  end
  check("W31-W34 nothing in the settings window overlaps", #items > 40 and overlap == nil, overlap or #items)
end
do
  -- X04: main window too (it's created at load, so spy on CreateFrame as it's defined)
  rawset(_G, "CreateFrame", nil)
  setmetatable(_G, { __newindex = function(t, k, v)
    if k == "CreateFrame" and type(v) == "function" then
      local create = v
      v = function(...)
        local f = create(...)
        rawset(f, "SetDontSavePosition", function(self, on) rawset(self, "dontSave", on) end)
        return f
      end
    end
    rawset(t, k, v)
  end })
  local c = H.boot()
  setmetatable(_G, nil)
  c.login()
  check("X04 main window position not saved by the game", rawget(c.ui, "dontSave") == true)
end

---------------------------------------------------------------------------
-- SettingsUI.lua: tooltips and buttons
---------------------------------------------------------------------------
do
  local c, ns = boot()
  local ctl = openPanel(c)
  ctl.alertPercent.widget.scripts.OnEnter(ctl.alertPercent.widget)
  check("W35 slider tooltip title shows the value", c.tooltip[1] == "Alert below: 60% of session", c.tooltip[1])
  ctl.alertSound.widget.scripts.OnEnter(ctl.alertSound.widget)
  local tip = table.concat(c.tooltip, "\n")
  check("W36 no 'turn on' warning while alerts are on", not tip:find("Turn on") and tip:find("Default: on"), tip)
  local resetPos = button(c, "Reset position")
  resetPos.scripts.OnEnter(resetPos)
  check("W37 button tooltip has its explanation", c.tooltip[1] == "Reset position"
    and tostring(c.tooltip[2]):find("Moves the window back"), c.tooltip[2])
  ns.DB.point = { "TOPLEFT", "BOTTOMLEFT", 5, 5 }
  local n = #c.printed
  c.click(resetPos)
  check("W38 reset position restores both anchors", ns.DB.point[1] == "CENTER" and ns.DB.point[2] == "CENTER",
    ns.DB.point[2])
  check("W39 reset position says so", printedSince(c, n, "moved back to its starting spot"))
  noErrors(c, "tooltips")
end
do
  -- W43: opening settings before login does nothing (and doesn't throw)
  local c = H.boot()
  local ok, err = pcall(c.ns.OpenSettings)
  check("W43 settings before login: no-op", ok and c.ns.settingsPanel == nil, err)
  c.login()
  openPanel(c)
  check("W43 and opens normally after login", c.ns.settingsPanel and c.ns.settingsPanel.shown)
end

---------------------------------------------------------------------------
-- Core.lua: the data floor for pre-3.1 sessions
---------------------------------------------------------------------------
do
  -- C24: a 3.1 session (which keeps 30 minutes) isn't floored on reload
  local c0 = H.boot()
  c0.login()
  c0.slash("set windowMinutes 30")
  farm(c0, 25, 10000)
  farm(c0, 15, 0)
  local before = c0.ns.RecentRate({ "c" })
  local c = H.boot({ saved = c0.saved() })
  c.login()
  check("C24 reload keeps a 3.1 session's floor", c.ns.S.minBucket == 0, c.ns.S.minBucket)
  local after = c.ns.RecentRate({ "c" })
  check("C24 and its 30 min recent rate", before and after and math.abs(after - before) < 1,
    tostring(before) .. " vs " .. tostring(after))
end
do
  -- C25: a saved session without an elapsed time loads cleanly
  local c, ns = boot({ saved = { char = { session = { buckets = {} } } } })
  check("C25 session without elapsed loads", ns.S and ns.S.minBucket == 0 and ns.S.elapsed == 0)
  noErrors(c, "session without elapsed")
end

---------------------------------------------------------------------------
-- Sync.lua: the partner's window is accepted from 1 to 1440 minutes
---------------------------------------------------------------------------
do
  local c, ns = boot()
  c.inGroup = true
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|1", "PARTY", "One")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|1440", "PARTY", "Day")
  c.fire("CHAT_MSG_ADDON", "VulcanGrindWatch", "4|7200|10|0|200000|160000|500000|120000|90000|200000|1441", "PARTY", "Over")
  check("Z01 a 1 min window is understood", ns.partners.One and ns.partners.One.window == 1)
  check("Z02/Z03 a 1440 min window is understood", ns.partners.Day and ns.partners.Day.window == 1440)
  check("Z02/Z03 over 1440 is unknown", ns.partners.Over and ns.partners.Over.window == nil)
  noErrors(c, "window range")
end

---------------------------------------------------------------------------
-- Commands.lua
---------------------------------------------------------------------------
do
  local c = boot()
  c.slash("help")
  check("K22 help mentions /gw defaults", c.printedMatch("/gw defaults"))
end

---------------------------------------------------------------------------
-- Ninth review (mutation gaps; names start with the mutant id)
---------------------------------------------------------------------------
do -- A35
  local c = boot(); local n = #c.printed
  local ok1, e1 = pcall(c.slash, "idle 5"); local ok2, e2 = pcall(c.slash, "scale 1")
  check("A35 /gw idle <current> answers normally", ok1 and printedSince(c, n, "clock stops after 5 min"), e1)
  check("A35 /gw scale <current> answers normally", ok2 and printedSince(c, n, "window scale set to 1%."), e2)
end
do -- A10
  local c, ns = boot()
  for _, row in ipairs(ns.menuRows) do rawset(row, "SetWidth", function(self, w) rawset(self, "width", w) end) end
  c.click(ns.gear)
  local bad
  for i, row in ipairs(ns.menuRows) do
    local w = rawget(row, "width")
    if not w or w < row.text:GetStringWidth() or w ~= ns.menu.w - 12 then bad = i .. ":" .. tostring(w) end
  end
  check("A10 menu rows span the menu", ns.menu.shown and bad == nil, bad)
end
do -- A16
  local c, ns = boot(); c.slash("settings"); c.slash("set scale 1.5")
  local d = button(c, "Defaults"); c.click(d); c.click(d)
  check("A16 Defaults text restored after confirming", ns.DB.scale == 1 and rawget(d, "text") == "Defaults", rawget(d, "text"))
  local cl = button(c, "Clear log"); c.click(cl); c.click(cl)
  check("A16 Clear log text restored after confirming", rawget(cl, "text") == "Clear log", rawget(cl, "text"))
end
do -- A22/A23
  local c, ns = boot(); c.slash("settings")
  local r = ns.settingControls.priceSource.radios
  r[2].widget.scripts.OnEnter(r[2].widget)
  local tip = table.concat(c.tooltip, "\n")
  check("A23 AH radio tooltip titled with its choice", c.tooltip[1] == "Auction house (Auctionator)", c.tooltip[1])
  check("A22 radio tooltip gives the default", tip:find("Default: Vendor price", 1, true), tip)
end
do -- A24
  local c, ns = boot({ blizzSettings = true }); c.slash("settings")
  c.click(button(c, "Open GrindWatch settings"))
  check("A24 options button keeps an open settings window open", ns.settingsPanel.shown)
end
do -- A56
  local c = boot(); c.slash("set idleMinutes")
  check("A56 /gw set <name> includes the help text", c.printedMatch("idleMinutes is 5 min%. Stop the clock"))
end
do -- A29
  local _, ns = boot({ saved = { db = { idleMinutes = -math.huge, scale = -math.huge, history = {} } } })
  check("A29 -inf -> default", ns.DB.idleMinutes == 5 and ns.DB.scale == 1, ns.DB.idleMinutes)
end
do -- B11
  local c, ns = boot(); c.slash("lock"); c.slash("lock"); local locked = ns.DB.locked
  c.slash("unlock"); c.slash("unlock")
  check("B11 /gw lock twice stays locked, unlock twice stays unlocked", locked == true and ns.DB.locked == false)
end
do -- B10
  local c, ns = boot({ auctionator = {} }); c.slash("settings")
  local ah = ns.settingControls.priceSource.radios[2]; local col = ah.label.color
  check("B10 unselected AH label plain white", ns.DB.priceSource == "vendor" and ah.widget.enabled
    and col and col[1] == 1 and col[2] == 1 and col[3] == 1, col and table.concat(col, ","))
end
do -- chat reports never carry colour codes
  local c, ns = boot()
  c.inGroup = true
  ns.S.note = "|cffff0000red|r spot"
  c.zone = "|cff00ff00Green|r Vale"
  farm(c, 4, 1000)
  c.slash("report party")
  local coloured = false
  for _, m in ipairs(c.sent) do if m.msg:find("|c%x%x%x%x%x%x%x%x") or m.msg:find("|r") then coloured = true end end
  check("party report stripped of colour codes", #c.sent > 0 and not coloured, c.sent[1] and c.sent[1].msg)
end

---------------------------------------------------------------------------
-- Tenth review
---------------------------------------------------------------------------
do -- U27: a click or a live drag prints nothing
  local c, ns = boot(); c.slash("settings")
  local n = #c.printed
  c.drag(ns.settingControls.idleMinutes.widget, { ns.settingControls.idleMinutes.widget.value })
  c.drag(ns.settingControls.scale.widget, { 1.5 })
  check("U27 slider click/drag prints nothing", #c.printed == n and ns.DB.scale == 1.5)
end
do -- C07
  local c, ns = boot({ auctionator = {} }); c.slash("price ah")
  check("C07 /gw price ah confirms", ns.DB.priceSource == "auction" and c.printed[#c.printed]:find("loot now valued at AH price"))
end
for i, bad in ipairs({ { "CENTER", "CENTER", "x", 0 }, { "CENTER", "CENTER", 0, 0 / 0 }, { "CENTER", "CENTER", math.huge, 0 } }) do
  local _, ns = boot({ saved = { db = { panelPoint = bad } } })
  check("K03 bad panel offset dropped " .. i, ns.DB.panelPoint == nil)
end
do -- U04
  local _, ns = boot(); ns.gear.scripts.OnClick(ns.gear); ns.menu.mouseOver = false
  ns.menu.scripts.OnUpdate(ns.menu, 10)
  check("U04 menu with click-outside support doesn't time out", ns.menu.shown)
end
do -- U08
  local c, ns = boot(); c.slash("compact"); c.slash("settings")
  local a, b = ns.settingControls.compact.label.color, ns.settingControls.locked.label.color
  check("U08 changed checkbox blue", a[1] == 0.4 and a[2] == 0.8 and a[3] == 1)
  check("U08 default checkbox white", b[1] == 1 and b[2] == 1 and b[3] == 1)
end
do -- C04
  local c = boot(); c.slash("set")
  check("C04 switches listed as on/off", c.printedMatch("locked = off %(") and c.printedMatch("sync = on %("))
end
do -- S15/S16
  local c, ns = boot()
  c.slash("set compact enabled");  check("S15 enabled", ns.DB.compact == true)
  c.slash("set compact disable");  check("S16 disable", ns.DB.compact == false)
  c.slash("set compact enable");   check("S15 enable", ns.DB.compact == true)
  c.slash("set compact disabled"); check("S16 disabled", ns.DB.compact == false)
end

---------------------------------------------------------------------------
-- Systematic mutation sweep: Settings.lua
---------------------------------------------------------------------------
do -- every on/off word means what it says
  local c, ns = boot()
  for word, want in pairs({ ["true"] = true, ["false"] = false, ["1"] = true, ["0"] = false, on = true, off = false,
      yes = true, no = false }) do
    ns.DB.compact = not want
    c.slash("set compact " .. word)
    check("'" .. word .. "' sets " .. tostring(want), ns.DB.compact == want)
  end
end
do -- a consistent saved debug pair is kept
  local _, ns = boot({ saved = { db = { debug = true, debugEcho = true, history = {} } } })
  check("saved debug + echo kept", ns.DB.debug == true and ns.DB.debugEcho == true)
end
do -- the ambiguous-opacity message, in full
  local c = boot()
  c.slash("set bgAlpha 1.5")
  check("ambiguous opacity message", c.printedMatch("couldn't set bgAlpha: use 0%-1, or a percentage like 50%%%."))
end

local ok = H.summary()
os.exit(ok and 0 or 1)
