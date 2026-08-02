-- Does the game itself know which objects matter?
--
-- The "ориентиры" category is a guess dressed as a category: a list of Russian word stems, and
-- anything whose name contains one is called a landmark. It works and it is a lie - it found a
-- rucksack because "рюкзак" contains "юк". The player's question behind it is much better than
-- the implementation: **the Ancient Door is where Shadowheart happens**, so if the game marks
-- the objects that carry the story, that mark is the category, and no word list is needed.
--
-- Four places such a mark could live, in the order they are worth checking:
--
--   1. A **tag**. BG3 entities carry `Tag` - a list of tag uuids - and tags resolve through
--      `Ext.StaticData.Get(uuid, "Tag")` to a name someone wrote. Story objects are tagged for
--      the scripts that fire off them, so the tag names are as close to "this matters" as the
--      data gets.
--   2. A **component nobody guessed**. The sweep prints every registered component whose name
--      contains poi / interest / important / story / quest / marker / highlight.
--   3. **What the game highlights.** The right stick click is `ShowWorldTooltips`: hold it and
--      the game names every object nearby it considers worth pointing at. That list is exactly
--      the category being asked for - if holding it changes anything readable, that is the
--      answer.
--   4. **Rarity.** Whatever flags a door as special, the barrel next to it will not have. So
--      the components of a thing the player names are compared against how common each one is
--      across everything standing around: what is rare is what distinguishes.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-poi", "PP")
--     Mods.BG3Access.PP.words()
--     Mods.BG3Access.PP.dump("двер")        -- everything about the nearest matching thing
--     Mods.BG3Access.PP.rare("двер")        -- what it has that its neighbours do not
--     Mods.BG3Access.PP.mark()  -- then hold the world-tooltips button -  Mods.BG3Access.PP.diff()

local A, Pad, Nav = _G.A11y, _G.Pad, _G.Nav
local W = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

local WORDS = { "poi", "interest", "import", "story", "quest", "marker", "highlight",
                "notable", "landmark", "objective", "tooltip", "waypoint", "trigger",
                "tag", "flag" }

