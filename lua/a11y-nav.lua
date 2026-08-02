-- Moving around the world without seeing it.
--
-- Everything the layer had so far reads panels. A session is not a panel: nothing is
-- focused, there is no list to walk, and the question a player actually has is "what is
-- near me and how do I get to it". That is answered from the client ECS, which turned out
-- to hold all of it:
--
--   ClientControl        exactly one entity - the character being controlled
--   Transform.Transform  Translate (position) and RotationQuat (facing)
--   GetEntitiesAroundPosition(pos, r)   17 entities within 20 m
--   DisplayName / CanInteract / IsDoor / Health   what each one is
--
-- So the world becomes a list, sorted by distance, with a bearing relative to where the
-- character is looking - and a list is something a screen reader can walk.
--
--     Nav = load(Ext.IO.LoadFile("A11y/a11y-nav.lua"))()

local A = _G.A11y
if A == nil then
    _P("[nav] a11y-menu is not loaded - push it first")
    error("a11y-nav needs A11y")
end

local M = {}
local try, soft = A.try, A.soft

local function say(text)
    if _G.Pad and _G.Pad.say then _G.Pad.say(text, true) else A.say(text, true) end
end
M.say = say

-- the character ------------------------------------------------------------------

--- The controlled character. ClientControl marks exactly one entity, which is the whole
--- reason this is cheap: no searching, no guessing which party member is active.
function M.me()
    local list = soft(function() return Ext.Entity.GetAllEntitiesWithComponent("ClientControl") end)
    if type(list) ~= "table" or #list == 0 then return nil end
    return list[1]
end

local function positionOf(e)
    local t = soft(function() return e.Transform.Transform.Translate end)
    if t == nil then return nil end
    local x, y, z = soft(function() return t[1] end), soft(function() return t[2] end),
                    soft(function() return t[3] end)
    if type(x) ~= "number" then return nil end
    return { x, y, z }
end
M.positionOf = positionOf

--- Which way the character is facing, in radians.
---
--- Taken from the rotation quaternion rather than from Steering.TargetRotation: steering is
--- where the character is turning *to*, which lags and overshoots while moving. The
--- component order of the quaternion is not documented here, so both readings are computed
--- and the one that matches reality is chosen once, by calibration, rather than assumed.
local function yawOf(e)
    local q = soft(function() return e.Transform.Transform.RotationQuat end)
    if q == nil then return nil end
    local a, b, c, d = soft(function() return q[1] end), soft(function() return q[2] end),
                       soft(function() return q[3] end), soft(function() return q[4] end)
    if type(a) ~= "number" then return nil end
    -- xyzw reading
    local xyzw = math.atan(2 * (d * b + a * c), 1 - 2 * (b * b + c * c))
    -- wxyz reading
    local wxyz = math.atan(2 * (a * c + b * d), 1 - 2 * (c * c + d * d))
    return xyzw, wxyz
end
M.yawOf = yawOf

-- naming -------------------------------------------------------------------------

--- What to call an entity.
---
--- Names arrive several ways and none of them is present on everything, so each is tried in
--- turn. A localisation handle is resolved the same way as everywhere else (E10).
local function nameOf(e)
    local n = soft(function() return e.DisplayName.Name:Get() end)
    if type(n) == "string" and n ~= "" then return n end
    n = soft(function() return e.CustomName.Name end)
    if type(n) == "string" and n ~= "" then return n end
    local h = soft(function() return e.DisplayName.NameKey.Handle.Handle end)
    if type(h) == "string" and h ~= "" then
        local t = soft(function() return Ext.Loca.GetTranslatedString(h) end)
        if type(t) == "string" and t ~= "" then return t end
    end
    return nil
end
M.nameOf = nameOf

local function has(e, comp)
    return soft(function() return e[comp] end) ~= nil
end

--- Which components an entity really carries.
---
--- `e[Name] ~= nil` is not an answer and this is measured (E7): `CanBeDisarmed` came back true
--- for all 133 entities in a sweep, while `Door` and `IsTrigger` came back false for
--- everything. The engine's own list is the only honest source. Asked for one entity at a
--- time, at the moment a claim is about to be made about it - never in the scan loop, where it
--- would be two hundred lookups a pass.
local function compSet(e)
    local names = soft(function() return e:GetAllComponentNames() end)
    if type(names) ~= "table" then return nil end
    local set = {}
    for i = 1, #names do set[tostring(names[i])] = true end
    return set
end
M.compSet = compSet

-- Metres. The engine stops a walk at its own interaction range, which is well inside this;
-- arriving is measured more loosely (WALK_ARRIVE) so that a walk which ends a little short is
-- still called an arrival, and those are exactly the cases where the action is not offered.
M.INTERACT_M = 2.0

-- What makes a thing usable. `CanInteract` is the general one; the rest are the specific
-- answers - a container can be searched, a door opened, a creature spoken to.
local INTERACT_COMPONENTS = { "CanInteract", "InteractionFilter", "CanBeLooted",
                              "InventoryContainer", "IsDoor", "Door", "CanSpeak" }

--- Is there really something to press A for.
---
--- The layer used to say "действие — кнопка A" on every arrival, which for a rock or a corpse
--- in a wall is a promise the game will not keep - and a player who cannot see is left
--- pressing a button at nothing, unable to tell a broken layer from a useless object.
function M.canInteract(e, dist)
    if e == nil then return false end
    if dist ~= nil and dist > M.INTERACT_M then return false end
    local set = compSet(e)
    -- No list to read means the entity does not answer that question, not that it is dead
    -- scenery. `CanInteract` by name is one of the readings that measured sanely - 41 of 133,
    -- not 133 of 133 - so it is the fallback rather than a flat no.
    if set == nil then return has(e, "CanInteract") end
    for i = 1, #INTERACT_COMPONENTS do
        if set[INTERACT_COMPONENTS[i]] then return true end
    end
    return false
end

--- Rough category, for sorting and for saying what a thing is.
local function kindOf(e)
    if has(e, "ClientCharacter") or has(e, "Character") then
        if has(e, "PartyMember") then return "спутник", 1 end
        return "существо", 2
    end
    if has(e, "IsDoor") then return "дверь", 3 end
    if has(e, "InventoryContainer") then return "контейнер", 4 end
    if has(e, "CanInteract") then return "объект", 5 end
    return nil, 9
end
M.kindOf = kindOf

-- the scan -------------------------------------------------------------------------

M.list = {}
M.cursor = 0
M.radius = 20              -- how far the ordinary categories look
-- How far the sweep itself reaches, for markers, quest objects and anything the near
-- categories are told to show. Measured on the beach: the query costs under a millisecond at
-- every radius tried - 5 entities at 20 m, 10 at 120 m, 46 at 200 m, 237 at 300 m, and
-- resolving all 237 names took under a millisecond too. So the limit on how wide this can be
-- is not the engine; it is that a list of three hundred barrels cannot be listened to. Hence
-- a wide sweep and a near radius the player moves themselves (M.radiusStep).
M.SCAN_RADIUS = 300

-- How often the list is rebuilt on its own, and how often the minimap is re-read while that
-- happens. Until now the scanner only ever ran on a keypress, and a keypress that came within
-- five metres and five seconds of the last one reused the old list - so walking past a body
-- did not put it in the list, and the category counts were about wherever the player last
-- stopped to press something. Now the world is swept on a timer and the categories are true
-- as you walk through them.
M.LIVE_MS = 700
M.OBJ_MS = 2000

-- What the near categories can be widened to, in metres. The first is the default: what is
-- within twenty metres is what is around you; the rest are for looking for somewhere to go.
M.RADII = { 20, 50, 100, 200 }

--- Twelve directions relative to where the character looks, because a clock face is the one
--- bearing scheme that needs no explaining.
local CLOCK = { "прямо", "на час", "на два", "направо", "на четыре", "на пять",
                "назад", "на семь", "на восемь", "налево", "на десять", "на одиннадцать" }

local function bearing(dx, dz, yaw)
    -- Screen-space heading of the target, then rotated into the character's frame.
    local ang = math.atan(dx, dz) - (yaw or 0)
    while ang < 0 do ang = ang + 2 * math.pi end
    while ang >= 2 * math.pi do ang = ang - 2 * math.pi end
    local hour = math.floor((ang / (2 * math.pi)) * 12 + 0.5) % 12
    return CLOCK[hour + 1], ang
end
M.bearing = bearing

--- Everything around, nearest first.
---
--- The radius is approximate on the engine side - a query for 5 m returned something at
--- 11 m, because it walks grid cells rather than measuring (E7) - so the distance is
--- recomputed here and anything outside the asked-for radius is dropped.
function M.scan(radius, quiet)
    -- Scanned wide, shown near: one sweep feeds every category, and each decides for itself
    -- how far it looks (rebuildView). A second sweep per category switch would cost more than
    -- the filtering it saves.
    radius = radius or M.SCAN_RADIUS
    -- A scan taken by the clock rather than by a keypress must never speak: the same failure
    -- said twice a second is not information, it is a jammed horn.
    local function complain(text) if not quiet then say(text) end end

    local me = M.me()
    if me == nil then complain("Персонаж не найден") return nil end
    local pos = positionOf(me)
    if pos == nil then complain("Позиция неизвестна") return nil end
    local yaw = yawOf(me)

    local near = soft(function() return Ext.Entity.GetEntitiesAroundPosition(pos, radius) end)
    if type(near) ~= "table" then complain("Сканирование недоступно") return nil end

    -- Which containers the player has already opened.
    --
    -- A looted chest is scenery: it stays in the world, it stays in the sweep, and it goes on
    -- being offered as somewhere to go long after there is any reason to walk to it. The engine
    -- says which ones have been opened, so the emptied ones can be told from the rest.
    --
    -- **Only the opened ones are asked what they hold**, and that is not an optimisation. A
    -- container the player has never opened may report nothing simply because its contents have
    -- not been replicated to the client yet - dropping those would empty the scanner of every
    -- chest on the level. Opened plus empty is a fact; empty alone is a guess.
    local opened = {}
    local ol = soft(Ext.Entity.GetAllEntitiesWithComponent, "HasOpened")
    if type(ol) == "table" then
        for i = 1, #ol do opened[tostring(ol[i])] = true end
    end

    local out = {}
    for i = 1, #near do
        local e = near[i]
        local p = positionOf(e)
        if p ~= nil then
            local dx, dz = p[1] - pos[1], p[3] - pos[3]
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist <= radius and dist > 0.3 then
                local name = nameOf(e)
                if name ~= nil then
                    local kind, rank = kindOf(e)
                    local dir = bearing(dx, dz, yaw)
                    local looted = nil
                    if opened[tostring(e)] then
                        -- Through M, not the local: contentsOf is declared further down the
                        -- file, so the name is not in scope here at all - only the field is.
                        local items = M.contentsOf(e)
                        looted = (items ~= nil and #items == 0) or nil
                    end
                    out[#out + 1] = { entity = e, name = name, kind = kind, rank = rank,
                                      dist = dist, dir = dir, pos = p, looted = looted }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)

    M.list = out
    M.at = pos
    M.scanAt = soft(Ext.Utils.MonotonicTime)
    -- The quest words and the marker labels are refreshed with the scan rather than per
    -- entry: both come off a widget, and reading it once for a list of thirty is the
    -- difference between a filter and a cost.
    --
    -- But not with *every* scan. The sweep itself is a sub-millisecond engine query; this is a
    -- six-hundred-node walk of the minimap's widget tree, and once the scan runs on a timer it
    -- would be the only expensive thing in the pass. The labels change when the story does, so
    -- twice a second is nonsense and every two seconds is plenty.
    local nowMs = soft(Ext.Utils.MonotonicTime) or 0
    if M.objAt == nil or (nowMs - M.objAt) > M.OBJ_MS then
        M.objAt = nowMs
        local obj = M.objective and M.objective()
        M.questKeys = (obj and obj.text) and M.stems(obj.text) or nil
        M.markerLabels = obj and obj.markers or nil
    end
    -- Walking past an anchor is what marks it seen, and walking is when the scan is taken.
    -- Only once the anchors exist: building them is a hundred entity lookups and it belongs
    -- to the moment the player asks for the category, not to every step.
    if M.anchors ~= nil then soft(M.exploreMark) end
    M.rebuildView()
    return out
