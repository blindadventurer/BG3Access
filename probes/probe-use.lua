-- Finding the thing a key is used on.
--
-- The scanner answers "what stands around me". It does not answer the question a player
-- actually has in front of Shadowheart's pod: **which of these can I do something with, and
-- what does the game say happens if I try**. Three things in the layer stand between the two,
-- and each is a guess until it is measured:
--
--   1. `Nav.scan` drops every entity whose DisplayName does not resolve (`if name ~= nil`).
--      A console, a panel, a rune plate may well be exactly that - so an object the player
--      is looking for can be standing two metres away and be absent from every category.
--   2. Nothing reads a lock. The engine knows a thing is locked and which key opens it; the
--      layer never asks, so "заперто" and "ключ у вас есть" are sentences it cannot say.
--   3. The game's own interactable cycle - `GetPickingHelper(1).SelectableObjects` - is used
--      only for combat targets. If it is populated out of combat it is a better list than
--      anything assembled from names, because it contains exactly what can be acted on.
--
-- Console output is ANSI, so nothing Russian is printed here: names go to the JSON files and
-- the console gets counts, flags and component names, which are ASCII.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-use", "PU")
--     Mods.BG3Access.PU.words()      -- which components this build has for locks and uses
--     Mods.BG3Access.PU.pick()       -- the game's own interactable cycle, out of combat
--     Mods.BG3Access.PU.near(25)     -- everything here, including what the scanner drops
--     Mods.BG3Access.PU.dump(3)      -- entry 3 of that list, every field of it
--     Mods.BG3Access.PU.keys()       -- what the character carries, with uuids
--     Mods.BG3Access.PU.cursor()     -- what the game says under the world cursor now

local A, Pad, Nav = _G.A11y, _G.Pad, _G.Nav
local W = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

--- `A.write` flattens at depth 3 and the answer here is deeper than that: a use action is a
--- list inside a component inside an entity, and three levels down it arrived as the string
--- "<depth>". Same shape, its own limit.
local function plain(v, d)
    d = d or 0
    local t = type(v)
    if t == "nil" or t == "boolean" or t == "number" or t == "string" then return v end
    if d > 8 then return "<depth>" end
    if t == "table" then
        local o, n = {}, 0
        for k, vv in pairs(v) do
            n = n + 1
            if n > 2000 then o["..."] = "truncated" break end
            o[tostring(k)] = plain(vv, d + 1)
        end
        return o
    end
    return tostring(v)
end

local function write(name, data)
    local body = soft(Ext.Json.Stringify, plain(data), { Beautify = true, MaxDepth = 24 })
    soft(Ext.IO.SaveFile, "A11y/" .. name .. ".json", body or "{}")
    _P("[use] wrote " .. name .. ".json")
end
W.write = write

-- What a lock, a key or a use could plausibly be called. Deliberately loose: this is the one
-- place where a false positive costs a line of output and a false negative costs a session.
local WORDS = { "lock", "key", "use", "interact", "door", "trap", "activat", "switch",
                "lever", "button", "trigger", "consum", "openable", "pick", "unlock",
                "container", "owner", "action" }

local function interesting(name)
    local low = name:lower()
    for i = 1, #WORDS do
        if low:find(WORDS[i], 1, true) then return true end
    end
    return false
end

local function compsOf(e)
    local names = soft(function() return e:GetAllComponentNames() end)
    if type(names) ~= "table" then return {} end
    local out = {}
    for i = 1, #names do out[#out + 1] = tostring(names[i]) end
    table.sort(out)
    return out
end
W.compsOf = compsOf

