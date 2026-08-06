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
-- The level index, built by the server half ------------------------------------------------
--
-- A thing with no display name is dropped by the scan, and that is not a rare corner: the
-- transponder that ends the prologue and the rune-key that opens Shadowheart's pod both have
-- **no `DisplayName` at all**. A player could stand ten metres from the object their
-- objective names and hear nothing, and no radius or better word-matching could have helped -
-- there is no word to match.
--
-- The server writes down what those things are, taken from the template name the level
-- designer wrote (see a11y-nav-server.lua). This reads that file once and keeps it, so a
-- nameless entity can still be called something: "пульт", "рычаг", "лестница", "ключ".
M.index = nil
M.indexAt = 0

--- The index, read from disk once and then kept.
---
--- The miss path matters more than the hit here: this is called from `nameOf`, which runs for
--- every entity of every sweep, so "no index yet" has to cost nothing at all. Hence the
--- counter - a missing file is re-checked every few hundred calls, not every one, and the
--- request to build it goes out once rather than on each nameless barrel.
M.indexMiss = 0
M.indexAsked = false

--- Which level the character is standing in, as the engine names it.
function M.myLevel()
    local me = M.me()
    if me == nil then return nil end
    local lv = soft(function() return me.Level.LevelName end)
    return lv and tostring(lv) or nil
end

--- Throw the index away when the level changes, and ask for a new one.
---
--- Nothing did this, and the cost was the worst bug the layer has had. The index is a file, so
--- it outlives the save load that takes the player to another region - and every row in it is
--- then an object somewhere else, offered as a landmark, at a distance computed from
--- coordinates that mean nothing here. Walking to one is not a walk: the engine drags the
--- character into the other level and the party stays behind.
---
--- Measured on the save where it bit, in Пустошь, against an index built in the prologue the
--- night before: 41 rows, of which **one** was in this level, four were in other levels, and
--- thirty-six no longer existed.
M.levelSeen = nil

function M.levelWatch()
    local lv = M.myLevel()
    if lv == nil or lv == M.levelSeen then return false end
    local was = M.levelSeen
    M.levelSeen = lv
    if was == nil then return false end
    _P("[nav] level " .. tostring(was) .. " -> " .. lv .. ", dropping the index")
    M.index, M.indexAsked, M.indexMiss = nil, false, 0
    M.anchors, M.anchorsAt = nil, 0
    soft(function() M.requestIndex(true) end)
    return true
end

local function levelIndex()
    if M.index ~= nil then return M.index end
    M.indexMiss = M.indexMiss + 1
    if M.indexMiss % 500 ~= 1 then return nil end
    local src = soft(Ext.IO.LoadFile, "A11y/level_index.txt")
    if type(src) ~= "string" or src == "" then
        if not M.indexAsked then
            M.indexAsked = true
            soft(function() M.requestIndex() end)
            _P("[nav] level index missing - asked the server to build one")
        end
        return nil
    end
    -- Whose level is this a list of? A file without the answer is from before the question was
    -- asked, and those are the ones that dragged a character across a region - so an unmarked
    -- file is discarded rather than trusted, and a fresh one asked for.
    local head = src:match("^#level\t([^\r\n]+)")
    local mine = M.myLevel()
    if head == nil or (mine ~= nil and head ~= mine) then
        _P("[nav] level index is for " .. tostring(head) .. ", we are in " .. tostring(mine) ..
           " - discarded")
        if not M.indexAsked then
            M.indexAsked = true
            soft(function() M.requestIndex(true) end)
        end
        return nil
    end

    local by = {}
    local n = 0
    for line in src:gmatch("[^\r\n]+") do
        local u, kind, x, y, z, tpl = line:match("^(%S+)\t([^\t]+)\t(%S+)\t(%S+)\t(%S+)\t(.*)$")
        if u ~= nil then
            n = n + 1
            by[u] = { kind = kind, x = tonumber(x), y = tonumber(y), z = tonumber(z),
                      template = tpl }
        end
    end
    if n == 0 then return nil end

    -- The fast-travel shrines arrive from the server as "точка перехода" and nothing else, and
    -- a level holds up to sixteen of them - a list of sixteen identical rows, which is the same
    -- as no list. The game names every one, so the shipped place table renames them here, where
    -- both `nameOf` and the landmark list pick it up for free.
    local _, wps = M.placeTables()
    if wps ~= nil then
        local lower = {}
        for u in pairs(by) do lower[tostring(u):lower()] = u end
        for i = 1, #wps do
            local key = lower[tostring(wps[i][3]):lower()]
            if key ~= nil then by[key].kind = M.wpName(wps[i]) end
        end
    end

    M.index = by
    _P("[nav] level index: " .. n .. " navigable things")
    return by
end
M.levelIndex = levelIndex

--- Ask the server to build it. Cheap to call: the server ignores a second request while one
--- is already walking the level.
function M.requestIndex(force)
    M.index = nil
    local body = soft(Ext.Json.Stringify, { cmd = "index", force = force == true })
    return try(function() Ext.Net.PostMessageToServer(M.CHANNEL, body) end).ok
end

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
    -- Nothing the game will say out loud. Before giving up - which used to mean the object
    -- vanished from the scan entirely - ask what the level was built from.
    local idx = levelIndex()
    if idx ~= nil then
        local u = soft(function() return e.Uuid.EntityUuid end)
        local row = u and idx[u]
        if row ~= nil then return row.kind, true end
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
---
--- **Both spellings go in, and that is a bug fix, not thoroughness.** The engine lists a
--- component as `eoc::item_template::UseActionComponent`; everything that indexes an entity
--- spells it `UseAction`. The set was built from the first and read with the second, so not one
--- lookup in it ever matched - `canInteract` answered false for every object in the world, and
--- "действие — кнопка A" was a line the layer could not reach. Measured at the pod on the
--- nautiloid: one metre away, carrying UseAction, and canInteract said no.
local function compSet(e)
    local names = soft(function() return e:GetAllComponentNames() end)
    if type(names) ~= "table" then return nil end
    local set = {}
    for i = 1, #names do
        local full = tostring(names[i])
        set[full] = true
        local tail = full:match("([^:]+)$")
        if tail ~= nil then
            local short = tail:gsub("Component$", "")
            if short ~= "" then set[short] = true end
        end
    end
    return set
end
M.compSet = compSet

-- Metres. The engine stops a walk at its own interaction range, which is well inside this;
-- arriving is measured more loosely (WALK_ARRIVE) so that a walk which ends a little short is
-- still called an arrival, and those are exactly the cases where the action is not offered.
M.INTERACT_M = 2.0

-- What makes a thing usable.
--
-- `UseAction` leads because it is what measurement says: on the nautiloid every object a player
-- actually works with - the pod, the console, the sphincter doors, the reliquary, the brain
-- jars - carries it, and `CanInteract` was on **creatures only** (Lae'zel, Shadowheart, the
-- sacrificed thralls) and on nothing else at all. A category built on `CanInteract` therefore
-- contained no objects, and the pod the player was looking for sat in "предметы" between eight
-- salted tubers.
local INTERACT_COMPONENTS = { "UseAction", "CanInteract", "InteractionFilter", "CanBeLooted",
                              "InventoryContainer", "IsDoor", "Door", "CanSpeak" }

--- Is there really something to press A for.
---
--- The layer used to say "действие — кнопка A" on every arrival, which for a rock or a corpse
--- in a wall is a promise the game will not keep - and a player who cannot see is left
--- pressing a button at nothing, unable to tell a broken layer from a useless object.
function M.canInteract(e, dist)
    if e == nil then return false end
    if dist ~= nil and dist > M.INTERACT_M then return false end
    -- Marked as an object, and marked as not to be touched. Shadowheart's cradle is one: it
    -- carries UseAction like the pod beside it and `InteractionDisabled` on top, and it stands
    -- nearer to her than the thing that actually opens it. Offering it is worse than silence -
    -- it is the layer sending a blind player to press A at the one object in the room that
    -- cannot answer.
    if has(e, "InteractionDisabled") then return false end
    local set = compSet(e)
    -- No list to read means the entity does not answer that question, not that it is dead
    -- scenery. `CanInteract` by name is one of the readings that measured sanely - 41 of 133,
    -- not 133 of 133 - so it is the fallback rather than a flat no.
    if set == nil then return has(e, "UseAction") or has(e, "CanInteract") end
    for i = 1, #INTERACT_COMPONENTS do
        if set[INTERACT_COMPONENTS[i]] then return true end
    end
    return false
end

