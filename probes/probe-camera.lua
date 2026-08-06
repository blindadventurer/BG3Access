-- Can the view be pointed at the thing the scanner has selected?
--
-- The clock bearing has been dropped from the spoken list, because it was information with
-- nothing to do: a player who hears "на два" has no key that turns anyone. Turning the view
-- would change that completely, and not only for the wording - BG3 writes the verb it would
-- carry out into `CursorText_c` for whatever the world cursor lands on, and in gamepad mode
-- that cursor is nailed to the centre of the screen. So the view **is** the aim: point it at
-- the door and the game itself says "Открыть", and the A button does it.
--
-- F8 already established the negative half: the cursor cannot be steered, because the ray is
-- built from the camera, upstream of every field that accepts a write. That is exactly why the
-- camera is worth a probe of its own - it is the thing upstream.
--
-- Three places to look, and they fail differently:
--
--   1. A camera **entity** in the client ECS. If it carries a position and a target, and the
--      target takes a write, the view can be aimed and everything else follows.
--   2. A camera on the **extender's own surface** - a function under Ext.Client / Ext.ClientUI
--      whose name mentions camera or look.
--   3. The character's **facing**, `Steering.TargetRotation`. Turning the character is not
--      turning the camera, but it is what decides where "прямо" points, and it may be all the
--      aim that is needed.
--
-- The measurement is the same in every case, and it is not "did the field change" - a mirror
-- field accepts a write and holds it while nothing moves (that is precisely how F8 ended). It
-- is whether the **trace result** moves: `GetPickingHelper(1).Inner.Position` is where the game
-- thinks the player is looking, and if that does not shift, nothing was aimed.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-camera", "PC")
--     Mods.BG3Access.PC.find()          -- what exists
--     Mods.BG3Access.PC.aim("двер")     -- try to point at the nearest door and measure

local A, Pad, Nav = _G.A11y, _G.Pad, _G.Nav
local W = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

local WORDS = { "camera", "look", "view", "aim", "rotat", "steer", "facing", "yaw" }

-- Confirmed to be real labels holding real entities in this build. `CameraTarget` is the one
-- the whole question turns on: one entity, and its name says it is what the view is pointed at.
local CAMERA_LABELS = { "Camera", "GameCameraBehavior", "CameraTarget", "CameraCombatTarget",
                        "CameraSelectorMode", "CameraSpline", "SelectorMode" }

local function relevant(name)
    local low = tostring(name):lower()
    for i = 1, #WORDS do
        if low:find(WORDS[i], 1, true) then return true end
    end
    return false
end

--- Where the game currently thinks the player is looking. The one honest measurement here.
function W.gaze()
    local ph = soft(Ext.ClientUI.GetPickingHelper, 1)
    local inner = ph and soft(function() return ph.Inner end)
    if inner == nil then return nil end
    local p = soft(function() return inner.Position end)
    if p == nil then return nil end
    local x, y, z = soft(function() return p[1] end), soft(function() return p[2] end),
                    soft(function() return p[3] end)
    if type(x) ~= "number" then return nil end
    return { x, y, z }
end

