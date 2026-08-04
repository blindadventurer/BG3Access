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
function F.pathTo(x, z, y)
    local nav = _G.Nav
    local me = nav and soft(nav.me)
    if me == nil then Ext.Utils.Print("[find] no character") return nil end
    local p = soft(function() return me.Transform.Transform.Translate end)
    if p == nil then return nil end

    local out = { string.format("from x=%.1f y=%.1f z=%.1f", p[1], p[2], p[3]),
                  string.format("to   x=%.1f y=%.1f z=%.1f", x, y or p[2], z) }
    local id = soft(function()
        return Ext.Level.BeginPathfindingImmediate(
            { p[1], p[2], p[3] }, { x, y or p[2], z })
    end)
    out[#out + 1] = "BeginPathfindingImmediate -> " .. str(id)
    if id ~= nil then
        local path = soft(function() return Ext.Level.GetPathById(id) end)
        out[#out + 1] = "GetPathById -> " .. type(path)
        if type(path) == "userdata" or type(path) == "table" then
            local props = soft(function() return path:GetAllProperties() end)
            if type(props) ~= "table" then props = path end
            for k, v in pairs(props) do
                out[#out + 1] = "   " .. tostring(k) .. " = " .. str(v):sub(1, 120)
            end
        end
        soft(function() Ext.Level.ReleasePath(id) end)
    end
    -- The other spelling, in case the immediate form is not the one this build wants.
    local p2 = soft(function() return Ext.Level.FindPath({ p[1], p[2], p[3] }, { x, y or p[2], z }) end)
    out[#out + 1] = "FindPath -> " .. type(p2) .. " " .. str(p2):sub(1, 160)

    Ext.IO.SaveFile("A11y/find_path.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[find] path -> find_path.txt")
    return true
end

Ext.Utils.Print("[find] ready: F.templates(p) / F.entities(p) / F.catalogue() / F.pathTo(x,z)")
return F
