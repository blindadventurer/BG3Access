-- Why the character would not stop, and whether a coordinate can ever be walked to.
--
-- Two findings from play stand behind this, and both point at the same mechanism:
--
--   * "Иду к рюкзаку" started a walk that could not be cancelled and did not end. The stop key
--     answered "Стою" while the character kept going, possibly in circles.
--   * Pressing "go" again while already walking did not change the destination.
--
-- Osiris movement is a **task on the character's queue**, not a state that a later call
-- overwrites. If that is what is happening here then a second order does not replace the
-- first, it waits for it - and an order to reach something unreachable never finishes, so
-- everything queued behind it, including "stand still", never runs. The layer now clears the
-- queue before every move (`NavSrv.clearQueue`), but *which* call does the clearing differs
-- between builds, and this is what says which ones this build has.
--
-- The second question is bigger. Coordinates are not walked to today because
-- `CharacterMoveToPosition` **places** the character rather than pathing it - asked for a point
-- five hundred metres up it put the character there, and `FindValidPosition` handed the same
-- impossible point straight back. That is why exploring hops between objects instead of going
-- in a direction. But the engine's own pathfinder answered in 19 ms in an earlier session, and
-- if it refuses points that cannot be reached, then a coordinate validated by it is safe - and
-- exploration stops needing something to stand in the way.
--
--     server
--     PM = load(Ext.IO.LoadFile("A11y/probe-move.lua"))()
--     PM.calls()  PM.paths()  PM.sample()

local M = {}

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

local function host() return soft(Osi.GetHostCharacter) end

local function pos()
    local h = host()
    if h == nil then return nil end
    local x, y, z = Osi.GetPosition(h)
    if type(x) ~= "number" then return nil end
    return { x, y, z }
end

