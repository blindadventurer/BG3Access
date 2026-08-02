-- Where have we not been, asked of the engine rather than of a list we keep ourselves.
--
-- The layer's "неизведанное" is bookkeeping: it remembers the map's region anchors and crosses
-- off the ones the character has stood near. That is honest but blind - it knows nothing about
-- ground, walls or water, so it points at a region across a ravine exactly as confidently as
-- at one down the path.
--
-- The game must know better, because it draws fog on the minimap and it paths characters
-- around obstacles. Two questions, and they have different answers:
--
--   1. Is exploration - the fog - readable at all? (F5 said the map's own records are useless:
--      282 rooms all `Shrouded` from minute one, 136 regions all `Hidden=false`.) What has not
--      been looked at is whether the **client** carries a fog component or a reveal mask
--      anywhere else, and whether the minimap widget holds the texture it draws from.
--
--   2. Is *walkable* readable? That is a different and possibly better question. A blind player
--      does not need to know what the party has seen; they need to know where they can go. The
--      picking helper's `Inner` carries an `AiGridTile` (F8), and pathfinding answered in 19 ms
--      (E7) - so "is there a path from here to a point 40 m that way" may be askable directly,
--      which would turn exploration from a list of remembered anchors into a real sonar.
--
-- This probe only looks. It moves nobody.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-fog", "PF")
--     Mods.BG3Access.PF.all()

local A, Pad, Nav = _G.A11y, _G.Pad, _G.Nav
local W = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

-- What counts as a lead, by name. Kept broad on purpose: the point of a sweep is to find the
-- word the engine actually uses, not to confirm the one we guessed.
local WORDS = { "fog", "explor", "discover", "reveal", "shroud", "unseen", "visib", "seen",
                "minimap", "aigrid", "grid", "walkab", "traver", "region", "mask" }

local function interesting(name)
    local low = tostring(name):lower()
    for i = 1, #WORDS do
        if low:find(WORDS[i], 1, true) then return WORDS[i] end
    end
    return nil
end

