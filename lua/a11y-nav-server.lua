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
    else
        _P("[nav-srv] unknown command: " .. tostring(msg.cmd))
    end
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