end

-- Categories, because a list of everything is not a list.
--
-- Standing on the beach the scanner answers with reeds, slime, a barrel and two corpses, and
-- the one thing that matters is somewhere in the middle of it. Stepping through all of it to
-- find that out is exactly the blind groping the layer exists to remove.
--
-- The categories are built out of what the client actually reports, which is less than it
-- looks: on the beach not one entity carried IsDoor, InventoryContainer or MapMarkerStyle -
-- the reliable signals are "is a creature" and "can be interacted with". So the split is
-- coarse on purpose; a category that lies is worse than one that is broad.
M.CATEGORIES = {
    { key = "all",     name = "всё" },
    { key = "markers", name = "метки" },
    { key = "quest",   name = "задача" },
    { key = "landmarks", name = "ориентиры" },
    { key = "explore", name = "неизведанное" },
    { key = "beings",  name = "существа" },
    { key = "usable",  name = "взаимодействие" },
    { key = "things",  name = "предметы" },
}
M.category = 1
M.view = {}

-- The two categories that answer "where do I go" look far, because that is the whole point:
-- a map marker or a quest object is normally well outside the twenty metres that "what is
-- around me" wants. Everything else stays near, or the list fills with barrels a hundred
-- metres away.
M.FAR = { markers = true, quest = true, landmarks = true }

-- Things worth walking to, recognised by name.
--
-- Measured on the beach at 300 m: 235 named entities, of which **one** is a creature, two are
-- doors and one is a container - and among the remaining 232 "items" sit Сумка Гейла at
-- 116 m, Круг древних знаков at 121, Деревянный сундук at 127, Люк at 157, Дверь at 158 and
-- three Лестница between 143 and 172. So the range is not the problem and the scanner is not
-- blind; the categories are, because `CanInteract` and `IsDoor` are simply not on entities
-- that far out and everything lands in "предметы" among two hundred shells.
--
-- The name is what is left, and it is enough. Stems are stored without their first letter,
-- for the same reason the objective's are: names arrive capitalised and Lua's `lower()` does
-- not touch Cyrillic.
local LANDMARK_STEMS = {
    "вер",      -- дверь
    "орот",     -- ворота
    "юк",       -- люк
    "естниц",   -- лестница
    "ход",      -- вход, выход, проход
    "унду",     -- сундук
    "щик",      -- ящик
    "лтар",     -- алтарь
    "руг древн", -- круг древних знаков
    "уины",     -- руины
    "клеп",     -- склеп
    "ашня",     -- башня
    "ычаг",     -- рычаг
    "айник",    -- тайник
    "ортал",    -- портал
    "остер", "остёр",  -- костер
    "агерь",    -- лагерь
    "юк в",     -- люк в подвал
}

-- A stem may only be followed by a case ending, not by the rest of another word. Without this
-- "юк" (люк, a hatch) matched **рюкзак**, and a backpack lying in the sand was announced as a
-- landmark three hundred metres of list away from anything that is one. Two Cyrillic letters,
-- four bytes: enough for "двери", "входа", "лестницы", not enough for "-зак".
M.STEM_TAIL = 4

local function stemHit(name, stem)
    local from = 1
    while true do
        local s, e = name:find(stem, from, true)
        if s == nil then return false end
        local rest = name:match("^[^%s,%.;:%(%)/%-]*", e + 1) or ""
        if #rest <= M.STEM_TAIL then return true end
        from = s + 1
    end
end
M.stemHit = stemHit

local function isLandmark(name)
    for i = 1, #LANDMARK_STEMS do
        if stemHit(name, LANDMARK_STEMS[i]) then return true end
    end
    return false
end
M.isLandmark = isLandmark

--- Does the map itself name this thing?
---
--- The marker labels are lifted off the minimap - "Заросшие руины", "Древняя дверь" - and they
--- are the game's own answer to "what here matters": the points the story runs through, put
--- there by hand. Anything they name is a landmark by definition, whatever a word list thinks.
local function isMarkerNamed(name)
    if M.markerLabels == nil then return false end
    for _, label in ipairs(M.markerLabels) do
        if name:find(label, 1, true) or label:find(name, 1, true) then return true end
    end
    return false
end
M.isMarkerNamed = isMarkerNamed

local function matches(key, it)
    -- An emptied container is out of every category but "всё". Not deleted, because the
    -- complete list is the one place the layer never hides anything - and a player who walks
    -- back to a chest wants to hear that it is the one they already took from, rather than
    -- find nothing there at all.
    if it.looted and key ~= "all" then return false end
    if key == "all" then return true end
    if key == "beings" then return it.kind == "существо" or it.kind == "спутник" end
    if key == "usable" then
        return it.kind == "дверь" or it.kind == "контейнер" or it.kind == "объект"
    end
    if key == "things" then return it.kind == nil end
    if key == "landmarks" then
        -- A door the game still flags as one counts too, wherever it is. A container does
        -- **not**: "контейнер" is every backpack, crate and corpse-with-pockets in three
        -- hundred metres, and a category that answers "where do I go" with loot answers a
        -- different question than the one asked. Chests and crates are still here - by name,
        -- through the stems, which is also what keeps a rucksack out.
        return it.kind == "дверь" or isMarkerNamed(it.name) or isLandmark(it.name)
    end
    if key == "quest" then
        if M.questKeys == nil then return false end
        for _, k in ipairs(M.questKeys) do
            if it.name:find(k, 1, true) then return true end
        end
        return false
    end
    if key == "markers" then
        -- The label is the thing's own name, so it matches outright - no stemming needed the
        -- way the objective sentence needs it.
        return isMarkerNamed(it.name)
    end
    return true
end

--- What identifies an entry across a rescan.
---
--- Not the index: the list is sorted by distance and every step changes it. The entity itself
--- is the identity where there is one, and the engine hands back the same proxy for it, so its
--- printed form is stable within a session.
local function idOf(it)
    if it == nil then return nil end
    if it.anchor ~= nil then return "a:" .. tostring(it.anchor) end
    if it.entity ~= nil then return "e:" .. tostring(it.entity) end
    return nil
end