-- What the game says pressing A would do, in the words a player would use.
--
-- `UseAction.UseActions[n].Type` is the game's own verb. These four are what the nautiloid
-- produced; anything else falls back to "использовать", which is true of every use action there
-- is and so cannot mislead.
local USE_VERBS = {
    Door      = "дверь",
    OpenClose = "открыть",
    StoryUse  = "использовать",
    Throw     = "бросить",
}

--- The verb for a thing, or nil if it takes no action at all.
function M.useVerb(e)
    if e == nil then return nil end
    if has(e, "InteractionDisabled") then return nil end
    local acts = soft(function() return e.UseAction.UseActions end)
    if acts == nil then return nil end
    local n = tonumber(soft(function() return #acts end)) or 0
    for i = 1, n do
        local t = soft(function() return tostring(acts[i].Type) end)
        if t ~= nil then
            local word = USE_VERBS[t]
            if word ~= nil then return word end
            return "использовать"
        end
    end
    return nil
end

-- Locks, and the keys that answer them ----------------------------------------------
--
-- The engine says all of this plainly and the layer was not asking. `Lock.Key_M` is the id of
-- the key a thing wants, `Lock.LockDC` is whether a pick is allowed at all (-1 means never),
-- and an item's `Key.Key` is the id it answers to. Between them they turn "заперто" - a dead
-- end for someone who cannot walk over and look - into "заперто, ключ у Лаэзель".
--
-- Measured on the nautiloid: one lock in the level (Замысловатый реликварий, `Key_M`
-- TUT_SharChest, DC -1) and one key (Золотой ключ, `Key` TUT_SharChest) - and the key sat in
-- Lae'zel's keychain while the player steered Astarion and searched his own pack for it.

M.keyIndex = nil
M.keyIndexAt = nil
M.KEY_INDEX_MS = 5000

--- Whose pack a thing is in, out through every bag it is nested in.
---
--- One level is not enough and that is the whole point of the loop: BG3 files a key into a
--- keychain and the keychain into a character, so the honest answer is two hops away and the
--- obvious one hop answers "Брелок", which tells the player nothing.
function M.holderOf(e)
    local at = e
    for _ = 1, 6 do
        local inv = soft(function() return at.InventoryMember.Inventory end)
        if inv == nil then return nil end
        local owner = soft(function() return inv.InventoryIsOwned.Owner end)
        if owner == nil then return nil end
        if soft(function() return owner.ClientCharacter end) ~= nil or
           soft(function() return owner.PartyMember end) ~= nil then
            return nameOf(owner)
        end
        at = owner
    end
    return nil
end

--- Who is carrying which key, by the id a lock names.
---
--- Swept from the level rather than from a pack: "do I have the key" is a question about the
--- party, not about whichever character the player happens to be steering.
function M.keysKnown()
    local now = soft(Ext.Utils.MonotonicTime) or 0
    if M.keyIndex ~= nil and (now - (M.keyIndexAt or 0)) < M.KEY_INDEX_MS then
        return M.keyIndex
    end
    local out = {}
    local list = soft(Ext.Entity.GetAllEntitiesWithComponent, "Key")
    if type(list) == "table" then
        for i = 1, #list do
            local e = list[i]
            local id = soft(function() return tostring(e.Key.Key) end)
            if type(id) == "string" and id ~= "" then
                out[id] = { name = nameOf(e), holder = M.holderOf(e) }
            end
        end
    end
    M.keyIndex, M.keyIndexAt = out, now
    return out
end

--- Why this thing will not simply open, in one phrase, or nil if it will.
function M.lockPhrase(e)
    if e == nil then return nil end
    local lock = soft(function() return e.Lock end)
    if lock == nil then return nil end
    local id = soft(function() return tostring(lock.Key_M) end)
    local dc = tonumber(soft(function() return lock.LockDC end))

    local bits = { "заперто" }
    if type(id) == "string" and id ~= "" then
        local k = M.keysKnown()[id]
        if k == nil then
            bits[#bits + 1] = "ключа нет"
        elseif k.holder ~= nil then
            bits[#bits + 1] = "ключ у " .. k.holder
        else
            bits[#bits + 1] = "ключ рядом"
        end
    end
    -- A negative DC is the engine saying the lock takes no pick at all, which is a different
    -- answer from a hard one and saves the player the attempt and the broken tools.
    if dc ~= nil and dc >= 0 then bits[#bits + 1] = "отмычка " .. dc
    elseif dc ~= nil then bits[#bits + 1] = "отмычкой не открыть" end
    return table.concat(bits, ", ")
end

--- Rough category, for sorting and for saying what a thing is.
---
--- Returns the word, a rank, and whether the thing belongs in "взаимодействие" at all. The
--- third value used to be inferred from the word, which is why a cradle marked
--- `InteractionDisabled` was offered as somewhere to go.
local function kindOf(e)
    if has(e, "ClientCharacter") or has(e, "Character") then
        -- A body is not a creature and the difference is the whole of what the player does
        -- next: you talk to one and you search the other. The rune that opens Shadowheart's pod
        -- is on a corpse the list called "существо", indistinguishable from the companion
        -- standing beside it.
        local hp = soft(function() return e.Health.Hp end)
        if type(hp) == "number" and hp <= 0 then return "труп", 2, true end
        if has(e, "PartyMember") then return "спутник", 1, true end
        return "существо", 2, true
    end
    local off = has(e, "InteractionDisabled")
    if has(e, "IsDoor") then return "дверь", 3, not off end
    if has(e, "InventoryContainer") then return "контейнер", 4, not off end
    -- The verb the game itself offers, which is where this used to read `CanInteract` - a
    -- creature component that never fires for an object, so "взаимодействие" held doors and
    -- chests and nothing else, and every console, lever and pod landed in "предметы".
    local verb = M.useVerb(e)
    if verb ~= nil then return verb, 5, true end
    if has(e, "CanInteract") then return "объект", 5, not off end
    return nil, 9, false
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

-- What the near categories can be widened to, in metres. Twenty is the default: what is within
-- twenty metres is what is around you; the rest are for looking for somewhere to go.
--
-- Ten is at the bottom because a room is not twenty metres. Standing at the pod the twenty-metre
-- list ran to forty-four entries, of which eight were salted tubers and four were cradles in the
-- next bay - and the two things that mattered were both inside three metres.
--
-- Three hundred is the top because that is `SCAN_RADIUS`, the sweep itself. A step past it would
-- widen the filter over a list that does not go that far, so the count would stop changing and
-- the key would read as broken.
M.RADII = { 10, 20, 50, 100, 200, 300 }

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
                local name, indexed = nameOf(e)
                if name ~= nil then
                    local kind, rank, usable = kindOf(e)
                    local dir = bearing(dx, dz, yaw)
                    local looted = nil
                    if opened[tostring(e)] then
                        -- Through M, not the local: contentsOf is declared further down the
                        -- file, so the name is not in scope here at all - only the field is.
                        local items = M.contentsOf(e)
                        looted = (items ~= nil and #items == 0) or nil
                    end
                    out[#out + 1] = { entity = e, name = name, kind = kind, rank = rank,
                                      dist = dist, dir = dir, pos = p, looted = looted,
                                      usable = usable,
                                      -- Named by the level index rather than by the game.
                                      -- Anything that had to be rescued that way is a fixture
                                      -- - a console, a lever, a ladder, a key - and belongs in
                                      -- "ориентиры" whatever else is true of it, because it is
                                      -- exactly the class of thing a player is trying to find
                                      -- and the only class the game refuses to name.
                                      indexed = indexed or nil,
                                      -- Never opened, so what is inside is unknown rather than
                                      -- absent. The list used to make these look exactly like a
                                      -- container already emptied, and that is how a corpse
                                      -- holding the rune gets walked past.
                                      --
                                      -- Chests and bodies only. `CanBeLooted` is on the living
                                      -- too, and the first run of this announced Shadowheart as
                                      -- unsearched about two seconds after she was freed.
                                      unopened = (kind == "контейнер" or kind == "труп" or
                                                  (kind == nil and has(e, "CanBeLooted")))
                                                 and not opened[tostring(e)] or nil }
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
    -- Named places, and the fast-travel shrines among them. Next to "задача" on purpose: the
    -- two together are the whole answer to "where do I go" - one says where the story is, the
    -- other says what the world is made of.
    { key = "places",  name = "локации" },
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
    -- The living only. A corpse answers a different question - it is somewhere to search, and
    -- that is what "взаимодействие" is for; leaving it here made "существа" the count of who is
    -- in the room plus everyone who used to be.
    if key == "beings" then return it.kind == "существо" or it.kind == "спутник" end
    if key == "usable" then
        -- Asked of the entity when the list was built, not guessed back from the word: the
        -- words are now the game's own verbs and there are more of them than this test could
        -- ever enumerate.
        return it.usable == true and it.kind ~= "спутник" and it.kind ~= "существо"
    end
    if key == "things" then return it.kind == nil end
    if key == "landmarks" then
        -- A door the game still flags as one counts too, wherever it is. A container does
        -- **not**: "контейнер" is every backpack, crate and corpse-with-pockets in three
        -- hundred metres, and a category that answers "where do I go" with loot answers a
        -- different question than the one asked. Chests and crates are still here - by name,
        -- through the stems, which is also what keeps a rucksack out.
        return it.indexed == true or it.kind == "дверь" or isMarkerNamed(it.name)
               or isLandmark(it.name)
    end
    -- "quest" is not here on purpose: it is built in rebuildView from the journal table rather
    -- than filtered out of the sweep. What used to stand in this place cut the objective
    -- sentence into stems and matched them against the names of whatever had been scanned,
    -- which is the guessing the shipped index exists to end.
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
    elseif cat.key == "places" then
        out = M.placeView()
    elseif cat.key == "quest" then
        -- Built, not filtered - see M.questView. This is also what makes the category work at
        -- any range: the entries come from UUIDs resolved against the world, so a target on
        -- the far side of the level is in the list with a real distance on it.
        out = M.questView()
    elseif cat.key == "landmarks" then
        -- The index first, and the sweep's own landmarks folded in behind it: a door the game
        -- names is worth hearing next to a console it does not, and the index knows nothing
        -- about doors it was never told to record.
        out = M.indexView()
        local have = {}
        for i = 1, #out do have[tostring(out[i].uuid)] = true end
        for i = 1, #M.list do
            local it = M.list[i]
            if matches("landmarks", it) then
                local u = soft(function() return it.entity.Uuid.EntityUuid end)
                if u == nil or not have[tostring(u)] then out[#out + 1] = it end
            end
        end
        M.landmarkSort(out)
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
--- The navigable fixtures of the level, from the index rather than from the sweep.
---
--- Built like `exploreView` and for the same reason: these are not a filter over what was
--- scanned. The client's spatial query returns a hundred-odd entities where the level holds
--- two thousand, so a console eighty metres away is simply not in the sweep to be filtered -
--- which is why the first version of this listed four doors and none of the four things the
--- player was actually looking for.
---
--- The index carries world positions, so distance and bearing are arithmetic and the entity
--- never has to be reachable at all. That is the whole point: the answer to "which way is the
--- transponder" must not depend on being near enough to the transponder to see it.
function M.indexView()
    local idx = M.levelIndex()
    if idx == nil then return {} end
    local me = M.me()
    local pos = me and positionOf(me)
    if pos == nil then return {} end
    local yaw = yawOf(me)

    local out = {}
    for u, r in pairs(idx) do
        if r.x ~= nil and r.z ~= nil then
            local dx, dz = r.x - pos[1], r.z - pos[3]
            local dist = math.sqrt(dx * dx + dz * dz)
            -- The entity is looked up so that walking to it still works: approachEntry sends a
            -- uuid, and the server can reach an object the client cannot see.
            out[#out + 1] = { name = r.kind, kind = nil, dist = dist,
                              dir = bearing(dx, dz, yaw),
                              pos = { r.x, r.y, r.z }, uuid = u, indexed = true,
                              entity = soft(Ext.Entity.Get, u) }
        end
    end
    table.sort(out, function(x, y) return x.dist < y.dist end)
    return out
end

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
                local e = { name = "участок", kind = nil, anchor = a.guid,
                            pos = a.pos, dist = dist, dir = bearing(dx, dz, yaw) }
                -- Which named place that patch of ground belongs to, when it belongs to one.
                -- "Участок, на два, 180 м" is a direction; "участок, Вымершая деревня, на два,
                -- 180 м" is somewhere to decide about.
                M.placeOf(e)
                out[#out + 1] = e
            end
        end
    end
    table.sort(out, function(x, y) return x.dist < y.dist end)
    return out
end

-- The places of the world, and which one you are standing in --------------------------
--
-- The scanner could say what stood near you and never what any of it was *part of*. A hundred
-- rows of "дверь, рычаг, сундук" with a distance each is not a list a person can hold in their
-- head, and it was the honest answer the layer had: it knew objects and it did not know places.
--
-- The game knows them exactly, and says so twice over. `DB_Subregion` binds a named area to a
-- trigger, and the trigger carries its shape - a polygon, a box, or a bare point. `DB_WaypointInfo`
-- binds a fast-travel name to the shrine that serves it. Both are in Gustav.pak, both are joined
-- offline by tools/build-place-index.ps1, and both arrive here as `a11y-placedata` - 268 places
-- and 40 shrines across 24 levels, as handles rather than text, so the game renders the names in
-- whatever language it is being played in.
--
-- Which turns three questions from guesses into arithmetic:
--
--   where am I            the smallest place whose ring contains the character
--   where is that thing   the place the thing stands in, said next to its name
--   where can I go        a category of places, nearest edge first, walkable like anything else
--
-- The smallest ring wins on purpose: places nest, and the useful answer at the bottom of the
-- Grymforge is "Гримфордж", not "Подземье". The vertical band comes with each ring for the same
-- reason - a cellar and the room above it share their outline and differ only in height.

M.places = nil          -- the subregion rows of the level we are in
M.waypoints = nil       -- and its fast-travel shrines
M.placesLevel = nil
M.placeMemo = nil       -- entity uuid -> place name, thrown away with the level
M.placeNow = nil        -- what the character is standing in, kept by placeTick
M.placeSaid = nil       -- the last place announced, so a boundary is not a bell

-- How far outside its own height band a place still owns a point. Floors are authored to the
-- centimetre and characters stand on props, so a metre or two of slack is the difference
-- between "you are in the tea house" and silence.
M.PLACE_Y = 3

local RING = 8          -- which slot of a place row holds its outline

--- The shipped tables for the level the character is in, or nil.
local function placeTables()
    local pd = _G.PlaceData
    if pd == nil or type(pd.sub) ~= "table" then return nil, nil, nil end
    local lv = M.myLevel()
    if lv == nil then return nil, nil, nil end
    if M.placesLevel ~= lv then
        M.placesLevel = lv
        M.placeMemo = {}
        M.placeNow, M.placeSaid = nil, nil
        M.places = pd.sub[lv]
        M.waypoints = pd.wp[lv]
        _P("[nav] places: " .. #(M.places or {}) .. " areas, " ..
           #(M.waypoints or {}) .. " waypoints in " .. lv)
    end
    return M.places, M.waypoints, lv
end
M.placeTables = placeTables

--- The centre of a place and how big it is, worked out once and left on the row.
---
--- The centre matters because the row's own position is the polygon's origin, which for a large
--- area is nowhere near the middle of it - the Emerald Grove's origin sits on its eastern edge.
--- The area matters because it is what decides which of two nested places is the answer.
local function placeShape(row)
    if row.cx ~= nil then return row end
    local ring = row[RING]
    local n = (type(ring) == "table") and math.floor(#ring / 2) or 0
    if n < 3 then
        row.cx, row.cz, row.area = row[3], row[5], 0
        return row
    end
    local sx, sz, a2 = 0, 0, 0
    local px, pz = ring[n * 2 - 1], ring[n * 2]
    for i = 1, n do
        local x, z = ring[i * 2 - 1], ring[i * 2]
        sx, sz = sx + x, sz + z
        a2 = a2 + (px * z - x * pz)
        px, pz = x, z
    end
    row.cx, row.cz, row.area = sx / n, sz / n, math.abs(a2) / 2
    return row
end

--- Is this point inside the place.
local function inPlace(row, pos)
    local ring = row[RING]
    local n = (type(ring) == "table") and math.floor(#ring / 2) or 0
    if n < 3 then return false end
    local y = pos[2]
    if type(y) == "number" and (y < row[6] - M.PLACE_Y or y > row[7] + M.PLACE_Y) then
        return false
    end
    local x, z = pos[1], pos[3]
    local inside, j = false, n
    for i = 1, n do
        local xi, zi = ring[i * 2 - 1], ring[i * 2]
        local xj, zj = ring[j * 2 - 1], ring[j * 2]
        if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

--- How far to the place: nought when standing in it, otherwise to its nearest edge.
---
--- To the edge rather than to the middle, because "how far to the grove" is asked by someone
--- who wants to know when they are there, and the middle of a hundred-metre area is not it.
local function placeDist(row, pos)
    if inPlace(row, pos) then return 0 end
    local ring = row[RING]
    local n = (type(ring) == "table") and math.floor(#ring / 2) or 0
    local x, z = pos[1], pos[3]
    if n < 3 then
        placeShape(row)
        local dx, dz = row.cx - x, row.cz - z
        return math.sqrt(dx * dx + dz * dz)
    end
    local best, j = nil, n
    for i = 1, n do
        local ax, az = ring[j * 2 - 1], ring[j * 2]
        local bx, bz = ring[i * 2 - 1], ring[i * 2]
        local ux, uz = bx - ax, bz - az
        local len = ux * ux + uz * uz
        local t = 0
        if len > 0 then
            t = ((x - ax) * ux + (z - az) * uz) / len
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local px, pz = ax + t * ux, az + t * uz
        local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
        if best == nil or d < best then best = d end
        j = i
    end
    return best or 0
end
M.inPlace = inPlace
M.placeDist = placeDist
M.placeShape = placeShape

--- What a place is called, in the language the game is being played in.
local function placeName(row)
    if row == nil then return nil end
    if row.said ~= nil then return row.said end
    local pad = _G.Pad
    local t = nil
    if row[2] ~= nil and pad ~= nil and pad.loca ~= nil then
        t = soft(function() return pad.loca(row[2]) end)
    end
    if type(t) ~= "string" or t == "" or t == row[2] then t = row[1] end
    row.said = t
    return t
end
M.placeName = placeName

--- The place a point is in - the smallest one that contains it - or nil for open ground.
function M.placeAt(pos)
    local rows = placeTables()
    if rows == nil or pos == nil then return nil end
    local best = nil
    for i = 1, #rows do
        local row = rows[i]
        if inPlace(row, pos) then
            placeShape(row)
            if best == nil or row.area < best.area then best = row end
        end
    end
    return best
end

--- What the level itself is called - "Пустошь", not "WLD_Main_A".
function M.levelName()
    local pd = _G.PlaceData
    local lv = M.myLevel()
    if pd == nil or lv == nil or type(pd.lvl) ~= "table" then return nil end
    local h = pd.lvl[lv]
    if h == nil then return nil end
    local pad = _G.Pad
    local t = (pad ~= nil and pad.loca ~= nil) and soft(function() return pad.loca(h) end) or nil
    if type(t) ~= "string" or t == "" or t == h then return nil end
    return t
end

--- The place a scan entry stands in, memoised by the thing rather than recomputed per sentence.
---
--- Keyed by uuid where there is one: an index row is the same object at the same coordinates for
--- as long as the level lasts, and the landmark list asks this of every row on every rebuild.
function M.placeOf(it)
    if it == nil or it.pos == nil or it.place then return nil end
    if it.where ~= nil then return it.where ~= false and it.where or nil end
    local memo = M.placeMemo
    -- Anything that names the same thing twice will do as a key. An anchor is a fixed point of
    -- the level, an indexed row is an object that does not move, and a swept entity keeps the
    -- same proxy for the session - so all three are worth remembering rather than re-measuring
    -- against fifty polygons on every rebuild.
    local key = it.uuid or it.anchor or (it.entity ~= nil and tostring(it.entity)) or nil
    if memo ~= nil and key ~= nil and memo[key] ~= nil then
        it.where = memo[key]
        return it.where ~= false and it.where or nil
    end
    local row = M.placeAt(it.pos)
    local name = row and placeName(row) or false
    it.where = name
    if memo ~= nil and key ~= nil then memo[key] = name end
    return name ~= false and name or nil
end

--- What a fast-travel shrine is called.
local function wpName(w)
    if w.said ~= nil then return w.said end
    local pad = _G.Pad
    local t = nil
    if w[2] ~= nil and pad ~= nil and pad.loca ~= nil then
        t = soft(function() return pad.loca(w[2]) end)
    end
    if type(t) ~= "string" or t == "" or t == w[2] then t = "точка перехода" end
    w.said = t
    return t
end
M.wpName = wpName

--- The named places of this level, nearest first, with the fast-travel shrines among them.
---
--- Built rather than filtered, for the reason the quest category is: a place is not an entity
--- and the sweep will never return one. The entries are shaped like scan entries, so the go key,
--- `describe` and the cursor take them without knowing what they are.
function M.placeView()
    local rows, wps = placeTables()
    local me = M.me()
    local pos = me and positionOf(me)
    if pos == nil then return {} end
    local yaw = yawOf(me)

    local out, byId = {}, {}
    for i = 1, #(rows or {}) do
        local row = rows[i]
        placeShape(row)
        local d = placeDist(row, pos)
        -- One name, one entry. A place is often two triggers - a hall and its cellar, a shop
        -- and its back room - and hearing "Ласка Шаресс" three times in a row is noise, not
        -- detail. The nearest of them stands for the rest.
        local id = row[1]
        local was = byId[id]
        if was == nil or d < was.dist then
            local dx, dz = row.cx - pos[1], row.cz - pos[3]
            local e = { name = placeName(row), kind = nil, dist = d,
                        dir = bearing(dx, dz, yaw), pos = { row.cx, row[4], row.cz },
                        anchor = "p:" .. id, place = true, inside = (d <= 0) or nil,
                        -- Kept so that refreshing the entry measures it the way it was built.
                        row = row }
            if was == nil then
                out[#out + 1] = e
                byId[id] = e
            else
                for k, v in pairs(e) do was[k] = v end
            end
        end
    end

    for i = 1, #(wps or {}) do
        local w = wps[i]
        local e = soft(function() return Ext.Entity.Get(w[3]) end)
        local p = (e and positionOf(e)) or { w[4], w[5], w[6] }
        local dx, dz = p[1] - pos[1], p[3] - pos[3]
        local d = math.sqrt(dx * dx + dz * dz)
        -- The entity is handed over only from close in, and that is the same rule the quest
        -- targets follow: with an entity the go key walks straight there, and a shrine three
        -- hundred metres off is a crossing of the map on one press. Further out it is an
        -- anchor, which walks in hops the player can hear the end of.
        local near = (d <= M.QUEST_DIRECT)
        out[#out + 1] = { name = wpName(w), kind = "точка перехода", dist = d,
                          dir = bearing(dx, dz, yaw), pos = p, place = true,
                          entity = near and e or nil, uuid = w[3],
                          anchor = (not near) and ("w:" .. w[1]) or nil }
    end

    table.sort(out, function(x, y) return (x.dist or 0) < (y.dist or 0) end)
    return out
end

--- Say the place the moment the character walks into it, the way the game shows it on screen.
---
--- Only on arriving somewhere named: walking out of a place onto open ground says nothing, and
--- the last named place is remembered rather than cleared, so pacing across a boundary does not
--- ring a bell every pass.
function M.placeTick()
    local me = M.me()
    local pos = me and positionOf(me)
    if pos == nil then return false end
    local row = M.placeAt(pos)
    local name = row and placeName(row) or nil
    M.placeNow = name
    if name == nil or name == M.placeSaid then return false end
    M.placeSaid = name
    say("Локация: " .. name)
    return true
end

-- Which objects the player's own quests point at, by uuid.
--
-- Built out of the shipped journal table, but never out of the whole of it: it knows every
-- marker in the game, and tagging a lever with a quest nobody has started is a spoiler dressed
-- as help. So the set is cut down to the quests the player has actually seen - the quest store
-- is a record of what the journal showed and what the server reported, and that is the honest
-- definition of "a task you have".
M.questUuidsAt = nil
M.questUuidsSet = nil
M.QUEST_UUIDS_MS = 10000

function M.questUuids()
    local qd = _G.QuestData
    if qd == nil or type(qd.obj) ~= "table" or type(qd.mk) ~= "table" then return nil end
    local now = soft(Ext.Utils.MonotonicTime) or 0
    if M.questUuidsSet ~= nil and (now - (M.questUuidsAt or 0)) < M.QUEST_UUIDS_MS then
        return M.questUuidsSet
    end
    M.questUuidsAt = now

    local quests = {}
    local store = soft(function() return M.questStoreLoad() end)
    for _, entry in pairs((store and store.quests) or {}) do
        for _, t in ipairs(entry.tasks or {}) do
            local oid = (t.handle ~= nil) and qd.oh[t.handle] or nil
            local row = (oid ~= nil) and qd.obj[oid] or nil
            if row ~= nil and row[1] ~= nil then quests[row[1]] = true end
        end
    end

    local out, n = {}, 0
    for _, row in pairs(qd.obj) do
        if row[1] ~= nil and quests[row[1]] then
            for i = 3, #row do
                local pts = qd.mk[row[i]]
                for j = 1, #(pts or {}) do
                    local u = pts[j][3]
                    if u ~= nil and out[u] == nil then
                        out[u] = true
                        n = n + 1
                    end
                end
            end
        end
    end
    M.questUuidsSet = out
    return out
end

--- The landmark list, put in an order a person can hold in their head.
---
--- Distance alone was the order, and with a hundred rows in it that is not an order at all: the
--- nearest thing in the goblin camp, then something in the grove, then the camp again. Now the
--- rows are grouped by the place they stand in, the groups sorted by their own nearest member,
--- and inside a group it is still nearest first. So the first thing said is still the nearest
--- thing - nothing is hidden and nothing moved far - but everything that belongs together is
--- now heard together.
function M.landmarkSort(out)
    local known = M.questUuids()
    local best = {}
    for i = 1, #out do
        local it = out[i]
        M.placeOf(it)
        local key = (type(it.where) == "string") and it.where or ""
        local d = it.dist or 0
        if best[key] == nil or d < best[key] then best[key] = d end
        if known ~= nil and it.task == nil then
            local u = it.uuid or soft(function() return it.entity.Uuid.EntityUuid end)
            if u ~= nil and known[tostring(u)] then it.task = true end
        end
    end
    table.sort(out, function(x, y)
        local kx = (type(x.where) == "string") and x.where or ""
        local ky = (type(y.where) == "string") and y.where or ""
        if kx ~= ky then
            local bx, by = best[kx] or 0, best[ky] or 0
            -- The key breaks the tie rather than leaving it: two groups whose nearest member is
            -- the same distance away would otherwise compare equal, and table.sort is free to
            -- interleave them, which is exactly the grouping this exists to produce.
            if bx ~= by then return bx < by end
            return kx < ky
        end
        return (x.dist or 0) < (y.dist or 0)
    end)
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
-- What is inside a body or a box, said in the list rather than found by walking to it.
--
-- This is the evening the feature was written for: a rune had to be fetched from "one of the
-- corpses", nothing said which, and the only way to find out was to walk to each of seventeen
-- in turn. `contentsOf` could answer that the whole time - it is the same call the layer
-- already makes to tell an emptied container from a full one - and nothing ever asked it.
--
-- Capped at three names. A corpse with a longer pocket than that is a shopping list, and the
-- list is walked to decide where to go, not to do the shopping; the rest is behind the
-- details key.
M.PEEK = 3

local function peek(it)
    if it.looted then return nil end
    if it.kind ~= "труп" and it.kind ~= "контейнер" and not it.unopened then return nil end
    local items = M.contentsOf(it.entity)
    if items == nil or #items == 0 then return nil end
    local names, seen = {}, {}
    for i = 1, #items do
        local n = items[i].name
        -- Nameless loot is real and common; saying "и ещё что-то" is honest and short.
        if type(n) == "string" and n ~= "" and not seen[n] then
            seen[n] = true
            names[#names + 1] = n
            if #names >= M.PEEK then break end
        end
    end
    if #names == 0 then return nil end
    local more = (#items > #names) and (" и ещё " .. (#items - #names)) or ""
    return table.concat(names, ", ") .. more
end
M.peek = peek

local function describe(it)
    local parts = { it.name }
    if it.kind then parts[#parts + 1] = it.kind end
    if it.looted then parts[#parts + 1] = "пусто"
    elseif it.unopened then parts[#parts + 1] = "не обыскано" end
    local inside = soft(function() return peek(it) end)
    if inside ~= nil then parts[#parts + 1] = "внутри " .. inside end
    -- Why pressing A will not be enough. Said in the list rather than only on arrival, because
    -- the decision it changes - walk over there at all, and with whom - is taken from the list.
    local lock = M.lockPhrase(it.entity)
    if lock ~= nil then parts[#parts + 1] = lock end
    -- Which place the thing is part of, when that is not the place the character is standing
    -- in. This is the whole of what turned the landmark list from a hundred anonymous rows into
    -- something a person can hold: the same words, each now attached to somewhere, and the
    -- places kept together in the order (M.landmarkSort). Left off for what is right here,
    -- which is most of a near list, because saying it every time is noise.
    if type(it.where) == "string" and it.where ~= M.placeNow then
        parts[#parts + 1] = it.where
    end
    -- And whether the story wants it. Only ever for a quest the player has actually seen -
    -- see M.questUuids.
    if it.task then parts[#parts + 1] = "по заданию" end
    if it.inside then
        parts[#parts + 1] = "вы здесь"
    else
        if it.anchor ~= nil and it.dir then parts[#parts + 1] = it.dir end
        parts[#parts + 1] = string.format("%.0f м", it.dist)
    end
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
    if mp == nil then return false end
    -- A named place is measured to its edge rather than to the point that stands for it, so it
    -- has to be refreshed the way it was built. Without this, stepping onto a place in the list
    -- turned "Изумрудная роща, 5 м" into "Изумрудная роща, 70 м" - the distance to the middle
    -- of it - and the two answers to the same question arrived a keypress apart.
    if it.row ~= nil then
        it.dist = M.placeDist(it.row, mp)
        it.inside = (it.dist <= 0) or nil
        it.dir = bearing(it.pos[1] - mp[1], it.pos[3] - mp[3], yawOf(me))
        return true
    end
    -- An exploration anchor is a place, not a thing: it has no entity to ask and its position
    -- cannot go stale. Everything else keeps the old rule, where a missing entity means the
    -- object is gone and the list has to be taken again.
    local p = it.entity and positionOf(it.entity) or (it.anchor and it.pos)
    if p == nil then return false end
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
---
--- The two coordinates used to be the whole answer, and they are the one part of it a person
--- cannot use: they say where you are to the engine, not to yourself. The place and the level
--- are the answer the game itself gives a sighted player, in the corner of the screen.
function M.where()
    local me = M.me()
    if me == nil then say("Персонаж не найден") return end
    local pos = positionOf(me)
    local name = nameOf(me) or "персонаж"
    local parts = { name }
    local row = M.placeAt(pos)
    local place = row and placeName(row) or nil
    M.placeNow = place
    if place ~= nil then parts[#parts + 1] = place end
    local lvl = M.levelName()
    if lvl ~= nil and lvl ~= place then parts[#parts + 1] = lvl end
    parts[#parts + 1] = string.format("%.0f, %.0f", pos[1], pos[3])
    say(table.concat(parts, ". "))
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

--- What the character the player is steering is carrying.
---
--- The same shape `openContainer` returns, because it feeds the same consumer: the panel reader
--- joins a slot index to a list of names. The *source* has to differ because the question does.
--- A container panel is about the thing in front of the character; the character sheet is about
--- the character - and `openContainer` deliberately hunts for the nearest thing in the **world**
--- with an inventory, which at an open character sheet is whatever crate happens to be standing
--- behind you.
---
--- Top level only, on purpose. A bag in the pack is one entry on the panel too; opening it opens
--- its own panel, and that panel is a container like any other.
function M.myInventory()
    local me = M.me()
    if me == nil then return nil end
    local items = contentsOf(me)
    if items == nil then return nil end
    return { entity = me, name = nameOf(me), dist = 0, items = items }
end

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
    -- Measured again first. Where a uuid exists the server resolves the object's own position
    -- anyway, but the check also catches an entry that is gone - and for the quest entries it
    -- is what makes the distance in "вы на месте" the distance now rather than the distance
    -- when the list was taken.
    if not M.refreshEntry(it) then
        M.scan()
        say("Пропало, список обновлён")
        return false
    end
    M.cursor = i
    return M.approachEntry(it)
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
                -- The game's own verb where it has one. "действие — кнопка A" was the layer
                -- admitting it did not know what the button would do; "использовать — кнопка A"
                -- is what the object itself says.
                local verb = M.useVerb(e)
                bits[#bits + 1] = (verb or "действие") .. " — кнопка A"
                local lock = M.lockPhrase(e)
                if lock ~= nil then bits[#bits + 1] = lock end
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
    if msg.cmd == "refused" then
        -- Naming the reason, because the two are different problems for the player: a place
        -- the pathing will not take them is a "go round"; a target in another region is the
        -- layer offering something it should not have, and the honest answer is to say so.
        say(msg.why == "level" and "Туда не пройти: это другая локация"
            or msg.why == "gone" and "Туда не пройти: этого здесь больше нет"
            or "Туда не пройти")
    end
    if msg.cmd == "quest" then
        -- The story moved, and the server is the only half that hears it move.
        soft(function() M.questStep(tostring(msg.quest), tostring(msg.step)) end)
    end
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
    -- No minimap is not "no objective".
    --
    -- This used to return here, and returning here made the journal fallback below
    -- unreachable in exactly the case it exists for: the minimap is part of the HUD, and the
    -- HUD is gone whenever a full-screen panel is up - including the journal itself. So the
    -- one moment the player has just read their tasks was the one moment this said there were
    -- none. Measured 2026-08-06 with the journal open on «Бежать с наутилоида»:
    -- bookObjective returned the task and objective() still answered nil.
    local out = { text = nil, turns = nil, place = nil, markers = {} }
    local info = node ~= nil and pad.visibleScan(node, 600, 24) or { texts = {} }
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
    -- Whatever the journal last showed goes into the store before it is asked anything, so
    -- that a quest the player looked at ten minutes ago is still somewhere the layer can send
    -- them. Does nothing until the book changes.
    M.questFold()

    if out.text == nil then
        local b = M.bookObjective()
        if b ~= nil then
            out.text = b.text
            out.quest = b.title
            out.handle = b.handle
            out.fromBook = true
        end
    end

    -- Neither screen has anything: fall back to the last task this profile was on. Only ever
    -- reached when both live sources are silent, and overwritten by either the moment it
    -- speaks again, so the worst it can be is one session behind - and one session behind is
    -- still a direction, where nil is nothing at all.
    if out.text == nil then
        local s = M.questRecall()
        if s ~= nil then
            out.text = s.text
            out.quest = s.title
            out.handle = s.handle
            out.fromSaved = true
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
--- Fixed 2026-08-06: this had been reading a book that is not the shape it is written in.
--- `Pad.journalRefresh` files the tasks flat, as `book.tasks`, because the screen shows them
--- flat - they live in the detail panel beside the list and belong to whichever quest is
--- selected, not under it in the tree. This walked `book.quests[n].objectives` and
--- `q.category`, neither of which is ever set, so the loop found no task and the function
--- returned nil on every call since it was written. Which means the minimap has been the
--- *only* source of the objective all along, and on a beach where the minimap says nothing
--- there was nothing - exactly the moment a player is most lost.
function M.bookObjective()
    local book = M.questBook
    if type(book) ~= "table" or type(book.tasks) ~= "table" then return nil end
    local task = nil
    for _, o in ipairs(book.tasks) do
        -- Lowest priority first among the unfinished: the game numbers them upwards along a
        -- quest, so that is the earliest thing still to do rather than the last thing shown.
        if not o.done and (task == nil or (o.priority or 0) < (task.priority or 0)) then
            task = o
        end
    end
    if task == nil then return nil end
    return { title = book.title, text = task.text, handle = task.handle }
end

-- The task, kept where a reload cannot reach it.
--
-- `Pad.book` is memory, and the client Lua state is rebuilt on every save load - so the
-- journal has to be opened again before the layer knows what the story is asking for. Which
-- means that at the start of every session, the one moment a player most wants "where do I
-- go", the answer is "open the journal first". Found by reloading the layer with the game
-- running: the whole chain went from a named place at seventy metres to nothing at all.
--
-- The handle is what makes this safe to keep. It is the game's own key for the objective, not
-- a sentence in a language, so a remembered one either still resolves to the same place or is
-- replaced the instant the journal is read again.
--- Every quest the layer has seen, and what each was asking for.
---
--- One quest is the easy case and it is not the case a player is in for long. The journal hands
--- over the tasks of the **selected** quest only - they live in the detail panel beside the
--- list, not under the quest in the tree - so the way to know about more than one is to keep
--- what each showed while the player walked the list. Hence a store rather than a variable.
---
--- Keyed by quest title, holding whatever that quest's panel last showed, because that set
--- *is* its current objectives: when a quest moves on, its panel shows the new ones and the
--- whole entry is replaced. Anything else would leave the layer pointing at finished work,
--- which is worse than pointing at nothing.
---
--- `last` is which quest was seen most recently, for the callers that want one answer rather
--- than a list - questTick and the single-objective wording.
M.QUEST_FILE = "A11y/quest_state.json"
M.questStore = nil
M.questFoldAt = nil
M.savedWarned = false

--- Through `M`, not the locals, wherever these are used: they are declared below
--- `M.objective`, which is where they are called from, so the *name* is not in scope there -
--- only the field is. The same trap `contentsOf` carries a note about further up; it cost a
--- live "attempt to call a nil value (global 'questRecall')" here before it was seen.
function M.questStoreLoad()
    if M.questStore ~= nil then return M.questStore end
    local raw = soft(function() return Ext.IO.LoadFile(M.QUEST_FILE) end)
    local t = (type(raw) == "string" and raw ~= "") and soft(function() return Ext.Json.Parse(raw) end) or nil
    if type(t) ~= "table" or type(t.quests) ~= "table" then t = { last = nil, quests = {} } end
    M.questStore = t
    return t
end

function M.questStoreSave()
    if M.questStore == nil then return end
    soft(function() Ext.IO.SaveFile(M.QUEST_FILE, Ext.Json.Stringify(M.questStore)) end)
end

--- Fold whatever the journal is showing into the store. Cheap to call on every pass: it does
--- nothing until `Pad.journalRefresh` has produced a newer book than the last one folded.
function M.questFold()
    local book = M.questBook
    if type(book) ~= "table" or type(book.tasks) ~= "table" then return end
    if book.at ~= nil and book.at == M.questFoldAt then return end
    M.questFoldAt = book.at

    local title = book.title or "Задание"
    local rows = {}
    for _, o in ipairs(book.tasks) do
        if not o.done and type(o.text) == "string" then
            rows[#rows + 1] = { handle = o.handle, text = o.text }
        end
    end

    local store = M.questStoreLoad()
    if #rows == 0 then
        -- Nothing left undone under this quest: it is finished, or the panel is between
        -- states. Either way it stops being somewhere to walk to.
        if store.quests[title] ~= nil then
            store.quests[title] = nil
            if store.last == title then store.last = nil end
            M.questStoreSave()
        end
        return
    end

    store.quests[title] = { tasks = rows }
    store.last = title
    M.questStoreSave()
end

--- The one task, for the callers that want one: the last quest the journal showed.
function M.questRecall()
    local store = M.questStoreLoad()
    local q = store.last and store.quests[store.last]
    if q == nil then
        -- No "last" - any quest will do, and there is normally only one.
        for title, entry in pairs(store.quests) do
            q = entry
            store.last = title
            break
        end
    end
    if q == nil or q.tasks == nil or q.tasks[1] == nil then return nil end
    return { handle = q.tasks[1].handle, text = q.tasks[1].text, title = store.last }
end

--- A quest moved to a new step, told by the server as it happened.
---
--- The journal is a record of what the player has looked at; this is a record of what the game
--- did. Between them the store is both complete and current: browsing the journal fills in
--- everything already under way, and this keeps it true afterwards without the player having
--- to open anything.
---
--- A step names its objective, and replacing the quest's whole entry is right rather than
--- lazy: when a quest advances its earlier objectives are done, and a layer that keeps
--- offering to walk to finished work is worse than one that offers nothing.
function M.questStep(quest, step)
    local qd = _G.QuestData
    if qd == nil or type(qd.steps) ~= "table" then return false end
    local rows = qd.steps[quest]
    if rows == nil then return false end

    local oid = nil
    for i = 1, #rows do
        if rows[i][1] == step then oid = rows[i][3] break end
    end
    -- A step with no objective of its own is normal - plenty of them only move the story on.
    -- The quest is left as it was rather than emptied, because "no objective on this step"
    -- does not mean "nothing to do".
    if oid == nil then return false end

    local row = qd.obj[oid]
    local handle = row and row[2]
    if handle == nil then return false end

    local pad = _G.Pad
    local function L(h)
        if h == nil or pad == nil or pad.loca == nil then return nil end
        local t = soft(function() return pad.loca(h) end)
        if type(t) == "string" and t ~= "" and t ~= h then return t end
        return nil
    end

    local q = qd.q[quest]
    local title = L(q and q[1]) or quest
    local store = M.questStoreLoad()
    store.quests[title] = { tasks = { { handle = handle, text = L(handle) } } }
    store.last = title
    M.questStoreSave()
    _P("[nav] quest " .. tostring(quest) .. " -> " .. tostring(step) .. " -> " .. oid)
    return true
end

--- Every task of every quest the layer knows about, live reading first.
function M.questTasks()
    local out, seen = {}, {}
    local function add(t)
        if type(t) ~= "table" then return end
        local k = t.handle or t.text
        if type(k) ~= "string" or seen[k] then return end
        seen[k] = true
        out[#out + 1] = t
    end
    add(M.bookObjective())
    local store = M.questStoreLoad()
    for title, entry in pairs(store.quests or {}) do
        for _, t in ipairs(entry.tasks or {}) do
            add({ handle = t.handle, text = t.text, title = title })
        end
    end
    return out
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
-- The journal's task as a place, not a sentence.
--
-- Everything below this comment used to be guesswork, and the guessing is what made the
-- prologue unplayable: the objective said "Соединить нервы передатчика", the thing it meant
-- carried no DisplayName at all, and no amount of better word-matching was ever going to
-- bridge that. The game does not have that problem because it does not match words - it
-- stores, for every objective, a list of markers, and every marker names an object by UUID.
-- That table ships with the game, in Gustav.pak, and now ships with us as `a11y-questdata`.
--
-- So the chain is: the journal line's loca handle -> the objective -> its markers -> a UUID
-- -> the entity -> where it is. Exact at every hop, in any language, and it works for the
-- 743 of 1335 objectives that point somewhere at all. The word matching stays underneath as
-- the fallback for the rest.

--- Objectives keyed by their rendered text, built once from the shipped table.
---
--- Only for the minimap path, which hands over a sentence and no handle. Costs about eleven
--- hundred `Ext.Loca` lookups, so it is built on first use rather than at load, and only if
--- something actually asks where a quest points.
M.qtext = nil

local function questTextIndex()
    if M.qtext ~= nil then return M.qtext end
    local qd = _G.QuestData
    local pad = _G.Pad
    if qd == nil or type(qd.oh) ~= "table" or pad == nil or pad.loca == nil then return nil end
    local out, n = {}, 0
    for h, oid in pairs(qd.oh) do
        local t = soft(function() return pad.loca(h) end)
        if type(t) == "string" and t ~= "" and t ~= h then
            out[t] = oid
            n = n + 1
        end
    end
    M.qtext = out
    _P("[nav] quest index: " .. n .. " objectives by text")
    return out
end
M.questTextIndex = questTextIndex

--- Which objective a reading of the journal is, by handle first and by text second.
local function objectiveId(obj)
    local qd = _G.QuestData
    if qd == nil or obj == nil then return nil end
    if type(obj.handle) == "string" and qd.oh[obj.handle] ~= nil then
        return qd.oh[obj.handle], "handle"
    end
    if type(obj.text) ~= "string" then return nil end
    local idx = questTextIndex()
    if idx == nil then return nil end
    local oid = idx[obj.text]
    if oid ~= nil then return oid, "text" end
    return nil
end
M.objectiveId = objectiveId

--- Where the current objective points, as scan entries.
---
--- Shaped exactly like what `M.scan` returns, so `describe` and `approachEntry` take them without
--- knowing where they came from. `anchor` is set because that is the field `describe` reads
--- to decide whether a direction is worth saying, and for something across the level it is
--- the only part that matters.
---
--- A marker on another level simply does not resolve - `Ext.Entity.Get` gives nil for a UUID
--- that is not in the world right now - so no level check is needed to keep them out.
function M.questMarks(obj)
    local qd = _G.QuestData
    if qd == nil or type(qd.obj) ~= "table" then return nil end
    local oid = objectiveId(obj)
    if oid == nil then return nil end
    local row = qd.obj[oid]
    if type(row) ~= "table" then return nil end

    local me = M.me()
    local pos = me and positionOf(me)
    if pos == nil then return nil end
    local yaw = yawOf(me)
    local pad = _G.Pad

    local out, off = {}, 0
    for i = 3, #row do
        local pts = qd.mk[row[i]]
        if type(pts) == "table" then
            for j = 1, #pts do
                local p = pts[j]
                local e = soft(function() return Ext.Entity.Get(p[3]) end)
                local ep = e and positionOf(e)
                if ep == nil then
                    off = off + 1
                else
                    -- The marker's own label wins over the entity's name. It is what the game
                    -- would print on the map ("Рулевая рубка"), it is curated per objective,
                    -- and half the time the entity has no name to offer at all.
                    local label = nil
                    if p[4] ~= nil and pad ~= nil and pad.loca ~= nil then
                        local t = soft(function() return pad.loca(p[4]) end)
                        if type(t) == "string" and t ~= "" and t ~= p[4] then label = t end
                    end
                    if label == nil then label = nameOf(e) end
                    local dx, dz = ep[1] - pos[1], ep[3] - pos[3]
                    local dist = math.sqrt(dx * dx + dz * dz)
                    -- What kind of thing the marker points at, kept because arriving at each
                    -- means something different. A Character or an Item is a destination: you
                    -- stand next to it and press A. A Trigger is an **area** the map points
                    -- at - there is nothing there to press, and saying "вы на месте" about it
                    -- sounds like the task is done when the player has only reached the place
                    -- the story pointed to. Which is exactly what happened on the first walk.
                    out[#out + 1] = { entity = e, name = label or "цель", pos = ep,
                                      dist = dist, dir = bearing(dx, dz, yaw),
                                      kind = (p[2] == "Trigger") and "точка на карте" or nil,
                                      mkind = p[2],
                                      anchor = row[i], marker = row[i], quest = oid }
                end
            end
        end
    end
    if #out == 0 then
        if off > 0 then _P("[nav] quest " .. oid .. ": " .. off .. " markers, none in this level") end
        return nil
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

--- Everything the story is pointing at, as scan entries, nearest first.
---
--- This is what the "задача" category shows, and it is built rather than filtered. A category
--- meant to answer "which way do I go" cannot be a filter over the client sweep: the object an
--- objective names is often not in the sweep at all, and when it is it frequently has no name
--- for a filter to match. Both were true of the prologue transponder, which is how that lesson
--- was learnt.
function M.questView()
    local out, seen, titles, ntitles = {}, {}, {}, 0
    local tasks = M.questTasks()
    for i = 1, #tasks do
        local t = tasks[i]
        local marks = soft(function() return M.questMarks(t) end)
        for j = 1, #(marks or {}) do
            local it = marks[j]
            local id = tostring(it.marker) .. "|" .. tostring(it.entity)
            if not seen[id] then
                seen[id] = true
                it.task = t.text
                it.questTitle = t.title
                if t.title ~= nil and not titles[t.title] then
                    titles[t.title] = true
                    ntitles = ntitles + 1
                end
                out[#out + 1] = it
            end
        end
    end

    -- Where each target is, in the world's own words. A quest target is routinely across the
    -- level, and "Передатчик, 110 м" leaves out the one thing that would let a player decide
    -- whether to set off now: which place it is in.
    for i = 1, #out do M.placeOf(out[i]) end

    -- Name the quest only when there is more than one to tell apart. With a single quest the
    -- title is on every line and adds nothing; with three it is the whole point of the list.
    if ntitles > 1 then
        for i = 1, #out do
            if out[i].questTitle ~= nil then
                out[i].name = out[i].questTitle .. ": " .. out[i].name
            end
        end
    end

    table.sort(out, function(x, y) return (x.dist or 0) < (y.dist or 0) end)
    return out
end

function M.findObjective(radius)
    local obj = M.objective()
    if obj == nil then return nil, obj end

    -- The table first. It is exact where the word matching is a hopeful guess, and it reaches
    -- across the whole level where the sweep reaches sixty metres.
    local marks = soft(function() return M.questMarks(obj) end)
    if marks ~= nil and #marks > 0 then return marks, obj end

    if obj.text == nil then return nil, obj end
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

-- Metres. How far the quest button will walk straight at the thing the journal names before it
-- starts hopping toward it instead. Eighty because that is what the button could reach before
-- the journal table existed - the old sweep's radius - so the behaviour a player already knows
-- is unchanged, and everything the table added is new ground rather than a new risk.
M.QUEST_DIRECT = 80

M.questText = nil

local function dm(d) return string.format("%.0f м", d or 0) end

--- Walk to one entry, and say the one thing that matters about the attempt.
---
--- Every key that sends the character somewhere comes through here: the scanner's own "go"
--- and the quest key both. That is the point of it. The two used to be separate pieces of
--- code, and the quest one had grown three things the scanner's had not - a ceiling on how
--- far one press may walk, what arriving at an area means as opposed to arriving at an
--- object, and re-measuring the entry first. With the quest targets now in the scanner's own
--- list, the scanner's key reaches exactly the same entries, so either both know those three
--- things or the player finds out which key they pressed by what goes wrong.
---
--- `note` is said last, after everything else, for the callers with a caveat to attach.
function M.approachEntry(it, parts, note)
    parts = parts or {}
    local function speak(ok)
        if note ~= nil then parts[#parts + 1] = note end
        say(table.concat(parts, ". "))
        return ok
    end
    if it == nil then
        parts[#parts + 1] = "Не выбрано"
        return speak(false)
    end

    local d = it.dist or 0
    local where = it.name .. ", " .. tostring(it.dir) .. ", " .. dm(d)

    -- Already there. Only for quest entries, because only they know what being there means:
    -- the rest of the scanner has always let the engine no-op a walk of two metres, and
    -- changing that would change every category at once for no reason anyone asked for.
    if it.quest ~= nil and d <= M.ARRIVE then
        parts[#parts + 1] = where
        if it.mkind == "Trigger" then
            -- Standing in the area the map pointed at finishes nothing, and this is the
            -- moment a player is most likely to think it did: the walk ended, the layer went
            -- quiet, and there is no button to press. So name what the place is, and hand
            -- over the only thing that helps next - what is actually usable around here.
            parts[#parts + 1] = "Вы в этой точке. Это область на карте, нажимать здесь нечего"
            local near = M.scan(20, true)
            local best = nil
            for i = 1, #(near or {}) do
                local n = near[i]
                if n.usable and (best == nil or n.dist < best.dist) then best = n end
            end
            if best ~= nil then
                parts[#parts + 1] = "Рядом: " .. best.name .. ", " .. dm(best.dist) ..
                                    ", " .. tostring(best.dir)
            end
        elseif M.canInteract(it.entity, d) then
            parts[#parts + 1] = "Вы на месте, действие — кнопка A"
        else
            parts[#parts + 1] = "Вы на месте"
        end
        return speak(true)
    end

    -- Beyond this a quest target is a direction, not a destination.
    --
    -- The journal table changed what one press can reach: it hands back the exact object an
    -- objective names wherever it is on the level - four hundred metres away, through a fight
    -- nobody has heard yet. `Osi.CharacterMoveTo` would accept that and set off, and a blind
    -- player would be crossing the map on one keypress with no idea what is on the way. So
    -- far targets go through the hop machinery exploration already uses: walk to the furthest
    -- thing standing that way, say what it was and how much is left. Each press is then a
    -- bounded move whose end can be heard, and the direction is still exact.
    local far = (it.quest ~= nil and d > M.QUEST_DIRECT)
    local uuid = soft(function() return it.entity.Uuid.EntityUuid end)
    local msg, going, tail = nil, it.name, nil

    if far or type(uuid) ~= "string" or uuid == "" then
        -- An exploration anchor is a **direction**, never a destination: it is a region
        -- trigger hundreds of metres off, and coordinates are not walked to at all (see the
        -- server). So the step is taken to the furthest *thing* standing that way - an object
        -- is on real ground, the engine paths to it and stops at reach. Which is also what
        -- exploring is: go to what you can hear, listen to what came into range, go again.
        if it.anchor == nil then
            parts[#parts + 1] = "Туда идти не по чему"
            return speak(false)
        end
        local target, err = M.stepTarget(it)
        if target == nil then
            if far then parts[#parts + 1] = where end
            parts[#parts + 1] = err or "В ту сторону не за что зацепиться"
            return speak(false)
        end
        going = target.name
        msg = { cmd = "gotoObject", uuid = target.uuid }
        if far then
            tail = where .. ". Иду в ту сторону: " .. target.name .. ", " .. dm(target.dist)
        else
            tail = "Иду " .. tostring(it.dir) .. ": " .. target.name .. ", " .. dm(target.dist) ..
                   -- One hop is not the journey: saying what is left to the region is what
                   -- turns a series of presses into progress the player can hear.
                   (target.left and (", до участка " .. dm(target.left)) or "")
        end
    else
        msg = { cmd = "gotoObject", uuid = uuid }
        tail = "Иду: " .. it.name .. ", " .. dm(d) .. ", " .. tostring(it.dir)
    end

    local body = soft(Ext.Json.Stringify, msg)
    local r = try(function() Ext.Net.PostMessageToServer(M.CHANNEL, body) end)
    if not r.ok then
        _P("[nav] approach failed: " .. tostring(r.error))
        parts[#parts + 1] = "Не получилось пойти"
        return speak(false)
    end
    M.walkStarted(msg.uuid, going)
    parts[#parts + 1] = tail
    return speak(true)
end


function M.questGo()
    -- Not a second way to walk. A way to *choose*.
    --
    -- This used to resolve the objective and set off, which was the only thing it could do
    -- while the quest targets lived nowhere but inside it. Now they are entries in the
    -- scanner's own "задача" category, and everything the scanner already knows how to do
    -- applies to them: Home says how far and whether it is getting closer, Alt+Home walks,
    -- the cursor keys step between targets. So this key does the one thing none of those can:
    -- it puts the player on that list, at the nearest thing the story is asking for.
    --
    -- Which is also the answer to more than one quest at a time. There is no longer a single
    -- "the objective" to walk to - there is a list, sorted by distance, and choosing from it
    -- is the player's business rather than a rule invented here.
    if M.stale() then M.scan() end

    local want = nil
    for i = 1, #M.CATEGORIES do
        if M.CATEGORIES[i].key == "quest" then want = i break end
    end
    local was = M.category
    M.category = want or was
    local view = M.rebuildView()

    local obj = M.objective()
    local parts = {}

    -- The wording is repeated only when it has changed. On the fifth press in a row, the
    -- sentence is not what the player is listening for - the distance is.
    if obj ~= nil and obj.text ~= nil and obj.text ~= M.questText then
        -- Name the quest with the task the first time it is said: out of the journal the task
        -- alone ("Найдите способ извлечь личинку") does not say which story it belongs to.
        if obj.quest ~= nil then parts[#parts + 1] = obj.quest end
        parts[#parts + 1] = obj.text
        M.questText = obj.text
    end
    if obj ~= nil and obj.turns then parts[#parts + 1] = obj.turns end

    if #view > 0 then
        M.cursor = 1
        parts[#parts + 1] = describe(view[1])
        -- How many others there are, so that "this is not the only one" is audible without
        -- stepping through the list to find out.
        if #view > 1 then parts[#parts + 1] = "Ещё " .. (#view - 1) end
        if obj ~= nil and obj.fromSaved and not M.savedWarned then
            M.savedWarned = true
            parts[#parts + 1] = "По памяти, откройте журнал чтобы обновить"
        end
        say(table.concat(parts, ". "))
        return true
    end

    -- Nothing to point at. Do not strand the player in an empty category.
    M.category = was
    M.rebuildView()

    if obj == nil then
        say("Задача не видна")
        return false
    end

    -- Why it failed, and not only that it did. There are three different failures behind the
    -- one sentence this used to say, and they want three different things from the player: an
    -- objective the shipped table does not know; an objective it knows that has no marker at
    -- all - roughly half of them, and those are the "talk to somebody" kind; and a marker
    -- whose object is not in this level.
    --
    -- Written after a timed fight on the nautiloid where the layer counted the turns down
    -- correctly and then said "цель не видна поблизости" while the player stood one metre
    -- from an object. Which link broke was not decidable from the transcript, and a second
    -- run of the same fight is expensive: it is a fight.
    local oid = M.objectiveId(obj)
    local qd = _G.QuestData
    local row = (oid ~= nil and qd ~= nil) and qd.obj[oid] or nil
    M.questFail = { text = obj.text, handle = obj.handle, turns = obj.turns, place = obj.place,
                    objective = oid, markers = {}, fromSaved = obj.fromSaved,
                    tasks = #M.questTasks() }
    for i = 3, #(row or {}) do M.questFail.markers[i - 2] = row[i] end
    soft(function() A.write("quest_fail", M.questFail) end)

    if oid == nil then
        parts[#parts + 1] = "эта задача не найдена в списке заданий игры"
    elseif row == nil or #row < 3 then
        parts[#parts + 1] = "у этой задачи нет точки на карте"
    else
        parts[#parts + 1] = "цель этой задачи не в этой локации"
    end

    -- Between quests - which is exactly when a player is most lost - the map's own labels are
    -- the only thing the game still says about where the story lies.
    local mhits = M.markerHits()
    if mhits ~= nil and #mhits > 0 then
        parts[#parts + 1] = "ближайшая метка: " .. describe(mhits[1])
    end
    say(table.concat(parts, ". "))
    return false
end

-- Kept as the old name. Walking itself now lives in approachEntry, which this no longer
-- calls: the key selects, and the scanner's own go key walks.
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
