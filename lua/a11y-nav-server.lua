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

-- A trail of everything this half ever told a character to do.
--
-- Written because a character was dragged across a level and there was nothing afterwards to
-- say what had done it: the console keeps a few screens, the extender writes no log, and the
-- one thing that could have answered - which order fired, from where, to where - existed only
-- as a print that had already scrolled away. A dozen rows on disk turn "sometimes it teleports
-- me" from a thing to be reasoned about into a thing to be read.
M.TRAIL_FILE = "A11y/nav_moves.json"
M.TRAIL_MAX = 40
M.trailRows = nil

function M.trail(kind, extra)
    local host = soft(Osi.GetHostCharacter)
    local row = { kind = kind, at = soft(Ext.Utils.MonotonicTime), host = tostring(host) }
    if host ~= nil then
        local x, y, z = Osi.GetPosition(host)
        if x ~= nil then
            row.pos = { math.floor(x * 10) / 10, math.floor(y * 10) / 10, math.floor(z * 10) / 10 }
        end
    end
    for k, v in pairs(extra or {}) do row[k] = v end

    if M.trailRows == nil then
        local raw = soft(function() return Ext.IO.LoadFile(M.TRAIL_FILE) end)
        local t = (type(raw) == "string" and raw ~= "") and
                  soft(function() return Ext.Json.Parse(raw) end) or nil
        M.trailRows = (type(t) == "table" and type(t.rows) == "table") and t.rows or {}
    end
    M.trailRows[#M.trailRows + 1] = row
    while #M.trailRows > M.TRAIL_MAX do table.remove(M.trailRows, 1) end
    soft(function() Ext.IO.SaveFile(M.TRAIL_FILE, Ext.Json.Stringify({ rows = M.trailRows })) end)
end

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
--- **There is no longer a trusted caller, and that is the fix for a character being dragged.**
---
--- `stop` used to end by asking for a move to the character's own position - the one
--- coordinate that "cannot be wrong". It can. The position is read when the key is pressed and
--- the placement happens some ticks later, after the queue has been cleared, and in between
--- the character keeps moving: under a Run order, or under the player's own stick, that gap is
--- metres. So the placement did not settle the character where it stood, it dragged it back to
--- where it had been - and a placement moves one character, so the party stays where it was
--- and the player is suddenly alone. Which is exactly what was reported.
---
--- The queue clear is the stop. Nothing else here is allowed to move anybody by coordinates.
function M.moveTo(x, y, z, speed)
    _P("[nav-srv] refused a bare coordinate (" ..
       string.format("%.1f %.1f %.1f", x or 0, y or 0, z or 0) ..
       "): moving by position places rather than walks, so only objects are walked to")
    M.last = { x = x, y = y, z = z, ok = false, err = "coordinates are not walked to" }
    M.reply({ cmd = "refused", why = "coordinates" })
    return false, "coordinates are not walked to"
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

--- Which level a thing is in, or nil if it will not say.
---
--- `Level.LevelName` reads on both halves and on every kind of object that has a place in the
--- world - measured on the host, on items and on triggers.
function M.levelOf(uuid)
    local e = soft(function() return Ext.Entity.Get(uuid) end)
    if e == nil then return nil end
    local lv = soft(function() return e.Level.LevelName end)
    if lv == nil then return nil end
    return tostring(lv)
end

--- **The guard that had to exist, and did not.**
---
--- `CharacterMoveTo` does not refuse an object in another level. It drags the character there
--- - and a drag is not a walk, so the party does not follow: they carry on standing in the
--- level that was left, and the first the player knows of it is a fight taken alone. That is
--- what happened, and this is the line that stops it happening again whatever else is wrong
--- upstream.
---
--- Measured on the save where it bit: of the 41 things the layer was offering as landmarks,
--- **one** was in the player's level, four were in other levels, and thirty-six no longer
--- existed at all. The index had been built in the prologue the night before and nothing ever
--- threw it away.
---
--- Two refusals, and deliberately not a third.
---
--- A thing that does not resolve to an entity is not in the world: thirty-six of the forty-one
--- rows in the file that caused this were of that kind, left over from a level the player had
--- walked out of hours before. And a thing whose level is known and is not ours is the four
--- that could actually be reached - by dragging.
---
--- What is *not* refused is an entity that exists but will not say which level it is in. It
--- has never been seen, and refusing on it would mean a layer that stops walking anywhere the
--- moment some component is missing - which for the person relying on it is worse than the bug
--- being fixed. It is written to the trail instead, so if it ever happens it is on record.
function M.moveToObject(uuid, speed)
    local host = soft(Osi.GetHostCharacter)
    if host == nil then return false, "no host character" end

    local target = soft(function() return Ext.Entity.Get(uuid) end)
    if target == nil then
        _P("[nav-srv] refused " .. tostring(uuid) .. ": no such thing in the world")
        M.trail("refused-gone", { uuid = uuid })
        M.reply({ cmd = "refused", why = "gone" })
        return false, "not in the world"
    end

    local mine, theirs = M.levelOf(host), M.levelOf(uuid)
    if mine ~= nil and theirs ~= nil and mine ~= theirs then
        _P("[nav-srv] refused " .. tostring(uuid) .. ": level " .. theirs .. " is not " .. mine)
        M.trail("refused-level", { uuid = uuid, want = theirs, have = mine })
        M.reply({ cmd = "refused", why = "level", where = theirs })
        return false, "not in this level"
    end
    if theirs == nil then
        _P("[nav-srv] " .. tostring(uuid) .. " will not say which level it is in - allowing")
        M.trail("level-unknown", { uuid = uuid, have = mine })
    end
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

-- **The layer does not teleport anybody. Ever.**
--
-- Decided 2026-08-06, by the person playing: the only travel that should move a character
-- without their legs is the game's own - the waypoint shrines. Everything else walks. A
-- placement or a teleport is not just a rougher way to arrive: it fires the engine's own
-- travel events, it skips whatever the ground between here and there was going to trigger,
-- and the party does not come with it.
--
-- So there is exactly one way for this half to move anyone, and it is `Osi.CharacterMoveTo`
-- to an object in the same level. `CharacterMoveToPosition` is refused for every caller
-- (M.moveTo), the teleport that used to end a hard stop is gone (M.stop), and a target in
-- another level is refused before the order is given (M.moveToObject). If a day comes when
-- somewhere is unreachable on foot, teleporting there becomes its own feature with its own
-- name and its own warning - not a side effect of the stop key.

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
--- **Rewritten 2026-08-06 after a character was dragged across a level.**
---
--- What this used to do last was place the character at the position read when the key was
--- pressed. That is not settling anybody: the read and the placement are separated by the
--- queue clear and by ticks, the character keeps moving in between, and the placement drags it
--- back over that gap. Under a Run order it is metres; on a long walk it is more. And a
--- placement moves one character - the party carries on standing where it was, which is how a
--- blind player ends up alone somewhere with the fight still to come.
---
--- The queue clear is the stop. `PurgeOsirisQueue(character, 1)` drops the task being carried
--- out, not merely what is waiting behind it, and that is what makes the character halt.
---
--- The hard form keeps the teleport-to-self, because a walk the engine will not drop has to be
--- broken somehow - but the position is read **immediately before** it now, with nothing in
--- between, so the window it can drag across is as small as this side can make it. And it
--- refuses outright rather than guess if the engine will not say where the character is.
function M.stop(hard)
    local host = soft(Osi.GetHostCharacter)
    if host == nil then return false end
    -- Twice on a hard stop, and that is the whole of the difference now. What used to be here
    -- was a teleport to the character's own position, and it is gone on purpose - see the note
    -- above about characters walking rather than being placed.
    local used = M.clearQueue(host)
    if hard then
        for _, w in ipairs(M.clearQueue(host)) do used[#used + 1] = w .. "2" end
    end

    local how = #used > 0 and table.concat(used, "+") or "nothing available"
    _P("[nav-srv] stop: " .. how)
    M.trail("stop", { how = how, hard = hard == true })
    M.reply({ cmd = "stopped", how = how, hard = hard == true })
    return #used > 0
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
    -- The level the index is *of*. Without it the file is a list of things that were once
    -- somewhere, and after a level change every one of them is a place the layer will happily
    -- send a character to - which drags them out of the world they are standing in.
    local host = soft(Osi.GetHostCharacter)
    local level = host and M.levelOf(host) or nil
    if level == nil then
        _P("[nav-srv] index: cannot tell which level the host is in - not building one")
        return false
    end
    M.indexing = { all = all, at = 1, rows = {}, kept = 0, seen = 0, level = level, skipped = 0 }
    _P("[nav-srv] index: walking " .. #all .. " entities of " .. level)

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
                    -- Only this level. `GetAllEntities` hands back everything the server is
                    -- holding, which after a few hours of play includes whole regions the
                    -- player left behind: the file that caused the bug had one row of the
                    -- level it was read in and forty of somewhere else.
                    if kind ~= nil and M.levelOf(u) ~= st.level then
                        kind = nil
                        st.skipped = st.skipped + 1
                    end
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
    elseif msg.cmd == "waypointsAsk" then
        -- The client half is rebuilt on every save load, and the poll below only speaks when the
        -- set *changes* - so without this a reloaded client would wait for the next shrine to be
        -- found before it learnt about the ones already there, and meanwhile list all of them.
        -- Answered without touching wpSeen: this is a repeat, not news.
        local set = M.waypointsUnlocked()
        if set ~= nil then
            local ids = {}
            for id in pairs(set) do ids[#ids + 1] = id end
            table.sort(ids)
            M.reply({ cmd = "waypoints", ids = ids, fresh = {} })
            _P("[nav-srv] waypoints on request: " .. #ids)
        end
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

-- Which fast-travel points this save has actually found ---------------------------------
--
-- The map's fog cannot be read - it is a mask the renderer draws and nothing in the ECS, the
-- widget tree or the whole Osiris corpus carries it. But the *consequence* of exploring can be
-- read exactly, and it is in the save rather than in a file of ours: `DB_WaypointUnlocked` is
-- the game's own record of every shrine the party has switched on, one row per waypoint per
-- character.
--
-- The layer used to list all sixteen shrines of Act 1 from the moment the level loaded,
-- including the six underground, which is both clutter and a spoiler of the shape of the act.
-- With this it lists the ones that exist for this playthrough.
--
-- Polled rather than hooked. The story unlocks a waypoint through its own procedure, not
-- through an engine event anyone can subscribe to, so there is nothing to listen for; a read of
-- a table with a handful of rows every couple of seconds is cheaper than the search for a hook
-- that may not exist. The client is told only when the set changes.
M.WP_POLL_MS = 2000
M.wpAt = 0
M.wpSeen = nil

--- The set of unlocked waypoint ids, or nil when the table is not there at all.
---
--- Read exactly the way the console reads it - `Osi.DB_WaypointUnlocked:Get(nil, nil)` inside
--- one pcall - rather than through a held reference. The first version kept the function object
--- in a local and called `db:Get(...)` off it, and that threw "attempt to call a nil value"
--- every time while the same expression typed at the console answered with six rows. An Osi
--- function is a proxy resolved per access; holding one across statements is not the same thing
--- as calling it, and this is not the place to find out why.
--- `M.wpErr` keeps whatever went wrong last, because this half is silent by design and a poll
--- that has been failing for an hour looks exactly like a save with two shrines in it.
M.wpErr = nil

function M.waypointsUnlocked()
    local ok, rows = pcall(function() return Osi.DB_WaypointUnlocked:Get(nil, nil) end)
    if not ok then
        M.wpErr = tostring(rows)
        return nil
    end
    if type(rows) ~= "table" then return nil end
    M.wpErr = nil
    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        local id = (type(row) == "table") and row[1] or nil
        if type(id) == "string" and id ~= "" then out[id] = true end
    end
    return out
end

--- Broadcast the set when it changes, and say which ones are new.
---
--- `fresh` is empty on the first pass of a session on purpose: two waypoints found an hour ago
--- are not news, and announcing the contents of the save at load time is exactly the kind of
--- noise that makes a layer something to be endured.
function M.waypointTick()
    local now = soft(Ext.Utils.MonotonicTime) or 0
    if (now - (M.wpAt or 0)) < M.WP_POLL_MS then return end
    M.wpAt = now

    local set = M.waypointsUnlocked()
    if set == nil then return end

    local ids, fresh, n = {}, {}, 0
    for id in pairs(set) do
        n = n + 1
        ids[#ids + 1] = id
        if M.wpSeen ~= nil and not M.wpSeen[id] then fresh[#fresh + 1] = id end
    end

    local changed = (M.wpSeen == nil) or (#fresh > 0)
    if not changed then
        local was = 0
        for _ in pairs(M.wpSeen) do was = was + 1 end
        changed = (was ~= n)
    end
    if not changed then return end

    table.sort(ids)
    table.sort(fresh)
    M.wpSeen = set
    M.reply({ cmd = "waypoints", ids = ids, fresh = fresh })
    _P("[nav-srv] waypoints unlocked: " .. n .. (#fresh > 0 and (", new " .. table.concat(fresh, ", ")) or ""))
end

--- Tell the client when the game asks whether the player is ready.
---
--- A ready check is the game's own "are you sure", and it is the only warning it gives before a
--- step that cannot be taken back. The story raises one as
---
---     ReadyCheckGlobal("ReadyCheck_EnterNightsongPrison", "Message_ProgressingWorldState", 1, _Char)
---
--- - an id, and the key of the message the modal shows. There are about fifteen of them in the
--- game, and between them they are every point of no return there is: the crossing out of an
--- act, the boat that does not come back, the last door of the story. Sighted players read that
--- box. In the controller interface it is one of the easiest things to walk past.
---
--- The message key is all that crosses the wire; the client turns it into a sentence through the
--- shipped table, the same way it does with quests and places. Which also means the layer says
--- exactly what Larian wrote, in the language the game is being played in, rather than a warning
--- invented here that would have to be kept true across patches.
---
--- **Passed and failed are reported too, and neither is ever answered from here.** Reading the
--- question out is help; pressing the button for the player is not, and a wrong press here would
--- be the single most expensive thing this layer could do.
---
--- Both are Osiris *calls* rather than events, so the listener is on the call itself. If that
--- turns out not to be allowed for calls in this build, the log line below is what says so.
function M.readyListen()
    if _G.A11Y_READY_OSI ~= nil then
        _P("[nav-srv] ready-check listener already registered")
        return true
    end
    local ok = false

    local r = try(function()
        Ext.Osiris.RegisterListener("ReadyCheckGlobal", 4, "after", function(id, message, force, char)
            M.reply({ cmd = "ready", id = tostring(id), msg = tostring(message) })
            _P("[nav-srv] ready check " .. tostring(id) .. " -> " .. tostring(message))
        end)
    end)
    if r.ok then ok = true
    else _P("[nav-srv] ReadyCheckGlobal listener failed: " .. tostring(r.error)) end

    -- What became of it. The check can also be answered by another player in multiplayer, or
    -- cancelled by the game itself, and either way the modal simply goes away.
    for _, ev in ipairs({ "ReadyCheckPassed", "ReadyCheckFailed" }) do
        local q = try(function()
            Ext.Osiris.RegisterListener(ev, 1, "after", function(id)
                M.reply({ cmd = "readyDone", id = tostring(id), passed = (ev == "ReadyCheckPassed") })
                _P("[nav-srv] " .. ev .. " " .. tostring(id))
            end)
        end)
        if q.ok then ok = true
        else _P("[nav-srv] " .. ev .. " listener failed: " .. tostring(q.error)) end
    end

    if ok then _G.A11Y_READY_OSI = true end
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

    -- The one thing this half has to do without being asked. Unsubscribed first for the reason
    -- the net listener is: a reload leaves the previous closure alive, and two of these would
    -- poll and broadcast twice.
    if _G.A11Y_WP_TICK ~= nil then
        soft(function() Ext.Events.Tick:Unsubscribe(_G.A11Y_WP_TICK) end)
        _G.A11Y_WP_TICK = nil
    end
    -- Deliberately not reset: `M.wpSeen` starts nil in a fresh module, which is what makes the
    -- first broadcast of a session announce nothing.
    local tick = soft(function()
        return Ext.Events.Tick:Subscribe(function() soft(M.waypointTick) end)
    end)
    if tick ~= nil then _G.A11Y_WP_TICK = tick
    else _P("[nav-srv] no Tick on the server - waypoints will not be reported") end

    _P("[nav-srv] listening on " .. M.CHANNEL .. " (" .. tostring(id) .. ")")
    pcall(M.questListen)
    pcall(M.readyListen)
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
