-- Do the shipped places match the world the player is standing in?
--
-- a11y-placedata was joined offline out of Gustav.pak: 268 named areas with their outlines, 40
-- fast-travel shrines, and the name of every level. Offline it agrees with itself - 34 of the 40
-- shrines fall inside an area of their own level, and every one of those lands somewhere that
-- makes sense. What no file can answer is the only question that matters here: **are those
-- coordinates the coordinates of this session**.
--
-- That question has teeth. The rule this project learnt the hard way is never to ship a position
-- and never to walk to one - the quest chain resolves a UUID against the live world for exactly
-- that reason. The place table breaks that rule on purpose, because an area is not an object:
-- it has no entity to ask, and the outline of the Emerald Grove is not going to be moved by the
-- story. This probe is what makes that a measurement rather than an assumption.
--
--   1. is the table here, and does it know this level
--   2. what does it say the character is standing in, and does that agree with the level's name
--   3. of the shrines it lists, how many are really in the world, and how far from where the
--      file put them - **this is the calibration**: if the shrines are where the file says, the
--      areas are too, because both came out of the same level files
--   4. the ten nearest places, as the player would hear them
--   5. the landmark list, with the place each row now carries
--   6. the navigation portals: how many of them really have a door, hatch or ladder standing at
--      their Source, which is the same measurement as (3) for the other shipped table - and a
--      route to every place the list says cannot be walked to
--
-- Reads only. Nothing here moves the character or touches game state.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-place", "PL")
--     Mods.BG3Access.A11yBoot.globals.PL.run()
--
-- The answer goes to <SE>/A11y/place.json, because most of it is Russian and the console input
-- buffer is ANSI. The console gets an ASCII summary, which is enough to know whether to read it.

local M = {}

local B = Mods.BG3Access.A11yBoot
local G = B.globals

local function soft(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function P(s) Ext.Utils.Print("[pl] " .. tostring(s)) end

function M.run()
    local Nav, pd = G.Nav, G.PlaceData
    local r = { at = soft(Ext.Utils.MonotonicTime) }

    if pd == nil then
        P("PlaceData MISSING - a11y-placedata did not load")
        soft(Ext.IO.SaveFile, "A11y/place.json", '{"table":"MISSING"}')
        return nil
    end
    r.build = pd.BUILD

    local lv = Nav.myLevel()
    r.level = lv
    r.levelName = Nav.levelName()
    local subs, wps = Nav.placeTables()
    r.areas = #(subs or {})
    r.shrines = #(wps or {})
    P("build " .. tostring(pd.BUILD) .. ", level " .. tostring(lv) ..
      ", areas " .. r.areas .. ", shrines " .. r.shrines)

    local me = Nav.me()
    local pos = me and Nav.positionOf(me)
    r.pos = pos
    if pos == nil then
        P("no character - nothing further can be measured")
        soft(Ext.IO.SaveFile, "A11y/place.json", soft(Ext.Json.Stringify, r))
        return r
    end

    -- 2. Where the table thinks we are.
    local row = Nav.placeAt(pos)
    r.here = row and Nav.placeName(row) or nil
    r.hereId = row and row[1] or nil
    P("here: " .. tostring(r.hereId) .. " (" .. tostring(r.level) .. ")")

    -- 3. The calibration. A shrine is an item with a UUID, so the world can be asked where it
    --    really is, and the answer compared with the file. Anything over a metre or two means
    --    the outlines are not to be trusted either, and the whole table wants rebuilding.
    r.shrineCheck = {}
    local worst, seen, missing = 0, 0, 0
    for i = 1, #(wps or {}) do
        local w = wps[i]
        local e = soft(function() return Ext.Entity.Get(w[3]) end)
        local p = e and Nav.positionOf(e) or nil
        if p == nil then
            missing = missing + 1
            r.shrineCheck[#r.shrineCheck + 1] = { id = w[1], live = false }
        else
            seen = seen + 1
            local d = math.sqrt((p[1] - w[4]) ^ 2 + (p[2] - w[5]) ^ 2 + (p[3] - w[6]) ^ 2)
            if d > worst then worst = d end
            r.shrineCheck[#r.shrineCheck + 1] = {
                id = w[1], live = true, off = d,
                file = { w[4], w[5], w[6] }, world = p,
                -- And which area the world says it is in, which is the join the layer relies on.
                inside = (function()
                    local q = Nav.placeAt(p)
                    return q and q[1] or nil
                end)(),
            }
        end
    end
    r.shrinesLive, r.shrinesMissing, r.shrineWorstOffset = seen, missing, worst
    P("shrines: " .. seen .. " live, " .. missing .. " not in the world, worst offset " ..
      string.format("%.2f", worst) .. " m")

    -- 4. The list the player would hear.
    local view = Nav.placeView()
    r.view = {}
    for i = 1, math.min(#view, 12) do
        r.view[i] = Nav.describe(view[i])
    end
    P("places in the list: " .. #view)

    -- 5. And the landmark list, which is the one the player complained about.
    local was = Nav.category
    for i, c in ipairs(Nav.CATEGORIES) do if c.key == "landmarks" then Nav.category = i end end
    Nav.scan(nil, true)
    local marks = Nav.rebuildView()
    r.landmarks, r.landmarkPlaces = {}, {}
    for i = 1, math.min(#marks, 40) do
        r.landmarks[i] = Nav.describe(marks[i])
        local w = marks[i].where
        if type(w) == "string" then r.landmarkPlaces[w] = (r.landmarkPlaces[w] or 0) + 1 end
    end
    r.landmarkCount = #marks
    Nav.category = was
    Nav.rebuildView()

    local groups = 0
    for _ in pairs(r.landmarkPlaces) do groups = groups + 1 end
    P("landmarks: " .. #marks .. " in " .. groups .. " named places")

    -- 6. The portals, and the one thing about them that cannot be checked offline: whether the
    --    thing standing at a Source is really there. The join is a coordinate, so a portal with
    --    nothing at it is a door the layer would send somebody to and they would find a wall.
    local pts = Nav.portalTables()
    r.portals = #(pts or {})
    r.region = Nav.regionNow
    local withObject, gates = 0, {}
    for i = 1, #(pts or {}) do
        local row = pts[i]
        local e = Nav.portalEntry(row)
        if e ~= nil and e.entity ~= nil then withObject = withObject + 1 end
        if e ~= nil and e.dist < 120 then
            gates[#gates + 1] = { name = e.name, dist = e.dist, dir = e.dir,
                                  named = e.entity ~= nil,
                                  from = row[7], to = row[8] }
        end
    end
    r.portalsWithObject, r.gatesNear = withObject, gates
    P("portals: " .. r.portals .. ", with something standing at the source " .. withObject ..
      ", within 120 m " .. #gates .. "; we are in region " .. tostring(r.region))

    -- And a route to each place the list says cannot be walked to, which is the whole feature.
    r.routes = {}
    for i = 1, math.min(#view, 12) do
        local it = view[i]
        if it.cross then
            local route = Nav.routeTo(it.pos)
            r.routes[#r.routes + 1] = {
                to = it.name, straight = it.dist,
                hops = route and route.hops or nil,
                cost = route and route.cost or nil,
                entrance = route and (function()
                    local e = Nav.portalEntry(route.first)
                    return e and { name = e.name, dist = e.dist, dir = e.dir } or nil
                end)() or nil,
            }
        end
    end
    P("places on another island: " .. #r.routes)
    P("wrote A11y/place.json")

    soft(Ext.IO.SaveFile, "A11y/place.json", soft(Ext.Json.Stringify, r))
    return r
end

return M
