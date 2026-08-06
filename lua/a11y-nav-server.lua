-- The server half of navigation: the client sees, the server walks.
--
-- Everything the layer reads lives on the client - the ECS there holds positions, names and
-- the one ClientControl entity that is the character being played. Moving that character is
-- the server's business: Osi.CharacterMoveToPosition sends it along the game's own path,
-- with its own animation, and was measured live doing exactly that.
--
-- The two halves are joined by the extender's own channel rather than by the file bridge:
-- the file bridge exists for speech, which is one-way and does not care about latency,
-- while a move request wants a round trip that the engine already provides.
--
--     server
--     NavSrv = load(Ext.IO.LoadFile("A11y/a11y-nav-server.lua"))()

local M = {}
M.CHANNEL = "A11yNav"

local function try(fn, ...)
    local r = table.pack(pcall(fn, ...))
    if r[1] then return { ok = true, value = r[2] } end
    return { ok = false, error = tostring(r[2]) }
end

local function soft(fn, ...)
    local r = try(fn, ...)
    if r.ok then return r.value end
    return nil
end

M.last = nil

--- Walk the controlled character to a point.
---
--- **The point is validated first, and this is not a nicety.** `CharacterMoveToPosition` does
--- not refuse a position that is not standable - it puts the character there, which off a
--- beach means in the sea, and the player drowned finding that out. `Osi.FindValidPosition`
--- is the engine's own answer to "where near here can something stand"; if it cannot find
--- one, or the one it finds is far from what was asked, the order is refused and said so
--- rather than carried out somewhere else.
--- Only ever called with a position the character is known to be able to occupy.
---
--- **Coordinates are not a safe way to move anyone in this engine, and this is measured.**
--- `CharacterMoveToPosition` does not path to a point and does not refuse an impossible one -
--- it puts the character there. Asked for (0, 500, 0), the middle of the map five hundred
--- metres up, it did exactly that. `Osi.FindValidPosition`, which reads like the guard against
--- this, handed the same point straight back unchanged, so it is no guard at all.
---
--- The player drowned finding the first half of that out. So the layer sends **objects**, not
--- places: a thing standing in the world is on ground the engine can path to and stops at
--- interaction range by itself. The only coordinates still allowed here are the character's
--- own, which is how a walk is cancelled.
function M.moveTo(x, y, z, speed, trusted)
    local host = soft(Osi.GetHostCharacter)
    if host == nil then return false, "no host character" end
    if not trusted then
        _P("[nav-srv] refused a bare coordinate (" ..
           string.format("%.1f %.1f %.1f", x or 0, y or 0, z or 0) ..
           "): moving by position teleports, so only objects are walked to")
        M.last = { x = x, y = y, z = z, ok = false, err = "coordinates are not walked to" }
        M.reply({ cmd = "refused", why = "coordinates" })
        return false, "coordinates are not walked to"
    end
    local r = try(function()
        Osi.CharacterMoveToPosition(host, x, y, z, speed or "Walk", "")
    end)
    M.last = { x = x, y = y, z = z, ok = r.ok, err = r.error, trusted = true }
    _P("[nav-srv] move to " .. string.format("%.1f %.1f %.1f", x, y, z) ..
       " ok=" .. tostring(r.ok) .. " err=" .. tostring(r.error))
    return r.ok, r.error
end

--- Tell the client what happened. Refusing quietly is indistinguishable from a layer that has
--- stopped working, and the player is standing there waiting to hear something.
function M.reply(msg)
    local body = soft(Ext.Json.Stringify, msg)
    if body == nil then return end
    soft(function() Ext.Net.BroadcastMessage(M.CHANNEL, body) end)
end

--- Walk to another entity, which is better than walking to its coordinates: the engine
--- stops at interaction range instead of trying to stand inside it.
---
--- **Run, not Walk.** The original reasoning for walking was that arriving slowly is easier to
--- correct than overshooting - which is true and turned out not to matter, because the layer
--- does not overshoot: the engine stops the order at interaction range by itself, and the stop
--- key clears the queue outright. What the player actually met was a fifty-metre errand taken
--- at walking pace, in silence, with nothing to do but wait it out. Speed is still a parameter,
--- so a caller that wants the careful pace can still ask for it.
M.SPEED = "Run"

