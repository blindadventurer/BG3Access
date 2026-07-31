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
--- "Walk" rather than "Run" on purpose: a blind player is navigating by ear and by the
--- object list, and arriving slowly is easier to correct than overshooting.
function M.moveTo(x, y, z, speed)
    local host = soft(Osi.GetHostCharacter)
    if host == nil then return false, "no host character" end
    local r = try(function()
        Osi.CharacterMoveToPosition(host, x, y, z, speed or "Walk", "")
    end)
    M.last = { x = x, y = y, z = z, ok = r.ok, err = r.error }
    _P("[nav-srv] move to " .. string.format("%.1f %.1f %.1f", x, y, z) ..
       " ok=" .. tostring(r.ok) .. " err=" .. tostring(r.error))
    return r.ok, r.error
end

--- Walk to another entity, which is better than walking to its coordinates: the engine
--- stops at interaction range instead of trying to stand inside it.
function M.moveToObject(uuid, speed)
    local host = soft(Osi.GetHostCharacter)
    if host == nil then return false, "no host character" end
    local r = try(function() Osi.CharacterMoveTo(host, uuid, speed or "Walk", "") end)
    _P("[nav-srv] move to object " .. tostring(uuid) .. " ok=" .. tostring(r.ok) ..
       " err=" .. tostring(r.error))
    return r.ok, r.error
end

--- Stop where we are: moving to the current position cancels the order in flight.
function M.stop()
    local host = soft(Osi.GetHostCharacter)
    if host == nil then return false end
    local x, y, z = Osi.GetPosition(host)
    return M.moveTo(x, y, z)
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
        M.stop()
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
    return true
end

function M.stopListening()
    if M.netId then soft(function() Ext.Events.NetMessage:Unsubscribe(M.netId) end) end
    M.netId, _G.A11Y_NAV_NET = nil, nil
end

_P("[nav-srv] loaded. NavSrv.listen() / NavSrv.moveTo(x,y,z)")
return M
