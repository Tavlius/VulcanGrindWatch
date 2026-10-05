-- Release checks: TOC fields, the version token and the addon-message prefix.
package.path = assert(os.getenv("GW_TESTS"), "GW_TESTS unset: run tests/run.sh") .. "?.lua;" .. package.path
local H = require("harness")
local check = H.check
local DIR = assert(os.getenv("GW_DIR"), "GW_DIR unset: run tests/run.sh")

local function read(name)
  local f = assert(io.open(DIR .. name, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- TOC: the packager puts the git tag where the token is, so the source keeps the token.
local toc = read("VulcanGrindWatch.toc")
check("TOC version is the packager token", toc:find("\n## Version: @project-version@\n", 1, true) ~= nil)
check("TOC author is Tavlius", toc:find("\n## Author: Tavlius\n", 1, true) ~= nil)
check("TOC title", toc:find("\n## Title: Vulcan GrindWatch\n", 1, true) ~= nil)
check("TOC interface is Forever 1.60.1 (16001)", toc:find("^## Interface: 16001\n") ~= nil)

-- The version isn't read anywhere in the code. If that changes, the reader must
-- cope with the unreplaced token (running from source) before this check is updated.
local readers = {}
for file in toc:gmatch("\n([%w_]+%.lua)") do
  local src = read(file)
  if src:find("GetAddOnMetadata") or src:find('"Version"', 1, true) then readers[#readers + 1] = file end
end
check("no code reads the version string", #readers == 0, table.concat(readers, ", "))

-- Running from source (token unreplaced) works: the add-on loads and syncs normally.
do
  local c = H.boot()
  c.login()
  c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED")
  c.gainMoney(30000)
  c.tick(31)
  check("from source: loads and syncs without errors", #c.errors() == 0, c.errors()[1])
end

-- Addon-message prefixes: at most 16 characters, and every Vulcan add-on's is different.
local SUITE_PREFIXES = {
  VulcanGrindWatch = "VulcanGrindWatch", VulcanRunBook = "VulcanRunBook", VulcanDuoQuest = "VulcanDuoQuest",
}
local prefix = read("Sync.lua"):match('local PREFIX = "([^"]+)"')
check("prefix found in Sync.lua", prefix ~= nil)
check("prefix is this add-on's suite prefix", prefix == SUITE_PREFIXES.VulcanGrindWatch, prefix)
local seen, distinct = {}, true
for _, p in pairs(SUITE_PREFIXES) do
  check("prefix " .. p .. " fits 16 characters", #p <= 16, #p)
  if seen[p] then distinct = false end
  seen[p] = true
end
check("suite prefixes are all different", distinct)
do
  local c = H.boot()
  c.login()
  c.inGroup = true
  c.fire("PLAYER_REGEN_DISABLED")  -- a pull starts the session, so there's something to share
  c.gainMoney(30000)
  c.tick(31)
  check("sync sends with that prefix", c.addonSent[1] ~= nil and c.addonSent[1].prefix == prefix, c.addonSent[1] and c.addonSent[1].prefix)
end

os.exit(H.summary() and 0 or 1)