function M.moveToObject(uuid, speed)
    local host = soft(Osi.GetHostCharacter)
    if host == nil then return false, "no host character" end
    -- The queue again (see M.stop): a second walk does not cancel the first, it waits for it.
    -- Pressing "go" three times down a list therefore does not change the destination three
    -- times - it books three journeys, and the character sets off on all of them in turn,
    -- which from the outside is a character running its own route and ignoring the layer.
    M.clearQueue(host)
    local r = try(function() Osi.CharacterMoveTo(host, uuid, speed or M.SPEED, "") end)
    _P("[nav-srv] move to object " .. tostring(uuid) .. " ok=" .. tostring(r.ok) ..
       " err=" .. tostring(r.error))
    return r.ok, r.error
end

--- Drop whatever the character has been told to do.
---
--- No "does this call exist" check in front of any of this, and that is deliberate. The first
--- version had one, and it threw "attempt to call a nil value" from a line that contains no
--- call - twice, in two different spellings, on a chunk loaded from the console. It was never
--- needed: `Osi.Whatever` for a name the build does not export is simply nil, and `pcall(nil)`
--- is a failed call, not a crash. So the guard is the pcall that was already there.
---
--- Measured live in this build (Patch 8): `Osi.PurgeOsirisQueue`, `Osi.FlushOsirisQueue` and
--- `Osi.TeleportToPosition` all exist and print as `OsiFunction(...)`.
function M.clearQueue(host)
    local used = {}
    -- `PurgeOsirisQueue(character, removeCurrentTask)` is the one that matters: with 1 it drops
    -- the task being carried out, not just what is waiting behind it.
    if try(Osi.PurgeOsirisQueue, host, 1).ok then used[#used + 1] = "purge" end
    if try(Osi.FlushOsirisQueue, host).ok then used[#used + 1] = "flush" end
    return used
end

--- Stop where we are.
---
--- Moving to the current position was the whole of this, and it does not work: Osiris movement
--- is a **task on the character's queue**, so a second order does not replace the first, it
--- lines up behind it. The character walks the old order out to its end - and when the old
--- order is `CharacterMoveTo` on something it cannot reach, that end never comes and the
--- player is left running in circles with a stop key that answers "Стою" and does nothing.
---
--- So the queue is cleared first and the move-to-self is only what settles the character
--- afterwards. Which call clears it differs between builds, so every candidate that exists is
--- used and what was actually available is reported back.
function M.stop(hard)
    local host = soft(Osi.GetHostCharacter)
    if host == nil then return false end
    local x, y, z = Osi.GetPosition(host)
    local used = M.clearQueue(host)

    -- The last resort, and only when asked for twice: placing the character where it already
    -- stands. This is the one coordinate that cannot be wrong - it is the ground the character
    -- is standing on this instant - and a placement is not a task, so nothing can queue behind
    -- it and keep running.
    if hard then
        local r = try(Osi.TeleportToPosition, host, x, y, z)
        if not r.ok then r = try(Osi.TeleportToPosition, host, x, y, z, "", 0, 0, 0) end
        if r.ok then used[#used + 1] = "teleport" end
    end

    local ok = M.moveTo(x, y, z, "Walk", true)
    _P("[nav-srv] stop: " .. (#used > 0 and table.concat(used, "+") or "moveToSelf only"))
    M.reply({ cmd = "stopped", how = table.concat(used, "+"), hard = hard == true })
    return ok
end

-- The index of the level ------------------------------------------------------------------
--
-- Two objects decide the whole prologue - the transponder that ends it and the rune that
-- opens a pod - and **neither has a display name**. `DisplayName` is absent on both, so
-- `nameOf` returns nil and the client scanner drops them before any category is asked, which
-- is why a player could stand ten metres from the thing the objective names and hear
-- nothing. Widening the radius could never have fixed that, and neither could better word
-- matching: there is no word.
--
-- What they do have is a template - the name whoever built the level wrote, in English, the
-- same in every language. `Osi.GetTemplate` is the only way to it and it is server-only, so
-- the index is built here and left in a file for the client to pick up. A net message was the
-- other option and is the wrong one: this is a few hundred rows, it is wanted once per level,
-- and a file survives the client state being wiped by a save load.
--
-- Built in slices across ticks. 2036 entities carry a uuid and asking each for its template
-- costs about ten seconds in one go - which as a single frame is a hang, and as a hang during
-- loading is a crash report nobody can read.

M.INDEX_FILE = "A11y/level_index.txt"

-- What is worth indexing, and what each thing should be called out loud.
--
-- Ordered: the first pattern that matches wins, so the specific ones come before the general.
-- Everything else on the level is scenery and is left out - an index of all 2036 would be the
-- same wall of barrels the scanner already refuses to read out.
M.INDEX_KINDS = {
    { "Controlpanel",        "пульт" },
    { "_Console",            "пульт" },
    { "Lever",               "рычаг" },
    { "Rune_Key",            "руна-ключ" },
    { "_Key_",               "ключ" },
    { "Rune_Tablet",         "руническая табличка" },
    { "TOOL_Ladder",         "лестница" },
    { "DOOR_",               "дверь" },
    { "_Hatch",              "люк" },
    { "WaypointShrine",      "точка перехода" },
    { "PUZ_",                "механизм" },
    { "Interactive",         "механизм" },
}

-- What is never worth saying out loud, tested before anything else.
--
-- The first index came back 128 rows and 118 of them were noise of exactly the kind this
-- project keeps refusing to read out: 41 `Helper_Waypoint_A`, which are invisible pathing
-- hints for the AI and not the fast-travel shrines the name suggests; 35 `Quest_CMB_StalkBulb`,
-- which are throwable bulbs that carry a Quest_ prefix and nothing else; and invisible
-- blockers. A category answering "where do I go" with forty invisible markers is worse than
-- one that answers nothing, because it sounds like it worked.
M.INDEX_SKIP = {
    "Helper_",           -- invisible AI hints, waypoints among them
    "InvisibleBlocker",
    "Quest_CMB_",        -- consumables that happen to be quest-tagged
    "Quest_Swarming",    -- spawners
    "Blocker",
    "_Trigger",
}

local function indexKind(tpl)
    for i = 1, #M.INDEX_SKIP do
        if tpl:find(M.INDEX_SKIP[i]) then return nil end
    end
    for i = 1, #M.INDEX_KINDS do
        if tpl:find(M.INDEX_KINDS[i][1]) then return M.INDEX_KINDS[i][2] end
    end
    return nil
end

M.indexing = nil

--- Walk the level a slice at a time and write down where the navigable things are.
function M.buildIndex(force)
    if M.indexing ~= nil and not force then return false end
    local all = soft(Ext.Entity.GetAllEntities)
    if type(all) ~= "table" then
        _P("[nav-srv] index: GetAllEntities gave " .. type(all))
        return false
    end
    M.indexing = { all = all, at = 1, rows = {}, kept = 0, seen = 0 }
    _P("[nav-srv] index: walking " .. #all .. " entities")

    local tick
    tick = Ext.Events.Tick:Subscribe(function()
        local st = M.indexing
        if st == nil then
            soft(function() Ext.Events.Tick:Unsubscribe(tick) end)
            return
        end
        local stop = math.min(st.at + 150, #st.all)
        for i = st.at, stop do
            local e = st.all[i]
            local u = soft(function() return e.Uuid.EntityUuid end)
            if u ~= nil then
                st.seen = st.seen + 1
                local tpl = soft(function() return Osi.GetTemplate(u) end)
                if type(tpl) == "string" then
                    local kind = indexKind(tpl)
                    if kind ~= nil then
                        local p = soft(function() return e.Transform.Transform.Translate end)
                        if p ~= nil then
                            st.kept = st.kept + 1
                            -- Tab separated and flat on purpose: the client reads this on a
                            -- keypress and a JSON parse of a few hundred rows is not free.
                            st.rows[#st.rows + 1] = string.format("%s\t%s\t%.1f\t%.1f\t%.1f\t%s",
                                u, kind, p[1], p[2], p[3], tpl)
                        end
                    end
                end
            end
        end
        st.at = stop + 1
        if st.at > #st.all then
            soft(function() Ext.Events.Tick:Unsubscribe(tick) end)
            soft(Ext.IO.SaveFile, M.INDEX_FILE, table.concat(st.rows, "\n"))
            _P("[nav-srv] index: " .. st.kept .. " of " .. st.seen .. " -> " .. M.INDEX_FILE)
            M.indexing = nil
        end
    end)
    return true
end

local function onMessage(channel, payload)
    if channel ~= M.CHANNEL then return end
    local msg = soft(Ext.Json.Parse, payload)
    if type(msg) ~= "table" then
        _P("[nav-srv] bad payload: " .. tostring(payload))
        return
    end
    if msg.cmd == "goto" then
        M.moveTo(tonumber(msg.x), tonumber(msg.y), tonumber(msg.z), msg.speed)
    elseif msg.cmd == "gotoObject" then
        M.moveToObject(msg.uuid, msg.speed)
    elseif msg.cmd == "stop" then
        M.stop(msg.hard == true)
    elseif msg.cmd == "index" then
        M.buildIndex(msg.force == true)
    else
        _P("[nav-srv] unknown command: " .. tostring(msg.cmd))
    end
end

--- Tell the client when a quest moves, because only this half is told.
---
--- `QuestUpdate` is the call the story itself makes - it is all over the goal scripts,
--- `QuestUpdate((CHARACTER)_Player, "TUT_NautiloidEscape", "LearnedHelm_Laezel")` - and it
--- fires whether or not anyone has the journal open. The client turns the step into an
--- objective through the shipped journal table; nothing but the ids crosses the wire.
---
--- Two arities because the story uses both: with the character who caused it and without.
---
--- Registered once per session and never unregistered, which is deliberate. The extender has
--- no way to drop an Osiris listener, and a reload builds a second module whose listener would
--- stack on the first. The guard is a global so the reload finds it: the closure left behind
--- keeps working, since all it does is read its arguments and broadcast them.
function M.questListen()
    if _G.A11Y_QUEST_OSI ~= nil then
        _P("[nav-srv] quest listener already registered")
        return true
    end
    local ok = false
    for _, arity in ipairs({ 2, 3 }) do
        local r = try(function()
            Ext.Osiris.RegisterListener("QuestUpdate", arity, "after", function(a, b, c)
                local quest, step = a, b
                if arity == 3 then quest, step = b, c end
                M.reply({ cmd = "quest", quest = tostring(quest), step = tostring(step) })
                _P("[nav-srv] quest " .. tostring(quest) .. " -> " .. tostring(step))
            end)
        end)
        if r.ok then ok = true
        else _P("[nav-srv] QuestUpdate/" .. arity .. " listener failed: " .. tostring(r.error)) end
    end
    if ok then _G.A11Y_QUEST_OSI = true end
    return ok
end

function M.listen()
    -- A reload leaves the previous listener alive and answering from a dead closure, the
    -- same way input subscriptions do, so the id is kept in a global and dropped first.
    if _G.A11Y_NAV_NET ~= nil then
        soft(function() Ext.Events.NetMessage:Unsubscribe(_G.A11Y_NAV_NET) end)
        _G.A11Y_NAV_NET = nil
    end
    local id = Ext.Events.NetMessage:Subscribe(function(e)
        onMessage(soft(function() return e.Channel end), soft(function() return e.Payload end))
    end)
    if id == nil then
        _P("[nav-srv] FAILED: NetMessage:Subscribe returned nil")
        return false
    end
    _G.A11Y_NAV_NET = id
    M.netId = id
    _P("[nav-srv] listening on " .. M.CHANNEL .. " (" .. tostring(id) .. ")")
    pcall(M.questListen)
    pcall(M.reportCalls)
    return true
end

function M.stopListening()
    if M.netId then soft(function() Ext.Events.NetMessage:Unsubscribe(M.netId) end) end
    M.netId, _G.A11Y_NAV_NET = nil, nil
end

-- Said once, at load: which of the queue calls this build has. If none of them are here the
-- stop key is back to hoping a second order replaces the first, and that is worth knowing from
-- the log rather than from a character that will not stand still.
--- Which of the queue calls this build has, in words, in the log.
---
--- A diagnostic that can stop the thing it diagnoses from loading is worse than none: the first
--- version of this ran at load time, threw, and took the whole server half down with it - so
--- the layer answered "Стою" from a module that was not there. Now it runs from `listen`, and
--- inside a pcall, because nothing here is worth a failed load.
function M.reportCalls()
    _P("[nav-srv] queue calls: purge=" .. tostring(Osi.PurgeOsirisQueue ~= nil) ..
       " flush=" .. tostring(Osi.FlushOsirisQueue ~= nil) ..
       " teleport=" .. tostring(Osi.TeleportToPosition ~= nil))
end

_P("[nav-srv] loaded. NavSrv.listen() / NavSrv.moveTo(x,y,z)")
return M
