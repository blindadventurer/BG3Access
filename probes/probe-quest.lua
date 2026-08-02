-- Where does the story want me: markers, and whether they can be aimed at.
--
-- Today the objective is read out of the Minimap widget's *text*, and on the crash-site beach
-- the game writes nothing there - so the layer says "задача не видна" and the player has
-- nowhere to walk. The widget's model turns out to hold more than its text: a collection of
-- records carrying a `Guid` and `Hidden`, one per marker.
--
-- The question this answers is whether that Guid is an entity. If it is, the client ECS gives
-- a name (`DisplayName`) and a position (`Transform`), and a marker becomes exactly what the
-- scanner already handles: a thing with a direction, a distance and a name to step through.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-quest", "PQ")
--     Mods.BG3Access.PQ.markers()

local A, Pad, Nav = _G.A11y, _G.Pad, _G.Nav
local W = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

--- Every data record under a widget, with all of its properties - scalars and the names of
--- everything else, because a position would arrive as a structure and never print.
local function records(node, want)
    local out = {}
    local function rec(o, depth)
        if o == nil or depth > 20 or #out > 200 then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            local p = soft(function() return ch[i]:GetAllProperties() end)
            if type(p) == "table" and p.ActualWidth == nil and p.IsVisible == nil then
                -- data, not an element
                if want == nil or p[want] ~= nil then
                    local scal, other = {}, {}
                    for k, v in pairs(p) do
                        local t = type(v)
                        if t == "boolean" or t == "number" or t == "string" then
                            scal[#scal + 1] = tostring(k) .. "=" .. str(v)
                        else
                            other[#other + 1] = tostring(k) .. ":" .. t .. "=" .. str(v)
                        end
                    end
                    table.sort(scal) table.sort(other)
                    out[#out + 1] = { node = ch[i], scalars = table.concat(scal, " "),
                                      other = table.concat(other, " ") }
                end
            else
                rec(ch[i], depth + 1)
            end
        end
    end
    rec(node, 0)
    return out
end

--- The marker records of a widget, and what each Guid turns out to be.
function W.markers(widgetName)
    widgetName = widgetName or "Minimap"
    local ws = soft(Pad.findWidgets) or {}
    local node = nil
    for i = 1, #ws do
        if str(ws[i].name) == widgetName and ws[i].visible ~= false then node = ws[i].node end
    end
    if node == nil then
        Ext.Utils.Print("[quest] " .. widgetName .. " is not up")
        return nil
    end

    local recs = records(node, "Guid")
    local me = soft(function() return Nav.me() end)
    local mypos = nil
    if me ~= nil then mypos = soft(function() return me.Transform.Transform.Translate end) end

    local out = { widget = widgetName, count = #recs, rows = {},
                  me = mypos and (str(mypos[1]) .. "," .. str(mypos[2]) .. "," .. str(mypos[3])) }

    for i = 1, math.min(#recs, 60) do
        local r = recs[i]
        local guid = nil
        local p = soft(function() return r.node:GetAllProperties() end)
        if type(p) == "table" then guid = str(p.Guid) end

        local line = i .. ". " .. r.scalars
        if r.other ~= "" then line = line .. "  {" .. r.other .. "}" end

        -- The question the probe exists for.
        local e = guid and soft(Ext.Entity.Get, guid)
        if e ~= nil then
            local name = soft(function() return e.DisplayName.Name:Get() end)
            local pos = soft(function() return e.Transform.Transform.Translate end)
            line = line .. "  ENTITY name=" .. str(name)
            if pos ~= nil then
                line = line .. " pos=" .. str(pos[1]) .. "," .. str(pos[2]) .. "," .. str(pos[3])
                if mypos ~= nil then
                    local dx, dz = pos[1] - mypos[1], pos[3] - mypos[3]
                    line = line .. " dist=" .. string.format("%.1f", math.sqrt(dx * dx + dz * dz))
                end
            end
            local comps = soft(function() return e:GetAllComponents() end)
            if type(comps) == "table" then
                local names = {}
                for k in pairs(comps) do names[#names + 1] = tostring(k) end
                table.sort(names)
                line = line .. " comps=" .. #names .. " [" .. table.concat(names, ",") .. "]"
            end
        else
            line = line .. "  (no entity)"
        end
        out.rows[#out.rows + 1] = line
    end

    Ext.IO.SaveFile("A11y/quest_markers.txt",
        "widget=" .. widgetName .. " records=" .. #recs .. " me=" .. tostring(out.me) ..
        "\n" .. table.concat(out.rows, "\n"))
    Ext.Utils.Print("[quest] " .. #recs .. " marker records -> quest_markers.txt")
    return #recs
end

--- What the client itself knows about markers and quests, by component name.
---
--- `MapMarkerStyle` came back empty in session 3, but that was one name out of many, and the
--- registry lists them all.
function W.components(pattern)
    local all = soft(Ext.Entity.GetAllComponentNames) or soft(Ext.Entity.GetRegisteredComponentTypes)
    local lines = {}
    if type(all) == "table" then
        for _, n in ipairs(all) do
            local name = tostring(n)
            local low = name:lower()
            if pattern == nil or low:find(pattern) then
                local es = soft(Ext.Entity.GetAllEntitiesWithComponent, name)
                lines[#lines + 1] = name .. " -> " .. tostring(es and #es or "nil")
            end
        end
    end
    table.sort(lines)
    Ext.IO.SaveFile("A11y/quest_components.txt", table.concat(lines, "\n"))
    Ext.Utils.Print("[quest] components matching " .. tostring(pattern) .. ": " .. #lines)
    return #lines
end

--- Candidate component names, tried the way the binding actually spells them.
---
--- The registry lists C++ names (`ecl::markers::AvailablePortalComponent`) and the binding
--- takes short ones (`Transform`, `DisplayName`), so a name from the registry answers nil and
--- proves nothing. This tries every spelling of each candidate and reports what resolves.
function W.tryComponents(list)
    list = list or { "MapMarkerStyle", "AvailablePortal", "AvailablePortals",
                     "AvailablePortalsSingleton", "PortalCandidate", "markers::AvailablePortal",
                     "ShownTraderMapMarkerGuid", "Waypoint", "Journal", "QuestTracker",
                     "FlagCollection", "ProgressionMeta", "GameplayObscurity" }
    local lines = {}
    for _, n in ipairs(list) do
        for _, form in ipairs({ n, "ecl::" .. n, "eoc::" .. n, "esv::" .. n }) do
            local es = soft(Ext.Entity.GetAllEntitiesWithComponent, form)
            if es ~= nil then
                lines[#lines + 1] = form .. " -> " .. tostring(#es)
                if #es > 0 and #es < 60 then
                    for i = 1, math.min(#es, 8) do
                        local e = es[i]
                        local name = soft(function() return e.DisplayName.Name:Get() end)
                        local pos = soft(function() return e.Transform.Transform.Translate end)
                        lines[#lines + 1] = "     " .. str(name) ..
                            (pos and (" @" .. string.format("%.0f,%.0f", pos[1], pos[3])) or "")
                    end
                end
            end
        end
    end

    -- What the played character itself carries: the journal, if it is anywhere in the ECS,
    -- hangs off the player rather than off the world.
    local me = soft(function() return Nav.me() end)
    if me ~= nil then
        local comps = soft(function() return me:GetAllComponents() end)
        if type(comps) == "table" then
            local names = {}
            for k in pairs(comps) do names[#names + 1] = tostring(k) end
            table.sort(names)
            lines[#lines + 1] = "PLAYER components (" .. #names .. "): " ..
                                table.concat(names, ", ")
        end
    end

    Ext.IO.SaveFile("A11y/quest_try.txt", table.concat(lines, "\n"))
    Ext.Utils.Print("[quest] tryComponents -> quest_try.txt (" .. #lines .. " lines)")
    return #lines
end

--- Fog of war, as the map model keeps it.
---
--- The map and the minimap are built from two collections, and both are in the tree while the
--- minimap is - which it always is, so this needs no screen open:
---
---   * regions: `Guid`, `Hidden`, and `WorldPos` / `WorldSize` as structures;
---   * rooms:   `BuildingUuid`, `Floor`, `Border`, and **`RoomState`** - Shrouded for a place
---     that has never been seen.
---
--- If either carries a usable position, "where have I not been" becomes a direction and a
--- distance, which is the one question the beach could not answer.
local function tableOf(v)
    local t = type(v)
    if t ~= "table" and t ~= "userdata" then return str(v) end
    local parts = {}
    local ok = pcall(function()
        for k, vv in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. str(vv)
            if #parts > 8 then return end
        end
    end)
    if not ok or #parts == 0 then
        -- Numeric-indexed structures do not always answer to pairs.
        for i = 1, 4 do
            local e = soft(function() return v[i] end)
            if e == nil then break end
            parts[#parts + 1] = i .. "=" .. str(e)
        end
    end
    return "{" .. table.concat(parts, " ") .. "}"
end

function W.fog(widgetName)
    widgetName = widgetName or "Minimap"
    local ws = soft(Pad.findWidgets) or {}
    local node = nil
    for i = 1, #ws do
        if str(ws[i].name) == widgetName then node = ws[i].node end
    end
    if node == nil then Ext.Utils.Print("[quest] no " .. widgetName) return nil end

    local me = soft(function() return Nav.me() end)
    local mypos = me and soft(function() return me.Transform.Transform.Translate end)

    local rows, shapes = {}, {}
    local function rec(o, depth)
        if o == nil or depth > 20 or #rows > 400 then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            local p = soft(function() return ch[i]:GetAllProperties() end)
            if type(p) == "table" and p.ActualWidth == nil and p.IsVisible == nil then
                local keys = {}
                for k in pairs(p) do keys[#keys + 1] = tostring(k) end
                table.sort(keys)
                local shape = table.concat(keys, ",")
                shapes[shape] = (shapes[shape] or 0) + 1

                local line = {}
                for _, k in ipairs(keys) do
                    local v = p[k]
                    local t = type(v)
                    if t == "boolean" or t == "number" or t == "string" then
                        line[#line + 1] = k .. "=" .. str(v)
                    else
                        -- The structures are the whole point: a position would be one.
                        local live = soft(function() return ch[i]:GetProperty(k) end)
                        line[#line + 1] = k .. "=" .. tableOf(live ~= nil and live or v)
                    end
                end
                rows[#rows + 1] = table.concat(line, " ")
            else
                rec(ch[i], depth + 1)
            end
        end
    end
    rec(node, 0)

    local head = { "widget=" .. widgetName .. " records=" .. #rows }
    if mypos ~= nil then
        head[#head + 1] = string.format("me=%.1f,%.1f,%.1f", mypos[1], mypos[2], mypos[3])
    end
    for shape, n in pairs(shapes) do head[#head + 1] = "shape " .. n .. "x: " .. shape end
    Ext.IO.SaveFile("A11y/fog.txt", table.concat(head, "\n") .. "\n" ..
                    table.concat(rows, "\n"))
    Ext.Utils.Print("[quest] fog -> fog.txt (" .. #rows .. " records)")
    return #rows
end

--- The regions of the level, and whether they can be named and told apart.
---
--- The map's own fog turned out to be about interiors only - all 282 room records are
--- Shrouded and they belong to buildings - so the open world needs another handle on "where
--- have I not been". The regions are it, if two things hold: they carry something a player
--- would recognise as a name, and the game says which one the character is standing in. The
--- second is already visible on the player as `TriggerIsInsideOf`.
function W.regions()
    local ws = soft(Pad.findWidgets) or {}
    local node = nil
    for i = 1, #ws do
        if str(ws[i].name) == "Minimap" then node = ws[i].node end
    end
    if node == nil then Ext.Utils.Print("[quest] no Minimap") return nil end

    local me = soft(function() return Nav.me() end)
    local mypos = me and soft(function() return me.Transform.Transform.Translate end)
    local lines = {}

    if me ~= nil then
        local inside = soft(function() return me.TriggerIsInsideOf end)
        lines[#lines + 1] = "TriggerIsInsideOf: " .. str(inside)
        if inside ~= nil then
            local p = soft(function() return inside:GetAllProperties() end)
            if type(p) == "table" then
                for k, v in pairs(p) do lines[#lines + 1] = "   " .. tostring(k) .. "=" .. str(v) end
            end
            -- Whatever it holds, list it: a collection of triggers is the answer to "which
            -- region am I in", and that is what makes "not been there" recordable.
            for _, field in ipairs({ "Triggers", "Trigger", "Entities" }) do
                local coll = soft(function() return inside[field] end)
                if coll ~= nil then
                    lines[#lines + 1] = "   " .. field .. " -> " .. str(coll)
                    soft(function()
                        for i, t in ipairs(coll) do
                            lines[#lines + 1] = "      " .. i .. ": " .. str(t)
                        end
                    end)
                end
            end
        end
    end

    local seen, n = {}, 0
    local function rec(o, depth)
        if o == nil or depth > 20 or n > 40 then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            local p = soft(function() return ch[i]:GetAllProperties() end)
            if type(p) == "table" and p.Guid ~= nil and p.WorldPos ~= nil then
                local guid = str(p.Guid)
                if not seen[guid] then
                    seen[guid] = true
                    n = n + 1
                    local e = soft(Ext.Entity.Get, guid)
                    local parts = { n .. ". " .. guid:sub(1, 8) }
                    if e == nil then
                        parts[#parts + 1] = "(no entity)"
                    else
                        local pos = soft(function() return e.Transform.Transform.Translate end)
                        if pos ~= nil then
                            parts[#parts + 1] = string.format("pos=%.0f,%.0f", pos[1], pos[3])
                            if mypos ~= nil then
                                local dx, dz = pos[1] - mypos[1], pos[3] - mypos[3]
                                parts[#parts + 1] = string.format("d=%.0f", math.sqrt(dx * dx + dz * dz))
                            end
                        end
                        -- Everything that could be a name.
                        for _, comp in ipairs({ "Tag", "TriggerType", "TriggerContainer",
                                                "Uuid", "Level", "TriggerArea" }) do
                            local c = soft(function() return e[comp] end)
                            if c ~= nil then
                                local cp = soft(function() return c:GetAllProperties() end)
                                local bits = {}
                                if type(cp) == "table" then
                                    for k, v in pairs(cp) do
                                        local t = type(v)
                                        bits[#bits + 1] = tostring(k) .. "=" ..
                                            ((t == "table" or t == "userdata") and tableOf(v) or str(v))
                                    end
                                end
                                parts[#parts + 1] = comp .. "{" ..
                                    table.concat(bits, " "):sub(1, 220) .. "}"
                            end
                        end
                        local tmpl = soft(Ext.Template.GetTemplate, guid)
                        if tmpl ~= nil then
                            parts[#parts + 1] = "template=" ..
                                str(soft(function() return tmpl.Name end))
                        end
                    end
                    lines[#lines + 1] = table.concat(parts, " ")
                end
            else
                rec(ch[i], depth + 1)
            end
        end
    end
    rec(node, 0)

    Ext.IO.SaveFile("A11y/regions.txt", table.concat(lines, "\n"))
    Ext.Utils.Print("[quest] regions -> regions.txt (" .. n .. " sampled)")
    return n
end

Ext.Utils.Print("[quest] probe-quest ready: PQ.markers('Minimap') / PQ.fog() / PQ.regions()")
return W