--- 2. Every component the client registers whose name hints at "this one matters".
function W.words()
    local all = soft(Ext.Entity.GetAllComponentNames)
             or soft(Ext.Entity.GetRegisteredComponentTypes)
    if type(all) ~= "table" then _P("[poi] no component list") return nil end
    local hits = {}
    for i = 1, #all do
        local low = tostring(all[i]):lower()
        for _, wd in ipairs(WORDS) do
            if low:find(wd, 1, true) then hits[#hits + 1] = tostring(all[i]) break end
        end
    end
    table.sort(hits)
    _P("[poi] " .. #all .. " components registered, " .. #hits .. " look relevant:")
    for i = 1, #hits do _P("[poi]   " .. hits[i]) end
    A.write("poi_words", hits)
    return hits
end

--- The nearest scanned thing whose name contains a fragment. Everything below works on one
--- object at a time, because the answer is a comparison, not a census.
local function find(part)
    local list = Nav.list
    if list == nil or #list == 0 then list = Nav.scan() or {} end
    for i = 1, #list do
        if tostring(list[i].name):find(part, 1, true) then return list[i] end
    end
    return nil
end
W.find = find

local function compsOf(e)
    local names = soft(function() return e:GetAllComponentNames() end)
    if type(names) ~= "table" then return {} end
    local out = {}
    for i = 1, #names do out[#out + 1] = tostring(names[i]) end
    table.sort(out)
    return out
end
W.compsOf = compsOf

--- 1 and 4 for one object: what it is made of, and what its tags are called.
function W.dump(part)
    local it = find(part or "")
    if it == nil then _P("[poi] nothing named like that nearby") return nil end
    local comps = compsOf(it.entity)
    _P("[poi] " .. it.name .. ", " .. string.format("%.0f м", it.dist) .. ", " ..
       #comps .. " components")
    _P("[poi]   " .. table.concat(comps, " "))

    local out = { name = it.name, dist = it.dist, comps = comps, tags = {} }
    -- Tags arrive as uuids and mean nothing until resolved; the resource behind each one
    -- carries the name a designer typed, which is the readable part.
    for _, field in ipairs({ "Tag", "Tags", "ServerTags" }) do
        local t = soft(function() return it.entity[field].Tags end)
                  or soft(function() return it.entity[field] end)
        local n = tonumber(soft(function() return #t end)) or 0
        for i = 1, n do
            local id = str(soft(function() return t[i] end))
            local res = soft(Ext.StaticData.Get, id, "Tag")
            local nm = res and (soft(function() return res.Name end) or
                                soft(function() return res.DisplayName end))
            out.tags[#out.tags + 1] = tostring(nm or id)
        end
    end
    if #out.tags > 0 then
        _P("[poi]   tags: " .. table.concat(out.tags, ", "))
    else
        _P("[poi]   tags: none readable")
    end
    A.write("poi_dump", out)
    return out
end

--- 4. What this thing has that the things around it do not.
---
--- The census is capped: a hundred entities is plenty to tell a common component from a rare
--- one, and every one of them costs a component-list lookup.
function W.rare(part, cap)
    local it = find(part or "")
    if it == nil then _P("[poi] nothing named like that nearby") return nil end
    local list = Nav.list or {}
    cap = math.min(cap or 100, #list)

    local freq, seen = {}, 0
    for i = 1, cap do
        local e = list[i].entity
        if e ~= nil then
            seen = seen + 1
            for _, c in ipairs(compsOf(e)) do freq[c] = (freq[c] or 0) + 1 end
        end
    end
    if seen == 0 then _P("[poi] nothing to compare against") return nil end

    local mine, rare = compsOf(it.entity), {}
    for _, c in ipairs(mine) do
        local share = (freq[c] or 0) / seen
        if share <= 0.2 then
            rare[#rare + 1] = c .. " (" .. tostring(freq[c] or 0) .. "/" .. seen .. ")"
        end
    end
    _P("[poi] " .. it.name .. ": " .. #rare .. " components rarer than one in five, of " ..
       #mine .. " total")
    for i = 1, #rare do _P("[poi]   " .. rare[i]) end
    A.write("poi_rare", { name = it.name, rare = rare, sampled = seen })
    return rare
end

--- 3. Whether holding the world-tooltips button changes anything the layer can read.
---
--- Called once before, then again while the button is held. Compares both the component sets
--- of everything nearby and the widget tree, because the highlight could be either - a flag on
--- the entities or a panel full of names.
W.snap = nil

local function snapshot()
    local out = { comps = {}, widgets = {} }
    local list = Nav.list or {}
    for i = 1, math.min(#list, 60) do
        local it = list[i]
        out.comps[tostring(it.name) .. "#" .. i] = table.concat(compsOf(it.entity), " ")
    end
    local ws = soft(Pad.findWidgets) or {}
    for i = 1, #ws do
        if ws[i].visible ~= false then
            out.widgets[tostring(ws[i].name)] = true
        end
    end
    return out
end

function W.mark()
    Nav.scan()
    W.snap = snapshot()
    _P("[poi] marked. Now hold the world-tooltips button (right stick click) and call PP.diff()")
    return true
end

function W.diff()
    if W.snap == nil then _P("[poi] call PP.mark() first") return nil end
    local now = snapshot()
    local changed, appeared = {}, {}
    for k, v in pairs(now.comps) do
        local was = W.snap.comps[k]
        if was ~= nil and was ~= v then changed[#changed + 1] = k end
    end
    for k in pairs(now.widgets) do
        if W.snap.widgets[k] == nil then appeared[#appeared + 1] = k end
    end
    table.sort(changed) table.sort(appeared)
    _P("[poi] entities whose components changed: " ..
       (#changed > 0 and table.concat(changed, ", ") or "none"))
    _P("[poi] widgets that appeared: " ..
       (#appeared > 0 and table.concat(appeared, ", ") or "none"))
    A.write("poi_diff", { changed = changed, appeared = appeared })
    return changed, appeared
end

_P("[probe-poi] loaded. PP.words() / PP.dump('двер') / PP.rare('двер') / PP.mark() + PP.diff()")
return W
