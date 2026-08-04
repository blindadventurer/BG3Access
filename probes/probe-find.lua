-- Finding a thing on the level, and finding the way to it.
--
-- The scanner answers "what is within N metres of me", and for a quest that is the wrong
-- question. The transponder that ends the prologue is in another room; the rune that opens a
-- pod is in a third; neither is within any radius worth sweeping, and a player who cannot see
-- has been reduced to walking to every object in turn to find out what it is.
--
-- Two engine facilities make a better answer possible, and neither has been used before:
--
--   * `Ext.Entity.GetAllEntities()` - the whole level, not a radius. A thing can be found
--     before it is anywhere near.
--   * `Ext.Level.FindPath()` - the game's own pathfinding, which is what decides whether a
--     place can be walked to at all and how far the walk really is. Straight-line distance
--     lies on a ship: 20 metres through a wall is not 20 metres.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-find", "F")
--     Mods.BG3Access.F.templates("Transponder")   -- what the level is built from
--     Mods.BG3Access.F.entities("Transponder")    -- where the instances are
--     Mods.BG3Access.F.pathTo(x, z)               -- can I get there, and how far

local A = _G.A11y
local F = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

--- Every root template whose name matches, with the shape of the answer reported.
---
--- Reported rather than assumed: `GetAllRootTemplates` exists in this build and came back
--- empty on the first call, and "the API is missing" and "I iterated it wrong" are different
--- problems with different fixes.
function F.templates(pattern)
    pattern = pattern or "Transponder"
    local out = {}
    for _, fname in ipairs({ "GetAllRootTemplates", "GetAllCacheTemplates",
                             "GetAllLocalTemplates", "GetAllLocalCacheTemplates" }) do
        local t = soft(function() return Ext.Template[fname]() end)
        local kind, n = type(t), 0
        if kind == "table" then
            for id, tpl in pairs(t) do
                n = n + 1
                local nm = str(soft(function() return tpl.Name end))
                if nm == "nil" then nm = str(soft(function() return tpl.TemplateName end)) end
                if nm:find(pattern) then
                    out[#out + 1] = fname .. ": " .. nm .. "  |  " .. str(id)
                end
            end
        end
        out[#out + 1] = "-- " .. fname .. " -> " .. kind .. ", " .. n .. " entries"
    end
    Ext.IO.SaveFile("A11y/find_templates.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[find] templates -> find_templates.txt")
    return #out
end

--- Every entity on the level whose template name matches, with where it is.
---
--- The template name is the one written by whoever built the level: English, stable across
--- languages, and the only handle on an object that a translated display name cannot break.
function F.entities(pattern, cap)
    pattern = pattern or "Transponder"
    local all = soft(Ext.Entity.GetAllEntities)
    if type(all) ~= "table" then
        Ext.Utils.Print("[find] GetAllEntities gave " .. type(all))
        return nil
    end
    local out, seen, hits = {}, 0, 0
    for i = 1, #all do
        local e = all[i]
        local u = soft(function() return e.Uuid.EntityUuid end)
        if u ~= nil then
            seen = seen + 1
            local t = soft(function() return Osi.GetTemplate(u) end)
            if type(t) == "string" and t:find(pattern) then
                hits = hits + 1
                local p = soft(function() return e.Transform.Transform.Translate end)
                out[#out + 1] = string.format("%-52s x=%.1f y=%.1f z=%.1f  %s",
                    t, p and p[1] or 0, p and p[2] or 0, p and p[3] or 0, u)
                if cap and hits >= cap then break end
            end
        end
    end
    Ext.IO.SaveFile("A11y/find_entities.txt",
        "entities=" .. #all .. " with uuid=" .. seen .. " hits=" .. hits .. "\n" ..
        table.concat(out, "\n"))
    Ext.Utils.Print("[find] " .. hits .. " of " .. seen .. " -> find_entities.txt")
    return hits
end

--- Every distinct template on the level, counted. The catalogue to search by eye when no
--- guess at a name has worked.
function F.catalogue()
    local all = soft(Ext.Entity.GetAllEntities)
    if type(all) ~= "table" then return nil end
    local count = {}
    for i = 1, #all do
        local u = soft(function() return all[i].Uuid.EntityUuid end)
        if u ~= nil then
            local t = soft(function() return Osi.GetTemplate(u) end)
            if type(t) == "string" then
                -- The trailing uuid makes every instance look unique; the name before it is
                -- what identifies the kind of thing.
                local base = t:gsub("_[0-9a-f%-]+$", "")
                count[base] = (count[base] or 0) + 1
            end
        end
    end
    local names = {}
    for k in pairs(count) do names[#names + 1] = k end
    table.sort(names)
    local out = {}
    for _, k in ipairs(names) do out[#out + 1] = string.format("%4d  %s", count[k], k) end
    Ext.IO.SaveFile("A11y/find_catalogue.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[find] " .. #names .. " distinct templates -> find_catalogue.txt")
    return #names
end

--- The engine's own answer to "can I walk there, and how far is it really".
---
--- Straight-line distance is a lie indoors: on a ship, twenty metres can be through a wall,
--- and the walk round to it two hundred. This asks the thing that actually knows.
--- Try every plausible call shape and write down what each one said.
---
--- The first attempt passed two vec3 tables and got nil from both entry points, with the
--- reason swallowed by pcall - which is the same mistake as reading a screen and reporting
--- "empty". An engine call that refuses says why, and the why is the whole message: a wrong
--- argument count reads differently from a wrong type, and both read differently from a
--- feature that is simply not wired up in this build.
function F.pathTo(x, z, y)
    local nav = _G.Nav
    local me = nav and soft(nav.me)
    local p = me and soft(function() return me.Transform.Transform.Translate end)
    if p == nil then Ext.Utils.Print("[find] no character position") return nil end
    local from = { p[1], p[2], p[3] }
    local to = { x, y or p[2], z }

    local out = { string.format("from x=%.1f y=%.1f z=%.1f", from[1], from[2], from[3]),
                  string.format("to   x=%.1f y=%.1f z=%.1f", to[1], to[2], to[3]),
                  "context = " .. (Ext.IsServer and Ext.IsServer() and "server" or "client") }

    local function attempt(label, fn)
        local ok, r = pcall(fn)
        out[#out + 1] = string.format("%-46s %s  %s", label,
            ok and ("-> " .. type(r)) or "THREW", str(r):sub(1, 200))
        return ok and r or nil
    end

    attempt("FindPath(from, to)", function() return Ext.Level.FindPath(from, to) end)
    attempt("FindPath(me, to)", function() return Ext.Level.FindPath(me, to) end)
    attempt("FindPath{Source=,Target=}", function()
        return Ext.Level.FindPath({ Source = from, Target = to })
    end)
    attempt("FindPath(x,y,z,x,y,z)", function()
        return Ext.Level.FindPath(from[1], from[2], from[3], to[1], to[2], to[3])
    end)
    attempt("FindPath()", function() return Ext.Level.FindPath() end)

    local id = attempt("BeginPathfindingImmediate(from,to)", function()
        return Ext.Level.BeginPathfindingImmediate(from, to)
    end)
    if id == nil then
        id = attempt("BeginPathfindingImmediate{...}", function()
            return Ext.Level.BeginPathfindingImmediate({ Source = from, Target = to })
        end)
    end
    if id == nil then
        id = attempt("BeginPathfinding(from,to)", function()
            return Ext.Level.BeginPathfinding(from, to)
        end)
    end
    attempt("GetActivePathfindingRequests()", function()
        return Ext.Level.GetActivePathfindingRequests()
    end)
    if id ~= nil then
        local path = attempt("GetPathById(id)", function() return Ext.Level.GetPathById(id) end)
        if path ~= nil then
            local props = soft(function() return path:GetAllProperties() end)
            if type(props) ~= "table" and type(path) == "table" then props = path end
            if type(props) == "table" then
                local keys = {}
                for k in pairs(props) do keys[#keys + 1] = tostring(k) end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    out[#out + 1] = "     " .. k .. " = " .. str(props[k]):sub(1, 160)
                end
            end
        end
        soft(function() Ext.Level.ReleasePath(id) end)
    end

    -- What the engine is willing to say about the ground itself, which is the cheaper half of
    -- the same question: a height at a point means the point exists on the level at all.
    attempt("GetHeightsAt(to)", function() return Ext.Level.GetHeightsAt(to[1], to[3]) end)
    attempt("GetLevelInfo()", function() return Ext.Level.GetLevelInfo() end)

    Ext.IO.SaveFile("A11y/find_path.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[find] path -> find_path.txt")
    return true
end

--- What an AiPath is, and how one is made.
---
--- `FindPath` answered "Argument 1: Expected AiPath, got Entity", which is the most useful
--- error of the round: the entry point is not "give me a path between two points" but "here
--- is a path object, fill it in". So the question becomes what that object is made of and
--- who hands one out.
function F.aipath()
    local out = {}

    local function dumpType(name)
        local ti = soft(Ext.Types.GetTypeInfo, name)
        if ti == nil then out[#out + 1] = "== " .. name .. ": no type info" return end
        out[#out + 1] = "== " .. name .. "  kind=" .. str(soft(function() return ti.Kind end))
        local members = {}
        soft(function()
            for k, v in pairs(ti.Members or {}) do
                members[#members + 1] = "   " .. tostring(k) .. " : " ..
                    str(soft(function() return tostring(v.TypeName) end) or "?")
            end
        end)
        soft(function()
            for k, v in pairs(ti.Methods or {}) do
                members[#members + 1] = "   ()" .. tostring(k)
            end
        end)
        table.sort(members)
        for _, s in ipairs(members) do out[#out + 1] = s end
    end

    for _, n in ipairs({ "AiPath", "eoc::AiPath", "esv::AiPath", "AiGrid", "AiPathSettings" }) do
        dumpType(n)
    end

    -- Who can hand one out.
    local function attempt(label, fn)
        local ok, r = pcall(fn)
        out[#out + 1] = string.format("%-40s %s  %s", label,
            ok and ("-> " .. type(r)) or "THREW", str(r):sub(1, 160))
        return ok and r or nil
    end
    attempt("Ext.Types.Construct('AiPath')", function() return Ext.Types.Construct("AiPath") end)
    attempt("Ext.Level.GetActivePathfindingRequests", function()
        local t = Ext.Level.GetActivePathfindingRequests()
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end)
    attempt("Ext.Level.BeginPathfinding()", function() return Ext.Level.BeginPathfinding() end)
    attempt("Ext.Level.GetPathById(0)", function() return Ext.Level.GetPathById(0) end)
    attempt("Ext.Level.GetPathById(1)", function() return Ext.Level.GetPathById(1) end)

    -- The character's own path component: the game is walking people about all the time, so
    -- a live example is the cheapest way to learn the shape.
    local nav = _G.Nav
    local me = nav and soft(nav.me)
    if me ~= nil then
        local comps = soft(function() return me:GetAllComponentNames() end)
        if type(comps) == "table" then
            table.sort(comps)
            for _, c in ipairs(comps) do
                local s = tostring(c)
                if s:find("ath") or s:find("Move") or s:find("Steer") or s:find("Ai") then
                    out[#out + 1] = "   me component: " .. s
                end
            end
        else
            out[#out + 1] = "   (no component list from the entity)"
        end
    end

    -- Ground under a point is the cheaper half of the same question and it already answers.
    local h = soft(function() return Ext.Level.GetHeightsAt(-82.4, -389.0) end)
    out[#out + 1] = "GetHeightsAt(transponder) -> " .. type(h)
    if type(h) == "table" then
        for k, v in pairs(h) do out[#out + 1] = "   " .. tostring(k) .. " = " .. str(v) end
    end

    Ext.IO.SaveFile("A11y/find_aipath.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[find] aipath -> find_aipath.txt")
    return #out
end

--- Ask for a path the way the engine hands one out, rather than the way it would be nice to.
---
--- `AiPath` is not constructible from Lua and `BeginPathfinding` wants a C++ value where a
--- table was offered, so the object comes from somewhere - the character, the grid, or the
--- pool the grid keeps. This tries each source in turn and reports what it got.
function F.walkpath(x, z, y)
    local nav = _G.Nav
    local me = nav and soft(nav.me)
    if me == nil then return nil end
    local p = soft(function() return me.Transform.Transform.Translate end)
    local to = { x, y or p[2], z }
    local out = { string.format("from %.1f %.1f %.1f -> %.1f %.1f %.1f",
                                p[1], p[2], p[3], to[1], to[2], to[3]) }

    local function attempt(label, fn)
        local ok, r = pcall(fn)
        out[#out + 1] = string.format("%-44s %s  %s", label,
            ok and ("-> " .. type(r)) or "THREW", str(r):sub(1, 170))
        return ok and r or nil
    end

    attempt("BeginPathfindingImmediate(me, to)", function()
        return Ext.Level.BeginPathfindingImmediate(me, to)
    end)
    attempt("BeginPathfinding(me, to)", function()
        return Ext.Level.BeginPathfinding(me, to)
    end)
    attempt("BeginPathfindingImmediate(me,to,{})", function()
        return Ext.Level.BeginPathfindingImmediate(me, to, {})
    end)

    -- The grid keeps a pool of these; a live one would answer every question about the shape
    -- at once, including whether Nodes is readable from Lua at all.
    local grid = nil
    for _, comp in ipairs({ "AiGrid", "eoc::AiGridComponent", "esv::AiGridComponent" }) do
        local l = soft(Ext.Entity.GetAllEntitiesWithComponent, comp)
        out[#out + 1] = "component " .. comp .. " -> " ..
                        tostring(type(l) == "table" and #l or type(l))
        if type(l) == "table" and #l > 0 then grid = l[1] end
    end
    if grid ~= nil then
        for _, f in ipairs({ "AiGrid", "eoc::AiGridComponent" }) do
            local g = soft(function() return grid[f] end)
            if g ~= nil then
                out[#out + 1] = "grid via " .. f .. ": " .. type(g)
                local paths = soft(function() return g.Paths end)
                local pool = soft(function() return g.PathPool end)
                out[#out + 1] = "   Paths=" .. tostring(type(paths) == "table" and #paths or "?") ..
                                " PathPool=" .. tostring(type(pool) == "table" and #pool or "?")
                local sample = (type(pool) == "table" and pool[1]) or
                               (type(paths) == "table" and paths[1]) or nil
                if sample ~= nil then
                    out[#out + 1] = "   sample path: GoalFound=" ..
                        str(soft(function() return sample.GoalFound end)) ..
                        " Nodes=" .. str(soft(function()
                            local n = sample.Nodes return n and #n end))
                end
            end
        end
    end

    Ext.IO.SaveFile("A11y/find_walkpath.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[find] walkpath -> find_walkpath.txt")
    return #out
end

--- The route to a point, as the engine walks it.
---
--- `Ext.Level.BeginPathfindingImmediate(character, {x,y,z})` hands back an `AiPath` - that
--- is the entry point, found by passing the entity where a table had been offered before.
--- What comes back is not a yes/no: it carries `GoalFound`, the nodes of the route, and an
--- `ErrorCause` when there is no way through. Which is exactly the three answers a player
--- standing in a corridor needs: is it reachable, how far is the real walk, and which way
--- does the first leg go.
function F.route(x, z, y, tag)
    local nav = _G.Nav
    local me = nav and soft(nav.me)
    if me == nil then return nil end
    local p = soft(function() return me.Transform.Transform.Translate end)
    local to = { x, y or p[2], z }

    local path = soft(function() return Ext.Level.BeginPathfindingImmediate(me, to) end)
    if path == nil then Ext.Utils.Print("[find] no path object") return nil end

    local function g(k) return soft(function() return path[k] end) end
    local out = {
        string.format("from %.1f %.1f %.1f", p[1], p[2], p[3]),
        string.format("to   %.1f %.1f %.1f", to[1], to[2], to[3]),
        "straight line   = " .. string.format("%.1f m",
            math.sqrt((to[1] - p[1]) ^ 2 + (to[3] - p[3]) ^ 2)),
        "GoalFound       = " .. str(g("GoalFound")),
        "SearchComplete  = " .. str(g("SearchComplete")),
        "DestinationReached = " .. str(g("DestinationReached")),
        "ErrorCause      = " .. str(g("ErrorCause")),
        "CanUseLadders   = " .. str(g("CanUseLadders")),
        "CanUsePortals   = " .. str(g("CanUsePortals")),
        "CheckLockedDoors= " .. str(g("CheckLockedDoors")),
        "Climbing        = " .. str(g("Climbing")),
    }

    local nodes = g("Nodes")
    local n = (type(nodes) == "table" or type(nodes) == "userdata") and
              soft(function() return #nodes end) or nil
    out[#out + 1] = "Nodes           = " .. str(n)
    if n ~= nil and n > 0 then
        -- The nodes come back from the goal backwards in this engine, so the walk is measured
        -- rather than assumed to start at the character.
        local total, prev = 0, nil
        for i = 1, n do
            local nd = soft(function() return nodes[i] end)
            local q = soft(function() return nd.Position end)
            if q == nil then q = soft(function() return nd.Pos end) end
            if q ~= nil then
                if prev ~= nil then
                    total = total + math.sqrt((q[1] - prev[1]) ^ 2 + (q[3] - prev[3]) ^ 2)
                end
                prev = q
                if i <= 12 or i > n - 3 then
                    out[#out + 1] = string.format("   [%2d] %.1f %.1f %.1f", i, q[1], q[2], q[3])
                end
            else
                local props = soft(function() return nd:GetAllProperties() end)
                if type(props) == "table" and i == 1 then
                    for k, v in pairs(props) do
                        out[#out + 1] = "   node field " .. tostring(k) .. " = " .. str(v):sub(1, 80)
                    end
                end
            end
        end
        out[#out + 1] = string.format("walk length     = %.1f m", total)
    end

    soft(function() Ext.Level.ReleasePath(path) end)
    Ext.IO.SaveFile("A11y/find_route_" .. tostring(tag or "now") .. ".txt",
                    table.concat(out, "\n"))
    Ext.Utils.Print("[find] route " .. tostring(tag) .. " -> find_route_" ..
                    tostring(tag or "now") .. ".txt")
    return true
end

--- The same question, waited out.
---
--- `BeginPathfindingImmediate` returns a path object with `SearchComplete = false`: despite
--- the name it starts the search rather than finishing it, and the engine works on it over
--- the following frames. So the path is held and looked at each tick until it settles, which
--- is also the honest shape for the layer to use later - a player pressing a key can be
--- answered a few frames afterwards, and must be told when the answer never comes.
function F.routeWait(x, z, y, tag, ladders)
    -- The character, from whichever half of the game this is running in: the client keeps it
    -- as ClientControl, the server answers `Osi.GetHostCharacter`. Movement is the server's
    -- business everywhere else in this layer, so pathfinding has to be tried from there too.
    local nav = _G.Nav
    local me = nav and soft(nav.me)
    if me == nil then
        local host = soft(function() return Osi.GetHostCharacter() end)
        if host ~= nil then me = soft(Ext.Entity.Get, host) end
    end
    if me == nil then Ext.Utils.Print("[find] no character") return nil end
    local p = soft(function() return me.Transform.Transform.Translate end)
    if p == nil then Ext.Utils.Print("[find] no position") return nil end
    local to = { x, y or p[2], z }

    local path = soft(function() return Ext.Level.BeginPathfindingImmediate(me, to) end)
    if path == nil then Ext.Utils.Print("[find] no path object") return nil end
    -- The defaults come back with ladders and portals off, which on a ship built of ladders
    -- would make a reachable place look unreachable. Set before the search settles.
    if ladders ~= false then
        soft(function() path.CanUseLadders = true end)
        soft(function() path.CanUsePortals = true end)
        soft(function() path.Climbing = true end)
    end

    local ticks = 0
    local id
    id = Ext.Events.Tick:Subscribe(function()
        ticks = ticks + 1
        local done = soft(function() return path.SearchComplete end)
        local nodes = soft(function() return path.Nodes end)
        local n = nodes and soft(function() return #nodes end) or 0
        if done ~= true and ticks < 240 then return end

        soft(function() Ext.Events.Tick:Unsubscribe(id) end)
        local function g(k) return str(soft(function() return path[k] end)) end
        local out = {
            "tag             = " .. tostring(tag),
            "waited ticks    = " .. ticks,
            string.format("straight line   = %.1f m",
                math.sqrt((to[1] - p[1]) ^ 2 + (to[3] - p[3]) ^ 2)),
            "SearchComplete  = " .. g("SearchComplete"),
            "GoalFound       = " .. g("GoalFound"),
            "ErrorCause      = " .. g("ErrorCause"),
            "ClosestCost     = " .. g("ClosestCost"),
            "Nodes           = " .. tostring(n),
        }
        local total, prev = 0, nil
        for i = 1, n do
            local nd = soft(function() return nodes[i] end)
            local q = soft(function() return nd.Position end)
            if q ~= nil then
                if prev ~= nil then
                    total = total + math.sqrt((q[1] - prev[1]) ^ 2 + (q[3] - prev[3]) ^ 2)
                end
                prev = q
                if i <= 14 or i > n - 3 then
                    out[#out + 1] = string.format("   [%2d] %.1f %.1f %.1f", i, q[1], q[2], q[3])
                end
            elseif i == 1 then
                local props = soft(function() return nd:GetAllProperties() end)
                if type(props) == "table" then
                    for k, v in pairs(props) do
                        out[#out + 1] = "   node." .. tostring(k) .. " = " .. str(v):sub(1, 90)
                    end
                end
            end
        end
        if total > 0 then out[#out + 1] = string.format("walk length     = %.1f m", total) end
        soft(function() Ext.Level.ReleasePath(path) end)
        Ext.IO.SaveFile("A11y/find_wait_" .. tostring(tag or "now") .. ".txt",
                        table.concat(out, "\n"))
        Ext.Utils.Print("[find] routeWait " .. tostring(tag) .. " done in " .. ticks .. " ticks")
    end)
    return true
end

Ext.Utils.Print("[find] ready: F.route / F.routeWait(x,z,y,tag)")
return F
