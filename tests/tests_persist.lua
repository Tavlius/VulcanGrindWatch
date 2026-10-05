-- Saved-data safety (Persist.lua): load-failure warnings, backup and restore.
package.path = assert(os.getenv("GW_TESTS"), "GW_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check

local function noErrors(c, name)
  local errs = c.errors()
  check(name .. ": no runtime errors", #errs == 0, errs[1])
end

local function deepEqual(a, b, path)
  path = path or "value"
  if type(a) ~= type(b) then return false, path .. ": " .. type(a) .. " vs " .. type(b) end
  if type(a) ~= "table" then
    if a == b then return true end
    return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b)
  end
  for k, v in pairs(a) do
    local ok, where = deepEqual(v, b[k], path .. "." .. tostring(k))
    if not ok then return false, where end
  end
  for k in pairs(b) do
    if a[k] == nil then return false, path .. "." .. tostring(k) .. ": missing on the left" end
  end
  return true
end

local function warned(c)
  return c.printedMatch("couldn't load your saved data") ~= nil
end
local function copyTitle()
  local f = _G.VulcanGrindWatchCopyFrame
  return f and f.shown and f.title.text or nil
end

-- A first login, then a normal logout: the two markers the cross-check needs.
local function firstInstall()
  local c = H.boot()
  c.login()
  return c, c.saved()
end

-- 1. A genuine first install warns about nothing, and logging out writes the markers.
do
  local c, saved = firstInstall()
  check("first install: no failure", c.ns.Persist.failure == nil)
  check("first install: no warning", not warned(c) and copyTitle() == nil)
  check("logout marks this character in the account data",
    type(saved.db.persistChars) == "table" and type(saved.db.persistChars["Tavlius-Emberfall"]) == "number")
  check("logout marks the account data in the character data", type(saved.char.persistAccount) == "number")
  noErrors(c, "first install")

  -- 2. The next normal login: still nothing to warn about.
  local c2 = H.boot({ saved = saved })
  c2.login()
  check("normal reload: no failure", c2.ns.Persist.failure == nil and not warned(c2))
  check("/gw check says saved data loaded", table.concat(c2.ns.CheckLines(), "\n"):find("Saved data: loaded normally") ~= nil)
  noErrors(c2, "normal reload")
end

-- 3. The account file didn't load, but this character's file says it existed.
do
  local _, saved = firstInstall()
  local c = H.boot({ saved = { db = nil, char = saved.char } })
  c.login()
  local f = c.ns.Persist.failure
  check("account load failure detected", f and f.account and not f.char)
  check("account failure: warned in chat", warned(c))
  check("account failure: warning window opened", (copyTitle() or ""):find("didn't load") ~= nil, copyTitle())
  local text = _G.VulcanGrindWatchCopyFrame.exportText or ""
  check("account failure: names the account file", text:find("\\SavedVariables\\VulcanGrindWatch.lua", 1, true) ~= nil
    and text:find("<character>", 1, true) == nil, text)
  check("account failure: says the next save overwrites the file", text:find("overwrite that file the next time you log out or /reload", 1, true) ~= nil)
  check("account failure: points to /gw restore", text:find("/gw restore", 1, true) ~= nil)
  check("account failure: says it's a known Forever client problem", text:find("known problem with the World of Warcraft: Forever client", 1, true) ~= nil)
  check("account failure: not silently empty (still tracking, with a warning)", c.ns.DB ~= nil and c.ns.S ~= nil and warned(c))
  check("/gw check reports the failure", table.concat(c.ns.CheckLines(), "\n"):find("didn't load this session") ~= nil)
  noErrors(c, "account failure")
end

-- 4. This character's file didn't load, but the account file lists the character.
do
  local _, saved = firstInstall()
  local c = H.boot({ saved = { db = saved.db, char = nil } })
  c.login()
  local f = c.ns.Persist.failure
  check("character load failure detected", f and f.char and not f.account)
  local text = _G.VulcanGrindWatchCopyFrame and _G.VulcanGrindWatchCopyFrame.exportText or ""
  check("character failure: names the character file only", text:find("<character>", 1, true) ~= nil
    and text:find("(settings and history)", 1, true) == nil, text)
  noErrors(c, "character failure")
end

-- 5. A new character on an account that has data is normal, not a failure.
do
  local _, saved = firstInstall()
  local c = H.boot({ saved = { db = saved.db, char = nil } })
  c.name = "Mirel"
  c.login()
  check("new character: no warning", c.ns.Persist.failure == nil and not warned(c))
  -- Same name on another realm is a different character too.
  local c2 = H.boot({ saved = { db = saved.db, char = nil }, realm = "Ashenreach" })
  c2.login()
  check("same name, other realm: no warning", c2.ns.Persist.failure == nil and not warned(c2))
end

-- 5b. The realm can be unreadable while the game loads: the character check waits for login.
do
  local _, saved = firstInstall()
  local c = H.boot({ saved = { db = saved.db, char = nil } })
  c.realm = nil
  c.fire("ADDON_LOADED", "VulcanGrindWatch")
  check("realm unreadable at load: no verdict yet", c.ns.Persist.failure == nil and not warned(c))
  c.realm = "Emberfall"
  c.fire("PLAYER_LOGIN")
  check("realm readable at login: the character failure is caught then", c.ns.Persist.failure
    and c.ns.Persist.failure.char and warned(c))
  check("and the warning window opens", (copyTitle() or ""):find("didn't load") ~= nil)
  local c2 = H.boot({ saved = { db = saved.db, char = nil } })
  c2.name, c2.realm = "Mirel", nil
  c2.fire("ADDON_LOADED", "VulcanGrindWatch")
  c2.realm = "Emberfall"
  c2.fire("PLAYER_LOGIN")
  check("late check: a new character is still not a failure", c2.ns.Persist.failure == nil and not warned(c2))
end

-- 6. Both files missing looks exactly like a first install (the documented limit).
do
  local c = H.boot({ saved = { db = nil, char = nil } })
  c.login()
  check("both missing: treated as a first install", c.ns.Persist.failure == nil and not warned(c))
end

-- 7. A damaged marker is ignored, never an error.
do
  local _, saved = firstInstall()
  saved.db.persistChars = "junk"
  local c = H.boot({ saved = { db = saved.db, char = nil } })
  c.login()
  check("junk marker list: no failure, no error", c.ns.Persist.failure == nil)
  noErrors(c, "junk marker")
  saved = c.saved()
  check("junk marker list is replaced at logout", type(saved.db.persistChars) == "table")
end

---------------------------------------------------------------------------
-- Backup data
---------------------------------------------------------------------------
local function rng(seed)
  local x = seed
  return function(n)
    x = (x * 1103515245 + 12345) % 2147483648
    return x % n
  end
end

local function randomString(r, maxLen)
  local t = {}
  for i = 1, r(maxLen + 1) do t[i] = string.char(r(256)) end
  return table.concat(t)
end

-- Sessions shaped like real history entries (the largest realistic history is
-- HISTORY_MAX of them, every text field at its longest).
local function fillHistory(ns, n, r, long)
  local h = {}
  for i = 1, n do
    h[i] = {
      when = 1700000000 + i * 3600, char = long and ("Tavlius" .. string.rep("x", 5)) or "Tavlius",
      zone = long and string.rep("Z", 60) or "Westfall", note = (i % 3 == 0) and "v1" or nil,
      label = long and string.rep("murlocs by the coast ", 3):sub(1, 60) or ("run " .. i),
      elapsed = 600 + r(20000), kills = r(2000), xp = r(500000), coin = r(10000000),
      loot = r(5000000), lootAH = r(9000000),
    }
  end
  ns.DB.history = h
end

local function fillSession(S, r, items)
  S.started, S.elapsed = true, 36000
  for i = 1, items do
    S.items[10000 + i] = { name = "Item number " .. i .. " of the long session", count = r(200), value = r(100000), valueAH = r(200000) }
    S.mobs["Mob " .. i] = r(300)
    S.zones["Zone " .. (i % 120)] = r(3600)
    S.seen["Creature-0-0000-0000-" .. i .. "-0000ABCDEF"] = 1700000000 + i
  end
  for b = 1, 120 do S.buckets[b] = { k = r(30), x = r(9000), c = r(50000), l = r(30000), la = r(60000) } end
end

-- 8. Round trip: backup -> restore window -> reload -> the same data.
do
  local c = H.boot()
  c.login()
  local ns, P = c.ns, c.ns.Persist
  local r = rng(7)
  fillHistory(ns, ns.HISTORY_MAX, r, false)
  ns.DB.alertPercent = 40
  ns.DB.customSpells[12345] = "gather"
  fillSession(ns.S, r, 40)
  ns.DB.debug = true
  ns.Log("test", "a diagnostics line that backups leave out")
  check("the diagnostics log has a line to keep", #ns.DB.debugLog >= 1)
  local expectDB = {}
  for k, v in pairs(VulcanGrindWatchDB) do if k ~= "debugLog" then expectDB[k] = v end end
  local text = P.ShowBackup()
  check("backup opens the copy window", (copyTitle() or ""):find("backup") ~= nil and _G.VulcanGrindWatchCopyFrame.exportText == text)
  check("backup string names the add-on and format", text:match("^VulcanGrindWatch%-backup:1:%d+:%x%x%x%x%x%x%x%x:") ~= nil)
  check("backup string is one line of safe characters", text:find("[^%w%+/=:%-]") == nil)
  local payload = P.ParseBackup(text)
  check("backup parses", payload ~= nil)
  local same, where = deepEqual(payload.db, expectDB)
  check("account data round-trips exactly (diagnostics log left out)", same, where)
  same, where = deepEqual(payload.session, VulcanGrindWatchCharDB.session)
  check("this character's session round-trips exactly", same, where)
  check("payload records the character", payload.char == "Tavlius-Emberfall")

  -- Wipe the data, then restore through the window like a player would.
  local history = P.Deserialize(P.Serialize(VulcanGrindWatchDB.history))   -- copies, not the live tables
  local session = P.Deserialize(P.Serialize(VulcanGrindWatchCharDB.session))
  wipe(ns.DB.history)
  ns.DB.alertPercent = 25
  local f = P.ShowRestore()
  check("restore window opens with Restore disabled", f.shown and not f.restore.enabled)
  f.box:SetText(text)
  f.box.scripts.OnTextChanged(f.box, true)
  check("valid backup enables Restore", f.restore.enabled)
  local info = f.info.text
  check("preview counts the history", info:find("History: 50 session%(s%)") ~= nil, info)
  check("preview shows the date range", info:find("2023%-11%-14 to 2023%-11%-17") ~= nil, info)
  check("preview says it includes this character's session", info:find("This character's current session") ~= nil, info)
  check("preview says what restoring replaces", info:find("replaces your current history and settings") ~= nil, info)
  check("nothing changed before confirming", #ns.DB.history == 0 and (c.reloads or 0) == 0)
  c.click(f.restore)
  check("confirming reloads the UI once", c.reloads == 1)
  local c2 = H.boot({ saved = c.saved() })
  c2.login()
  same, where = deepEqual(c2.ns.DB.history, history)
  check("restored history matches after the reload", same, where)
  check("restored settings match", c2.ns.DB.alertPercent == 40 and c2.ns.DB.customSpells[12345] == "gather")
  same, where = deepEqual(c2.ns.S.items, session.items)
  check("restored session items match", same, where)
  check("restore keeps the current diagnostics log", #c2.ns.DB.debugLog >= 1)
  check("restored install still warns about nothing", c2.ns.Persist.failure == nil and not warned(c2))
  noErrors(c2, "round trip")
end

-- 9. A backup from another character restores the account data and keeps this
--    character's session.
do
  local c = H.boot()
  c.login()
  fillHistory(c.ns, 3, rng(3), false)
  c.ns.S.started, c.ns.S.elapsed = true, 900
  local text = c.ns.Persist.MakeBackup()
  local c2 = H.boot({ realm = "Ashenreach" })
  c2.login()
  c2.ns.S.started, c2.ns.S.elapsed = true, 123
  local f = c2.ns.Persist.ShowRestore()
  f.box:SetText(text)
  f.box.scripts.OnTextChanged(f.box, true)
  check("other character: preview says the session is kept", f.info.text:find("belongs to Tavlius%-Emberfall, so this character's session is kept") ~= nil, f.info.text)
  c2.click(f.restore)
  check("other character: history restored", #VulcanGrindWatchDB.history == 3)
  check("other character: own session kept", VulcanGrindWatchCharDB.session.elapsed == 123)
end

-- 10. The largest realistic history (HISTORY_MAX sessions, every text field at
--     its longest) plus a ten-hour session with hundreds of items.
do
  local c = H.boot()
  c.login()
  local r = rng(11)
  fillHistory(c.ns, c.ns.HISTORY_MAX, r, true)
  fillSession(c.ns.S, r, 600)
  local text = c.ns.Persist.MakeBackup()
  local payload, err = c.ns.Persist.ParseBackup(text)
  check("largest realistic backup parses", payload ~= nil, err)
  local expectDB = {}
  for k, v in pairs(VulcanGrindWatchDB) do if k ~= "debugLog" then expectDB[k] = v end end
  check("largest realistic backup round-trips", payload and deepEqual(payload.db, expectDB) and deepEqual(payload.session, VulcanGrindWatchCharDB.session))
  check("largest realistic backup fits the paste limit (" .. #text .. " characters)", #text < 512 * 1024, #text)
  io.write(string.format("largest realistic backup: %d characters\n", #text))
end

-- 11. Fuzz: random data of every allowed kind, and random bytes through the encoding.
do
  local c = H.boot()
  c.login()
  local P = c.ns.Persist
  local r = rng(2024)
  local function randomValue(depth)
    local kind = r(depth > 4 and 3 or 4)
    if kind == 0 then return randomString(r, 40)
    elseif kind == 1 then
      local picks = { 0, -0, 1, -1, 0.1, 1 / 3, 2 ^ 53, -2 ^ 53, 1e300, -1e-300, 123456.789, r(1000000) - 500000 }
      return picks[r(#picks) + 1]
    elseif kind == 2 then return r(2) == 1
    end
    local t = {}
    for _ = 1, r(6) do
      local key = r(2) == 1 and randomString(r, 12) or (r(100) - 50)
      t[key] = randomValue(depth + 1)
    end
    return t
  end
  local bad = 0
  for i = 1, 400 do
    local v = { data = randomValue(0), n = i }
    local back = P.Deserialize(P.Serialize(v))
    if not deepEqual(v, back) then bad = bad + 1 end
  end
  check("400 random tables round-trip through the serializer", bad == 0, bad)
  bad = 0
  for len = 0, 300 do
    local s = randomString(r, len)
    if P.Base64Decode(P.Base64Encode(s)) ~= s then bad = bad + 1 end
  end
  check("random bytes round-trip through the text encoding", bad == 0, bad)
  -- Whole backups of random account data.
  bad = 0
  for _ = 1, 40 do
    VulcanGrindWatchDB = { history = {}, extra = randomValue(0) }
    local payload = P.ParseBackup(P.MakeBackup())
    if not payload or not deepEqual(payload.db, VulcanGrindWatchDB) then bad = bad + 1 end
  end
  check("40 random backups round-trip", bad == 0, bad)
end

---------------------------------------------------------------------------
-- Rejections: every bad paste says what's wrong and changes nothing
---------------------------------------------------------------------------
do
  local c = H.boot()
  c.login()
  local ns, P = c.ns, c.ns.Persist
  fillHistory(ns, 5, rng(5), false)
  local good = P.MakeBackup()
  local before = P.Serialize(VulcanGrindWatchDB)

  -- A valid envelope around any raw payload (so only the payload is wrong).
  local function wrap(raw, format)
    return string.format("VulcanGrindWatch-backup:%d:%d:%08x:%s", format or 1, #raw, P.Adler32(raw), P.Base64Encode(raw))
  end
  local function payloadWith(changes)
    local p = P.ParseBackup(good)
    for k, v in pairs(changes) do p[k] = v end
    return P.Serialize(p)
  end
  local body = good:match(":([%w%+/=]+)$")
  local flipped = body:sub(1, 40) .. (body:sub(41, 41) == "A" and "B" or "A") .. body:sub(42)
  local cases = {
    { "empty paste", "", "Paste a backup string first" },
    { "only spaces", "   \n  ", "Paste a backup string first" },
    { "chat text", "hello there", "isn't a GrindWatch backup" },
    { "truncated end", good:sub(1, #good - 12), "incomplete or damaged" },
    { "truncated middle", good:sub(1, 60) .. good:sub(200), "incomplete or damaged" },
    { "header only", "VulcanGrindWatch-backup:1:", "incomplete or damaged" },
    { "one character changed", good:gsub(":[%w%+/=]+$", ":" .. flipped), "incomplete or damaged" },
    { "wrong length", good:gsub("^(VulcanGrindWatch%-backup:1:)(%d+)", function(a, n) return a .. (tonumber(n) + 1) end), "incomplete or damaged" },
    { "wrong checksum", good:gsub("^(VulcanGrindWatch%-backup:1:%d+:)(%x+)", "%100000000"), "incomplete or damaged" },
    { "not base64", good:gsub(":[%w%+/=]+$", ":!!!!"), "incomplete or damaged" },
    { "RunBook backup", (good:gsub("^VulcanGrindWatch", "VulcanRunBook")), "from Vulcan RunBook%. Paste it into that add%-on" },
    { "DuoQuest backup", (good:gsub("^VulcanGrindWatch", "VulcanDuoQuest")), "from Vulcan DuoQuest" },
    { "some other add-on", (good:gsub("^VulcanGrindWatch", "SomeAddon")), "isn't a GrindWatch backup" },
    { "future format", (good:gsub("^VulcanGrindWatch%-backup:1:", "VulcanGrindWatch-backup:2:")), "newer GrindWatch %(format 2%)" },
    { "unknown old format", (good:gsub("^VulcanGrindWatch%-backup:1:", "VulcanGrindWatch-backup:0:")), "unknown format %(0%)" },
    { "far too long", string.rep("A", 600 * 1024), "far longer" },
    { "payload for another add-on", wrap(payloadWith({ addon = "VulcanRunBook" })), "incomplete or damaged" },
    { "payload format mismatch", wrap(payloadWith({ format = 2 })), "incomplete or damaged" },
    { "payload without account data", wrap(payloadWith({ db = "x" })), "incomplete or damaged" },
    { "trailing bytes after the data", wrap(P.Serialize({ addon = "VulcanGrindWatch", format = 1, db = {} }) .. "T"), "incomplete or damaged" },
    { "nested 100 deep", wrap(string.rep("{S1:a", 100) .. "T" .. string.rep("}", 100)), "incomplete or damaged" },
    -- These two hide the bad value inside an otherwise valid backup, so only the
    -- nesting limit / the finite-number check can refuse them.
    { "valid backup with data nested 30 deep", wrap((payloadWith({ deep = "DEEP" }):gsub("S4:DEEP", string.rep("{S1:a", 30) .. "T" .. string.rep("}", 30)))), "incomplete or damaged" },
    { "valid backup with an infinite number", wrap((payloadWith({ big = 12345.5 }):gsub("N12345%.5;", "N1e999;"))), "incomplete or damaged" },
    { "string longer than the data", wrap("{S5:addonS999999999:x}"), "incomplete or damaged" },
    { "infinite number", wrap("{S6:formatN1e999;}"), "incomplete or damaged" },
    { "not-a-number", wrap("{S6:formatNnan;}"), "incomplete or damaged" },
    { "boolean key", wrap("{TT}"), "incomplete or damaged" },
    { "not a table", wrap("S3:abc"), "incomplete or damaged" },
  }
  check("planted payloads are otherwise valid", P.ParseBackup(wrap(payloadWith({ deep = "DEEP", big = 12345.5 }))) ~= nil)
  local f = P.ShowRestore()
  for _, case in ipairs(cases) do
    local name, text, want = case[1], case[2], case[3]
    local payload, err = P.ParseBackup(text)
    check("reject " .. name .. ": refused", payload == nil)
    check("reject " .. name .. ": says why", type(err) == "string" and err:find(want) ~= nil, err)
    f.box:SetText(text)
    f.box.scripts.OnTextChanged(f.box, true)
    check("reject " .. name .. ": Restore stays disabled", not f.restore.enabled and not c.click(f.restore))
  end
  check("rejections changed nothing", P.Serialize(VulcanGrindWatchDB) == before and (c.reloads or 0) == 0)

  -- Pasted with line breaks and spaces around it (chat clients wrap long lines): still fine.
  local wrapped = "  " .. good:sub(1, 50) .. "\n" .. good:sub(51, 120) .. " \r\n" .. good:sub(121) .. "\n"
  check("backup pasted with line breaks still parses", P.ParseBackup(wrapped) ~= nil)
  noErrors(c, "rejections")
end

-- 12. Saving can't silently fail: a value that can't be saved gives a message.
do
  local c = H.boot()
  c.login()
  c.ns.DB.broken = function() end
  local text = c.ns.Persist.ShowBackup()
  check("unsaveable data: no backup, a message instead", text == nil and c.printedMatch("couldn't make a backup") ~= nil)
  check("unsaveable data: no backup time recorded", c.ns.DB.persistBackedUp == nil)
  c.ns.DB.broken = 0 / 0
  check("non-finite number refuses to save", not pcall(c.ns.Persist.MakeBackup))
  noErrors(c, "unsaveable")
end

-- 13. A backup is offered when a session goes to history, at most once a week,
--     and not again soon after you made one.
do
  local c = H.boot()
  c.login()
  local ns = c.ns
  local function archive()
    c.printed = {}
    ns.S.started, ns.S.elapsed = true, 600
    c.slash("reset")
    return c.printedMatch("tip: /gw backup") ~= nil
  end
  check("first archived session: backup offered", archive())
  check("second one the same day: not offered", not archive())
  c.wall = c.wall + 8 * 24 * 3600
  check("a week later: offered again", archive())
  c.wall = c.wall + 8 * 24 * 3600
  ns.Persist.ShowBackup()
  check("right after a backup: not offered", not archive())
  c.printed = {}
  c.slash("reset")  -- nothing to archive
  check("nothing archived: not offered", c.printedMatch("tip: /gw backup") == nil)
end

-- 14. Commands, help and the gear menu reach it.
do
  local c = H.boot()
  c.login()
  c.slash("backup")
  check("/gw backup opens the backup", (copyTitle() or ""):find("backup") ~= nil)
  c.slash("restore")
  check("/gw restore opens the restore window", _G.VulcanGrindWatchRestoreFrame and _G.VulcanGrindWatchRestoreFrame.shown)
  c.printed = {}
  c.slash("help")
  check("help lists backup and restore", c.printedMatch("/gw backup") ~= nil and c.printedMatch("/gw restore") ~= nil)
  -- The real gear menu: both rows are there, before "Hide window", and they work.
  _G.VulcanGrindWatchCopyFrame:Hide()
  _G.VulcanGrindWatchRestoreFrame:Hide()
  c.click(_G.VulcanGrindWatchGearButton)
  local order, rows = {}, {}
  for _, row in ipairs(c.ns.menuRows) do
    if row.shown ~= false then
      local t = tostring(row.text.text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
      order[#order + 1] = t
      rows[t] = row
    end
  end
  local list = table.concat(order, " / ")
  check("gear menu lists backup and restore before Hide window",
    list:find("Export history / Back up data%.%.%. / Restore from backup%.%.%. / Hide window") ~= nil, list)
  c.click(rows["Back up data..."])
  check("menu: Back up data opens the backup", (copyTitle() or ""):find("backup") ~= nil)
  c.click(_G.VulcanGrindWatchGearButton)
  c.click(rows["Restore from backup..."])
  check("menu: Restore opens the restore window", _G.VulcanGrindWatchRestoreFrame.shown)
  noErrors(c, "commands")
end

os.exit(H.summary() and 0 or 1)