--- The name a component is reached by, from the name the engine lists it under.
---
--- `GetAllComponentNames` answers in the engine's own spelling - `eoc::item_template::
--- UseActionComponent` - and that string is not what indexes an entity: `e[full]` is nil for
--- every one of them, which is why the first dump came back with no fields at all. The Lua
--- accessor is the last namespace segment without its `Component` suffix, so it is derived
--- rather than guessed one name at a time.
local function shortName(full)
    local tail = full:match("([^:]+)$") or full
    local short = tail:gsub("Component$", "")
    if short == "" then return nil end
    return short
end
W.shortName = shortName

local function hits(comps)
    local out = {}
    for i = 1, #comps do
        if interesting(comps[i]) then out[#out + 1] = comps[i] end
    end
    return out
end

--- The field names of an engine object, without guessing any of them.
---
--- `GetProperty` on a name this build does not have throws and logs, at 150x the cost of a
--- hit (E5), so the names are asked for rather than tried: the type registry knows them, and
--- iterating the object itself is the fallback where it does not.
local function memberNames(o)
    local t = soft(Ext.Types.GetObjectType, o)
    local info = t and soft(Ext.Types.GetTypeInfo, t)
    local m = info and soft(function() return info.Members end)
    local out = {}
    if type(m) == "table" then
        for k in pairs(m) do out[#out + 1] = tostring(k) end
    else
        local ok = pcall(function()
            for k in pairs(o) do out[#out + 1] = tostring(k) end
        end)
        if not ok then return nil end
    end
    table.sort(out)
    return out
end
W.memberNames = memberNames

local function fieldsOf(o)
    local s = soft(Ext.Types.Serialize, o)
    if type(s) == "table" then return s end
    local names = memberNames(o)
    if names == nil then return str(o) end
    local out = {}
    for _, k in ipairs(names) do out[k] = str(soft(function() return o[k] end)) end
    return out
end
W.fieldsOf = fieldsOf

-- 1. what this build even has ---------------------------------------------------------

function W.words()
    local all = soft(Ext.Entity.GetAllComponentNames)
             or soft(Ext.Entity.GetRegisteredComponentTypes)
    if type(all) ~= "table" then _P("[use] no component list") return nil end
    local out = {}
    for i = 1, #all do
        local n = tostring(all[i])
        if interesting(n) then out[#out + 1] = n end
    end
    table.sort(out)
    _P("[use] " .. #all .. " components registered, " .. #out .. " match:")
    for i = 1, #out do _P("[use]   " .. out[i]) end
    A.write("use_words", out)
    return out
end

-- 2. the game's own list of what can be acted on ---------------------------------------

local function distTo(e, pos)
    local p = Nav.positionOf(e)
    if p == nil or pos == nil then return nil end
    local dx, dz = p[1] - pos[1], p[3] - pos[3]
    return math.sqrt(dx * dx + dz * dz)
end

function W.pick()
    local me = Nav.me()
    local pos = me and Nav.positionOf(me)
    local out = { helpers = {} }

    for id = 0, 2 do
        local ph = soft(Ext.ClientUI.GetPickingHelper, id)
        if ph ~= nil then
            local rec = { id = id, type = str(soft(Ext.Types.GetObjectType, ph)),
                          members = memberNames(ph), objects = {} }

            local sel = soft(function() return ph.Selection end)
            if sel ~= nil then
                rec.selMembers = memberNames(sel)
                local e = soft(function() return sel.field_0_Entity end)
                if e ~= nil then
                    rec.selected = Nav.nameOf(e)
                    rec.selectedDist = distTo(e, pos)
                    rec.selectedComps = hits(compsOf(e))
                end
            end

            local objs = soft(function() return ph.SelectableObjects end)
            local n = tonumber(soft(function() return #objs end)) or 0
            rec.count = n
            for i = 1, math.min(n, 40) do
                local o = soft(function() return objs[i] end)
                -- An element may be the entity itself or a struct holding one. Both are tried
                -- and whichever names something wins.
                local e = soft(function() return o.field_0_Entity end)
                if e == nil or Nav.nameOf(e) == nil then
                    if Nav.nameOf(o) ~= nil then e = o end
                end
                rec.objects[#rec.objects + 1] = {
                    name = e and Nav.nameOf(e) or nil,
                    dist = e and distTo(e, pos) or nil,
                    comps = e and hits(compsOf(e)) or nil,
                    raw = (e == nil) and str(o) or nil,
                }
            end
            _P("[use] picking helper " .. id .. ": " .. n .. " selectable, selection=" ..
               tostring(rec.selected ~= nil))
            out.helpers[#out.helpers + 1] = rec
        end
    end

    if #out.helpers == 0 then _P("[use] no picking helper answered") end
    A.write("use_pick", out)
    return out
end

-- 3. everything standing here, including what the scanner throws away -------------------

W.last = {}

function W.near(radius)
    radius = radius or 25
    local me = Nav.me()
    local pos = me and Nav.positionOf(me)
    if pos == nil then _P("[use] no character") return nil end

    local list = soft(Ext.Entity.GetEntitiesAroundPosition, pos, radius)
    if type(list) ~= "table" then _P("[use] sweep failed") return nil end

    local out = {}
    for i = 1, #list do
        local e = list[i]
        local d = distTo(e, pos)
        if d ~= nil and d <= radius and d > 0.3 then
            local comps = compsOf(e)
            local hit = hits(comps)
            local name = Nav.nameOf(e)
            -- Named things are the scanner's world; the unnamed ones with a usable-looking
            -- component are precisely what it cannot see, and the reason for this probe.
            if name ~= nil or #hit > 0 then
                out[#out + 1] = { entity = e, name = name, dist = d, total = #comps, hit = hit,
                                  uuid = soft(function() return e.Uuid.EntityUuid end) }
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    W.last = out

    local named, blind = 0, 0
    local rows = {}
    for i = 1, #out do
        local it = out[i]
        if it.name ~= nil then named = named + 1 else blind = blind + 1 end
        rows[#rows + 1] = { i = i, name = it.name, dist = it.dist, uuid = it.uuid,
                            total = it.total, hit = it.hit }
        if i <= 60 then
            _P(string.format("[use] %2d %6.1fm %-6s n=%-3d %s", i, it.dist,
               it.name and "named" or "NONAME", it.total, table.concat(it.hit, " ")))
        end
    end
    _P("[use] " .. #out .. " within " .. radius .. " m: " .. named .. " named, " ..
       blind .. " the scanner drops")
    A.write("use_near", { radius = radius, at = pos, rows = rows })
    return out
end

--- One entry of the last sweep, in full: every component, every field of the ones that could
--- carry a lock, and the tags, which are how the story marks its own objects.
function W.dump(i)
    local it = W.last[i or 1]
    if it == nil then _P("[use] no entry " .. tostring(i) .. " - run PU.near() first") return nil end
    local e = it.entity
    local comps = compsOf(e)
    local out = { name = it.name, dist = it.dist, uuid = it.uuid, comps = comps,
                  fields = {}, tags = {} }

    for _, c in ipairs(comps) do
        if interesting(c) then
            local short = shortName(c)
            local comp = short and soft(function() return e[short] end)
            if comp ~= nil then
                out.fields[short] = fieldsOf(comp)
            elseif short ~= nil then
                out.fields[short] = "<not reachable by that name>"
            end
        end
    end
    -- Not "interesting" by word, but the two that name a thing across a save: the template it
    -- was made from, and whatever the engine files under Data.
    for _, extra in ipairs({ "OriginalTemplate", "Data", "ActionType", "Icon" }) do
        local comp = soft(function() return e[extra] end)
        if comp ~= nil and out.fields[extra] == nil then out.fields[extra] = fieldsOf(comp) end
    end

    for _, field in ipairs({ "Tag", "Tags", "ServerTags" }) do
        local t = soft(function() return e[field].Tags end) or soft(function() return e[field] end)
        local n = tonumber(soft(function() return #t end)) or 0
        for k = 1, n do
            local id = str(soft(function() return t[k] end))
            local res = soft(Ext.StaticData.Get, id, "Tag")
            local nm = res and (soft(function() return res.Name end) or
                                soft(function() return res.DisplayName end))
            out.tags[#out.tags + 1] = tostring(nm or id)
        end
    end

    _P("[use] entry " .. tostring(i) .. ": " .. #comps .. " components, " ..
       tostring(it.uuid))
    _P("[use]   " .. table.concat(comps, " "))
    write("use_dump", out)
    return out
end

--- What the game says can be done with a thing, and whether it is locked.
---
--- This is the readout the layer is missing: `UseAction.UseActions` is the object's own list of
--- verbs, `Lock` is why one of them will be refused, and `Key` on an item in the pack is what
--- lifts the refusal. Asked of every entry of the last sweep at once, because the question in
--- front of a pod is not "what about this one" but "which of these forty".
function W.actions(radius)
    if #W.last == 0 then W.near(radius) end
    local out = {}
    for i = 1, #W.last do
        local it = W.last[i]
        local e = it.entity
        local ua = soft(function() return e.UseAction end)
        local lock = soft(function() return e.Lock end)
        local key = soft(function() return e.Key end)
        if ua ~= nil or lock ~= nil or key ~= nil then
            out[#out + 1] = { i = i, name = it.name, dist = it.dist, uuid = it.uuid,
                              use = ua and fieldsOf(ua) or nil,
                              lock = lock and fieldsOf(lock) or nil,
                              key = key and fieldsOf(key) or nil }
            _P(string.format("[use] %2d %6.1fm use=%s lock=%s key=%s", i, it.dist,
               tostring(ua ~= nil), tostring(lock ~= nil), tostring(key ~= nil)))
        end
    end
    write("use_actions", out)
    return out
end

-- 4. what the character carries ---------------------------------------------------------

--- The inventory, with uuids and template-ish fields, so a key can be matched to a lock.
---
--- **Recursive, and that is the finding.** The flat reading showed ten items and no key at all,
--- because BG3 files keys into the keychain (`OBJ_Keychain`) automatically - so the thing the
--- player is carrying sits one container down, where `Nav.contentsOf` never looks. A pouch, a
--- backpack and a keychain are all the same shape, so the descent is general rather than a
--- special case for keys.
function W.keys(depth)
    local me = Nav.me()
    if me == nil then _P("[use] no character") return nil end
    local out = {}
    W.collect(me, out, 0, depth or 3)
    _P("[use] inventory: " .. #out .. " items down to depth " .. tostring(depth or 3))
    write("use_keys", out)
    return out
end

function W.collect(holder, out, level, maxLevel)
    local items = Nav.contentsOf(holder)
    if items == nil then return end
    for i = 1, #items do
        local e = items[i].entity
        local rec = { level = level, slot = items[i].slot, name = items[i].name,
                      uuid = e and soft(function() return e.Uuid.EntityUuid end) or nil }
        if e ~= nil then
            rec.hit = hits(compsOf(e))
            -- The half of the pair that lives in the pack. A lock names the key it wants by
            -- id (`Lock.Key_M`); this is where that id can be matched, which is the whole
            -- difference between "заперто" and "заперто, ключ у вас есть".
            local key = soft(function() return e.Key end)
            if key ~= nil then rec.key = fieldsOf(key) end
            local data = soft(function() return e.Data end)
            if data ~= nil then rec.stats = soft(function() return data.StatsId end) end
        end
        out[#out + 1] = rec
        if e ~= nil and level < maxLevel and
           soft(function() return e.InventoryOwner end) ~= nil then
            W.collect(e, out, level + 1, maxLevel)
        end
    end
end

--- What stands next to entry `i`, nearest first.
---
--- The scanner measures everything from the player, and that is the wrong origin for the
--- question actually being asked in front of a row of pods: not "how far is this from me" but
--- "which of these belongs to her". Two capsules a metre apart are indistinguishable from
--- where the player stands and obvious from where the prisoner is.
function W.beside(i, radius)
    local it = W.last[i or 1]
    if it == nil then _P("[use] no entry " .. tostring(i) .. " - run PU.near() first") return nil end
    radius = radius or 6
    local at = Nav.positionOf(it.entity)
    if at == nil then _P("[use] entry has no position") return nil end

    local out = {}
    for k = 1, #W.last do
        if k ~= i then
            local d = distTo(W.last[k].entity, at)
            if d ~= nil and d <= radius then
                out[#out + 1] = { i = k, name = W.last[k].name, d = d,
                                  use = soft(function() return W.last[k].entity.UseAction end) ~= nil }
            end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    for k = 1, #out do
        _P(string.format("[use]   %2d at %4.1fm  use=%s", out[k].i, out[k].d, tostring(out[k].use)))
    end
    write("use_beside", { of = i, name = it.name, radius = radius, rows = out })
    return out
end

--- Every key in the level, and every lock, asked of the engine rather than of a container.
---
--- Walking the pack found nothing: the keychain reads empty on the client, which is either a
--- replication gap or a key that is somewhere else entirely, and those two need telling apart.
--- `GetAllEntitiesWithComponent` answers without caring where a thing is stored - so a key in
--- a nested pouch, on a corpse, or in another party member's pack all show up the same way,
--- and each can then be paired with the lock that names it.
function W.pairs_()
    local me = Nav.me()
    local pos = me and Nav.positionOf(me)
    local out = { keys = {}, locks = {} }

    local ks = soft(Ext.Entity.GetAllEntitiesWithComponent, "Key")
    if type(ks) == "table" then
        for i = 1, #ks do
            local e = ks[i]
            out.keys[#out.keys + 1] = {
                name = Nav.nameOf(e), dist = distTo(e, pos),
                uuid = soft(function() return e.Uuid.EntityUuid end),
                key = fieldsOf(soft(function() return e.Key end)),
                stats = soft(function() return e.Data.StatsId end),
                -- Whose pack it sits in, which is the half "where is it" turns on.
                owner = Nav.nameOf(soft(function() return e.InventoryMember.Inventory end))
                     or Nav.nameOf(soft(function() return e.InventoryOwner end)),
            }
        end
    end

    local ls = soft(Ext.Entity.GetAllEntitiesWithComponent, "Lock")
    if type(ls) == "table" then
        for i = 1, #ls do
            local e = ls[i]
            out.locks[#out.locks + 1] = {
                name = Nav.nameOf(e), dist = distTo(e, pos),
                uuid = soft(function() return e.Uuid.EntityUuid end),
                lock = fieldsOf(soft(function() return e.Lock end)),
            }
        end
    end

    _P("[use] keys=" .. #out.keys .. " locks=" .. #out.locks)
    write("use_pairs", out)
    return out
end

--- What the game itself says is under the world cursor this instant. The one readout that is
--- already the whole answer when it works - verb, object, distance, refusal.
function W.cursor()
    local parts = Nav.cursorParts()
    A.write("use_cursor", parts or {})
    _P("[use] cursor: " .. (parts and (#parts .. " parts, in use_cursor.json") or "nothing"))
    return parts
end

_P("[probe-use] loaded. PU.words() / PU.pick() / PU.near(25) / PU.dump(1) / PU.keys()")
return W
