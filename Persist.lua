-- GrindWatch: saved-data safety (Vulcan Suite).
--
-- REMOVE WHEN FIXED. The World of Warcraft: Forever client has been reported to
-- write add-on saved data to disk but not load it back, and then overwrite the
-- good file at the next logout or /reload. Add-ons can't read or write files, so
-- this module does what is possible from inside the game:
--   * spots a failed load by cross-checking the account and character files
--     (each records that the other exists), and warns instead of silently
--     starting empty;
--   * makes a backup string of all saved data (/gw backup) and restores one
--     (/gw restore), with checks and a preview before anything changes.
-- (A registered CVar would make a better marker, but on client build 70205
-- registered CVars come back empty after a full restart.)
--
-- To retire it: delete this file and its line in the TOC. Core.lua, Commands.lua
-- and SettingsUI.lua only reach it through `ns.Persist` / `ns.extra*` guards.
local _, ns = ...
local P = {}
ns.Persist = P

local TAG = "VulcanGrindWatch"      -- names the add-on inside every backup string
local FORMAT = 1                    -- bump when the backup payload changes shape
local MAX_INPUT = 512 * 1024        -- longest paste worth reading
local MAX_DEPTH = 20
local OFFER_EVERY = 7 * 24 * 3600   -- offer a backup at most once a week
local MAX_CHARS = 200               -- characters remembered for the cross-check

-- Other Vulcan add-ons, so a backup pasted into the wrong one says where it goes.
local SUITE = {
  VulcanGrindWatch = "Vulcan GrindWatch", VulcanRunBook = "Vulcan RunBook",
  VulcanDuoQuest = "Vulcan DuoQuest", VulcanSimBench = "Vulcan SimBench",
}