function M.rebuildView()
    local cat = M.CATEGORIES[M.category]
    -- What the player had selected. A rescan used to drop the cursor back to the first entry,
    -- and a rescan happens every three metres walked - so stepping through the list on the way
    -- somewhere kept announcing entry one, and "иди туда" walked to entry one: a different
    -- object every time, which is a character running a route nobody chose.
    local want = idOf(M.view and M.view[M.cursor or 0])

    local out
    -- Exploration is not a filter over what was scanned: the places it names are hundreds of
    -- metres away and hold nothing the scan would ever return.
    if cat.key == "explore" then
        out = M.exploreView()
    else
        local limit = M.FAR[cat.key] and M.SCAN_RADIUS or M.radius
        out = {}
        for i = 1, #M.list do
            local it = M.list[i]
            if (it.dist or 0) <= limit and matches(cat.key, it) then out[#out + 1] = it end
        end
    end

    M.view, M.cursor = out, 0
    if want ~= nil then
        for i = 1, #out do
            if idOf(out[i]) == want then M.cursor = i break end
        end
    end
    return out
end

--- Move to the next category that has anything in it.
---
--- Empty ones are stepped over rather than announced: hearing "двери, ноль" three times on
--- the way to the creatures is the same waste as stepping through the reeds. "Всё" is never
--- skipped, so there is always a way back to the complete list.
function M.categoryStep(delta)
    -- Switching category is a deliberate press, which makes it the right moment to pay for a
    -- fresh sweep: the counts announced here are the player's picture of the room.
    if M.stale() then M.scan() end
    local n = #M.CATEGORIES
    local was = M.category
    for _ = 1, n do
        M.category = ((M.category - 1 + (delta or 1)) % n) + 1
        local view = M.rebuildView()
        if #view > 0 or M.CATEGORIES[M.category].key == "all" then
            say(M.CATEGORIES[M.category].name .. ", " .. #view)
            return view
        end
    end
    M.category = was
    M.rebuildView()
    say("Больше ничего")
    return M.view
end

-- Where have I not been ------------------------------------------------------------
--
-- The game has no answer to this and it is worth writing down why, because the obvious places
-- were all checked. The map's fog is not a list of areas: its 282 room records are interiors
-- (KethericCity, Tollhouse, HagSecretLair) and every one of them reads `RoomState=Shrouded`
-- from the first minute, while the open world has no such record at all. The 136 region
-- records all carry `Hidden=false`, so that flag is not a "seen it" either. The client ECS is
-- no help: the played character carries 142 components and none is a journal or a map, and
-- `MapMarkerStyle` holds no entities.
--
-- What those region records do give is **positions**. Each has a `Guid` that resolves to a
-- real entity with a `Transform`, spread over the whole level - about 130 of them. Their
-- components are empty (`Tag{}`, `TriggerType{}`, `TriggerArea{}`), so they cannot be named
-- or bounded, and the layer says so plainly: this category speaks in directions and metres,
-- not in place names.
--
-- Visiting is tracked here rather than read: the character's position is known every tick, so
-- an anchor the player has stood near is marked and kept in a file, which is what makes the
-- list shrink as the level is explored - and survive the save-load that wipes the Lua state.

M.anchors = nil
M.anchorsAt = 0
M.visited = nil
M.visitedDirty = false
M.VISIT_M = 25              -- standing this close counts as having been there
M.EXPLORE_MAX = 600         -- further than this is another part of the act, not a direction
M.EXPLORE_STEP = 20         -- one walk toward an anchor; exploring is many of these
M.EXPLORE_FILE = "A11y/explored.json"

local function visitedLoad()
    if M.visited ~= nil then return M.visited end
    M.visited = {}
    local body = soft(Ext.IO.LoadFile, M.EXPLORE_FILE)
    if type(body) == "string" and #body > 0 then
        local t = soft(Ext.Json.Parse, body)
        if type(t) == "table" then
            for k, v in pairs(t) do if v then M.visited[tostring(k)] = true end end
        end
    end
    return M.visited
end

local function visitedSave()
    if not M.visitedDirty then return end
    M.visitedDirty = false
    local body = soft(Ext.Json.Stringify, M.visited or {})
    if body ~= nil then soft(Ext.IO.SaveFile, M.EXPLORE_FILE, body) end
end
M.visitedSave = visitedSave

--- The anchors of this level: the map's own regions, as points in the world.
---
--- Read from the Minimap rather than from the map screen, because the minimap is part of the
--- HUD and is therefore always in the tree - no screen has to be opened for this to work.
function M.anchorsScan(force)
    local t = soft(Ext.Utils.MonotonicTime) or 0
    if not force and M.anchors ~= nil and (t - M.anchorsAt) < 60000 then return M.anchors end

    local pad = _G.Pad
    if pad == nil then return M.anchors end
    local ws = soft(pad.findWidgets) or {}
    local node = nil
    for i = 1, #ws do
        if tostring(ws[i].name):find("Minimap", 1, true) then node = ws[i].node end
    end
    if node == nil then return M.anchors end

    -- The minimap holds four hundred-odd records and the regions are scattered among them, so
    -- the budget is generous on purpose: this runs once a minute at most, on a keypress.
    local out, seen, budget = {}, {}, { n = 4000 }
    local function rec(o, depth)
        if o == nil or depth > 20 or budget.n <= 0 then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            budget.n = budget.n - 1
            if budget.n <= 0 then return end
            local p = soft(function() return ch[i]:GetAllProperties() end)
            if type(p) == "table" and p.Guid ~= nil and p.WorldPos ~= nil then
                local guid = tostring(p.Guid)
                if not seen[guid] then
                    seen[guid] = true
                    -- The record's own WorldPos is in map space and does not convert; the
                    -- entity behind the Guid carries the real one.
                    local e = soft(Ext.Entity.Get, guid)
                    local pos = e and positionOf(e)
                    if pos ~= nil then
                        out[#out + 1] = { guid = guid, pos = { pos[1], pos[2], pos[3] } }
                    end
                end
            elseif type(p) == "table" and p.ActualWidth ~= nil then
                rec(ch[i], depth + 1)
            end
        end
    end
    rec(node, 0)

    if #out > 0 then
        M.anchors, M.anchorsAt = out, t
        _P("[nav] anchors: " .. #out .. " regions")
    end
    return M.anchors
end

--- Mark what the character has walked past. Cheap enough to run with every scan.
function M.exploreMark()
    local anchors = M.anchors
    if anchors == nil then return 0 end
    local me = M.me()
    local pos = me and positionOf(me)
    if pos == nil then return 0 end
    local visited = visitedLoad()
    local n = 0
    for i = 1, #anchors do
        local a = anchors[i]
        if not visited[a.guid] then
            local dx, dz = a.pos[1] - pos[1], a.pos[3] - pos[3]
            if (dx * dx + dz * dz) <= (M.VISIT_M * M.VISIT_M) then
                visited[a.guid] = true
                M.visitedDirty = true
                n = n + 1
            end
        end
    end
    if n > 0 then visitedSave() end
    return n
end

-- Everything the layer moves to has to be an object - coordinates are not walked to, they are
-- teleported to (see the server half) - so a direction is followed by hopping between what
-- stands in it.
M.STEP_MIN = 4              -- closer than this is where we already are

-- How far off the line a thing may stand and still count as "that way", tried in turn. One
-- narrow arc was the whole of this and it was why the category never moved anyone: on open
-- ground the things that happen to stand within 35° of a region three hundred metres off are
-- often none at all, and the answer was "поверните и попробуйте снова" - which is the layer
-- asking the player to solve the problem it exists to solve.
M.STEP_ARCS = { math.rad(35), math.rad(60), math.rad(90) }
-- And how far one hop may reach. The near value first, so the walk stays a walk; the wide one
-- only when nothing nearer stands in the way at all.
M.STEP_RANGES = { 20, 45 }
-- A hop has to actually get us closer to the anchor, or the list of things "that way" will
-- happily send the character round in a circle - which is exactly what it did.
M.STEP_GAIN = 2

--- The next thing to walk to on the way to an anchor, or why there is none.
function M.stepTarget(anchor)
    local me = M.me()
    local mp = me and positionOf(me)
    if mp == nil then return nil, "Позиция неизвестна" end
    if M.stale() then M.scan() end

    local ax, az = anchor.pos[1], anchor.pos[3]
    local a0 = math.atan(ax - mp[1], az - mp[3])
    local now = math.sqrt((ax - mp[1]) ^ 2 + (az - mp[3]) ^ 2)
    local seen = 0

    for _, range in ipairs(M.STEP_RANGES) do
        for _, arc in ipairs(M.STEP_ARCS) do
            local best = nil
            for i = 1, #M.list do
                local it = M.list[i]
                local d = it.dist or 0
                if d >= M.STEP_MIN and d <= range then
                    local a = math.atan(it.pos[1] - mp[1], it.pos[3] - mp[3])
                    local off = math.abs(((a - a0 + math.pi) % (2 * math.pi)) - math.pi)
                    if off <= arc then
                        seen = seen + 1
                        -- Furthest, not nearest: each hop should uncover as much new ground as
                        -- it safely can, and the near things were already in range before it.
                        -- But only if standing there is progress toward the anchor.
                        local left = math.sqrt((ax - it.pos[1]) ^ 2 + (az - it.pos[3]) ^ 2)
                        if left <= now - M.STEP_GAIN then
                            local uuid = soft(function() return it.entity.Uuid.EntityUuid end)
                            if type(uuid) == "string" and uuid ~= "" then
                                if best == nil or d > best.dist then
                                    best = { uuid = uuid, name = it.name, dist = d,
                                             dir = it.dir, left = left }
                                end
                            end
                        end
                    end
                end
            end
            if best ~= nil then return best end
        end
    end

    if seen > 0 then
        return nil, "В ту сторону всё, что стоит, не приближает к участку"
    end
    return nil, "В ту сторону ничего не стоит, поверните или подойдите ближе"
end

--- The places on this level the character has never stood near, nearest first.
function M.exploreView()
    M.anchorsScan()
    local anchors = M.anchors
    if anchors == nil then return {} end
    M.exploreMark()

    local me = M.me()
    local pos = me and positionOf(me)
    if pos == nil then return {} end
    local yaw = yawOf(me)
    local visited = visitedLoad()

    local out = {}
    for i = 1, #anchors do
        local a = anchors[i]
        if not visited[a.guid] then
            local dx, dz = a.pos[1] - pos[1], a.pos[3] - pos[3]
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist <= M.EXPLORE_MAX then
                out[#out + 1] = { name = "участок", kind = nil, anchor = a.guid,
                                  pos = a.pos, dist = dist, dir = bearing(dx, dz, yaw) }
            end
        end
    end
    table.sort(out, function(x, y) return x.dist < y.dist end)
    return out
end

--- Things standing in the world that a map marker names, nearest first.
---
--- Kept apart from the category machinery so the navigator can ask without moving the
--- player's place in the review list.
function M.markerHits()
    local obj = M.objective()
    local labels = obj and obj.markers
    if labels == nil or #labels == 0 then return nil, obj end

    local list = M.list
    if #list == 0 then list = M.scan() or {} end
    local hits = {}
    for i = 1, #list do
        local name = list[i].name
        for _, label in ipairs(labels) do
            if name:find(label, 1, true) or label:find(name, 1, true) then
                hits[#hits + 1] = list[i]
                break
            end
        end
    end
    return hits, obj
end

--- Widen or narrow what "around me" means.
---
--- Exploring blind and standing in a room are the same question asked at two scales, and the
--- scanner cannot serve both at once: twenty metres keeps the list to what is actually here,
--- while two hundred is how you find out that there is a building over that way at all. The
--- sweep is wide either way and costs nothing measurable, so this only moves the filter.
function M.radiusStep(delta)
    local at = 1
    for i, r in ipairs(M.RADII) do if M.radius == r then at = i end end
    at = ((at - 1 + (delta or 1)) % #M.RADII) + 1
    M.radius = M.RADII[at]
    if M.stale() then M.scan() end
    local view = M.rebuildView()
    say("Радиус " .. M.radius .. " метров, " .. #view)
    return M.radius
end

function M.categorySay()
    say(M.CATEGORIES[M.category].name .. ", " .. #M.view)
    return M.CATEGORIES[M.category].key
end

-- The clock bearing is gone from the spoken list, and it was there for a reason that did not
-- survive being used: a bearing is only worth hearing if you can act on it, and there is no key
-- that turns the character. "Труп, на два, 6 м" costs a word and a half of listening to say
-- nothing the player can use - the number is the whole message, and whether it is going down.
--
-- The one exception is an exploration anchor. It has no name and no kind; the direction is
-- everything it is.
local function describe(it)
    local parts = { it.name }
    if it.kind then parts[#parts + 1] = it.kind end
    if it.looted then parts[#parts + 1] = "пусто" end
    if it.anchor ~= nil and it.dir then parts[#parts + 1] = it.dir end
    parts[#parts + 1] = string.format("%.0f м", it.dist)
    return table.concat(parts, ", ")
end
M.describe = describe

--- Say what is around, nearest first - within the current category.
function M.around(limit)
    if M.scan() == nil then return end
    local list = M.view
    local cat = M.CATEGORIES[M.category]
    if #list == 0 then
        say(cat.key == "all" and "Рядом никого" or (cat.name .. ", пусто"))
        return list
    end
    local n = math.min(#list, limit or 8)
    local parts = {}
    for i = 1, n do parts[#parts + 1] = describe(list[i]) end
    local head = #list .. ". "
    if cat.key ~= "all" then head = cat.name .. ", " .. head end
    say(head .. table.concat(parts, ". "))
    return list
end

-- Keeping the list honest.
--
-- Three ways a scanner goes stale, and all three read as confidence rather than as error:
-- the player walks away from where the list was taken, something in the list moves or dies
-- while the player stands still, and the list simply ages while the world carries on. The
-- first two are cheap to check, the third is a timer.
M.STALE_MS = 5000
M.STALE_M2 = 9              -- three metres, squared

function M.stale()
    if #M.list == 0 then return true end
    local now = soft(Ext.Utils.MonotonicTime)
    if now ~= nil and M.scanAt ~= nil and (now - M.scanAt) > M.STALE_MS then return true end
    local me = M.me()
    local pos = me and positionOf(me)
    if pos ~= nil and M.at ~= nil then
        local dx, dz = pos[1] - M.at[1], pos[3] - M.at[3]
        if dx * dx + dz * dz > M.STALE_M2 then return true end
    end
    return false
end

--- Keep the list true while the player walks, without being asked.
---
--- Called from the reader's pass. The engine query is what makes this affordable: measured at
--- 300 m it returns 237 entities in under a millisecond, and resolving all their names cost
--- under a millisecond more. Silent by construction - it rebuilds the list and the category,
--- and says nothing at all; every announcement still belongs to a key the player pressed.
function M.scanTick()
    local now = soft(Ext.Utils.MonotonicTime) or 0
    if M.scanAt ~= nil and (now - M.scanAt) < M.LIVE_MS then return false end
    M.scan(nil, true)
    return true
end

--- Recompute one entry against the world as it stands this instant.
---
--- Even a fresh list ages between the scan and the sentence: a creature walks while the
--- player is listening, and the distance said out loud is the one measured a second ago.
--- Cheap enough to do for the single entry being announced.
local function refreshEntry(it)
    local me = M.me()
    local mp = me and positionOf(me)
    -- An exploration anchor is a place, not a thing: it has no entity to ask and its position
    -- cannot go stale. Everything else keeps the old rule, where a missing entity means the
    -- object is gone and the list has to be taken again.
    local p = it.entity and positionOf(it.entity) or (it.anchor and it.pos)
    if mp == nil or p == nil then return false end
    local dx, dz = p[1] - mp[1], p[3] - mp[3]
    it.pos = p
    it.dist = math.sqrt(dx * dx + dz * dz)
    it.dir = bearing(dx, dz, yawOf(me))
    return true
end
M.refreshEntry = refreshEntry

--- Step through the scan one entry at a time.
function M.step(delta)
    if M.stale() then M.scan() end
    if #M.view == 0 then
        local cat = M.CATEGORIES[M.category]
        say(cat.key == "all" and "Рядом никого" or (cat.name .. ", пусто"))
        return
    end
    -- Running off either end used to be silent, which is indistinguishable from a key that
    -- did nothing - and with the cursor resetting on every rescan, "did nothing" was what it
    -- looked like all the way up the list. Now an end says it is an end.
    local i = M.cursor + (delta or 1)
    local edge = nil
    if i < 1 then i, edge = 1, "начало списка" end
    if i > #M.view then i, edge = #M.view, "конец списка" end
    M.cursor = i

    local it = M.view[i]
    -- An entry whose entity no longer answers has been picked up, killed or unloaded. Saying
    -- its old distance would be the worst kind of wrong, so the list is taken again and the
    -- same position in it is read instead.
    if not refreshEntry(it) then
        M.scan()
        if #M.view == 0 then say("Рядом никого") return end
        i = math.min(i, #M.view)
        M.cursor = i
        it = M.view[i]
        refreshEntry(it)
    end
    say((edge and (edge .. ". ") or "") .. describe(it) .. ", " .. i .. " из " .. #M.view)
    return it
end

--- Where the character is standing, and which way it looks.
function M.where()
    local me = M.me()
    if me == nil then say("Персонаж не найден") return end
    local pos = positionOf(me)
    local name = nameOf(me) or "персонаж"
    say(name .. ". " .. string.format("%.0f, %.0f", pos[1], pos[3]))
    return pos
end

-- What is inside the thing that is open ----------------------------------------------
--
-- Looting is the one panel whose text is not in the panel. Measured on an opened pouch: the
-- widget carries 3037 nodes, of which 138 are visible and twelve are strings - the weight, the
-- capacity, and names that belong to the other half of the screen. The slot the d-pad stands
-- on has exactly one string under it, "1", the stack count. The items are **icons**.
--
-- So the names are read where they actually live, and the client ECS has all of it:
--
--   HasOpened                        marks the container the player has opened
--   InventoryOwner.PrimaryInventory  the inventory entity behind it
--     InventoryContainer.Items       LegacyMap<uint16, ContainerSlotData>
--       [slot].Item                  the item entity, and DisplayName from there as usual
--
-- The panel is still needed for one thing the ECS cannot know: which slot the player is on.
-- That comes from the widget's focus chain (Pad.slotFind), and the two are joined by index.

--- What one entity holds, in slot order, or nil if it holds nothing readable.
local function contentsOf(e)
    local items = soft(function()
        return e.InventoryOwner.PrimaryInventory.InventoryContainer.Items
    end)
    if items == nil then return nil end
    -- The map is keyed by slot number and comes back in no order; the player's list is the
    -- one the panel draws, which is slot order.
    local keys = {}
    for k in pairs(items) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)

    local out = {}
    for i = 1, #keys do
        local slot = items[keys[i]]
        local it = soft(function() return slot.Item end)
        out[#out + 1] = { slot = tonumber(keys[i]), entity = it,
                          name = (it and nameOf(it)) or nil }
    end
    return out
end
M.contentsOf = contentsOf

--- The container the player has open, with what is in it, in slot order.
---
--- Two ways of finding it, tried in turn, because neither is reliable alone. `HasOpened` is the
--- game's own flag and is the right answer when it is right - but it stays on things that were
--- opened earlier and elsewhere, so the first entity carrying it is not necessarily the one in
--- front of the player. The fallback is what measured correctly at the pouch: the nearest thing
--- within five metres that owns an inventory at all. Whichever has contents wins.
M.OPEN_M = 6                -- further than this is not the thing in front of you
-- And nearer than this is not a thing in the world at all. An item inside a character's
-- inventory inherits the carrier's transform, so a supply pouch in the player's own backpack
-- reads as a container standing at exactly zero metres - and, being flagged `HasOpened` from
-- whenever it was last opened, it won every search. The loot panel was reading out the
-- player's own bag while the chest in front of them went unmentioned.
M.OPEN_MIN = 0.5

function M.openContainer()
    local me = M.me()
    local mp = me and positionOf(me)
    if mp == nil then return nil end

    -- **Sorted by distance, and this is the whole correctness of it.** The first version took
    -- the first candidate that had anything in it, and `HasOpened` stays set on every container
    -- opened earlier in the level - so a pouch looted a minute ago and left behind kept winning
    -- over the chest standing in front of the character, and the panel read out the wrong
    -- inventory with complete confidence.
    local cands, seen = {}, {}
    local function offer(e)
        local id = tostring(e)
        if seen[id] then return end
        local p = positionOf(e)
        if p == nil then return end
        local dx, dz = p[1] - mp[1], p[3] - mp[3]
        local d = math.sqrt(dx * dx + dz * dz)
        if d > M.OPEN_M or d < M.OPEN_MIN then return end
        seen[id] = true
        cands[#cands + 1] = { entity = e, dist = d }
    end

    local list = soft(Ext.Entity.GetAllEntitiesWithComponent, "HasOpened")
    if type(list) == "table" then
        for i = 1, #list do offer(list[i]) end
    end
    -- The world list is not refreshed while a panel is up - the reader hands its pass to the
    -- panel - so it is the sweep from just before the container was opened, which is exactly
    -- the moment the character was standing at it.
    if #M.list == 0 then M.scan(nil, true) end
    for i = 1, #M.list do
        local it = M.list[i]
        if (it.dist or 99) <= M.OPEN_M and
           soft(function() return it.entity.InventoryOwner end) ~= nil then
            offer(it.entity)
        end
    end
    table.sort(cands, function(a, b) return a.dist < b.dist end)

    local fallback = nil
    for i = 1, #cands do
        local items = contentsOf(cands[i].entity)
        if items ~= nil and #items > 0 then
            return { entity = cands[i].entity, name = nameOf(cands[i].entity),
                     dist = cands[i].dist, items = items }
        end
        if fallback == nil and items ~= nil then fallback = cands[i] end
    end
    -- Nothing with contents. Still an answer, and the right one: an empty container is not a
    -- broken layer, and the player needs to hear the difference.
    if fallback ~= nil then
        return { entity = fallback.entity, name = nameOf(fallback.entity),
                 dist = fallback.dist, items = {} }
    end
    return nil
end

--- The same, said out loud: what is in the thing in front of you.
function M.containerSay()
    local c = M.openContainer()
    if c == nil then say("Ничего не открыто") return nil end
    if #c.items == 0 then say((c.name or "Контейнер") .. ", пусто") return c end
    local parts = {}
    for i = 1, math.min(#c.items, 12) do
        parts[#parts + 1] = c.items[i].name or "предмет"
    end
    say((c.name or "Контейнер") .. ", " .. #c.items .. ". " .. table.concat(parts, ". "))
    return c
end

-- going there ----------------------------------------------------------------------

M.CHANNEL = "A11yNav"

--- Walk to the entry under the cursor.
---
--- The request goes to the server because that is where movement lives; the client only
--- knows where things are. Moving to the object rather than to its coordinates where a uuid
--- is available, so the engine stops at interaction range instead of trying to stand inside
--- the thing.
function M.goTo(index)
    local i = index or M.cursor
    local it = M.view[i]
    if it == nil then say("Не выбрано") return false end
    -- The coordinate fallback below sends wherever the thing was when the list was taken, so
    -- the entry is measured again first. Where a uuid exists it does not matter - the server
    -- resolves the object's own position - but the check also catches an entry that is gone.
    if not M.refreshEntry(it) then
        M.scan()
        say("Пропало, список обновлён")
        return false
    end

    local uuid = soft(function() return it.entity.Uuid.EntityUuid end)
    local msg, spoken, going = nil, nil, it.name
    if type(uuid) == "string" and uuid ~= "" then
        msg = { cmd = "gotoObject", uuid = uuid }
        spoken = "Иду: " .. it.name
    elseif it.anchor ~= nil then
        -- An exploration anchor is a **direction**, never a destination: it is a region
        -- trigger hundreds of metres off, and coordinates are not walked to at all (see the
        -- server). So the step is taken to the furthest *thing* standing that way - an object
        -- is on real ground, the engine paths to it and stops at reach. Which is also what
        -- exploring is: go to what you can hear, listen to what came into range, go again.
        local target, err = M.stepTarget(it)
        if target == nil then say(err or "В ту сторону не за что зацепиться") return false end
        going = target.name
        msg = { cmd = "gotoObject", uuid = target.uuid }
        spoken = "Иду " .. tostring(it.dir) .. ": " .. target.name .. ", " ..
                 string.format("%.0f м", target.dist) ..
                 -- One hop is not the journey: saying what is left to the region is what turns
                 -- a series of presses into progress the player can hear.
                 (target.left and (", до участка " .. string.format("%.0f м", target.left)) or "")
    else
        say("Туда идти не по чему")
        return false
    end

    local body = soft(Ext.Json.Stringify, msg)
    local r = try(function() Ext.Net.PostMessageToServer(M.CHANNEL, body) end)
    if not r.ok then
        _P("[nav] goTo failed: " .. tostring(r.error))
        say("Не получилось пойти")
        return false
    end
    M.cursor = i
    M.walkStarted(msg.uuid, going)
    say(spoken)
    return true
end

-- Stopping, and knowing whether it worked.
--
-- The old version said "Стою" and hoped. It was not stopping anything: Osiris movement queues
-- rather than replaces (see the server half), so the order to stand still lined up behind a
-- walk that was still running - and a walk to something unreachable never ends. The player
-- heard "Стою" while the character kept going, which is the worst answer a layer can give.
--
-- So the word is now "Стоп" - an acknowledgement of the press, not a claim about the world -
-- and the claim is checked a moment later against the character's own position. Pressed twice
-- in a row it escalates to the hard stop, which places the character on the ground it is
-- already standing on and cannot be queued behind anything.
M.STOP_AGAIN_MS = 5000      -- a second press inside this is "it did not work, try harder"
M.STOP_CHECK_MS = 1800      -- long enough for a walk order to have died
M.STOP_MOVED_M2 = 9         -- three metres on from where stop was pressed is "still going"

M.stopAt = nil
M.stopping = nil

function M.stop()
    local now = soft(Ext.Utils.MonotonicTime) or 0
    local hard = M.stopAt ~= nil and (now - M.stopAt) < M.STOP_AGAIN_MS
    M.stopAt = now
    -- Whatever we were watching, we are no longer going there: leaving it set is how "Пришли"
    -- gets announced about a walk the player cancelled.
    M.walking = nil

    local me = M.me()
    M.stopping = { at = now, pos = me and positionOf(me) }

    local body = soft(Ext.Json.Stringify, { cmd = "stop", hard = hard })
    soft(function() Ext.Net.PostMessageToServer(M.CHANNEL, body) end)
    say(hard and "Стоп, жёстко" or "Стоп")
end

--- Did it stop? Called from the same pass as walkTick.
function M.stopTick()
    local s = M.stopping
    if s == nil then return false end
    local now = soft(Ext.Utils.MonotonicTime) or 0
    if (now - s.at) < M.STOP_CHECK_MS then return false end
    M.stopping = nil

    local me = M.me()
    local p = me and positionOf(me)
    if p == nil or s.pos == nil then return false end
    local dx, dz = p[1] - s.pos[1], p[3] - s.pos[3]
    if (dx * dx + dz * dz) > M.STOP_MOVED_M2 then
        if M.stopHow == "" then
            -- The server answered and had nothing to answer with. Worth saying once in plain
            -- words, because no amount of pressing the key will change it.
            say("Не останавливается. Сборка без очистки очереди — стоп невозможен")
        else
            say("Не останавливается, нажмите ещё раз")
        end
        return true
    end
    return false
end

-- Did we get there? ------------------------------------------------------------------
--
-- The layer could send the character walking and then said nothing ever again: not on
-- arrival, not when the path ran out, not when something blocked the way. For a player who
-- cannot see the character move, "иду к двери" followed by silence is indistinguishable from
-- a layer that has crashed - and the honest answers are all cheap, because the position is
-- already read every pass.

M.walking = nil
M.WALK_ARRIVE = 3.0         -- close enough to call it arrival; the engine stops at reach
M.WALK_STUCK_MS = 2000      -- standing still this long, still short of the target, is stuck
M.WALK_CIRCLE_MS = 5000     -- moving this long without getting any nearer is not a path
M.WALK_GIVEUP_MS = 60000

--- Remember what we were sent to, so arriving at it can be noticed.
function M.walkStarted(uuid, name)
    local me = M.me()
    local p = me and positionOf(me)
    -- Going somewhere on purpose ends any argument about whether the last stop worked; without
    -- this the check fires on the new walk and says the layer cannot stop the character.
    M.stopping = nil
    local now = soft(Ext.Utils.MonotonicTime) or 0
    M.walking = { uuid = uuid, name = name, at = now,
                  lastPos = p, lastMove = now, said = nil }

    -- The distance the walk started from, and the best one reached since. Between them they
    -- answer the question the player could not ask before: is this walk making progress, or is
    -- the character going round something it cannot path past.
    local d = M.distanceTo(uuid)
    M.walking.startDist, M.walking.best, M.walking.bestAt = d, d, now
end

--- How far the character is from an object, right now.
function M.distanceTo(uuid)
    if uuid == nil then return nil end
    local me = M.me()
    local mp = me and positionOf(me)
    local e = soft(Ext.Entity.Get, uuid)
    local tp = e and positionOf(e)
    if mp == nil or tp == nil then return nil end
    local dx, dz = tp[1] - mp[1], tp[3] - mp[3]
    return math.sqrt(dx * dx + dz * dz), bearing(dx, dz, yawOf(me)), e
end

--- How the walk is going: the one question a blind player has while the character moves, and
--- the layer had no answer for it. The number alone is not enough - "16 метров" twice in a row
--- means something very different from "16" then "9" - so the change since the last press is
--- said with it, which is what turns a distance into "we are getting there" or "we are not".
function M.progress()
    local w = M.walking
    if w == nil then
        -- Not walking. The same question about the entry under the cursor, because that is
        -- what the player is deciding whether to walk to.
        local it = M.view[M.cursor]
        if it == nil then say("Никуда не идём") return nil end
        if not refreshEntry(it) then say("Никуда не идём") return nil end
        say("Не идём. Выбрано: " .. describe(it))
        return nil
    end

    local d = M.distanceTo(w.uuid)
    if d == nil then
        M.walking = nil
        say("Цель пропала: " .. tostring(w.name))
        return nil
    end

    local bits = { tostring(w.name), string.format("%.0f м", d) }
    -- Against the last thing said, not against the start: on the fifth press the player is
    -- asking about the last few seconds, not about the whole journey.
    local ref = w.saidDist or w.startDist
    if ref ~= nil then
        local delta = ref - d
        if delta >= 1 then bits[#bits + 1] = string.format("ближе на %.0f", delta)
        elseif delta <= -1 then bits[#bits + 1] = string.format("дальше на %.0f", -delta)
        else bits[#bits + 1] = "без изменений" end
    end
    w.saidDist = d
    say(table.concat(bits, ", "))
    return d
end

--- Watch the walk to its end. Called from the reader's pass, like the other world ticks.
function M.walkTick()
    local w = M.walking
    if w == nil then return false end
    local now = soft(Ext.Utils.MonotonicTime) or 0
    -- A walk that has run a minute is a walk that is not going to end, and giving up on it
    -- quietly is how the character ends up running somewhere with the layer saying nothing.
    if (now - w.at) > M.WALK_GIVEUP_MS then
        M.walking = nil
        say("Не дошли: " .. tostring(w.name) .. ". Остановить — стик")
        return true
    end

    local me = M.me()
    local p = me and positionOf(me)
    if p == nil then return false end

    -- Where the target is now: it may be a creature, and creatures walk away.
    local tp, e = nil, nil
    if w.uuid ~= nil then
        e = soft(Ext.Entity.Get, w.uuid)
        tp = e and positionOf(e)
    end
    if tp ~= nil then
        local dx, dz = tp[1] - p[1], tp[3] - p[3]
        local d = math.sqrt(dx * dx + dz * dz)
        if d <= M.WALK_ARRIVE then
            M.walking = nil
            -- The action is promised only when the thing can actually take one and we are
            -- close enough for the game to offer it; otherwise the distance is said instead,
            -- which is the fact the player needs to decide whether to walk the rest.
            local bits = { "Пришли: " .. tostring(w.name) }
            if M.canInteract(e, d) then
                bits[#bits + 1] = "действие — кнопка A"
            else
                bits[#bits + 1] = string.format("%.0f м", d)
            end
            say(table.concat(bits, ", "))
            return true
        end

        -- Walking, but no nearer than it has been for a while: the character is going round
        -- something, or the engine is pathing to a spot on the far side of a wall. Standing
        -- still is caught below and sounds like a stop; this one sounds exactly like a walk,
        -- which is why it went unnoticed for a whole session.
        if w.best == nil or d < w.best - 0.5 then
            w.best, w.bestAt = d, now
        elseif (now - (w.bestAt or now)) > M.WALK_CIRCLE_MS then
            w.bestAt = now
            say("Не приближаемся: " .. tostring(w.name) .. ", " .. string.format("%.0f м", d))
            return true
        end
    end

    -- Still moving? Any change of position counts; the engine's walk is not smooth enough to
    -- measure speed, but standing perfectly still for two seconds is a stop, not a step.
    local moved = false
    if w.lastPos ~= nil then
        local dx, dz = p[1] - w.lastPos[1], p[3] - w.lastPos[3]
        moved = (dx * dx + dz * dz) > 0.04         -- twenty centimetres
    end
    if moved then
        w.lastPos, w.lastMove, w.said = p, now, nil
        return false
    end
    if (now - w.lastMove) > M.WALK_STUCK_MS and w.said ~= "stuck" then
        w.said = "stuck"
        local left = ""
        if tp ~= nil then
            local dx, dz = tp[1] - p[1], tp[3] - p[3]
            left = ", осталось " .. string.format("%.0f м", math.sqrt(dx * dx + dz * dz))
        end
        say("Стою" .. left .. ", дальше не идёт")
        M.walking = nil
        return true
    end
    return false
end

--- Hear the server say no.
---
--- The server refuses a destination it cannot find standable ground for, and a refusal that
--- is not spoken is indistinguishable from a layer that has died: the player pressed the key
--- and the character is simply standing there.
local function onNet(channel, payload)
    if channel ~= M.CHANNEL then return end
    local msg = soft(Ext.Json.Parse, payload)
    if type(msg) ~= "table" then return end
    if msg.cmd == "refused" then say("Туда не пройти") end
    if msg.cmd == "stopped" then
        -- Kept rather than spoken: the player has already heard "Стоп", and will hear this
        -- back only if the character is still moving two seconds later. An empty "how" means
        -- the build exports nothing that clears a character's task queue - which is the whole
        -- explanation for a stop key that answers and does nothing, and it should reach the
        -- player as a sentence rather than as a line in a log they cannot read.
        M.stopHow = tostring(msg.how or "")
        _P("[nav] stop acknowledged, how=" .. M.stopHow)
    end
end

function M.listen()
    if _G.A11Y_NAV_CLIENT ~= nil then
        soft(function() Ext.Events.NetMessage:Unsubscribe(_G.A11Y_NAV_CLIENT) end)
        _G.A11Y_NAV_CLIENT = nil
    end
    local id = Ext.Events.NetMessage:Subscribe(function(e)
        onNet(soft(function() return e.Channel end), soft(function() return e.Payload end))
    end)
    _G.A11Y_NAV_CLIENT = id
    return id ~= nil
end

-- combat ---------------------------------------------------------------------------
--
-- Combat had never been reached in any session, and it turned out to need no new machinery:
-- the components are all on the client.
--
--   Health           Hp, MaxHp, TemporaryHp, IsInvulnerable
--   CombatParticipant CombatHandle (set = in this fight), InitiativeRoll, Flags(CanFight)
--   TurnBased        IsActiveCombatTurn (whose turn it is), CombatTeam (who is with whom),
--                    HadTurnInCombat, RequestedEndTurn
--
-- Which gives the three things a blind player cannot fight without: whose turn it is, how
-- much health everyone has, and where the enemies are standing.

local function healthOf(e)
    local h = soft(function() return e.Health end)
    if h == nil then return nil end
    local hp = soft(function() return h.Hp end)
    local max = soft(function() return h.MaxHp end)
    if type(hp) ~= "number" then return nil end
    return hp, max, soft(function() return h.TemporaryHp end)
end
M.healthOf = healthOf

--- Everyone in the current fight, with where they stand and how they are doing.
function M.combat()
    local me = M.me()
    if me == nil then return nil end
    local myHandle = soft(function() return me.CombatParticipant.CombatHandle end)
    local myTeam = soft(function() return tostring(me.TurnBased.CombatTeam) end)
    local myPos = positionOf(me)
    local yaw = yawOf(me)

    local out = { inCombat = myHandle ~= nil, allies = {}, enemies = {}, active = nil,
                  myTeam = myTeam }
    local hp, max = healthOf(me)
    out.me = { name = nameOf(me) or "вы", hp = hp, max = max }
    if myHandle == nil then return out end

    -- The CombatHandle every participant carries *is* the combat: that entity holds
    -- CombatState with the whole roster and the initiative rolls, plus a TurnOrder
    -- component. Asking it directly beats sweeping the level - and it has to be asked,
    -- because GetAllEntitiesWithComponent("CombatParticipant") comes back empty on the
    -- client even while the component reads fine on individual entities.
    local parts = soft(function() return myHandle.CombatState.Participants end)
    if parts == nil then return out end
    local n = tonumber(soft(function() return #parts end)) or 0

    for i = 1, n do
        local e = soft(function() return parts[i] end)
        if e ~= nil then
            local name = nameOf(e)
            if name ~= nil then
                local p = positionOf(e)
                local dist, dir = nil, nil
                if p ~= nil and myPos ~= nil then
                    local dx, dz = p[1] - myPos[1], p[3] - myPos[3]
                    dist = math.sqrt(dx * dx + dz * dz)
                    dir = bearing(dx, dz, yaw)
                end
                local team = soft(function() return tostring(e.TurnBased.CombatTeam) end)
                local active = soft(function() return e.TurnBased.IsActiveCombatTurn end)
                local h, m = healthOf(e)
                -- A fight's roster includes the scenery: reservoirs, tubers and loose
                -- objects join combat with initiative -20 and no CanFight. Reading them out
                -- as enemies buries the four things actually trying to kill you.
                local flags = tostring(soft(function()
                    return tostring(e.CombatParticipant.Flags)
                end) or "")
                local rec = { entity = e, name = name, hp = h, max = m, dist = dist,
                              dir = dir, active = active == true,
                              canFight = flags:find("CanFight", 1, true) ~= nil,
                              initiative = soft(function() return e.CombatParticipant.InitiativeRoll end) }
                if active == true then out.active = rec end
                -- Party membership decides before the team guid does: the guid is reliable
                -- for grouping but says nothing about which group is ours.
                local isMine = soft(function() return e.PartyMember end) ~= nil
                              or (team ~= nil and myTeam ~= nil and team == myTeam)
                if isMine then
                    out.allies[#out.allies + 1] = rec
                else
                    out.enemies[#out.enemies + 1] = rec
                end
            end
        end
    end

    local function byDist(a, b) return (a.dist or 999) < (b.dist or 999) end
    table.sort(out.enemies, byDist)
    table.sort(out.allies, byDist)
    return out
end

local function healthWord(rec)
    if rec.hp == nil then return nil end
    if rec.hp <= 0 then return "повержен" end
    return rec.hp .. " из " .. tostring(rec.max)
end

--- The situation, out loud.
function M.combatSay()
    local c = M.combat()
    if c == nil then say("Нет данных") return end
    if not c.inCombat then say("Не в бою") return end

    local parts = {}
    if c.active ~= nil then
        parts[#parts + 1] = "Ход: " .. c.active.name
    end
    local mine = healthWord(c.me)
    if mine then parts[#parts + 1] = "вы " .. mine end

    -- The clock first, when there is one: a fight with a turn limit is lost by ignoring it,
    -- however well the fighting goes.
    local obj = M.objective()
    if obj ~= nil and obj.turns ~= nil then parts[#parts + 1] = obj.turns end
    local fighters = {}
    for i = 1, #c.enemies do
        local e = c.enemies[i]
        if e.canFight and (e.hp == nil or e.hp > 0) then fighters[#fighters + 1] = e end
    end
    if #fighters == 0 then
        parts[#parts + 1] = "врагов не видно"
    else
        parts[#parts + 1] = "врагов " .. #fighters
        for i = 1, math.min(#fighters, 5) do
            local e = fighters[i]
            local bits = { e.name }
            local hw = healthWord(e)
            if hw then bits[#bits + 1] = hw end
            if e.dir then bits[#bits + 1] = e.dir end
            if e.dist then bits[#bits + 1] = string.format("%.0f м", e.dist) end
            parts[#parts + 1] = table.concat(bits, ", ")
        end
    end
    say(table.concat(parts, ". "))
    return c
end

M.lastTurn = nil
M.wasInCombat = false

--- Announce the things that cannot be asked for after the fact: the fight starting, and the
--- turn passing. Everything else is available on request.
function M.combatTick()
    local c = M.combat()
    if c == nil then return false end

    if c.inCombat and not M.wasInCombat then
        M.wasInCombat = true
        M.lastTurn = nil
        say("Бой. " .. #c.enemies .. " против " .. (#c.allies + 1))
        return true
    end
    if not c.inCombat then
        if M.wasInCombat then
            M.wasInCombat = false
            M.lastTurn = nil
            say("Бой окончен")
        end
        return false
    end

    local who = c.active and c.active.name or nil
    if who ~= M.lastTurn then
        M.lastTurn = who
        if who == nil then return true end
        local mineNow = c.active and c.me and c.active.name == c.me.name
        if mineNow then
            local mine = healthWord(c.me)
            say("Ваш ход" .. (mine and (", " .. mine) or ""))
        else
            say("Ход: " .. who)
        end
    end
    return true
end

-- the game's own target cursor -------------------------------------------------------
--
-- The D-pad's left and right cycle through targets in combat - the game's own mechanism,
-- and a far better list than anything the scanner assembles, because it contains exactly
-- what can be acted on and in the order the game will step through. It was going entirely
-- unannounced.
--
--   GetPickingHelper(1).Selection          the target under the cursor
--     .field_0_Entity                      which entity that is
--     .field_8_TurnOrder                   its place in the cycle, from 0
--   GetPickingHelper(1).SelectableObjects  the whole cycle

function M.target()
    local ph = soft(Ext.ClientUI.GetPickingHelper, 1)
    if ph == nil then return nil end
    local sel = soft(function() return ph.Selection end)
    if sel == nil then return nil end
    local e = soft(function() return sel.field_0_Entity end)
    if e == nil then return nil end

    local out = { entity = e, name = nameOf(e) }
    out.index = tonumber(soft(function() return sel.field_8_TurnOrder end))
    out.total = tonumber(soft(function() return #ph.SelectableObjects end))
    out.hp, out.max = healthOf(e)
    out.party = soft(function() return e.PartyMember end) ~= nil

    -- Whether this one can be attacked, which the cycle itself does not say: it steps
    -- through allies and scenery just as readily as through enemies.
    local flags = tostring(soft(function() return tostring(e.CombatParticipant.Flags) end) or "")
    out.canFight = flags:find("CanFight", 1, true) ~= nil
    local myTeam = soft(function() return tostring(M.me().TurnBased.CombatTeam) end)
    local team = soft(function() return tostring(e.TurnBased.CombatTeam) end)
    if out.party then out.side = "спутник"
    elseif out.canFight and team ~= nil and myTeam ~= nil and team ~= myTeam then
        out.side = "враг"
    elseif not out.canFight then out.side = "объект" end

    local me = M.me()
    local mp = me and positionOf(me)
    local p = positionOf(e)
    if mp ~= nil and p ~= nil then
        local dx, dz = p[1] - mp[1], p[3] - mp[3]
        out.dist = math.sqrt(dx * dx + dz * dz)
        out.dir = bearing(dx, dz, yawOf(me))
    end
    return out
end

local function targetPhrase(t)
    local bits = { t.name or "цель" }
    if t.side then bits[#bits + 1] = t.side end
    if t.hp ~= nil then
        bits[#bits + 1] = (t.hp <= 0) and "повержен" or (t.hp .. " из " .. tostring(t.max))
    end
    -- No clock bearing here either, for the same reason it left the scanner: there is no key
    -- that turns anyone, so "на десять" is a word and a half of listening that changes nothing
    -- the player can do. The distance is what decides whether a target is reachable.
    if t.dist then bits[#bits + 1] = string.format("%.0f м", t.dist) end
    if t.index ~= nil and t.total ~= nil and t.total > 1 then
        bits[#bits + 1] = (t.index + 1) .. " из " .. t.total
    end
    return table.concat(bits, ", ")
end
M.targetPhrase = targetPhrase

M.lastTarget = nil

--- Announce the target as it changes. This is the one readout that has to be automatic:
--- the player is pressing left and right precisely to hear what comes next.
--- Returns true only when it actually said something, which is what lets the pass that
--- announced a target keep the world cursor quiet (see the reader): the game rewrites
--- `CursorText_c` on every step of the target cycle, so the two of them together turned one
--- press into "Пожиратель интеллекта, враг, 3 из 10, 6 м" followed by "Урон:, Атака основной
--- рукой, Недостаточно движения" - the second one burying the first.
function M.targetTick()
    local t = M.target()
    if t == nil then
        M.lastTarget = nil
        return false
    end
    local key = tostring(t.entity) .. "|" .. tostring(t.hp)
    if key == M.lastTarget then return false end
    M.lastTarget = key
    if t.name == nil then return false end
    say(targetPhrase(t))
    return true
end

function M.targetSay()
    local t = M.target()
    if t == nil then say("Цель не выбрана") return nil end
    say(targetPhrase(t))
    return t
end

-- What the game itself says is under the world cursor.
--
-- `CursorText_c` is the one place BG3 already answers the blind player's whole question: the
-- verb it would carry out, the thing it would do it to, the distance, and the reason it will
-- not. Caught mid-fight it held "Перейти / Кровь иллитида / 104 фут / Недостаточно движения" -
-- four facts that no scanner of ours could have assembled, because three of them are the
-- game's own judgement about the move rather than anything standing in the world.
--
-- So aiming becomes a conversation: the cursor moves, the game names what it found, the layer
-- repeats it. Nothing is reconstructed from coordinates and nothing has to be aimed blind.
--
-- Two things are dropped. Raw localisation handles (`h` followed by hex, which the widget
-- carries beside the resolved text) are not words. And the reading is reversed: the tree
-- order comes out refusal-first and ends with the verb, while spoken sense runs the other way
-- round - verb, object, distance, refusal. That is an observed order, not a documented one,
-- so nothing else depends on it.
M.lastCursor = nil
M.lastCursorKey = nil

-- What is never worth saying: raw localisation handles and unresolved string ids that the
-- widget carries beside the real text, and the lone punctuation it uses as separators.
local function junk(s)
    if #s == 0 then return true end
    if s:find("^h%x%x%x%x%x%x%x%x") then return true end
    if s:find("^ResStr_") then return true end
    -- A bare label. "Урон:" arrives with nothing after it - the number it introduces is drawn
    -- somewhere this scan does not reach - so it is a colon read out loud, once per press.
    if s:find(":%s*$") then return true end
    return s == "~" or s == "*" or s == "-" or s == ":"
end

--- A distance reading rather than a word - "1,8 фут", "104 фут", "3 м".
local function isDistance(s)
    return s:find("^%d+[%.,]?%d*%s*фут") ~= nil or s:find("^%d+[%.,]?%d*%s*м$") ~= nil
end

function M.cursorParts()
    local pad = _G.Pad
    if pad == nil then return nil end
    local ws = pad.findWidgets()
    local node = nil
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false and tostring(w.name) == "CursorText_c" then node = w.node end
    end
    if node == nil then return nil end

    local info = pad.visibleScan(node, 200, 12)
    if info == nil then return nil end
    local parts, seen = {}, {}
    for i = #info.texts, 1, -1 do
        local s = info.texts[i]
        if not junk(s) and not seen[s] then
            seen[s] = true
            parts[#parts + 1] = s
        end
    end
    if #parts == 0 then return nil end
    return parts
end

function M.cursorText()
    local parts = M.cursorParts()
    if parts == nil then return nil end
    return table.concat(parts, ", ")
end

--- Say it as it changes. Same reasoning as the target cursor: the player is moving the aim
--- precisely to hear what it lands on, so this is one of the few readouts that has to be
--- automatic rather than asked for.
---
--- "As it changes" is the hard part. The widget flickers: standing still in front of one
--- object it produced "Перейти, Кровь, 1,8 фут", then "Кровь, 1,8 фут", then "Перейти,
--- Кровь", then the first again - the same fact said seven times because a line blinked out
--- of the panel for a frame. So the comparison ignores two things it must not react to.
---
--- The distance is dropped from the key: it ticks over continuously while walking and would
--- restart the sentence on every centimetre, while the number itself is still spoken as part
--- of the phrase. And a reading whose words are a subset of the last one is the flicker,
--- not a new object - only genuinely different words are worth interrupting for.
local function keyOf(parts)
    local words = {}
    for _, s in ipairs(parts) do
        if not isDistance(s) then words[#words + 1] = s end
    end
    table.sort(words)
    return table.concat(words, "|"), words
end

local function subset(a, b)          -- is every word of a present in b
    local have = {}
    for _, w in ipairs(b) do have[w] = true end
    for _, w in ipairs(a) do if not have[w] then return false end end
    return true
end

M.lastCursorWords = nil

-- How long the same cursor reading stays uninteresting once it has been said.
M.CURSOR_REPEAT_MS = 10000
M.cursorSaid = {}
M.cursorSaidN = 0

function M.cursorTick()
    local parts = M.cursorParts()
    if parts == nil then
        M.lastCursor, M.lastCursorKey, M.lastCursorWords = nil, nil, nil
        return false
    end

    local key, words = keyOf(parts)
    if key == M.lastCursorKey then return false end
    if M.lastCursorWords ~= nil and #words > 0 and
       (subset(words, M.lastCursorWords) or subset(M.lastCursorWords, words)) then
        -- Same thing, fewer or more lines on the panel. Keep the richer wording as the
        -- reference so the flicker cannot ratchet the key down to a single word.
        if #words > #M.lastCursorWords then
            M.lastCursorKey, M.lastCursorWords = key, words
        end
        return false
    end

    -- Said this recently already. The cursor panel does not flicker between two readings so
    -- much as cycle through four - verb, verb plus target, verb plus refusal, verb plus
    -- distance - and each of them is genuinely different words, so the subset test above lets
    -- every one of them through. Over a target cycle in combat that is four sentences per
    -- press, none of them new. A line is worth interrupting for once; the fifth time in ten
    -- seconds it is noise whatever it says.
    local now = soft(Ext.Utils.MonotonicTime) or 0
    if M.cursorSaid[key] ~= nil and (now - M.cursorSaid[key]) < M.CURSOR_REPEAT_MS then
        M.lastCursorKey, M.lastCursorWords = key, words
        return false
    end
    -- Kept small by hand: this is a cache of what was just said, not a history.
    if M.cursorSaidN > 24 then M.cursorSaid, M.cursorSaidN = {}, 0 end
    M.cursorSaid[key] = now
    M.cursorSaidN = M.cursorSaidN + 1

    M.lastCursorKey, M.lastCursorWords = key, words
    M.lastCursor = table.concat(parts, ", ")
    say(M.lastCursor)
    return true
end

function M.cursorSay()
    local t = M.cursorText()
    say(t or "Под курсором ничего")
    return t
end

--- Walk up to whatever is under the target cursor.
---
--- Closing to melee is the one move the cursor cannot make on its own: it selects, it does
--- not approach. Going to the object rather than to its coordinates matters more here than
--- anywhere - the engine stops at reach instead of trying to stand where the enemy is.
function M.approach()
    local t = M.target()
    if t == nil then say("Цель не выбрана") return false end
    local uuid = soft(function() return t.entity.Uuid.EntityUuid end)
    if type(uuid) ~= "string" or uuid == "" then
        say("К этой цели нельзя подойти")
        return false
    end
    local body = soft(Ext.Json.Stringify, { cmd = "gotoObject", uuid = uuid })
    local r = try(function() Ext.Net.PostMessageToServer(M.CHANNEL, body) end)
    if not r.ok then say("Не получилось подойти") return false end
    M.walkStarted(uuid, t.name)
    say("Иду к: " .. tostring(t.name) ..
        (t.dist and (", " .. string.format("%.0f м", t.dist)) or ""))
    return true
end

-- the objective ----------------------------------------------------------------------
--
-- Some fights are not won by killing anyone. This one is "reach the transmitter before the
-- nautiloid crashes", on a clock of fifteen turns - and none of that was being said, while
-- it decides everything the player should do.
--
-- The minimap widget carries both the objective and the clock, next to the coordinate
-- readout and an update marker that have to be dropped.

local OBJECTIVE_NOISE = { ["[ForceUpdate]"] = true }

--- Does the string contain a lowercase Cyrillic letter?
---
--- Lua's lower() leaves Cyrillic alone, so case is checked against the UTF-8 byte ranges
--- directly: а-п is D0 B0..BF, р-я is D1 80..8F. Capitals mean a title, mixed case means a
--- phrase someone wrote to be read.
local function hasLower(s)
    return s:find("\208[\176-\191]") ~= nil or s:find("\209[\128-\143]") ~= nil
end
M.hasLower = hasLower

--- The objective of the moment, and the turns left on it.
function M.objective()
    local pad = _G.Pad
    if pad == nil then return nil end
    local ws = pad.findWidgets()
    local node = nil
    for i = 1, #ws do
        if ws[i].visible ~= false and tostring(ws[i].name):find("Minimap", 1, true) then
            node = ws[i].node
        end
    end
    if node == nil then return nil end

    local info = pad.visibleScan(node, 600, 24)
    local out = { text = nil, turns = nil, place = nil, markers = {} }
    for _, s in ipairs(info.texts) do
        if not OBJECTIVE_NOISE[s] then
            -- The coordinate readout arrives in two spellings, "X:285 Y:290" and "285 Y:290";
            -- the second one slipped past a check for the prefix and was taken for the turn
            -- counter, so both are recognised by the Y: instead.
            if s:find("^X:") or s:find("Y:") then
            elseif s:find("^%d+$") then                 -- the bare number beside the clock
            elseif s:find(":%s*%d+%s*$") then out.turns = s
            elseif not hasLower(s) then
                -- Set in capitals: the region title. It shares the widget with everything
                -- else and passed the old length test, so "МЕСТО КРУШЕНИЯ" was read as the
                -- objective and the quest category matched things named after the shipwreck.
                if #s > 8 then out.place = s end
            elseif #s > 40 then
                out.text = s                            -- a sentence: the objective proper
            elseif #s > 6 then
                -- A short phrase in mixed case is a **map marker label** - "Заросшие руины",
                -- "Древняя дверь". These are the points the story runs through, and they are
                -- the only thing in the game that answers "where do I go" without eyes: no
                -- entity nearby carries MapMarkerStyle, and the marker components the client
                -- registers hold no entities at all.
                out.markers[#out.markers + 1] = s
            end
        end
    end
    -- The minimap says nothing about the task on a beach where nothing has been discovered
    -- yet, and that is most of the time a player is lost. The journal knows - it is read and
    -- kept by the screen side whenever it is open (Pad.journalRefresh), so the objective
    -- survives the journal being closed.
    if out.text == nil then
        local b = M.bookObjective()
        if b ~= nil then
            out.text = b.text
            out.quest = b.title
            out.fromBook = true
        end
    end

    if out.text == nil and out.turns == nil and out.place == nil and #out.markers == 0 then
        return nil
    end
    return out
end

--- The task the journal knows, when the minimap has nothing.
---
--- The one the player last selected wins, then any quest still in progress; the completed
--- category is skipped by name, matched without its first letter because Lua's `lower()` does
--- not touch Cyrillic and the word is written both ways.
function M.bookObjective()
    local book = M.questBook
    if type(book) ~= "table" or type(book.quests) ~= "table" then return nil end
    local best = nil
    for _, q in ipairs(book.quests) do
        local cat = tostring(q.category or "")
        if not cat:find("авершен", 1, true) then
            local task = nil
            for _, o in ipairs(q.objectives or {}) do
                if not o.done and (task == nil or (o.priority or 0) < (task.priority or 0)) then
                    task = o
                end
            end
            if task ~= nil then
                local score = (q.selected and 2 or 0) + (q.inProgress and 1 or 0)
                if best == nil or score > best.score then
                    best = { title = q.title, text = task.text, score = score }
                end
            end
        end
    end
    return best
end

--- Word stems of the objective, for matching against what is standing in the world.
---
--- The first character is dropped from each: the objective says "до передатчика" and the
--- thing is called "Передатчик", so skipping the initial letter sidesteps both the case
--- difference and the fact that Lua's lower() does not touch Cyrillic. What remains is a
--- byte prefix, which also absorbs the case endings.
local function stems(text)
    local out = {}
    for w in text:gmatch("[^%s,%.!%?:;%(%)«»\"]+") do
        if #w >= 12 then out[#out + 1] = w:sub(3, 16) end
    end
    return out
end
M.stems = stems

--- Where the objective actually is, if anything nearby is named after it.
---
--- A wide sweep on purpose: quest targets are routinely well outside the 20 m the ordinary
--- scan uses, and 60 m costs 2.4 ms, which is affordable on request.
function M.findObjective(radius)
    local obj = M.objective()
    if obj == nil or obj.text == nil then return nil, obj end
    local keys = stems(obj.text)
    if #keys == 0 then return nil, obj end

    local list = M.scan(radius or 60)
    if list == nil then return nil, obj end
    local hits = {}
    for i = 1, #list do
        local name = list[i].name
        for _, k in ipairs(keys) do
            if name:find(k, 1, true) then hits[#hits + 1] = list[i] break end
        end
    end
    return hits, obj
end

function M.objectiveSay(withHint)
    local hits, obj = M.findObjective()
    if obj == nil then say("Задача не видна") return nil end
    local parts = {}
    if obj.text then parts[#parts + 1] = obj.text end
    if obj.turns then parts[#parts + 1] = obj.turns end
    if hits ~= nil and #hits > 0 then
        parts[#parts + 1] = describe(hits[1])
        M.objectiveTarget = hits[1]
        if withHint then parts[#parts + 1] = "ещё раз — идти" end
    else
        parts[#parts + 1] = "цель не найдена поблизости"
        M.objectiveTarget = nil
    end
    say(table.concat(parts, ". "))
    return hits, obj
end

--- Ask the server to walk the character to a scan entry.
---
--- To the object where there is a uuid, so the engine stops at interaction range instead of
--- trying to stand inside the thing; to bare coordinates otherwise.
--- Objects only. A thing without a uuid is a thing the layer cannot send anyone to: moving by
--- coordinates does not walk, it places, and the place may be the sea (see the server half).
local function walkTo(it)
    local uuid = soft(function() return it.entity.Uuid.EntityUuid end)
    if type(uuid) ~= "string" or uuid == "" then return false end
    local body = soft(Ext.Json.Stringify, { cmd = "gotoObject", uuid = uuid })
    return try(function() Ext.Net.PostMessageToServer(M.CHANNEL, body) end).ok
end
M.walkTo = walkTo

-- The objective, as a place to go rather than a sentence to hear.
--
-- Groping for a quest object with the world cursor is the part of playing blind that has no
-- answer: the cursor gives no clue where it is until it lands on something, and the thing the
-- objective names is normally out of the target cycle's reach. So one button carries the
-- whole loop instead - it re-reads the objective, finds what it names, and walks there; press
-- it again and it says how far is left; press it after the objective changes and it leads
-- somewhere else, because it never trusts a remembered target.
--
-- Re-resolved on every press rather than cached. A 60 m sweep costs 2.4 ms, and everything
-- else about a fight moves: the character walks, the objective completes, the named object is
-- picked up or destroyed. A stale target is worse than a slow one - it sends the player
-- confidently to where the answer used to be.
-- Metres. Deliberately shorter than it looks like it should be: the engine stops a walk at
-- interaction range by itself, so being generous here only means announcing "you are there"
-- while the game still refuses the action. Below this, walking again would gain nothing; above
-- it, let the engine decide where to stop.
M.ARRIVE = 2.0
M.questText = nil

local function dm(d) return string.format("%.0f м", d or 0) end

function M.questGo()
    local hits, obj = M.findObjective(80)
    if obj == nil then say("Задача не видна") return false end

    local parts = {}
    -- The wording is repeated only when it has changed. On the fifth press in a row, the
    -- sentence is not what the player is listening for - the distance is.
    if obj.text ~= nil and obj.text ~= M.questText then
        -- Name the quest with the task the first time it is said: out of the journal the task
        -- alone ("Найдите способ извлечь личинку") does not say which story it belongs to.
        if obj.quest ~= nil then parts[#parts + 1] = obj.quest end
        parts[#parts + 1] = obj.text
        M.questText = obj.text
    end
    if obj.turns then parts[#parts + 1] = obj.turns end

    local it = hits and hits[1] or nil

    -- No objective object, or no objective at all: fall back to the map markers. Between
    -- quests - which is exactly when a player is most lost - the marker labels are the only
    -- thing the game still says about where the story lies, and the nearest of them is a
    -- better answer than "nothing found".
    if it == nil then
        local mhits = M.markerHits()
        if mhits ~= nil and #mhits > 0 then
            it = mhits[1]
            parts[#parts + 1] = "метка"
        end
    end

    if it == nil then
        M.questTarget = nil
        if obj.markers ~= nil and #obj.markers > 0 then
            -- The label is on the map but nothing near carries that name: still worth saying,
            -- because it names the direction the story runs even when the thing is far.
            parts[#parts + 1] = "метки: " .. table.concat(obj.markers, ", ") .. ", рядом не найдено"
        elseif obj.text == nil and obj.place ~= nil then
            parts[#parts + 1] = "Задачи нет. " .. obj.place
        else
            parts[#parts + 1] = "цель не видна поблизости"
        end
        say(table.concat(parts, ". "))
        return false
    end
    M.questTarget = it

    local d = it.dist or 0
    if d <= M.ARRIVE then
        -- Arrival is the point where the layer runs out of moves: BG3 has no Osiris call for
        -- using a thing (CharacterUseItem, UseObject, Activate - none of them exist), so the
        -- action stays on the player's button. Saying so plainly beats walking on the spot.
        parts[#parts + 1] = it.name .. ", " .. tostring(it.dir) .. ", " .. dm(d) ..
                            (M.canInteract(it.entity, d) and ". Вы на месте, действие — кнопка A"
                                                          or ". Вы на месте")
        say(table.concat(parts, ". "))
        return true
    end

    if not walkTo(it) then
        parts[#parts + 1] = "не получилось пойти"
        say(table.concat(parts, ". "))
        return false
    end
    M.walkStarted(soft(function() return it.entity.Uuid.EntityUuid end), it.name)
    parts[#parts + 1] = "иду: " .. it.name .. ", " .. dm(d) .. ", " .. tostring(it.dir)
    say(table.concat(parts, ". "))
    return true
end

-- Kept as the old name; everything about it now lives in questGo.
M.goObjective = M.questGo

--- Say the objective the moment it changes, without being asked.
---
--- The completion of one objective and the appearance of the next is the one event in a quest
--- that a blind player cannot notice at all - the minimap simply says something else. It is
--- also exactly when the navigator button starts leading somewhere new, so the two belong
--- together.
M.questAnnounced = nil

function M.questTick()
    local obj = M.objective()
    local text = obj and obj.text
    if text == M.questAnnounced then return false end
    M.questAnnounced = text
    if text == nil then return false end
    M.questText = text
    local parts = { "Задача", text }
    if obj.turns then parts[#parts + 1] = obj.turns end
    say(table.concat(parts, ". "))
    return true
end

-- calibration ----------------------------------------------------------------------

--- Which quaternion reading is the real facing, and which way the bearing runs.
---
--- Written to a file rather than guessed: the two readings differ by axis order, and a
--- bearing that is silently mirrored is worse than none - it sends the player the wrong way
--- with full confidence. Turn the character to face a known object and compare.
function M.calibrate(tag)
    local me = M.me()
    if me == nil then return nil end
    local pos = positionOf(me)
    local a, b = yawOf(me)
    local steer = soft(function() return me.Steering.TargetRotation end)
    local out = { tag = tostring(tag), pos = pos, yawXYZW = a, yawWXYZ = b,
                  steering = steer, targets = {} }
    local list = M.scan()
    for i = 1, math.min(#(list or {}), 6) do
        local it = list[i]
        local dx, dz = it.pos[1] - pos[1], it.pos[3] - pos[3]
        local _, angA = bearing(dx, dz, a)
        local _, angB = bearing(dx, dz, b)
        out.targets[i] = { name = it.name, dist = it.dist,
                           raw = math.atan(dx, dz),
                           relXYZW = angA, relWXYZ = angB }
    end
    A.write("nav_calibrate_" .. tostring(tag or "now"), out)
    _P("[nav] calibrate: yawXYZW=" .. tostring(a) .. " yawWXYZ=" .. tostring(b) ..
       " steering=" .. tostring(steer))
    return out
end

-- Stamped so a session can be told apart from the one before it. A push that does not take -
-- because the game was not focused when the console line was sent, or because only the client
-- half was reloaded - is otherwise invisible: the layer answers, it just answers the old way,
-- and a whole session gets spent testing code that is not running.
M.BUILD = "nav-2 stop/progress/live-scan"

_P("[nav] a11y-nav loaded (" .. M.BUILD .. "). Nav.progress() / Nav.step(1) / Nav.where()")
return M
