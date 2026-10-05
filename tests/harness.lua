-- Mock WoW client for GrindWatch tests. boot() builds a fresh client, loads the
-- addon files in TOC order, and returns a handle for driving events and time.
local H = {}
local ADDON_DIR = assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh")

-- A secret value that behaves like the real client's: using it in arithmetic,
-- comparisons (<, >), concatenation, indexing or as a string throws. (Lua 5.1
-- can't make `==` or a truthiness test throw; tests_v3b.lua scans the source for
-- those instead.)
local SECRET = newproxy(true)
do
  local mt = getmetatable(SECRET)
  local function boom() error("secret value touched", 2) end
  for _, k in ipairs({ "__index", "__newindex", "__lt", "__le", "__add", "__sub", "__mul", "__div", "__mod",
      "__unm", "__concat", "__len", "__call" }) do mt[k] = boom end
  mt.__tostring = function() return "<secret>" end
end
H.SECRET = SECRET
local rawtype = type

local function readToc()
  local files = {}
  for line in io.lines(ADDON_DIR .. "VulcanGrindWatch.toc") do
    if line:match("%.lua%s*$") then files[#files + 1] = line:match("^%s*(.-)%s*$") end
  end
  return files
end

function H.boot(opts)
  opts = opts or {}
  local c = {
    now = 1000, wall = 1700000000,
    xp = 1000, xpMax = 5000, level = 20, maxLevel = 60, money = 50000,
    afk = false, dead = false, inGroup = false, inRaid = false, combat = false,
    zone = "Westfall", name = "Tavlius", rested = nil,
    printed = {}, sent = {}, addonSent = {}, frames = {}, items = {}, cached = {},
    loot = {}, secret = {}, loadRequests = {},
  }
  local function sec(key, v) if c.secret[key] then return SECRET end return v end
  c.SECRET = SECRET
  -- A reload continues the wall clock from where the saved session left off.
  local savedSession = opts.saved and opts.saved.char and opts.saved.char.session
  if savedSession and (savedSession.lastSeen or 0) > 0 then c.wall = savedSession.lastSeen + (opts.gap or 1) end
  -- globals that persist across "reloads" are passed in opts.saved
  _G.VulcanGrindWatchDB = opts.saved and opts.saved.db or nil
  _G.VulcanGrindWatchCharDB = opts.saved and opts.saved.char or nil

  -- (the string "SECRET" is also treated as secret, for event-argument tests)
  _G.issecretvalue = opts.secretAware and function(v) return rawequal(v, SECRET) or v == "SECRET" end or nil
  -- Real secrets keep their Lua type (a secret number is still a "number"), so
  -- type() checks don't filter them. c.secretType sets what type() reports.
  if opts.secretAware then
    _G.type = function(v)
      if rawequal(v, SECRET) then return c.secretType or "userdata" end
      return rawtype(v)
    end
  else
    _G.type = rawtype
  end
  _G.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    c.printed[#c.printed + 1] = table.concat(t, " ")
  end
  _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  _G.GetTime = function() return c.now end
  _G.time = function() return c.wall end
  _G.date = function(fmt, t) return os.date("!" .. fmt, t) end
  _G.UnitXP = function() return sec("xp", c.xp) end
  _G.UnitXPMax = function() return sec("xpMax", c.xpMax) end
  _G.UnitLevel = function() return sec("level", c.level) end
  _G.GetMaxPlayerLevel = function() return c.maxLevel end
  _G.GetXPExhaustion = function() return sec("rested", c.rested) end
  -- Independent of UnitLevel/GetMaxPlayerLevel so each max-level signal is tested on its own.
  _G.IsPlayerAtEffectiveMaxLevel = opts.noEffectiveMax and nil or function() return c.effectiveMax and true or false end
  _G.IsXPUserDisabled = function() return c.xpDisabled end
  _G.GetMoney = function() return sec("money", c.money) end
  _G.UnitIsAFK = function() return c.afk end
  _G.UnitIsDeadOrGhost = function() return sec("dead", c.dead) end
  c.units = {}  -- c.units.target = { guid =, name =, dead = }
  _G.UnitGUID = function(u) return c.units[u] and sec("guid", c.units[u].guid) or nil end
  _G.UnitIsDead = function(u)
    if not c.units[u] then return nil end
    return sec("dead", c.units[u].dead)
  end
  _G.UnitName = function(u)
    if u and u ~= "player" then return c.units[u] and c.units[u].name or nil end
    return c.name
  end
  _G.IsInGroup = function() return c.inGroup end
  _G.IsInRaid = function() return c.inRaid end
  _G.InCombatLockdown = function() return c.combat end
  _G.UnitAffectingCombat = function() return sec("combat", c.combat) end
  _G.GetRealZoneText = function() return c.zone end
  _G.Ambiguate = function(n) return (n:match("^[^%-]+")) end
  local L = opts.locale or {}
  _G.LOOT_ITEM_SELF = L.single or "You receive loot: %s."
  _G.LOOT_ITEM_SELF_MULTIPLE = L.multiple or "You receive loot: %sx%d."
  _G.COMBATLOG_XPGAIN_FIRSTPERSON = L.xp or "%s dies, you gain %d experience."
  _G.C_Item = {
    GetItemInfo = function(x)
      local id = rawtype(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)"))
      if not c.cached[id] then return nil end
      local it = c.items[id]
      return it[1], nil, nil, nil, nil, nil, nil, nil, nil, nil, it[2]
    end,
    RequestLoadItemDataByID = function(id) c.loadRequests[#c.loadRequests + 1] = id end,
  }
  _G.GetItemInfo = nil
  -- Spell names: a retail-style rank ID (e.g. 194174) shares the "Skinning" name.
  local spellNames = { [8613] = "Skinning", [194174] = "Skinning", [921] = "Pick Pocket", [116] = "Frostbolt",
    [2366] = "Herb Gathering", [2575] = "Mining", [265819] = "Herb Gathering" }
  _G.C_Spell = { GetSpellName = function(id) return spellNames[id] end }
  _G.C_ChatInfo = {
    SendChatMessage = function(msg, ch, _, target)
      if c.chatFails then error("chat blocked") end
      c.sent[#c.sent + 1] = { msg = msg, ch = ch, target = target }
    end,
    SendAddonMessage = function(prefix, msg, ch)
      if c.addonResult and c.addonResult ~= 0 then return c.addonResult end  -- e.g. throttled
      c.addonSent[#c.addonSent + 1] = { prefix = prefix, msg = msg, ch = ch }
      if c.oldClientSend then return nil end  -- older clients return nothing on success
      return 0
    end,
    RegisterAddonMessagePrefix = function()
      if opts.prefixReturnsNil then return nil end  -- older clients return nothing
      return opts.prefixResult or 0
    end,
  }
  _G.GetNumLootItems = function() return #c.loot end
  _G.GetLootSourceInfo = function(slot) return unpack(c.loot[slot]) end
  _G.Enum = { PlayerInteractionType = { Merchant = 5, MailInfo = 17, TradePartner = 1 } }
  _G.Auctionator = opts.auctionator and {
    API = { v1 = { GetAuctionPriceByItemID = function(_, id)
      if opts.auctionatorThrows then error("Auctionator internal error") end
      return opts.auctionator[id]
    end } },
  } or nil
  _G.BackdropTemplateMixin = {}
  _G.GetBuildInfo = function() return "1.60.1", "69893", "Sep 2026", 16001 end
  -- Saved-data safety (Persist.lua): realm for the character key, and a UI reload
  -- that only records it was asked for (tests reboot with c.saved() to follow it).
  c.realm = opts.realm or "Emberfall"
  _G.GetRealmName = function() return c.realm end
  _G.ReloadUI = function() c.reloads = (c.reloads or 0) + 1 end
  c.sounds, c.errorsFrame = {}, {}
  _G.SOUNDKIT = { RAID_WARNING = 8959, IG_MAINMENU_OPTION_CHECKBOX_ON = 856, IG_MAINMENU_OPTION_CHECKBOX_OFF = 857,
    IG_MAINMENU_OPTION = 852, U_CHAT_SCROLL_BUTTON = 1115 }
  -- c.sounds: alert sounds only; c.uiSounds: clicks (so alert counts stay exact)
  c.uiSounds = {}
  _G.PlaySound = function(id)
    if id == 8959 then c.sounds[#c.sounds + 1] = id else c.uiSounds[#c.uiSounds + 1] = id end
  end
  _G.UIErrorsFrame = { AddMessage = function(_, msg) c.errorsFrame[#c.errorsFrame + 1] = msg end }
  _G.ChatFontNormal = {}
  _G.UISpecialFrames = {}
  _G.UIParent = {}
  _G.SlashCmdList = {}
  _G.VulcanGrindWatch_OnAddonCompartmentClick = nil
  _G.VulcanGrindWatch_OnAddonCompartmentEnter = nil
  _G.VulcanGrindWatch_OnAddonCompartmentLeave = nil
  _G.GameTooltip_SetDefaultAnchor = function(tt) tt.defaultAnchored = true end
  c.tooltip = {}
  _G.GameTooltip = {
    SetOwner = function() c.tooltip = {} end,
    AddLine = function(_, t, _, _, _, wrap)
      c.tooltip[#c.tooltip + 1] = t
      c.tooltipWrap = c.tooltipWrap or {}
      c.tooltipWrap[#c.tooltip] = wrap
    end,
    Show = function() c.tooltip.shown = true end,
    Hide = function() c.tooltip.shown = false end,
  }

  local function newFS()
    local fs = { shown = true, text = "" }
    function fs:SetPoint(...) self.point = { ... } end
    function fs:ClearAllPoints() end
    function fs:SetText(t) self.text = t end
    function fs:GetText() return self.text end
    function fs:SetJustifyH(j) self.justifyH = j end
    function fs:SetJustifyV() end
    function fs:SetWidth(w) self.width = w end
    function fs:SetHeight(v) self.height = v end
    function fs:SetMaxLines(n) self.maxLines = n end
    function fs:SetTextColor(r, g, b) self.color = { r, g, b } end
    function fs:Show() self.shown = true end
    function fs:Hide() self.shown = false end
    function fs:SetShown(v) self.shown = v and true or false end
    function fs:GetStringWidth()
      return #(tostring(self.text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) * 6
    end
    return fs
  end
  -- Blizzard Settings (Options > AddOns) registration, when opts.blizzSettings.
  c.categories = {}
  _G.Settings = opts.blizzSettings and {
    RegisterCanvasLayoutCategory = function(frame, name) return { frame = frame, name = name } end,
    RegisterAddOnCategory = function(cat)
      if opts.blizzSettings == "throws" then error("settings API changed") end
      c.categories[#c.categories + 1] = cat
    end,
  } or nil
  _G.GetFileIDFromPath = opts.fileIDs and function(p) return opts.fileIDs[p] end or nil
  c.textures = {}
  local function newTexture()
    local t = {}
    setmetatable(t, { __index = function() return function() end end })
    function t:SetTexture(path) rawset(self, "path", path) end
    function t:SetTexCoord(...) rawset(self, "texCoord", { ... }) end
    function t:SetAllPoints() rawset(self, "allPoints", true) end
    c.textures[#c.textures + 1] = t
    return t
  end
  _G.CreateFrame = function(ftype, name, parent, template)
    if opts.noTemplates and template and template ~= "BackdropTemplate" then
      error("Couldn't find inherited node '" .. template .. "'")
    end
    -- silentTemplates: like a client that logs the missing template and returns a bare frame
    local bare = opts.silentTemplates and template and template ~= "BackdropTemplate"
    local f = { scripts = {}, events = {}, shown = true, fontstrings = {}, w = 0, h = 0, scale = 1,
      ftype = ftype, template = template, parent = parent, enabled = true, checked = false, value = 0,
      minV = 0, maxV = 0, alpha = 1, frameName = name }
    setmetatable(f, { __index = function() return function() end end })
    if bare then rawset(f, "Left", false) end
    function f:SetNormalTexture(t) rawset(self, "normalTexture", t) end
    function f:GetNormalTexture() return rawget(self, "normalTexture") end
    function f:SetCheckedTexture(t) rawset(self, "checkedTexture", t) end
    function f:EnableMouse(v) rawset(self, "mouseEnabled", v and true or false) end
    function f:IsMouseEnabled() return rawget(self, "mouseEnabled") ~= false end
    function f:SetUserPlaced(v) rawset(self, "userPlaced", v and true or false) end
    function f:SetFrameStrata(st) rawset(self, "strata", st) end
    function f:SetNormalFontObject(font) rawset(self, "normalFont", font) end
    function f:SetValueStep(step) rawset(self, "valueStep", step) end
    -- Widget wiring the tests check (the real client needs these to be usable).
    for _, m in ipairs({ "SetToplevel", "SetClampedToScreen", "SetMovable", "SetThumbTexture", "SetObeyStepOnDrag",
        "SetAutoFocus", "SetNumeric", "SetMaxLetters", "SetOrientation", "SetHitRectInsets",
        "SetMotionScriptsWhileDisabled", "SetMultiLine", "SetScrollChild" }) do
      f[m] = function(self, v, ...)
        local extra = select("#", ...) > 0 and { v, ... } or v
        rawset(self, m, extra)
      end
    end
    function f:RegisterForDrag(...) rawset(self, "dragButtons", { ... }) end
    function f:RegisterForClicks(...) rawset(self, "clickButtons", { ... }) end
    function f:StartMoving() rawset(self, "moving", true) end
    function f:StopMovingOrSizing() rawset(self, "moving", false) end
    function f:ClearFocus() rawset(self, "focusCleared", (rawget(self, "focusCleared") or 0) + 1) end
    function f:RegisterEvent(e)
      if c.unknownEvents and c.unknownEvents[e] then error("unknown event " .. e) end
      self.events[e] = true
    end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:GetName() return rawget(self, "frameName") end
    function f:CreateTexture() return newTexture() end
    function f:IsMouseOver() return rawget(self, "mouseOver") and true or false end
    function f:SetAlpha(a) self.alpha = a end
    function f:Enable() self.enabled = true end
    function f:Disable() self.enabled = false end
    function f:IsEnabled() return self.enabled end
    function f:SetChecked(v) self.checked = v and true or false end
    function f:GetChecked() return self.checked end
    function f:SetMinMaxValues(lo, hi) self.minV, self.maxV = lo, hi end
    function f:GetMinMaxValues() return self.minV, self.maxV end
    -- Like the real client: clamps, and fires OnValueChanged only on a change.
    function f:SetValue(v)
      v = math.max(self.minV, math.min(self.maxV, v))
      -- opts.sliderSnaps: a client whose sliders snap set values to their step
      local step = rawget(self, "valueStep")
      if opts.sliderSnaps and step then v = self.minV + math.floor((v - self.minV) / step + 0.5) * step end
      if v == self.value then return end
      self.value = v
      if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v, false) end
    end
    function f:GetValue() return self.value end
    function f:GetBottom() return rawget(self, "bottom") end
    function f:GetEffectiveScale() return rawget(self, "effScale") or 1 end
    function f:GetSize() return self.w, self.h end
    function f:SetScript(n, fn) self.scripts[n] = fn end
    function f:CreateFontString(_, _, font)
      local fs = newFS()
      fs.font = font
      table.insert(self.fontstrings, fs)
      return fs
    end
    -- Like the client: OnShow/OnHide fire only when the state actually changes.
    function f:Show()
      if self.shown then return end
      self.shown = true
      if self.scripts.OnShow then self.scripts.OnShow(self) end
    end
    function f:Hide()
      if not self.shown then return end
      self.shown = false
      if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function f:SetShown(v) if v then self:Show() else self:Hide() end end
    function f:IsShown() return self.shown end
    function f:SetBackdropColor(r, g, b, a) rawset(self, "bgColor", { r, g, b, a }) end
    function f:SetBackdropBorderColor(r, g, b, a) rawset(self, "borderColor", { r, g, b, a }) end
    function f:SetWidth(w) self.w = w end
    function f:SetHeight(v) self.h = v end
    function f:SetSize(w, h) self.w, self.h = w, h; self.sizeCalls = (rawget(self, "sizeCalls") or 0) + 1 end
    function f:SetText(t)
      -- A plain EditBox or Button has no font until one is set, and the client errors.
      local plain = not template or bare
      if ftype == "EditBox" and plain and not rawget(self, "font") then error("Font not set") end
      if ftype == "Button" and plain and not rawget(self, "normalFont") then error("Font not set") end
      rawset(self, "text", t)
    end
    function f:SetFontObject(font) rawset(self, "font", font) end
    function f:Raise() c.raiseCount = (c.raiseCount or 0) + 1; rawset(self, "raisedAt", c.raiseCount) end
    function f:GetText() return rawget(self, "text") end
    function f:SetScale(s) self.scale = s end
    function f:GetPoint() return "TOP", nil, "TOP", 10, -20 end
    function f:SetPoint(...) rawset(self, "lastPoint", { ... }) end
    c.frames[#c.frames + 1] = f
    if name then _G[name] = f end
    return f
  end
  local ticker
  c.timers = {}
  _G.C_Timer = {
    NewTicker = function(_, fn) ticker = fn end,
    After = function(d, fn) c.timers[#c.timers + 1] = { at = c.now + d, fn = fn } end,
  }
  c.unknownEvents = opts.unknownEvents

  local ns = {}
  for _, file in ipairs(readToc()) do
    local chunk = assert(loadfile(ADDON_DIR .. file))
    chunk("VulcanGrindWatch", ns)
  end
  c.ns = ns
  c.eventFrame = c.frames[1]
  c.ui = _G.VulcanGrindWatchFrame

  function c.fire(event, ...)
    c.eventFrame.scripts.OnEvent(c.eventFrame, event, ...)
  end
  function c.tick(n, step)
    for _ = 1, n or 1 do
      c.now = c.now + (step or 1)
      c.wall = c.wall + (step or 1)
      ticker()
      local due = {}
      for i = #c.timers, 1, -1 do
        if c.timers[i].at <= c.now then due[#due + 1] = table.remove(c.timers, i) end
      end
      for i = #due, 1, -1 do due[i].fn() end
    end
  end
  -- A user click: disabled widgets ignore it; check buttons toggle first, like the client.
  function c.click(w, button)
    if not w.enabled then return false end
    if w.ftype == "CheckButton" then w.checked = not w.checked end
    if w.scripts.OnClick then w.scripts.OnClick(w, button or "LeftButton", true) end
    return true
  end
  -- A user drag to value v (the client fires OnValueChanged with userInput = true).
  -- A mouse drag through several values: button down, the moves, button up.
  -- between(i) runs after each move (e.g. to let the clock tick mid-drag).
  function c.drag(w, values, between)
    if not w.enabled then return false end
    if w.scripts.OnMouseDown then w.scripts.OnMouseDown(w, "LeftButton") end
    for i, v in ipairs(values) do
      v = math.max(w.minV, math.min(w.maxV, v))
      if v ~= w.value then
        w.value = v
        w.scripts.OnValueChanged(w, v, true)
      end
      if between then between(i) end
    end
    if w.scripts.OnMouseUp then w.scripts.OnMouseUp(w, "LeftButton") end
    return true
  end
  function c.slide(w, v)
    if not w.enabled then return false end
    v = math.max(w.minV, math.min(w.maxV, v))
    if v == w.value then return true end
    w.value = v
    w.scripts.OnValueChanged(w, v, true)
    return true
  end
  function c.slash(s) _G.SlashCmdList.VULCANGRINDWATCH(s) end
  function c.printedMatch(pat)
    for _, p in ipairs(c.printed) do if p:find(pat) then return p end end
    return nil
  end
  function c.login()
    c.fire("ADDON_LOADED", "VulcanGrindWatch")
    c.fire("PLAYER_LOGIN")
    c.fire("PLAYER_ENTERING_WORLD")
    ticker()
  end
  function c.item(id, name, price, cached)
    c.items[id] = { name, price }
    c.cached[id] = cached ~= false
  end
  function c.lootMsg(id, name, qty)
    local link = string.format("|cffffffff|Hitem:%d::::::::20:::::|h[%s]|h|r", id, name)
    c.fire("CHAT_MSG_LOOT", qty and qty > 1 and ("You receive loot: " .. link .. "x" .. qty .. ".")
      or ("You receive loot: " .. link .. "."))
  end
  function c.xpKill(mob, xp)
    c.fire("CHAT_MSG_COMBAT_XP_GAIN", string.format("%s dies, you gain %d experience.", mob, xp))
    c.xp = c.xp + xp
    c.fire("PLAYER_XP_UPDATE", "player")
  end
  -- Kill a mob you had targeted: seen alive, then it dies and the XP line arrives.
  function c.killTargeted(guid, name, xp)
    c.units.target = { guid = guid, name = name, dead = false }
    c.fire("PLAYER_TARGET_CHANGED")
    c.units.target.dead = true
    c.xpKill(name, xp or 100)
  end
  function c.gainMoney(n) c.money = c.money + n c.fire("PLAYER_MONEY") end
  -- A whole loot window: opens, then closes (unless keepOpen).
  function c.corpse(guid, keepOpen)
    c.loot = { { guid, 1 } }
    c.fire("LOOT_OPENED")
    if not keepOpen then c.fire("LOOT_CLOSED") end
  end
  local castN = 0
  function c.cast(spellID)
    castN = castN + 1
    c.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-" .. castN, spellID)
  end
  -- Logging out fires PLAYER_LOGOUT before SavedVariables are written.
  function c.saved()
    c.fire("PLAYER_LOGOUT")
    return { db = _G.VulcanGrindWatchDB, char = _G.VulcanGrindWatchCharDB }
  end
  function c.errors()
    local out = {}
    for _, p in ipairs(c.printed) do if p:find("error in") then out[#out + 1] = p end end
    return out
  end
  function c.cellText()
    local out = {}
    for _, fs in ipairs(c.ui.fontstrings) do
      if fs.shown then out[#out + 1] = (tostring(fs.text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    end
    return table.concat(out, " | ")
  end
  return c
end

local passed, failed = 0, 0
function H.check(name, cond, detail)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("FAIL " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or "") .. "\n")
  end
end
function H.summary()
  io.write(string.format("%d passed, %d failed\n", passed, failed))
  return failed == 0
end
return H