--- Every name the extender exposes on a table, filtered to the leads.
local function names(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        local hit = interesting(k)
        if hit ~= nil then out[#out + 1] = tostring(k) .. " (" .. type(v) .. ")" end
    end
    table.sort(out)
    return out
end

--- 1. Does anything in the extender's own surface even mention fog or exploration.
function W.api()
    local out = {}
    for _, mod in ipairs({ "Level", "ClientUI", "Entity", "Utils", "Vars", "Resource" }) do
        local t = soft(function() return Ext[mod] end)
        local hits = names(t)
        if #hits > 0 then out[mod] = hits end
        _P("[fog] Ext." .. mod .. ": " .. (#hits > 0 and table.concat(hits, ", ") or "-"))
    end

    -- Every component the client registers, filtered the same way. This is the list that
    -- matters most: a fog component would be here under a name nobody guessed.
    local all = soft(Ext.Entity.GetAllComponentNames) or soft(Ext.Entity.GetRegisteredComponentTypes)
    local comps = {}
    if type(all) == "table" then
        for i = 1, #all do
            if interesting(all[i]) then comps[#comps + 1] = tostring(all[i]) end
        end
    end
    out.components = comps
    _P("[fog] components (" .. tostring(type(all) == "table" and #all or "?") .. " total): " ..
       (#comps > 0 and table.concat(comps, ", ") or "-"))
    A.write("fog_api", out)
    return out
end

--- 2. What the world cursor's trace result actually holds.
---
--- F8 established that the cursor cannot be *aimed* from Lua - both writable fields are
--- mirrors and the ray is built from the camera. But `Inner` is the result of that ray, and
--- if it names an AI grid tile then the grid is reachable from Lua, which is the whole
--- question for a sonar.
function W.cursor()
    local ph = soft(Ext.ClientUI.GetPickingHelper, 1)
    if ph == nil then _P("[fog] picking helper: nil") return nil end
    local out = { fields = {} }
    for _, f in ipairs({ "Inner", "Selection", "WindowCursorPos", "PickingDirection",
                         "SelectableObjects", "TargetOverride" }) do
        local v = soft(function() return ph[f] end)
        out.fields[f] = (v ~= nil) and type(v) or "nil"
    end

    local inner = soft(function() return ph.Inner end)
    if inner ~= nil then
        local got = {}
        -- Named rather than iterated: these are userdata, and pairs() on them is empty even
        -- where the fields read fine one at a time.
        for _, f in ipairs({ "Position", "WorldPosition", "PlaceablePosition", "AiGridTile",
                             "AiGridTileValue", "Normal", "Entity", "PickingDistance" }) do
            local v = soft(function() return inner[f] end)
            if v ~= nil then got[f] = str(v) end
        end
        out.inner = got
        for k, v in pairs(got) do _P("[fog] Inner." .. k .. " = " .. v) end
    end
    A.write("fog_cursor", out)
    return out
end

--- 3. Can the engine be asked whether a point is reachable.
---
--- The answer decides whether exploration can ever be more than remembered anchors. Points are
--- taken in a fan around the character at three distances; nothing is walked to, only asked
--- about. What matters in the output is not just ok/found but **whether the answer differs
--- between directions** - a call that says yes to every point, including the sea, is not an
--- answer, it is the same trap `FindValidPosition` turned out to be.
function W.paths(step)
    local me = Nav and Nav.me()
    local pos = me and Nav.positionOf(me)
    if pos == nil then _P("[fog] no character") return nil end
    step = step or 30

    local begin = soft(function() return Ext.Level.BeginPathfindingImmediate end)
    if begin == nil then
        _P("[fog] Ext.Level.BeginPathfindingImmediate is not on the client - server only")
        return nil
    end

    local out = { from = pos, rays = {} }
    for h = 0, 11 do
        local ang = (h / 12) * 2 * math.pi
        for _, d in ipairs({ step, step * 2, step * 4 }) do
            local target = { pos[1] + math.sin(ang) * d, pos[2], pos[3] + math.cos(ang) * d }
            local t0 = soft(Ext.Utils.MonotonicTime) or 0
            local p = soft(Ext.Level.BeginPathfindingImmediate, me, target)
            local found, kind = nil, nil
            if p ~= nil then
                found = soft(Ext.Level.FindPath, p)
                kind = type(found)
                soft(Ext.Level.ReleasePath, p)
            end
            out.rays[#out.rays + 1] = { hour = h, dist = d, began = p ~= nil,
                                        found = str(found), kind = kind,
                                        ms = (soft(Ext.Utils.MonotonicTime) or 0) - t0 }
        end
    end

    local yes, no = 0, 0
    for _, r in ipairs(out.rays) do
        if r.found == "true" then yes = yes + 1 elseif r.found == "false" then no = no + 1 end
    end
    _P("[fog] paths: " .. #out.rays .. " asked, true=" .. yes .. " false=" .. no ..
       " (anything else means FindPath does not answer in booleans - read the file)")
    A.write("fog_paths", out)
    return out
end

--- 4. Does the minimap widget carry the fog it draws.
---
--- The anchors already come off this widget (Nav.anchorsScan), so the tree is known to be
--- readable. What is asked here is whether any record in it says *discovered* - which would be
--- the shortest possible answer to "where have we not been".
function W.minimap()
    if Pad == nil then _P("[fog] no Pad") return nil end
    local ws = soft(Pad.findWidgets) or {}
    local node = nil
    for i = 1, #ws do
        if tostring(ws[i].name):find("Minimap", 1, true) then node = ws[i].node end
    end
    if node == nil then _P("[fog] no minimap widget") return nil end

    local out, budget = {}, { n = 4000 }
    local function rec(o, depth)
        if o == nil or depth > 20 or budget.n <= 0 then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            budget.n = budget.n - 1
            if budget.n <= 0 then return end
            local p = soft(function() return ch[i]:GetAllProperties() end)
            if type(p) == "table" then
                for k, v in pairs(p) do
                    if interesting(k) then
                        local line = tostring(k) .. "=" .. str(v) .. " (" .. type(v) .. ")"
                        out[line] = (out[line] or 0) + 1
                    end
                end
                if p.ActualWidth ~= nil then rec(ch[i], depth + 1) end
            end
        end
    end
    rec(node, 0)

    local lines = {}
    for k, n in pairs(out) do lines[#lines + 1] = k .. " x" .. n end
    table.sort(lines)
    for i = 1, math.min(#lines, 40) do _P("[fog] map: " .. lines[i]) end
    _P("[fog] map: " .. #lines .. " distinct properties matched")
    A.write("fog_minimap", lines)
    return lines
end

function W.all()
    W.api()
    W.cursor()
    W.minimap()
    W.paths()
    _P("[fog] done - four files written")
end

_P("[probe-fog] loaded. PF.all() / PF.api() / PF.cursor() / PF.paths(30) / PF.minimap()")
return W
