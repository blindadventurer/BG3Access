-- What came up on screen, recorded while somebody plays.
--
-- The instrument for a thing nobody can hold still: a tutorial popup or a dice roll is on
-- screen for seconds, and by the time a player has said "it is up now" and a console line has
-- been typed it is gone. So this writes as it happens - every widget that appears gets a line
-- in a log and, the first few times, a full structural dump on disk. Then the question "what
-- was that" is answered from the file afterwards instead of from memory.
--
-- Two things it is built around:
--
--   * **The log outlives the Lua state.** Loading a save wipes the client state and every dev
--     module with it (BootstrapClient's own header says so), and this probe is exactly the
--     one that must not be lost at the moment the player starts playing. So the log is read
--     back off disk on every start and appended to, and a heartbeat file lets something
--     outside notice the probe died and arm it again (tools/watch-arm.ps1).
--   * **A widget that has closed is often still in the tree**, hidden rather than destroyed.
--     `W.snap("tag", true)` takes the hidden ones too, which is a free second chance at a
--     panel that has just gone.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-appear", "W")
--     Mods.BG3Access.W.start(1754300000)   -- epoch seconds, so lines carry wall-clock time
--     Mods.BG3Access.W.snap("roll")        -- everything visible, right now
--     Mods.BG3Access.W.stop()

local A, Pad = _G.A11y, _G.Pad
local W = { ticks = 0, sig = nil, up = {}, dumps = {}, dumpTotal = 0, lines = {},
            follow = {}, changed = {} }

-- Widgets whose *content* is the news, watched from the start.
--
-- These are up the whole time a session is running and hold nothing: `Notification_c` at 5
-- nodes, `PassiveRoll` at 3, `CombatLog_c` at 8. So the appear/disappear detector below can
-- never fire for them - they never appear, they fill - and a tutorial popup or a roll that
-- arrives inside one would go straight past a watcher that only counted widgets. Found by
-- snapshotting the session a few seconds after a tutorial hint had already closed: the hint
-- was gone, and these were the names sitting there empty and waiting.
--
-- Seeded here rather than added with `W.watch` at the console, because a save load wipes the
-- Lua state and the module is re-read from this file: anything typed in is lost exactly when
-- the player starts playing, which is the only time any of this matters.
W.FOLLOW = { Notification_c = true, PassiveRoll = true, CombatLog_c = true,
             TargetInfo_c = true, ModalTutorial_c = true }

-- The ones where the interesting moment is shorter than a second.
--
-- `ActiveRoll` reveals its result by unhiding nodes and takes it away again when the dialogue
-- moves on, so the once-a-second pass that suits a notification would step straight over it.
-- These are scanned at 5 Hz instead, and it costs nothing when it costs nothing: the widget
-- only exists while a roll is on screen.
W.HOT = { ActiveRoll = true }
W.DUMP_ON_CHANGE = 14   -- per widget, so a roll animation is caught frame by frame

local LOG  = "A11y/appear_log.txt"
local BEAT = "A11y/appear_beat.txt"

W.LINE_CAP = 2000       -- the log is rewritten whole; this is what keeps that write small
W.DUMP_PER_NAME = 3
W.DUMP_TOTAL = 80

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

--- Wall-clock seconds, taken from a base handed in at start.
---
--- The extender offers a monotonic microsecond counter and no calendar, and a log of "12.4 s
--- after the probe started" cannot be lined up with "it happened just now" typed by a player.
--- So the caller passes the epoch second it armed at and everything here is an offset on it.
function W.now()
    local t = soft(Ext.Utils.MicrosecTime) or 0
    if W.t0 == nil then W.t0 = t end
    return (W.base or 0) + math.floor((t - W.t0) / 1000000)
end

local function save()
    while #W.lines > W.LINE_CAP do table.remove(W.lines, 1) end
    soft(Ext.IO.SaveFile, LOG, table.concat(W.lines, "\n"))
end

function W.note(line)
    W.lines[#W.lines + 1] = tostring(W.now()) .. " " .. tostring(line)
    save()
end

--- Pick the log back up rather than starting a new one.
local function loadLog()
    local s = soft(Ext.IO.LoadFile, LOG)
    local out = {}
    if type(s) == "string" then
        for line in s:gmatch("[^\r\n]+") do out[#out + 1] = line end
    end
    return out
end

-- The structural dump ------------------------------------------------------------------
--
-- Same shape as probe-screens: every node with its flags and text, and - for children that
-- are data rather than elements - the record behind them. Roll and tutorial panels are
-- template-bound, so the caption and the numbers are as likely to be in the data as in the
-- tree, and a dump that only walks elements answers half the question.

local function isElement(o)
    local p = soft(function() return o:GetAllProperties() end)
    if type(p) ~= "table" then return false end
    return p.ActualWidth ~= nil or p.IsHitTestVisible ~= nil or p.IsVisible ~= nil
end

local function recordOf(o)
    local p = soft(function() return o:GetAllProperties() end)
    if type(p) ~= "table" then return nil end
    local names = {}
    for k in pairs(p) do names[#names + 1] = tostring(k) end
    table.sort(names)
    local parts = {}
    for _, k in ipairs(names) do
        local v = p[k]
        local t = type(v)
        if (t == "boolean" or t == "number" or t == "string") and k:sub(1, 1) ~= "." then
            parts[#parts + 1] = k .. "=" .. str(v)
        end
    end
    return table.concat(parts, " ")
end

function W.dump(node, name, tag)
    local lines, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or n >= 2500 or depth > 40 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1

        local p = A.props(o)
        local cls, label = A.splitToString(A.realType(o))
        local text = nil
        if type(p.Text) == "string" and p.Text ~= "" then text = p.Text end
        if text == nil and type(label) == "string" and label ~= "" then text = label end
        if text ~= nil then text = text:gsub("[\r\n]+", " / ") end

        local flags = {}
        local function flag(c, s) if c then flags[#flags + 1] = s end end
        flag(p.IsVisible == false, "hid")
        flag(p.IsSelected == true, "SEL")
        flag(p.IsFocused == true, "FOC")
        flag(p.IsKeyboardFocusWithin == true, "within")
        flag(p.IsEnabled == false, "disabled")
        flag(p.IsChecked ~= nil, "chk=" .. str(p.IsChecked))
        flag(p.AlternationIndex ~= nil, "alt=" .. str(p.AlternationIndex))
        flag(p.SelectedIndex ~= nil, "selIdx=" .. str(p.SelectedIndex))
        flag(type(p.Value) == "number", "val=" .. str(p.Value))

        lines[#lines + 1] = string.format("%d|%s%d|%s|%s|%s|%s", n, string.rep(" ", depth),
            depth, cls:sub(1, 60), str(p.Name), table.concat(flags, ","), tostring(text))

        local ch, cn = A.kids(o)
        for i = 1, cn do
            if isElement(ch[i]) then
                rec(ch[i], depth + 1)
            else
                n = n + 1
                lines[#lines + 1] = string.format("%d|%sDATA|%s", n,
                    string.rep(" ", depth + 1), tostring(recordOf(ch[i])))
            end
        end
    end
    rec(node, 0)
    local file = "A11y/appear_" .. tostring(name) .. "_" .. tostring(tag) .. ".txt"
    soft(Ext.IO.SaveFile, file, table.concat(lines, "\n"))
    return file, n
end

--- Everything on screen this moment, as one file. `hidden` takes the closed panels too.
function W.snap(tag, hidden)
    local ws = soft(Pad.findWidgets) or {}
    local out = {}
    for i = 1, #ws do
        local w = ws[i]
        if hidden or w.visible ~= false then
            local nm = str(w.name)
            local info = soft(Pad.visibleScan, w.node, 600, 40) or { nodes = 0, texts = {} }
            out[#out + 1] = nm .. (w.visible == false and " (hidden)" or "") ..
                            " n=" .. tostring(info.nodes) ..
                            " [" .. table.concat(info.texts, " | ") .. "]"
            W.dump(w.node, nm, tostring(tag))
        end
    end
    soft(Ext.IO.SaveFile, "A11y/appear_snap_" .. tostring(tag) .. ".txt",
         table.concat(out, "\n"))
    W.note("SNAP " .. tostring(tag) .. " " .. #out .. " widgets")
    Ext.Utils.Print("[appear] snap " .. tostring(tag) .. ": " .. #out .. " widgets")
    return #out
end

-- The model behind a tutorial hint -------------------------------------------------------
--
-- `CurrentPlayer.UIData` carries three Noesis collections: `Tutorials`, the journal - 82
-- entries with a title, the long description and a per-player HasBeenShown - and
-- `UnifiedTutorials` / `TutorialNotifications`, both empty except, it is believed, while a
-- hint is actually up. That belief is the thing this records: the collections are read at the
-- moment the panel appears, which is the only moment they can be caught.
--
-- A collection is an Array in the extender's type system: `#c` for the length and `c[i]` for
-- an item, one-based, with `c[0]` nil. String indexing throws outright, which is how the
-- shape was settled rather than guessed.

W.TUTHOOK = { ModalTutorial_c = true, Notification_c = true }

local function uiData()
    local ws = soft(Pad.findWidgets) or {}
    local seen = {}
    local found = nil
    local function hunt(o, depth)
        if o == nil or found ~= nil or depth > 5 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        local p = soft(function() return o:GetAllProperties() end)
        if type(p) ~= "table" then return end
        if p.Tutorials ~= nil and p.UnifiedTutorials ~= nil then found = p return end
        for k, v in pairs(p) do
            local ks = tostring(k)
            if type(v) == "userdata" and ks:sub(1, 1) ~= "." and ks ~= "Parent" then
                hunt(v, depth + 1)
            end
        end
    end
    for i = 1, #ws do
        local p = soft(function() return ws[i].node:GetAllProperties() end)
        if type(p) == "table" and p.DataContext ~= nil then hunt(p.DataContext, 0) end
        if found ~= nil then break end
    end
    return found
end

--- The journal stores its title as a loca handle and its description already rendered, which
--- is why one of them came out as "hac27dae7gbd60g4dd4…" and the other as a sentence.
local function locaText(v)
    if type(v) ~= "string" then return str(v) end
    if v:match("^h%x%x%x%x%x%x%x%xg") == nil then return v end
    local t = soft(Ext.Loca.GetTranslatedString, v)
    if type(t) == "string" and t ~= "" then return t end
    return v
end

local function entryLine(it)
    local p = soft(function() return it:GetAllProperties() end)
    if type(p) ~= "table" then return str(it) end
    local function f(k) return locaText(soft(function() return p[k] end)) end
    return "Title=" .. f("Title") .. " Category=" .. f("Category") ..
           " shown=" .. str(p.HasBeenShown) .. " new=" .. str(p.IsNewTutorial) ..
           " desc=" .. (f("DescriptionController"):gsub("[\r\n]+", " / ")):sub(1, 160)
end

--- What the three collections hold right now, and which journal entries are marked seen.
function W.tutModel(why)
    local d = uiData()
    if d == nil then W.note("MODEL " .. tostring(why) .. " no UIData found") return nil end
    for _, name in ipairs({ "UnifiedTutorials", "TutorialNotifications" }) do
        local c = soft(function() return d[name] end)
        local n = (c ~= nil) and (soft(function() return #c end) or 0) or -1
        W.note("MODEL " .. tostring(why) .. " " .. name .. " n=" .. tostring(n))
        for i = 1, math.min(n, 6) do
            local it = soft(function() return c[i] end)
            if it ~= nil then W.note("   [" .. i .. "] " .. entryLine(it)) end
        end
    end
    -- The journal is 82 entries and is not worth writing out per hint; what changes is the
    -- seen flag, and only the ones now marked are news.
    local t = soft(function() return d.Tutorials end)
    local n = (t ~= nil) and (soft(function() return #t end) or 0) or 0
    local shown = {}
    for i = 1, n do
        local it = soft(function() return t[i] end)
        if it ~= nil then
            local p = soft(function() return it:GetAllProperties() end)
            if type(p) == "table" and p.HasBeenShown == true then
                shown[#shown + 1] = locaText(soft(function() return p.Title end))
            end
        end
    end
    W.note("MODEL " .. tostring(why) .. " Tutorials n=" .. n .. " shown=[" ..
           table.concat(shown, " | ") .. "]")
    return n
end

-- The pass -----------------------------------------------------------------------------

local function appeared(nm, w)
    local info = soft(Pad.visibleScan, w.node, 500, 30) or { nodes = 0, texts = {} }
    W.note("SHOW " .. nm .. " n=" .. tostring(info.nodes) ..
           " [" .. table.concat(info.texts, " | ") .. "]")
    -- Before the dump, not after: the collections behind a hint are emptied as soon as it is
    -- acknowledged, and a dump of 2500 nodes is long enough to lose them in.
    if W.TUTHOOK[nm] then soft(W.tutModel, "on " .. nm) end
    local k = (W.dumps[nm] or 0) + 1
    W.dumps[nm] = k
    -- Dumped on the way in, and only the first few times. A HUD badge that flickers all
    -- evening would otherwise write a file per flicker, and the third look at a panel has
    -- never yet said anything the first two did not.
    if k <= W.DUMP_PER_NAME and W.dumpTotal < W.DUMP_TOTAL and info.nodes > 3 then
        W.dumpTotal = W.dumpTotal + 1
        local file, n = W.dump(w.node, nm, "a" .. k)
        W.note("DUMP " .. nm .. " -> " .. tostring(file) .. " (" .. tostring(n) .. " nodes)")
    end
end

--- Text appearing inside a widget that was already up.
---
--- Off for every widget by default and opt-in by name (`W.watch("Dialogue_c")`), because it
--- costs a bounded scan per followed widget per pass and the player is playing. A roll that
--- turns out to happen inside the dialogue rather than in a panel of its own is exactly what
--- this is held in reserve for.
local function followed(nm, w)
    local info = soft(Pad.visibleScan, w.node, 400, 24) or { texts = {} }
    local joined = table.concat(info.texts, " | ")
    if joined == W.follow[nm] then return end
    local was = W.follow[nm]
    W.follow[nm] = joined
    if was == nil then return end          -- the first reading is a baseline, not news
    local had = {}
    for s in tostring(was):gmatch("[^|]+") do had[(s:gsub("^%s+", ""):gsub("%s+$", ""))] = true end
    local fresh = {}
    for _, s in ipairs(info.texts) do if not had[s] then fresh[#fresh + 1] = s end end
    if #fresh > 0 then
        W.note("TEXT " .. nm .. " + [" .. table.concat(fresh, " | ") .. "]")
    else
        -- Changed without adding a word: a number was replaced, or a line went away. On the
        -- roll panel that is the whole event - the die already reads "20" before it is
        -- thrown, so a result of 20 adds nothing and would have been missed by the test
        -- above. Recorded as a plain difference rather than reasoned about here.
        W.note("DIFF " .. nm .. " [" .. joined .. "]")
    end
    -- The state itself, not only its text: which of ResultTxt and ResultTxtFail was unhidden
    -- is what says whether the check passed, and no reading of the strings can answer it.
    local k = (W.changed[nm] or 0) + 1
    W.changed[nm] = k
    if k <= W.DUMP_ON_CHANGE then
        local file = W.dump(w.node, nm, "c" .. k)
        W.note("DUMP " .. nm .. " -> " .. tostring(file))
    end
end

function W.watch(name)
    W.follow[str(name)] = nil
    W.FOLLOW[str(name)] = true
    Ext.Utils.Print("[appear] following " .. str(name))
end

-- Screens that mean the tree underneath is about to be torn down and rebuilt.
--
-- A save load wipes the client state, and the UI goes with it. This probe reads UI nodes and
-- an 82-entry collection on every widget change, and a node handle does not survive its
-- element (§9 rule 1) - so a walk that straddles the teardown is reaching into freed memory,
-- which is not a Lua error that pcall can catch but a native crash with no dump and no event.
--
-- The game did die once, 34 ms into a load, with the probe running. That is not proof it was
-- this; it is a good enough reason to stand down for the one moment nothing here needs to be
-- watching anyway.
W.QUIET = { LoadGame_c = true, LoadGame = true, Loading = true, LoadingScreen = true,
            MainMenu_c = true, ScreenFadeLoading = true }
W.quiet = 0

function W.tick()
    W.ticks = W.ticks + 1
    -- Every fourth frame. findWidgets is capped at 60 nodes, so this is the one thing here
    -- cheap enough to run while somebody is playing; everything expensive hangs off a change.
    if W.ticks % 4 ~= 0 then return end

    local ws = soft(Pad.findWidgets) or {}

    -- Stand down while a load is on screen, and for a few seconds after it goes: the tree is
    -- still settling when the loading screen lifts, and the state may have been rebuilt
    -- underneath us. Coming back is free - the next pass rebuilds W.up from scratch.
    for i = 1, #ws do
        if ws[i].visible ~= false and W.QUIET[str(ws[i].name)] then W.quiet = 60 break end
    end
    if W.quiet > 0 then
        W.quiet = W.quiet - 1
        if W.quiet == 0 then
            W.sig, W.up = nil, {}
            W.note("AWAKE after a load screen")
        end
        return
    end
    local vis, sig = {}, ""
    for i = 1, #ws do
        if ws[i].visible ~= false then
            local nm = str(ws[i].name)
            vis[nm] = ws[i]
            sig = sig .. nm .. ","
        end
    end

    -- The hot ones first and often; they are the reason this probe exists and they are only
    -- ever up for a moment.
    if W.ticks % 12 == 0 then
        for nm in pairs(W.HOT) do
            if vis[nm] ~= nil then soft(followed, nm, vis[nm]) end
        end
    end

    if W.ticks % 60 == 0 then
        soft(Ext.IO.SaveFile, BEAT, tostring(W.ticks) .. "|" .. tostring(W.now()))
        for nm in pairs(W.FOLLOW) do
            if W.HOT[nm] == nil and vis[nm] ~= nil then soft(followed, nm, vis[nm]) end
        end
    end

    if sig == W.sig then return end
    W.sig = sig

    for nm, w in pairs(vis) do
        if not W.up[nm] then soft(appeared, nm, w) end
    end
    for nm in pairs(W.up) do
        if vis[nm] == nil then W.note("GONE " .. nm) end
    end
    W.up = {}
    for nm in pairs(vis) do W.up[nm] = true end
end

function W.start(base)
    W.stop()
    W.base = tonumber(base) or 0
    W.t0 = nil
    W.lines = loadLog()
    W.ticks, W.sig, W.up = 0, nil, {}
    W.id = Ext.Events.Tick:Subscribe(W.tick)
    _G.A11Y_APPEAR = W.id
    W.note("ARMED (" .. tostring(#W.lines) .. " lines carried over)")
    Ext.Utils.Print("[appear] watching, log has " .. tostring(#W.lines) .. " lines")
    return true
end

function W.stop()
    local id = W.id or _G.A11Y_APPEAR
    if id ~= nil then soft(function() Ext.Events.Tick:Unsubscribe(id) end) end
    W.id, _G.A11Y_APPEAR = nil, nil
end

Ext.Utils.Print("[appear] ready: W.start(epoch) / W.snap(tag[,hidden]) / W.watch(name) / W.stop()")
return W