---------------------------------------------------------------------------
-- Serializer: plain data only (tables, strings, finite numbers, booleans).
-- Reading never runs pasted text as code.
---------------------------------------------------------------------------
local function KeyOrder(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  return a < b
end

local function Write(v, out, depth)
  local t = type(v)
  if t == "string" then
    out[#out + 1] = "S" .. #v .. ":" .. v
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("a number isn't finite", 0) end
    out[#out + 1] = "N" .. string.format("%.17g", v) .. ";"
  elseif t == "boolean" then
    out[#out + 1] = v and "T" or "F"
  elseif t == "table" then
    if depth > MAX_DEPTH then error("data nested too deeply", 0) end
    out[#out + 1] = "{"
    local keys = {}
    for k in pairs(v) do
      local kt = type(k)
      if kt ~= "string" and kt ~= "number" then error("a " .. kt .. " key can't be saved", 0) end
      keys[#keys + 1] = k
    end
    table.sort(keys, KeyOrder)
    for _, k in ipairs(keys) do
      Write(k, out, depth + 1)
      Write(v[k], out, depth + 1)
    end
    out[#out + 1] = "}"
  else
    error("a " .. t .. " can't be saved", 0)
  end
end

function P.Serialize(v)
  local out = {}
  Write(v, out, 0)
  return table.concat(out)
end

-- Returns value, next position; or nil when the text is malformed.
local function Read(s, i, depth)
  local c = s:sub(i, i)
  if c == "S" then
    local len, j = s:match("^(%d+):()", i + 1)
    if not len or #len > 9 then return nil end
    local last = j + tonumber(len) - 1
    if last > #s then return nil end
    return s:sub(j, last), last + 1
  elseif c == "N" then
    local num, j = s:match("^([%d%.eE%+%-]+);()", i + 1)
    local n = num and #num <= 32 and tonumber(num)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n, j
  elseif c == "T" then
    return true, i + 1
  elseif c == "F" then
    return false, i + 1
  elseif c == "{" then
    if depth > MAX_DEPTH then return nil end
    local t = {}
    i = i + 1
    while true do
      if s:sub(i, i) == "}" then return t, i + 1 end
      local k, v
      k, i = Read(s, i, depth + 1)
      if k == nil or (type(k) ~= "string" and type(k) ~= "number") then return nil end
      v, i = Read(s, i, depth + 1)
      if v == nil then return nil end
      t[k] = v
    end
  end
  return nil
end

function P.Deserialize(s)
  local v, nextPos = Read(s, 1, 0)
  if v == nil or nextPos ~= #s + 1 then return nil end
  return v
end

---------------------------------------------------------------------------
-- Checksum and text encoding (Lua 5.1 has no bit operators: plain arithmetic)
---------------------------------------------------------------------------
function P.Adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, 64 do B64_INDEX[B64:byte(i)] = i - 1 end

function P.Base64Encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local d1, d2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
    local d3, d4 = math.floor(n / 64) % 64, n % 64
    out[#out + 1] = B64:sub(d1 + 1, d1 + 1) .. B64:sub(d2 + 1, d2 + 1)
      .. (b and B64:sub(d3 + 1, d3 + 1) or "=") .. (c and B64:sub(d4 + 1, d4 + 1) or "=")
  end
  return table.concat(out)
end

function P.Base64Decode(s)
  if #s % 4 ~= 0 then return nil end
  local pad = s:match("(=*)$")
  if #pad > 2 then return nil end
  local body = s:sub(1, #s - #pad)
  if body:find("[^%w%+/]") then return nil end
  body = body .. string.rep("A", #pad)
  local out = {}
  for i = 1, #body, 4 do
    local n = 0
    for j = 0, 3 do n = n * 64 + B64_INDEX[body:byte(i + j)] end
    out[#out + 1] = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
  end
  local raw = table.concat(out)
  return raw:sub(1, #raw - #pad)
end

---------------------------------------------------------------------------
-- Backup strings: TAG-backup:FORMAT:LENGTH:ADLER32:BASE64
---------------------------------------------------------------------------
local function CopyData(v, depth)
  if type(v) ~= "table" then return v end
  if depth > MAX_DEPTH then return nil end
  local t = {}
  for k, val in pairs(v) do
    if type(k) == "string" or type(k) == "number" then t[k] = CopyData(val, depth + 1) end
  end
  return t
end

local function CharKey()
  local name = UnitName and ns.plain(UnitName("player"))
  local realm = GetRealmName and ns.plain(GetRealmName())
  if type(name) ~= "string" or name == "" or type(realm) ~= "string" or realm == "" then return nil end
  return name .. "-" .. realm:gsub("[%s%-]", "")
end
P.CharKey = CharKey

-- Everything saved: settings and history (account), plus this character's live
-- session. The diagnostics log is left out (it's for troubleshooting only).
function P.MakeBackup()
  local db = CopyData(VulcanGrindWatchDB or {}, 0)
  db.debugLog = nil
  local payload = {
    addon = TAG, format = FORMAT, made = time(), char = CharKey() or "?",
    db = db,
    session = CopyData(type(VulcanGrindWatchCharDB) == "table" and VulcanGrindWatchCharDB.session or nil, 0),
  }
  local raw = P.Serialize(payload)
  return string.format("%s-backup:%d:%d:%08x:%s", TAG, FORMAT, #raw, P.Adler32(raw), P.Base64Encode(raw))
end

local DAMAGED = "This backup is incomplete or damaged. It's one long line: copy all of it and try again."

-- text -> payload, or nil + a message saying what's wrong. Nothing is changed.
function P.ParseBackup(text)
  if type(text) ~= "string" then return nil, "Paste a backup string first." end
  if #text > MAX_INPUT then return nil, "That's far longer than any GrindWatch backup." end
  local s = text:gsub("%s+", "")
  if s == "" then return nil, "Paste a backup string first." end
  local tag = s:match("^(%a+)%-backup:")
  if not tag then
    if s:find("%-backup:") then return nil, DAMAGED end
    return nil, "That isn't a GrindWatch backup string."
  end
  if tag ~= TAG then
    if SUITE[tag] then return nil, "That's a backup from " .. SUITE[tag] .. ". Paste it into that add-on instead." end
    return nil, "That isn't a GrindWatch backup string."
  end
  local format = tonumber(s:match("^%a+%-backup:(%d+):") or "")
  if not format then return nil, DAMAGED end
  if format > FORMAT then
    return nil, string.format("This backup was made by a newer GrindWatch (format %d). Update GrindWatch, then try again.", format)
  end
  if format ~= FORMAT then return nil, string.format("This backup uses an unknown format (%d).", format) end
  local len, sum, body = s:match("^%a+%-backup:%d+:(%d+):(%x+):([%w%+/=]+)$")
  if not len or #sum ~= 8 then return nil, DAMAGED end
  local raw = P.Base64Decode(body)
  if not raw or #raw ~= tonumber(len) or P.Adler32(raw) ~= tonumber(sum, 16) then return nil, DAMAGED end
  local payload = P.Deserialize(raw)
  if type(payload) ~= "table" or payload.addon ~= TAG or payload.format ~= FORMAT
      or type(payload.db) ~= "table" or (payload.session ~= nil and type(payload.session) ~= "table") then
    return nil, DAMAGED
  end
  return payload
end

local function Safe(s) return (tostring(s):gsub("|", "||")) end

-- What a restore would do, in plain words (shown before you confirm).
function P.PreviewLines(payload)
  local lines = {}
  local made = type(payload.made) == "number" and date("%Y-%m-%d %H:%M", payload.made) or "unknown time"
  lines[#lines + 1] = string.format("Backup made %s on %s.", made, Safe(payload.char))
  local history = type(payload.db.history) == "table" and payload.db.history or {}
  local n, oldest, newest = 0, nil, nil
  for _, h in ipairs(history) do
    n = n + 1
    local when = type(h) == "table" and type(h.when) == "number" and h.when > 0 and h.when or nil
    if when then
      oldest = math.min(oldest or when, when)
      newest = math.max(newest or when, when)
    end
  end
  if n > 0 and oldest then
    lines[#lines + 1] = string.format("History: %d session(s), %s to %s.", n, date("%Y-%m-%d", oldest), date("%Y-%m-%d", newest))
  else
    lines[#lines + 1] = string.format("History: %d session(s).", n)
  end
  lines[#lines + 1] = "Settings, window position and taught spells."
  local here = CharKey()
  if payload.session and payload.char == here then
    lines[#lines + 1] = string.format("This character's current session (%s).", ns.Duration and ns.Duration(tonumber(payload.session.elapsed) or 0) or "")
  elseif payload.session then
    lines[#lines + 1] = "The session in it belongs to " .. Safe(payload.char) .. ", so this character's session is kept."
  end
  lines[#lines + 1] = "Restoring replaces your current history and settings, then reloads the UI."
  return lines
end

-- Puts the backup in place and reloads so every part of the add-on starts from it
-- (loading runs the same checks as a normal login).
function P.Restore(payload)
  local db = CopyData(payload.db, 0)
  local old = type(VulcanGrindWatchDB) == "table" and VulcanGrindWatchDB or {}
  db.debugLog = old.debugLog          -- the log isn't in backups: keep the current one
  db.persistChars = old.persistChars  -- markers describe this install, not the backup
  VulcanGrindWatchDB = db
  local here = CharKey()
  if payload.session and payload.char == here then
    VulcanGrindWatchCharDB = { session = CopyData(payload.session, 0) }
  end
  P.restored = true
  if ReloadUI then ReloadUI() end
end

---------------------------------------------------------------------------
-- Load-failure detection
---------------------------------------------------------------------------
-- Called by Core.lua with the raw saved globals, before defaults fill them in.
-- The account file lists the characters that have saved data; each character's
-- file records that the account file existed. One missing while the other says
-- it should exist means the client failed to load it. (Both missing at once looks
-- exactly like a first install, so that case can't be told apart.)
-- The character check needs this character's realm, which can be unreadable while the
-- game is still loading. Then CheckLoad leaves P.charCheck (the list it loaded) and the
-- check runs again at PLAYER_LOGIN.
local function KeySet(list)
  if type(list) ~= "table" then return nil end
  local out = {}
  for k in pairs(list) do if type(k) == "string" then out[k] = true end end
  return out
end
function P.CheckLoad(rawDB, rawChar)
  local key = CharKey()
  local accountFailed = type(rawDB) ~= "table" and type(rawChar) == "table" and rawChar.persistAccount ~= nil
  P.charCheck = type(rawChar) ~= "table" and type(rawDB) == "table" and KeySet(rawDB.persistChars) or nil
  local charFailed = P.charCheck ~= nil and key ~= nil and P.charCheck[key] == true
  if key then P.charCheck = nil end
  P.failure = (accountFailed or charFailed) and { account = accountFailed, char = charFailed } or nil
  return P.failure
end

-- Written at logout, just before the client saves.
local function WriteMarkers()
  local db, char = VulcanGrindWatchDB, VulcanGrindWatchCharDB
  if type(db) ~= "table" or type(char) ~= "table" then return end
  local key = CharKey()
  if key then
    if type(db.persistChars) ~= "table" then db.persistChars = {} end
    db.persistChars[key] = time()
    local keys = {}
    for k, v in pairs(db.persistChars) do
      if type(k) ~= "string" or type(v) ~= "number" then db.persistChars[k] = nil else keys[#keys + 1] = k end
    end
    if #keys > MAX_CHARS then  -- forget the characters not seen for longest
      table.sort(keys, function(a, b) return db.persistChars[a] < db.persistChars[b] end)
      for i = 1, #keys - MAX_CHARS do db.persistChars[keys[i]] = nil end
    end
  end
  char.persistAccount = time()
end
ns.On("PLAYER_LOGOUT", WriteMarkers)

function P.WarningLines(f)
  local lines = {
    "GrindWatch couldn't load your saved data.",
    "",
    "This is a known problem with the World of Warcraft: Forever client: add-on data is",
    "written to disk but sometimes not loaded back. Your data is probably still in the file",
    "on disk, but the game will overwrite that file the next time you log out or /reload.",
    "",
    "Before you log out or /reload:",
    "1. Alt-Tab out of the game and copy this file somewhere safe:",
  }
  if f.account then
    lines[#lines + 1] = "   WTF\\Account\\<your account>\\SavedVariables\\VulcanGrindWatch.lua  (settings and history)"
  end
  if f.char then
    lines[#lines + 1] = "   WTF\\Account\\<your account>\\<realm>\\<character>\\SavedVariables\\VulcanGrindWatch.lua  (this character's session)"
  end
  lines[#lines + 1] = "2. Then either exit the game fully, copy the file back over the new one and start again,"
  lines[#lines + 1] = "   or, if you made a backup string with /gw backup, type /gw restore and paste it."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Until then GrindWatch keeps tracking, starting from empty."
  return lines
end

function P.ShowWarning()
  local f = P.failure
  if not f then return end
  ns.Print("|cffff4040couldn't load your saved data.|r This is a known Forever client problem, and your "
    .. "file will be overwritten at your next logout or /reload. Read the window that just opened before you do either.")
  if UIErrorsFrame then pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, "GrindWatch: saved data didn't load - see chat", 1, 0.25, 0.25) end
  ns.ShowCopy("GrindWatch: saved data didn't load", P.WarningLines(f))
end
ns.Listen("READY", P.ShowWarning)

ns.On("PLAYER_LOGIN", function()
  local pending, key = P.charCheck, CharKey()
  P.charCheck = nil
  if not (pending and key and pending[key]) then return end
  P.failure = P.failure or { account = false }
  P.failure.char = true
  P.ShowWarning()
end)

---------------------------------------------------------------------------
-- Offering a backup (when a session is saved to history, at most once a week)
---------------------------------------------------------------------------
ns.Listen("RESET", function(archived)
  local db = ns.DB
  if not archived or not db then return end
  local now = time()
  local last = math.max(tonumber(db.persistOffered) or 0, tonumber(db.persistBackedUp) or 0)
  if now - last < OFFER_EVERY then return end
  db.persistOffered = now
  ns.Print("tip: /gw backup copies your history and settings as text you can keep outside the game, "
    .. "in case the Forever client loses saved data.")
end)

---------------------------------------------------------------------------
-- The restore window: paste, read what it holds, then confirm.
---------------------------------------------------------------------------
local pasteFrame

local function BuildPasteFrame()
  local f = CreateFrame("Frame", "VulcanGrindWatchRestoreFrame", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(560, 380)
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
    f:SetBackdropBorderColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3], 1)
  end
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -10)
  title:SetText("GrindWatch: restore from a backup string  |cff888888(paste with Ctrl+V)|r")
  title:SetTextColor(ns.ACCENT[1], ns.ACCENT[2], ns.ACCENT[3])

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local scroll = CreateFrame("ScrollFrame", "VulcanGrindWatchRestoreScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -32)
  scroll:SetPoint("BOTTOMRIGHT", -30, 150)
  local box = CreateFrame("EditBox", nil, scroll)
  box:SetMultiLine(true)
  box:SetAutoFocus(true)
  box:SetMaxLetters(0)
  box:SetFontObject(ChatFontNormal)
  box:SetWidth(510)
  box:SetScript("OnEscapePressed", function() f:Hide() end)
  scroll:SetScrollChild(box)

  local info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  info:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 140)
  info:SetPoint("RIGHT", -12, 0)
  info:SetJustifyH("LEFT")
  info:SetJustifyV("TOP")

  local restore = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  restore:SetSize(120, 22)
  restore:SetPoint("BOTTOMRIGHT", -12, 10)
  restore:SetText("Restore")
  local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  cancel:SetSize(90, 22)
  cancel:SetPoint("RIGHT", restore, "LEFT", -8, 0)
  cancel:SetText("Cancel")
  cancel:SetScript("OnClick", function() f:Hide() end)

  local function Update()
    local payload, err = P.ParseBackup(box:GetText())
    f.payload = payload
    if payload then
      info:SetText(table.concat(P.PreviewLines(payload), "\n"))
      restore:Enable()
    else
      info:SetText("|cffff8080" .. err .. "|r")
      restore:Disable()
    end
  end
  box:SetScript("OnTextChanged", function() Update() end)
  restore:SetScript("OnClick", function() if f.payload then P.Restore(f.payload) end end)

  if UISpecialFrames then table.insert(UISpecialFrames, "VulcanGrindWatchRestoreFrame") end
  f.box, f.info, f.restore, f.cancel, f.Update = box, info, restore, cancel, Update
  pasteFrame = f
end

function P.ShowRestore()
  if not pasteFrame then BuildPasteFrame() end
  pasteFrame.box:SetText("")
  pasteFrame.Update()
  pasteFrame:Show()
  pasteFrame:Raise()
  pasteFrame.box:SetFocus()
  return pasteFrame
end

function P.ShowBackup()
  local ok, text = pcall(P.MakeBackup)
  if not ok then
    ns.Print("couldn't make a backup: " .. tostring(text))
    return nil
  end
  ns.DB.persistBackedUp = time()
  ns.ShowCopy("GrindWatch backup: copy it and keep it somewhere safe", { text })
  ns.Print(string.format("backup ready (%d characters). Ctrl+C copies it; /gw restore puts it back.", #text))
  return text
end

function P.CheckLine()
  if not P.failure then return "Saved data: loaded normally." end
  return "Saved data: |cffff4040didn't load this session|r (see /gw backup and /gw restore)."
end

---------------------------------------------------------------------------
-- Commands, menu items and help lines (picked up by Commands.lua / SettingsUI.lua)
---------------------------------------------------------------------------
ns.extraCommands = {
  backup = function() P.ShowBackup() end,
  restore = function() P.ShowRestore() end,
}
ns.extraHelp = {
  "|cffffd700Your data|r",
  "/gw backup - all your history and settings as text to keep outside the game;  /gw restore - paste one back",
}
ns.extraMenuItems = {
  { label = function() return "Back up data..." end, run = function() P.ShowBackup() end,
    tip = "Copy all your history and settings as text, to keep outside the game." },
  { label = function() return "Restore from backup..." end, run = function() P.ShowRestore() end,
    tip = "Paste a backup string. You'll see what's in it before anything changes." },
}