--- 1 and 2: what exists at all.
function W.find()
    local out = { components = {}, entities = {}, api = {} }

    local all = soft(Ext.Entity.GetAllComponentNames)
             or soft(Ext.Entity.GetRegisteredComponentTypes)
    if type(all) == "table" then
        for i = 1, #all do
            if relevant(all[i]) then out.components[#out.components + 1] = tostring(all[i]) end
        end
    end
    _P("[cam] components: " ..
       (#out.components > 0 and table.concat(out.components, ", ") or "none"))

    -- Which of those actually hold anything. A component with no entities is a name, not a
    -- handle - MapMarkerStyle taught that lesson already.
    --
    -- The registered list prints C++ names (`ecl::camera::TargetComponent`) but the lookup
    -- takes the extender's own short labels, and a label it does not know is a hard error
    -- rather than an empty answer - hence the pcall and the hand-written list. These five are
    -- the ones that answered in this build: Camera 2, GameCameraBehavior 1, CameraTarget 1,
    -- CameraCombatTarget 1, CameraSelectorMode 1.
    for _, c in ipairs(CAMERA_LABELS) do
        local ok, list = pcall(Ext.Entity.GetAllEntitiesWithComponent, c)
        local n = (ok and type(list) == "table") and #list or 0
        out.entities[c] = ok and n or "no such label"
        _P("[cam]   " .. c .. ": " .. (ok and (n .. " entities") or "no such label"))
    end

    for _, mod in ipairs({ "Client", "ClientUI", "Level", "Utils" }) do
        local t = soft(function() return Ext[mod] end)
        if type(t) == "table" then
            for k, v in pairs(t) do
                if relevant(k) then out.api[#out.api + 1] = mod .. "." .. tostring(k) end
            end
        end
    end
    table.sort(out.api)
    _P("[cam] api: " .. (#out.api > 0 and table.concat(out.api, ", ") or "none"))
    A.write("cam_find", out)
    return out
end

--- Everything readable on one camera entity, so the fields have names before anything is
--- written to them.
function W.dump(comp)
    comp = comp or "CameraTarget"
    local list = soft(Ext.Entity.GetAllEntitiesWithComponent, comp)
    if type(list) ~= "table" or #list == 0 then
        _P("[cam] no entities with " .. comp)
        return nil
    end
    local e = list[1]
    local names = soft(function() return e:GetAllComponentNames() end) or {}
    _P("[cam] " .. comp .. "[1]: " .. #names .. " components")
    local out = { comp = comp, components = {}, fields = {} }
    for i = 1, #names do out.components[#out.components + 1] = tostring(names[i]) end
    table.sort(out.components)
    _P("[cam]   " .. table.concat(out.components, " "))

    local c = soft(function() return e[comp] end)
    if c ~= nil then
        for _, f in ipairs({ "Position", "Target", "LookAt", "Rotation", "Direction",
                             "Distance", "Pitch", "Yaw", "Fov", "IsActive", "Mode" }) do
            local v = soft(function() return c[f] end)
            if v ~= nil then
                out.fields[f] = str(v)
                _P("[cam]   " .. comp .. "." .. f .. " = " .. str(v))
            end
        end
    end
    A.write("cam_dump", out)
    return out
end

--- 3 and the measurement: try to aim at something and see whether the gaze followed.
---
--- Writes are attempted one at a time and each is checked against `Inner.Position`, because a
--- field that accepts a value and changes nothing is the expected outcome, not the surprising
--- one. Nothing here moves the character.
function W.aim(part, comp)
    local list = Nav.list
    if list == nil or #list == 0 then list = Nav.scan() or {} end
    local it = nil
    for i = 1, #list do
        if tostring(list[i].name):find(part or "", 1, true) then it = list[i] break end
    end
    if it == nil then _P("[cam] nothing named like that nearby") return nil end
    _P("[cam] aiming at " .. it.name .. ", " .. string.format("%.1f м", it.dist))

    local before = W.gaze()
    _P("[cam] gaze before: " .. (before and string.format("%.1f %.1f %.1f", before[1],
        before[2], before[3]) or "unreadable"))

    local tried = {}
    local function attempt(what, fn)
        local ok = soft(fn)
        local after = W.gaze()
        local moved = nil
        if before ~= nil and after ~= nil then
            local dx, dz = after[1] - before[1], after[3] - before[3]
            moved = math.sqrt(dx * dx + dz * dz)
        end
        tried[#tried + 1] = { what = what, wrote = ok ~= nil,
                              gazeMoved = moved and string.format("%.2f", moved) or "?" }
        _P("[cam] " .. what .. ": wrote=" .. tostring(ok ~= nil) ..
           " gaze moved " .. (moved and string.format("%.2f м", moved) or "?"))
    end

    -- The character's own facing, from the client side.
    local me = Nav.me()
    if me ~= nil then
        local mp = Nav.positionOf(me)
        local yaw = math.atan(it.pos[1] - mp[1], it.pos[3] - mp[3])
        attempt("Steering.TargetRotation", function()
            me.Steering.TargetRotation = yaw
            return true
        end)
    end

    -- And the camera itself, if there is one to write to.
    comp = comp or "CameraTarget"
    local cams = soft(Ext.Entity.GetAllEntitiesWithComponent, comp)
    if type(cams) == "table" and #cams > 0 then
        local c = soft(function() return cams[1][comp] end)
        if c ~= nil then
            for _, f in ipairs({ "Target", "LookAt", "Direction" }) do
                if soft(function() return c[f] end) ~= nil then
                    attempt(comp .. "." .. f, function()
                        c[f] = { it.pos[1], it.pos[2], it.pos[3] }
                        return true
                    end)
                end
            end
        end
    end

    -- What the game says is under the cursor now. If any of the above worked, this is the
    -- sentence that proves it - and it is also the whole point of aiming.
    local ct = Nav.cursorText and Nav.cursorText()
    _P("[cam] cursor text now: " .. tostring(ct))
    A.write("cam_aim", { target = it.name, before = before, tried = tried, cursor = ct })
    return tried
end

-- How far the view is, and what it is made of ------------------------------------------
--
-- A different question from aiming, and the one the player actually reported: the camera drifts
-- a long way from the character and the footsteps go quiet with it. Before anything can be done
-- about that, two facts are needed and neither can be had from a file.
--
--   1. **What is normal.** The layer warns on a multiple of the nearest distance it has seen,
--      because nobody has ever measured what the camera's resting distance is. This prints it.
--   2. **What the camera is made of.** `dump()` above asks a hand-written list of field names,
--      which finds nothing if the field is called something else. This walks the real type, so
--      a zoom or a distance is found by whatever name it has.
--
-- If a writable distance turns up here, the drift becomes something the layer can undo rather
-- than only report. If it does not, the answer is the third-party native plugin (Native Camera
-- Tweaks), and that is the player's decision to take, not ours.

--- Every field of every component on the camera entity, by walking the type rather than guessing.
function W.fields(comp)
    local e, found = Nav.cameraEntity and Nav.cameraEntity() or nil, comp
    if comp ~= nil then
        local list = soft(Ext.Entity.GetAllEntitiesWithComponent, comp)
        e = (type(list) == "table") and list[1] or nil
    end
    if e == nil then _P("[cam] no camera entity") return nil end

    local names = soft(function() return e:GetAllComponentNames() end) or {}
    local out = { component = found, components = {}, fields = {} }
    for i = 1, #names do out.components[#out.components + 1] = tostring(names[i]) end

    -- Three ways in, because which of them a build supports is not documented and the cost of
    -- trying all three is nothing.
    local function walk(label, obj)
        if obj == nil then return end
        local seen = {}
        local ser = soft(Ext.Types.Serialize, obj)
        if type(ser) == "table" then
            for k, v in pairs(ser) do seen[tostring(k)] = str(v) end
        end
        local ok = pcall(function()
            for k, v in pairs(obj) do seen[tostring(k)] = str(v) end
        end)
        local tname = soft(Ext.Types.GetObjectType, obj)
        if tname ~= nil then
            local info = soft(Ext.Types.GetTypeInfo, tname)
            local members = info and soft(function() return info.Members end)
            if type(members) == "table" then
                for k in pairs(members) do
                    if seen[tostring(k)] == nil then
                        seen[tostring(k)] = str(soft(function() return obj[k] end))
                    end
                end
            end
        end
        local n = 0
        for k, v in pairs(seen) do
            out.fields[label .. "." .. k] = v
            n = n + 1
            _P("[cam] " .. label .. "." .. k .. " = " .. v)
        end
        if n == 0 then _P("[cam] " .. label .. ": nothing readable (pairs ok=" .. tostring(ok) .. ")") end
    end

    for i = 1, #names do
        local full = tostring(names[i])
        local short = (full:match("([^:]+)$") or full):gsub("Component$", "")
        local c = soft(function() return e[short] end)
        if c ~= nil then walk(short, c) end
    end

    A.write("cam_fields", out)
    return out
end

--- What the distance actually is, sampled over a few seconds of ordinary play.
---
--- Run it, then walk about and turn the view. The spread is what a threshold has to live with.
function W.watch(seconds)
    local n = math.max(1, math.floor((seconds or 20)))
    local samples = {}
    local i = 0
    local sub
    sub = Ext.Events.Tick:Subscribe(function()
        i = i + 1
        if i % 30 ~= 0 then return end
        local d = Nav.cameraDistance and Nav.cameraDistance()
        if d ~= nil then samples[#samples + 1] = d end
        if #samples >= n then
            soft(function() Ext.Events.Tick:Unsubscribe(sub) end)
            local lo, hi, sum = nil, nil, 0
            for _, v in ipairs(samples) do
                lo = (lo == nil or v < lo) and v or lo
                hi = (hi == nil or v > hi) and v or hi
                sum = sum + v
            end
            _P(string.format("[cam] distance over %d samples: min %.1f, mean %.1f, max %.1f",
                #samples, lo or 0, sum / #samples, hi or 0))
            A.write("cam_watch", { samples = samples, min = lo, max = hi })
        end
    end)
    _P("[cam] watching the camera distance - walk about for a bit")
    return true
end

_P("[probe-camera] loaded. PC.find() / PC.dump('Camera') / PC.fields() / PC.watch(20) / PC.aim('двер')")
return W