--- 1. Which of the calls that could clear a task queue exist here.
---
--- Presence only. Nothing is invoked: `PurgeOsirisQueue` with the wrong arity would be a
--- crash, and the point is the inventory, not the experiment.
function M.calls()
    local want = { "PurgeOsirisQueue", "FlushOsirisQueue", "CharacterPurgeQueue",
                   "CharacterMoveTo", "CharacterMoveToPosition", "TeleportToPosition",
                   "CharacterStopMoving", "StopMoving", "CharacterMoveToAndTalk",
                   "FindValidPosition", "IsMoving", "GetPosition",
                   -- Turning, which is the other half of "point me at it": if any of these
                   -- exist, Home can face the character at what it just measured.
                   "SetRotation", "CharacterLookAt", "CharacterSetLookAt", "LookAtPosition",
                   "SetCameraTarget", "CameraLookAt", "SetCameraDistance",
                   "PlayCameraAnimation", "SetOnStage" }
    local have, missing = {}, {}
    for _, n in ipairs(want) do
        if soft(function() return Osi[n] end) ~= nil then have[#have + 1] = n
        else missing[#missing + 1] = n end
    end
    _P("[move] have:    " .. table.concat(have, ", "))
    _P("[move] missing: " .. table.concat(missing, ", "))
    return have, missing
end

--- 2. Can the engine be asked whether a point is reachable, and does it ever say no.
---
--- A fan of twelve bearings at three distances. The number that matters is not how many came
--- back true - it is whether **any** came back false. A validator that approves everything is
--- not a validator, and the layer already lost a character to one of those.
function M.paths(step)
    local h = host()
    local p = pos()
    if p == nil then _P("[move] no host") return nil end
    step = step or 30

    local ent = soft(Ext.Entity.Get, h)
    if ent == nil then _P("[move] host is not an entity handle: " .. tostring(h)) return nil end
    if soft(function() return Ext.Level.BeginPathfindingImmediate end) == nil then
        _P("[move] no Ext.Level.BeginPathfindingImmediate on the server")
        return nil
    end

    local rows, yes, no, other = {}, 0, 0, 0
    for hour = 0, 11 do
        local ang = (hour / 12) * 2 * math.pi
        for _, d in ipairs({ step, step * 2, step * 4 }) do
            local target = { p[1] + math.sin(ang) * d, p[2], p[3] + math.cos(ang) * d }
            local pr = try(Ext.Level.BeginPathfindingImmediate, ent, target)
            local found = nil
            if pr.ok and pr.value ~= nil then
                local fr = try(Ext.Level.FindPath, pr.value)
                found = fr.ok and fr.value or ("ERR " .. tostring(fr.error))
                try(Ext.Level.ReleasePath, pr.value)
            end
            if found == true then yes = yes + 1
            elseif found == false then no = no + 1
            else other = other + 1 end
            rows[#rows + 1] = { hour = hour, dist = d, found = tostring(found),
                                type = type(found) }
        end
    end
    _P("[move] paths: true=" .. yes .. " false=" .. no .. " other=" .. other ..
       " of " .. #rows)
    -- Printed rather than written to a file: the server side has no A.write.
    for i = 1, #rows do
        if rows[i].found ~= "true" then
            _P("[move]   " .. rows[i].hour .. "h " .. rows[i].dist .. "m -> " ..
               rows[i].found .. " (" .. rows[i].type .. ")")
        end
    end
    return rows
end

--- 3. Where the character is, right now.
---
--- Called by hand, a few seconds apart, while a walk is running. Two readings that differ mean
--- the order is still being carried out; two that match after "stop" mean it worked. Crude,
--- and it is the measurement the layer's own stop check now makes for itself.
M.marks = {}

function M.sample(tag)
    local p = pos()
    if p == nil then _P("[move] no host") return nil end
    local last = M.marks[#M.marks]
    local moved = ""
    if last ~= nil then
        local dx, dz = p[1] - last.pos[1], p[3] - last.pos[3]
        moved = string.format(", сдвиг %.2f м", math.sqrt(dx * dx + dz * dz))
    end
    M.marks[#M.marks + 1] = { tag = tostring(tag or #M.marks + 1), pos = p }
    _P(string.format("[move] %s: %.2f %.2f %.2f%s", tostring(tag or #M.marks), p[1], p[2],
                     p[3], moved))
    return p
end

--- 4. Does clearing the queue actually take: order a walk to something far, clear, sample.
---
--- Run as three separate console calls, seconds apart, so the walk has time to be visible:
---     PM.go(uuid)   PM.sample("during")   PM.clear()   PM.sample("after")   PM.sample("after2")
function M.go(uuid, speed)
    local h = host()
    if h == nil then return false end
    local r = try(function() Osi.CharacterMoveTo(h, uuid, speed or "Walk", "") end)
    _P("[move] go " .. tostring(uuid) .. " ok=" .. tostring(r.ok) .. " " .. tostring(r.error))
    M.sample("go")
    return r.ok
end

function M.clear()
    local h = host()
    if h == nil then return nil end
    local used = {}
    if soft(function() return Osi.PurgeOsirisQueue end) ~= nil then
        used[#used + 1] = "purge:" .. tostring(try(Osi.PurgeOsirisQueue, h, 1).ok)
    end
    if soft(function() return Osi.FlushOsirisQueue end) ~= nil then
        used[#used + 1] = "flush:" .. tostring(try(Osi.FlushOsirisQueue, h).ok)
    end
    _P("[move] clear: " .. (#used > 0 and table.concat(used, " ") or "nothing to call"))
    M.sample("clear")
    return used
end

--- 5. The dangerous one, kept behind its own name and a short leash.
---
--- Walks to a coordinate ten metres ahead **after** the pathfinder has agreed to it. If the
--- character arrives on foot, coordinates are usable once validated and exploration can stop
--- hopping between barrels. If the character arrives instantly, they are not, and the layer's
--- refusal to send bare coordinates stays as it is.
---
--- Ten metres and level ground on purpose: the worst outcome should be a short walk, not a
--- swim. Do not run this on a cliff or a jetty.
function M.walkTest(dist)
    local h, p = host(), pos()
    if p == nil then _P("[move] no host") return nil end
    dist = dist or 10

    local ent = soft(Ext.Entity.Get, h)
    local yaw = 0
    local target = { p[1] + math.sin(yaw) * dist, p[2], p[3] + math.cos(yaw) * dist }

    local ok = nil
    local pr = try(Ext.Level.BeginPathfindingImmediate, ent, target)
    if pr.ok and pr.value ~= nil then
        ok = try(Ext.Level.FindPath, pr.value).value
        try(Ext.Level.ReleasePath, pr.value)
    end
    _P(string.format("[move] walkTest to %.1f %.1f %.1f, pathfinder says %s",
                     target[1], target[2], target[3], tostring(ok)))
    if ok ~= true then
        _P("[move] refused by the pathfinder - not sending. This is the good outcome: it means" ..
           " the validator has an opinion.")
        return false
    end
    M.sample("before")
    local r = try(function()
        Osi.CharacterMoveToPosition(h, target[1], target[2], target[3], "Walk", "")
    end)
    _P("[move] sent, ok=" .. tostring(r.ok) .. ". Now call PM.sample('t1'), then again a" ..
       " second later: a jump of ten metres between two samples is a teleport, a metre at a" ..
       " time is a walk.")
    return r.ok
end

_P("[probe-move] loaded. PM.calls() / PM.paths(30) / PM.sample('t') / PM.go(uuid) / PM.clear()" ..
   " / PM.walkTest(10)")
return M
