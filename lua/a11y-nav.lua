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
M.SCAN_RADIUS = 80         -- how far the scan itself reaches, for markers and quest objects

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
function M.scan(radius)
    -- Scanned wide, shown near: one sweep feeds every category, and each decides for itself
    -- how far it looks (rebuildView). A second sweep per category switch would cost more than
    -- the filtering it saves.
    radius = radius or M.SCAN_RADIUS
    local me = M.me()
    if me == nil then say("Персонаж не найден") return nil end
    local pos = positionOf(me)
    if pos == nil then say("Позиция неизвестна") return nil end
    local yaw = yawOf(me)

    local near = soft(function() return Ext.Entity.GetEntitiesAroundPosition(pos, radius) end)
    if type(near) ~= "table" then say("Сканирование недоступно") return nil end

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
                    out[#out + 1] = { entity = e, name = name, kind = kind, rank = rank,
                                      dist = dist, dir = dir, pos = p }
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
    local obj = M.objective and M.objective()
    M.questKeys = (obj and obj.text) and M.stems(obj.text) or nil
    M.markerLabels = obj and obj.markers or nil
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
M.FAR = { markers = true, quest = true }

local function matches(key, it)
    if key == "all" then return true end
    if key == "beings" then return it.kind == "существо" or it.kind == "спутник" end
    if key == "usable" then
        return it.kind == "дверь" or it.kind == "контейнер" or it.kind == "объект"
    end
    if key == "things" then return it.kind == nil end
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
        if M.markerLabels == nil then return false end
        for _, label in ipairs(M.markerLabels) do
            if it.name:find(label, 1, true) or label:find(it.name, 1, true) then return true end
        end
        return false
    end
    return true
end

function M.rebuildView()
    local cat = M.CATEGORIES[M.category]
    local limit = M.FAR[cat.key] and M.SCAN_RADIUS or M.radius
    local out = {}
    for i = 1, #M.list do
        local it = M.list[i]
        if (it.dist or 0) <= limit and matches(cat.key, it) then out[#out + 1] = it end
    end
    M.view, M.cursor = out, 0
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

function M.categorySay()
    say(M.CATEGORIES[M.category].name .. ", " .. #M.view)
    return M.CATEGORIES[M.category].key
end

local function describe(it)
    local parts = { it.name }
    if it.kind then parts[#parts + 1] = it.kind end
    parts[#parts + 1] = it.dir
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

--- Recompute one entry against the world as it stands this instant.
---
--- Even a fresh list ages between the scan and the sentence: a creature walks while the
--- player is listening, and the distance said out loud is the one measured a second ago.
--- Cheap enough to do for the single entry being announced.
local function refreshEntry(it)
    local me = M.me()
    local mp = me and positionOf(me)
    local p = it.entity and positionOf(it.entity)
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
    local i = M.cursor + (delta or 1)
    if i < 1 then i = 1 end
    if i > #M.view then i = #M.view end
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
    say(describe(it) .. ", " .. i .. " из " .. #M.view)
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
    local msg
    if type(uuid) == "string" and uuid ~= "" then
        msg = { cmd = "gotoObject", uuid = uuid }
    else
        msg = { cmd = "goto", x = it.pos[1], y = it.pos[2], z = it.pos[3] }
    end

    local body = soft(Ext.Json.Stringify, msg)
    local r = try(function() Ext.Net.PostMessageToServer(M.CHANNEL, body) end)
    if not r.ok then
        _P("[nav] goTo failed: " .. tostring(r.error))
        say("Не получилось пойти")
        return false
    end
    M.cursor = i
    say("Иду: " .. it.name)
    return true
end

function M.stop()
    local body = soft(Ext.Json.Stringify, { cmd = "stop" })
    soft(function() Ext.Net.PostMessageToServer(M.CHANNEL, body) end)
    say("Стою")
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
    if t.dir then bits[#bits + 1] = t.dir end
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
function M.targetTick()
    local t = M.target()
    if t == nil then
        M.lastTarget = nil
        return false
    end
    local key = tostring(t.entity) .. "|" .. tostring(t.hp)
    if key == M.lastTarget then return true end
    M.lastTarget = key
    if t.name == nil then return true end
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
    local msg
    if type(uuid) == "string" and uuid ~= "" then
        msg = { cmd = "gotoObject", uuid = uuid }
    else
        local p = positionOf(t.entity)
        if p == nil then say("Не знаю, где цель") return false end
        msg = { cmd = "goto", x = p[1], y = p[2], z = p[3] }
    end
    local body = soft(Ext.Json.Stringify, msg)
    local r = try(function() Ext.Net.PostMessageToServer(M.CHANNEL, body) end)
    if not r.ok then say("Не получилось подойти") return false end
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
    if out.text == nil and out.turns == nil and out.place == nil and #out.markers == 0 then
        return nil
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
local function walkTo(it)
    local uuid = soft(function() return it.entity.Uuid.EntityUuid end)
    local msg
    if type(uuid) == "string" and uuid ~= "" then
        msg = { cmd = "gotoObject", uuid = uuid }
    else
        msg = { cmd = "goto", x = it.pos[1], y = it.pos[2], z = it.pos[3] }
    end
    local body = soft(Ext.Json.Stringify, msg)
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
                            ". Вы на месте, действие — кнопка A"
        say(table.concat(parts, ". "))
        return true
    end

    if not walkTo(it) then
        parts[#parts + 1] = "не получилось пойти"
        say(table.concat(parts, ". "))
        return false
    end
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

_P("[nav] a11y-nav loaded. Nav.around() / Nav.step(1) / Nav.where() / Nav.calibrate('t')")
return M
