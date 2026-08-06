-- The controller side of the layer: pad input, and reading the screen that is actually up.
--
-- Two things force this to exist. The game drops out of controller mode on any keyboard
-- input, Alt+Tab included, so every observation made from outside showed the mouse-mode UI
-- rather than what the tester had on screen (§С4). And the layer's own commands cannot live
-- on the keyboard for the same reason: pressing a key to ask "where am I" would rebuild the
-- interface underneath the question. The pad carries both the game's navigation and ours.
--
-- What a screen is, established by comparing tree outlines with and without a sub-screen up:
-- ls.UIWidget nodes sitting under ContentRoot, one per screen, each with a Name and an
-- IsVisible saying whether it is on display. Opening Load sets MainMenu invisible and adds
-- LoadGame. That is the whole reason the layer used to go quiet on sub-screens - the menu
-- stays in the tree underneath with its own IsFocused still set, and a walk from the root
-- reached that stale focus and the menu's text long before the screen actually on display.
--
-- What a pad run then showed:
--   * in controller mode the screens are a different set of widgets, suffixed _c
--     (MainMenu_c 162 nodes, LoadGame_c 214, Options_c 1087, LobbyBrowser_c 115);
--   * MainMenu_c carries a real Noesis focus and reads perfectly;
--   * Options_c and LoadGame_c carry none at all - the highlight there is not Noesis focus,
--     so a focus watcher can only ever be silent on them;
--   * and the reader cost 50-58 ms per tick against a 16 ms frame, which is what preceded
--     the game falling over. Two full tree walks at 10 Hz, plus SE logging three
--     "Don't know how to fetch property ls.LSButton:TapTime" lines for every button on
--     every GetAllProperties call - 2040 of them in one session.
--
-- So: one scan, of one widget, rate-limited and self-throttling; a review cursor over the
-- text for screens that mark no focus; and every command on a pad chord.
--
--     Pad = load(Ext.IO.LoadFile("A11y/a11y-pad.lua"))()
--     Pad.start()

local A = _G.A11y
if A == nil then
    _P("[pad] a11y-menu is not loaded - push it first")
    error("a11y-pad needs A11y")
end

local M = {}
local try, soft, props = A.try, A.soft, A.props

local function now()
    return tonumber(soft(function() return Ext.Utils.MonotonicTime() end)) or 0
end

local function micros()
    return tonumber(soft(function() return Ext.Utils.MicrosecTime() end)) or 0
end

local function str(v)
    return tostring(soft(function() return tostring(v) end))
end
M.str = str

--- Russian counts out loud. A screen reader saying "3 вариантов" is the sort of thing that
--- grates on every single utterance, and the rule is three lines.
local PLURALS = {
    ["вариант"]  = { "вариант", "варианта", "вариантов" },
    ["строка"]   = { "строка", "строки", "строк" },
    ["пункт"]    = { "пункт", "пункта", "пунктов" },
    ["объект"]   = { "объект", "объекта", "объектов" },
    ["сохранение"] = { "сохранение", "сохранения", "сохранений" },
    ["кампания"] = { "кампания", "кампании", "кампаний" },
    ["час"]      = { "час", "часа", "часов" },
    ["минута"]   = { "минута", "минуты", "минут" },
    ["ход"]      = { "ход", "хода", "ходов" },
}

function M.plural(n, word)
    local forms = PLURALS[word]
    if forms == nil then return n .. " " .. word end
    local a, b = n % 10, n % 100
    local form
    if a == 1 and b ~= 11 then form = forms[1]
    elseif a >= 2 and a <= 4 and (b < 12 or b > 14) then form = forms[2]
    else form = forms[3] end
    return n .. " " .. form
end

-- speech ------------------------------------------------------------------------

M.lastSaid = nil

local function say(text, interrupt)
    if type(text) ~= "string" or text == "" then return end
    M.lastSaid = text
    A.say(text, interrupt ~= false)
end
M.say = say

-- pad input ---------------------------------------------------------------------

-- Only these two exist. ControllerAxis, ControllerButton and ControllerInput were tried and
-- each logged "Attempted to subscribe to nonexistent event", which is noise in the runtime
-- log for nothing - the IDE helper names are not the runtime ones (§А).
M.EVENT_NAMES = { "ControllerButtonInput", "ControllerAxisInput" }

local EVENT_FIELDS = { "Button", "Pressed", "Value", "Value2", "Axis", "Index",
                       "DeviceId", "PlayerIndex", "PlayerId", "Event", "Repeat",
                       "CanPreventAction", "ActionPrevented" }

M.raw = {}
M.log = {}
M.subs = {}
M.lastPad = nil
M.speakPad = false      -- learning mode: name every button as it is pressed
M.unknown = {}
M.queue = {}
M.held = {}

local function describeEvent(e)
    local rec = {}
    for _, f in ipairs(EVENT_FIELDS) do
        local r = try(function() return e[f] end)
        if r.ok and r.value ~= nil then rec[f] = str(r.value) end
    end
    local keys = {}
    soft(function()
        for k, v in pairs(e) do keys[#keys + 1] = tostring(k) .. "=" .. type(v) end
    end)
    table.sort(keys)
    rec._pairs = table.concat(keys, ", ")
    return rec
end

local function buttonName(e)
    local b = soft(function() return e.Button end)
    if b == nil then return nil end
    local s = str(b)
    return (s:match("([^:%.]+)$") or s)
end

local function pressed(e)
    local v = soft(function() return e.Pressed end)
    if type(v) == "boolean" then return v end
    local s = soft(function() return tostring(e.Event) end)
    if type(s) == "string" then return s:lower():find("down") ~= nil end
    return nil
end

-- Controls, take three: **the pad belongs to the game**.
--
-- The first attempt hung commands off a held LeftShoulder and none of them fired - LB
-- switches tabs, so it is tapped, never held. The second took the two stick clicks, and that
-- worked, but the price only became clear once the full layout was read out of the game
-- (§F13): the left stick click is the game's `ToggleInputMode` and the right stick click is
-- `ShowWorldTooltips`, which highlights every interactable object nearby and names it. The
-- layer was suppressing the one button that answers "what can I touch here" - and the D-pad,
-- inside review mode, was suppressing `PrevObject`/`NextObject` and the rest panel with it.
--
-- So the scanner moves to the keyboard entirely, where there are dozens of free keys and no
-- competition, and the pad is left alone. There is no review mode any more either: it existed
-- to lend the D-pad to the cursor, and nothing borrows the D-pad now.
M.BUTTONS = {}                  -- deliberately empty; see above
M.REVIEW_BUTTONS = {}

M.review = false

-- The left stick is the stop button.
--
-- It has to be. A scripted walk is an Osiris task and the layer's own stop key was answering
-- "Стою" without stopping anything (see a11y-nav-server); meanwhile the one reflex a player
-- has when the character runs off somewhere wrong is to push the stick. So that push is now
-- what cancels the walk - no key to remember, and it is the same gesture a sighted player
-- would make.
--
-- Axis events arrive continuously, several a frame, including drift on a stick nobody is
-- touching. Hence a dead zone, and a second between one cancellation and the next.
M.AXIS_DEAD = 0.35
M.AXIS_QUIET_MS = 1000
M.axisNames = {}
M.lastAxis = nil
M.stopSent = nil

local function axisName(e)
    local a = soft(function() return e.Axis end)
    if a == nil then return nil end
    local s = str(a)
    return (s:match("([^:%.]+)$") or s)
end

local function onAxis(e)
    local name = axisName(e) or "?"
    -- Named once each in the log, the same way buttons were learned: the runtime's spelling of
    -- the axes is not documented and the filter below depends on it.
    if M.axisNames[name] == nil then
        M.axisNames[name] = true
        _P("[pad] axis seen: " .. name)
    end

    -- The scale is not documented and both are plausible: a normalised -1..1, or the raw
    -- signed short SDL reports. Anything past the normalised range is taken for the latter and
    -- brought back, so the dead zone means the same thing either way.
    local v = tonumber(soft(function() return e.Value end)) or 0
    if math.abs(v) > 1.5 then v = v / 32767 end
    if math.abs(v) < M.AXIS_DEAD then return end
    M.lastAxis = { name = name, value = v, t = now() }

    -- Only the stick that walks. The right one turns the camera and a trigger is not a stick,
    -- and neither of them means "I am taking over".
    local low = name:lower()
    if low:find("right", 1, true) or low:find("trigger", 1, true) or
       low:find("camera", 1, true) then return end

    local nav = _G.Nav
    -- `nav.walking` used to be the test here, and it was wrong in the one case that matters:
    -- the layer drops that field after sixty seconds of walking, on a false reading of "stuck",
    -- and the moment a stop is sent - so on a long walk the stick went dead exactly when the
    -- player most wanted it. `stopArmed` answers the question actually being asked, which is
    -- whether the layer ever ordered a walk that has not been seen to end.
    if nav == nil or nav.stopArmed == nil or not nav.stopArmed() then return end
    local t = now()
    if M.stopSent ~= nil and (t - M.stopSent) < M.AXIS_QUIET_MS then return end
    M.stopSent = t
    -- Queued like every other command: inside an input handler the reads the layer needs are
    -- degraded (§9 rule 2). Not prevented, either - the stick must still drive the game.
    M.queue[#M.queue + 1] = "stopWalk"
end

local function onPad(eventName)
    return function(e)
        if #M.raw < 12 then
            local rec = describeEvent(e)
            rec._event = eventName
            M.raw[#M.raw + 1] = rec
        end
        local name = buttonName(e) or "?"
        local down = pressed(e)
        M.lastPad = { event = eventName, button = name, pressed = down, t = now() }
        if eventName == "ControllerAxisInput" then
            soft(function() onAxis(e) end)
            return
        end
        if eventName == "ControllerButtonInput" then
            M.log[#M.log + 1] = { t = now(), button = name, pressed = down }
            if #M.log > 120 then table.remove(M.log, 1) end
        end
        if M.speakPad and down == true then say(name, true) end
        if name == "?" or down ~= true then return end

        local cmd = M.BUTTONS[name]
        if cmd == nil and M.review then cmd = M.REVIEW_BUTTONS[name] end
        if cmd ~= nil then
            -- Suppression is the one thing that cannot be deferred a frame.
            soft(function() e:PreventAction() end)
            -- Everything else is queued: inside an input handler the property read is
            -- degraded and a node looks like it carries nothing (§9 rule 2).
            M.queue[#M.queue + 1] = cmd
            return
        end

        -- The bumpers are how tabs are switched, so a press means the list under the cursor
        -- is about to be a different one, its length has to be counted again, and the tab
        -- itself - the thing the press was for - has to be read and said.
        if name == "LeftShoulder" or name == "RightShoulder" then
            M.listDirty, M.tabDirty = true, true
        end

        if M.unknown[name] == nil and eventName == "ControllerButtonInput" then
            M.unknown[name] = true
            _P("[pad] button seen: " .. name)
        end
    end
end

-- The layer's whole control surface: the keyboard.
--
-- The pad plays the game, the keyboard drives the layer, and nothing is shared. These keys
-- reach the layer even in Controller mode, where the game's own keyboard bindings are dead
-- (J does not open the journal there) - because this is a Script Extender hook on the raw key
-- event, not a game binding. Every listed key is suppressed so nothing reaches the game;
-- anything not listed passes through untouched, Alt included.
--
-- Names as this runtime reports them, learned by pressing each key and reading
-- `Pad.unknownKeys`. Delete arrives as DEL, not DELETE, so the binding written from the SDL
-- name never fired once; both spellings are kept so neither runtime can be wrong.
--
-- What is deliberately absent: a key that reads out everything around. Thirty entries of
-- barrels and reeds is not a picture of a room, it is a wall the player has to sit through,
-- and the entry that mattered is somewhere in the middle of it. The list is walked one step
-- at a time, filtered by category, which is how a picture actually gets built.
--
-- Four of these mean one thing in the world and another on a screen, because the question
-- behind them is the same and only its subject changes. End asks "what does all this add up
-- to": the objective in the world, the character sheet on a screen. Delete asks "tell me
-- more about the thing that is selected": close on it out there, read its description here.
M.KEYS = {
    PAGEUP = "prev", PAGEDOWN = "next",     -- with Alt: previous / next category
    -- Home asks "how is the walk going", Alt+Home starts one. That way round because of which
    -- one is pressed more: setting off happens once, and then the question is asked over and
    -- over - are we getting closer, or is the character walking a circle - and it must be the
    -- easier press. Stopping is no longer a key at all: the left stick does it (M.axisTick).
    HOME = "progress",                      -- how far to the target / top of the screen
    END = "quest",                          -- the objective, or the summary of the screen
    DELETE = "range", DEL = "range",        -- how far the scanner looks / details of a screen
    INSERT = "read",                        -- the fight, or the screen, or the last line again
    PAUSE = "where",
}

-- Alt is a modifier here and a game key everywhere else - BG3 highlights loot while it is
-- held - so it is watched, never suppressed.
M.ALT_KEYS = { LALT = true, RALT = true, ALT = true }
M.altDown = false

M.unknownKeys = {}

local function keyName(e)
    local k = soft(function() return tostring(e.Key) end)
    if k == nil then return nil end
    return k:upper():gsub("^SDLK_", "")
end

local function keyPressed(e)
    local v = soft(function() return e.Pressed end)
    if type(v) == "boolean" then return v end
    local s = soft(function() return tostring(e.Event) end)
    if type(s) == "string" then return s:lower():find("down") ~= nil end
    return nil
end

-- Which command a key means right now. Alt turns the list keys into category keys - one pair
-- of keys for "next thing" and "next kind of thing", which is how a screen reader's own
-- navigation reads and needs no second row of bindings to remember.
local ALT_CMD = { prev = "catPrev", next = "catNext" }
-- Setting off is the rarer press, so it takes the modifier and the bare key reports the walk.
-- Written this way rather than in the table above because "goto" is a Lua keyword and cannot
-- be a key in a constructor.
ALT_CMD["progress"] = "goto"
-- Stopping by hand, kept as a fallback to the stick. It is on "where am I" because that is the
-- other key about standing still, and because it is not one that is pressed by accident.
ALT_CMD["where"] = "stop"
-- Delete used to walk to the game's own target - the one its d-pad cycle has picked - which
-- in a fight is a different thing from the scanner's selection and out of one is usually the
-- same thing said twice. So the key now carries how far the scanner looks, which is asked
-- constantly, and closing on the game's target moves to Alt, where it is still there for the
-- fight it was written for.
ALT_CMD["range"] = "approach"

local function onKey(e)
    local k = keyName(e)
    if k == nil then return end

    -- Tracked on both edges, and never suppressed: holding Alt is how BG3 highlights loot.
    if M.ALT_KEYS[k] then
        M.altDown = (keyPressed(e) == true)
        return
    end

    if keyPressed(e) ~= true then return end
    local cmd = M.KEYS[k]
    if cmd ~= nil and M.altDown and ALT_CMD[cmd] then cmd = ALT_CMD[cmd] end
    if cmd == nil then
        -- Learn what this runtime calls its keys, the same way the pad buttons were learned,
        -- and only once each so a held key does not fill the log.
        if M.unknownKeys[k] == nil then
            M.unknownKeys[k] = true
            _P("[pad] key seen: " .. k)
        end
        return
    end
    -- Suppression is the one thing that cannot wait for the next frame (E1).
    soft(function() e:PreventAction() end)
    M.queue[#M.queue + 1] = cmd
end

function M.keysStart()
    M.keysStop()
    local id = Ext.Events.KeyInput:Subscribe(onKey)
    -- Subscribe returns nil for a wrong event name rather than throwing (§А).
    if id == nil then _P("[pad] FAILED: KeyInput:Subscribe returned nil") return false end
    M.keyId = id
    _G.A11Y_KEYS = id
    _P("[pad] keyboard commands active (" .. tostring(id) .. ")")
    return true
end

function M.keysStop()
    local id = M.keyId or _G.A11Y_KEYS
    if id ~= nil then soft(function() Ext.Events.KeyInput:Unsubscribe(id) end) end
    M.keyId, _G.A11Y_KEYS = nil, nil
end

function M.padStart()
    M.padStop()
    _G.A11Y_PAD = {}
    local ok = {}
    for _, name in ipairs(M.EVENT_NAMES) do
        local ev = Ext.Events[name]
        if ev ~= nil then
            local id = soft(function() return ev:Subscribe(onPad(name)) end)
            if id ~= nil then
                M.subs[name] = id
                _G.A11Y_PAD[name] = id
                ok[#ok + 1] = name
            end
        end
    end
    M.held = {}
    _P("[pad] subscribed: " .. (#ok > 0 and table.concat(ok, ", ") or "NOTHING"))
    return ok
end

function M.padStop()
    if _G.A11Y_PAD ~= nil then
        for name, id in pairs(_G.A11Y_PAD) do
            local ev = Ext.Events[name]
            if ev ~= nil then soft(function() ev:Unsubscribe(id) end) end
        end
    end
    _G.A11Y_PAD = nil
    M.subs = {}
    M.held = {}
end

function M.padDump()
    _P("[pad] " .. #M.raw .. " raw shapes, " .. #M.log .. " logged presses")
    A.write("pad_events", { raw = M.raw, log = M.log, seen = M.unknown })
    return M.raw
end

-- finding the screen --------------------------------------------------------------

--- Walk one subtree rather than the whole root.
local function walkFrom(node, visit, maxNodes)
    local n, seen, stop = 0, {}, false
    local function rec(o, depth)
        if stop or o == nil or n >= (maxNodes or 4000) or depth > 40 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        if visit(o, depth, n) then stop = true return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            if stop then return end
            rec(ch[i], depth + 1)
        end
    end
    rec(node, 0)
    return n
end
M.walkFrom = walkFrom

--- The screen containers, straight off ContentRoot.
---
--- Deliberately does not descend into the widgets: this runs several times a second, and the
--- point is to pay for reading one screen rather than all of them. About fifteen nodes.
local function findWidgets(maxDepth)
    local root = soft(Ext.ClientUI.GetRoot)
    if root == nil then return {}, 0 end
    local out, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or depth > (maxDepth or 6) or n > 60 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local cls = select(1, A.splitToString(A.realType(o)))
        if cls:find("UIWidget", 1, true) then
            local p = props(o)
            out[#out + 1] = { node = o, name = str(p.Name), visible = p.IsVisible,
                              order = #out + 1, depth = depth }
            return
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(root, 0)
    return out, n
end
M.findWidgets = findWidgets

--- Read one screen: its visible text in order, and the element it has focused.
---
--- Hidden branches are pruned rather than walked. That is not only cheaper - it is what
--- keeps the readout honest, since BG3 leaves whole panels in the tree with IsVisible false
--- and reading them would announce things that are not on screen.
local function visibleScan(node, nodeCap, textCap)
    local texts, focus, n = {}, nil, 0
    local visited = {}
    nodeCap, textCap = nodeCap or 900, textCap or 40
    local capped = false
    local function rec(o, depth)
        if o == nil or depth > 40 then return end
        if n >= nodeCap then capped = true return end
        local id = tostring(o)
        if visited[id] then return end
        visited[id] = true
        local p = props(o)
        if p.IsVisible == false then return end
        n = n + 1

        if focus == nil and (p.IsFocused == true or p.IsKeyboardFocused == true) then
            local cls = select(1, A.splitToString(A.realType(o)))
            focus = { class = cls, name = str(p.Name), depth = depth,
                      keyboard = p.IsKeyboardFocused == true,
                      text = select(1, A.describe(o)) }
        end
        if #texts < textCap then
            local cls, label = A.splitToString(A.realType(o))
            -- Same reason as in collectText: a nine-slice frame is thirty Image nodes, and
            -- a screen's worth of them eats the node budget before any text is reached.
            if A.NO_TEXT[cls] then return end
            -- Adjacent duplicates only. The visual and logical trees overlap, so a node is
            -- reached twice and its text arrives twice in a row - but `visited` cannot
            -- catch that, because the two references are separate Lua userdata and
            -- tostring() gives different addresses for the same underlying element.
            -- Deduplicating by text outright was the old fix, and it silently deleted real
            -- content: an ability block is a column of numbers, and the second 10 on the
            -- screen belongs to a different ability. That is why Интеллект used to read
            -- with no value at all. Two equal values are never adjacent - the ability's
            -- name sits between them - so collapsing only neighbours separates the cases.
            for _, s in ipairs(A.strings(p.Text, label)) do
                if A.looksLikeText(s) then
                    s = s:gsub("^%s+", ""):gsub("%s+$", "")
                    if texts[#texts] ~= s then texts[#texts + 1] = s end
                end
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(node, 0)
    return { nodes = n, texts = texts, focus = focus, capped = capped }
end
M.visibleScan = visibleScan

--- "Real content" is not "any text": ModDownloadingWidget sits above the menu permanently
--- and holds a single character (a counter reading "0"), which was enough to make it beat
--- the main menu on a first-with-text rule. Two lines and twenty nodes separates a screen
--- from a badge, without a list of overlay names to keep up to date.
local function hasSubstance(info)
    return #info.texts >= 2 and info.nodes >= 20
end

--- Which screen the player is actually looking at.
---
--- Topmost first: the widgets stack in z-order and the newest is last. A widget holding a
--- focused element wins outright, since that is the game saying where the player is; failing
--- that, the topmost widget with real content does.
function M.active(textCap, nodeCap, wantThin)
    local ws = findWidgets()
    if #ws == 0 then return nil end

    -- A confirmation box is the screen for as long as it is up. It holds no focus of its own
    -- while the screen underneath keeps one, so without this every question about "the
    -- screen" - read it, review it, where am I - is answered by what the box is standing in
    -- front of.
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false and M.MODAL_NAMES[str(w.name)] then
            local info = visibleScan(w.node, nodeCap or M.nodeCap, textCap or 40)
            if #info.texts > 0 then
                return { name = w.name, node = w.node, texts = info.texts,
                         focus = info.focus, nodes = info.nodes, capped = info.capped,
                         widgets = #ws, modal = true }
            end
        end
    end

    -- A panel the player opened is the screen too, and for a stronger reason than the box
    -- above: it holds no focus at all, so without this it loses to whatever HUD widget happens
    -- to sit higher in the stack. Checked before the focus loop, not after - a badge that
    -- claims focus behind an open container is not what the player is looking at.
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false and M.PANEL_NAMES[str(w.name)] then
            local info = visibleScan(w.node, nodeCap or M.nodeCap, textCap or 40)
            if #info.texts > 0 then
                return { name = w.name, node = w.node, texts = info.texts,
                         focus = info.focus, nodes = info.nodes, capped = info.capped,
                         widgets = #ws, panel = true }
            end
        end
    end

    local fallback, thin = nil, nil
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false then
            local info = visibleScan(w.node, nodeCap or M.nodeCap, textCap or 40)
            local rec = { name = w.name, node = w.node, texts = info.texts,
                          focus = info.focus, nodes = info.nodes, capped = info.capped,
                          widgets = #ws }
            if info.focus ~= nil then return rec end
            if fallback == nil and hasSubstance(info) then fallback = rec end
            if thin == nil and #info.texts > 0 then thin = rec end
        end
    end
    -- The thin one is returned only when asked for explicitly: during a transition the
    -- badges are briefly all there is, and announcing "ModDownloadingWidget, 1 строка"
    -- between two real screens is worse than saying nothing.
    if fallback ~= nil then return fallback end
    if wantThin then return thin end
    return nil
end

-- commands -------------------------------------------------------------------------

M.cursor = 0            -- review position within the current screen's lines
M.lines = {}
M.lastScreen = nil
M.lastFocus = nil

-- Screens whose first line is not their title.
--
-- The title is normally the first string in the widget, and normally that is right. The
-- journal is not: its first line is the tab strip, so opening it announced "Карта, 24 строк"
-- while the player was looking at the quest log. Named screens are listed here; everything
-- else keeps the first-line rule, which is right far more often than it is wrong.
M.SCREEN_TITLES = {
    JournalQuest = "Дневник заданий",
    JournalQuest_c = "Дневник заданий",
    Journal = "Журнал",
    Journal_c = "Журнал",
    -- Character creation has no title text of its own at all: the first string in the widget
    -- is the value of the first spinner, so arriving on it announced "По выбору".
    CharacterCreation_c = "Создание персонажа",
    CharacterCreation = "Создание персонажа",
    -- The loot panel's first string is the weight readout ("49,1"), which as a title says
    -- nothing about what has just opened in front of the player.
    Container_c = "Контейнер",
    Trade_c = "Обмен",
    Loot_c = "Добыча",
    -- The options screen has no title text either, and its first string is the name of the
    -- first tab - which the tab strip is about to announce in its own right. So arriving
    -- there said "Игра. Игра." and never the word the player pressed to get there.
    Options_c = "Параметры",
    Options = "Параметры",
}

local function screenTitle(a)
    local named = a.name and M.SCREEN_TITLES[tostring(a.name)]
    if named then return named end
    return (a.texts and a.texts[1]) or tostring(a.name)
end

-- One tick, one utterance.
--
-- The speech bridge is a single file rewritten per line (E6), so two `say` calls in the same
-- tick are not two lines - the second overwrites the first before the companion has looked,
-- and the first is simply never heard. That is not a theoretical hazard: arriving on a
-- screen said its title and then, a few statements later in the same pass, the focused
-- element, so no screen title has ever been spoken. Switching tabs on the options screen
-- went the same way.
--
-- So everything that wants to be said in a pass is queued instead, and joined at the end
-- into the one line the bridge can carry. Order is arrival order, which is also the order a
-- player needs it: where you are, then what you are on.
M.pending = {}

local function pend(s)
    if type(s) == "string" and s ~= "" then M.pending[#M.pending + 1] = s end
end

local function flush(interrupt)
    if #M.pending == 0 then return false end
    local line = table.concat(M.pending, ". ")
    M.pending = {}
    say(line, interrupt)
    return true
end

--- Say one line of the review cursor.
---
--- This is what makes Options and Load usable at all today: they mark no Noesis focus, so
--- there is nothing to follow, but their text is right there in the widget. The cursor is
--- ours - it moves only on our chord, never on the game's own navigation - so it cannot
--- fight the game's highlight, and it cannot get out of step with it either, because it
--- makes no claim to be it.
--- Re-read the screen before reviewing it.
---
--- The line list used to be captured once, when the screen came up. On character creation
--- the screen never changes - picking a different origin rewrites the whole right-hand
--- panel while CharacterCreation_c stays exactly where it is - so a review taken from the
--- old capture described the character the player had already moved off. The scan is ~20 ms
--- on the largest screen, which is affordable when it happens on a keypress rather than on
--- every tick.
---
--- Which is what it was written for and never did: the refresh was wired into the "top of
--- the list" key alone, and stepping through the lines walked whatever list happened to be
--- in M.lines - the one captured when the screen came up. Character creation is exactly the
--- screen that breaks: it never changes widget, so the capture is from the first moment the
--- player arrived and describes a character they have long moved off.
---
--- The lists a command builds are left alone. Reading the details or the summary puts them
--- under the cursor deliberately, so that PageUp/PageDown walks what was just read; Home
--- brings the screen back.
M.linesFrom = "screen"

local function refreshLines(force)
    -- Through M, not the local: navMode is declared below this point in the file.
    if M.navMode ~= nil and M.navMode() ~= nil then return end
    if M.linesFrom ~= "screen" and not force then return end
    local a = M.active(120, 2500)
    if a == nil then return end
    M.lines, M.linesFrom = M.linesOf(a), "screen"
    if M.cursor > #M.lines then M.cursor = #M.lines end
end

local function sayLine(delta)
    local n = #M.lines
    if n == 0 then say("нет строк") return end
    local i = M.cursor + delta
    if i < 1 then i = 1 end
    if i > n then i = n end
    M.cursor = i
    say(M.lines[i] .. ", " .. i .. " из " .. n)
end

--- In a session the review cursor walks the world instead of a screen: there is no panel to
--- read, and the list a player needs is the one of things standing around them.
---
--- Except when there is a panel. Character creation is a screen *inside* a running session -
--- the character exists, so `nav.me()` answers - and every key was therefore handled by the
--- world scanner standing behind it: PageDown listed barrels, End walked to the objective,
--- Delete closed on a target. The screen itself could not be reviewed at all.
---
--- A screen is told from the world by the focus. In a session nothing is focused anywhere
--- (§D12) - that is why in-game reading had to be event-driven in the first place - so a
--- widget that does hold a Noesis focus is a panel the player has opened, and while one is
--- up the keys belong to it.
local function navMode()
    local nav = _G.Nav
    if nav == nil or M.inDialogue then return nil end
    if M.screenUp then return nil end
    if soft(function() return nav.me() end) == nil then return nil end
    return nav
end
M.navMode = navMode

local function perform(cmd)
    local nav = navMode()

    if cmd == "goto" then
        -- In the world: walk to what the scanner has selected. On a screen the same key keeps
        -- its old meaning, the top of the list, where "go there" means nothing - and it is
        -- also the way back to the screen after the details or the summary have been put
        -- under the cursor.
        if nav ~= nil then nav.goTo()
        else refreshLines(true) M.cursor = 1 sayLine(0) end
    elseif cmd == "progress" then
        -- The question a walk raises and the layer could not answer: how far is left, and is
        -- that number going down. Without it "иду к рюкзаку" is a promise with no way to check
        -- it, and a character walking a circle sounds exactly like one walking a path.
        -- On a screen the key keeps Home's old meaning, the top of the list.
        if nav ~= nil then nav.progress()
        else refreshLines(true) M.cursor = 1 sayLine(0) end
    elseif cmd == "quest" then
        -- One key for "where does the story want me". It no longer walks: it puts the scanner
        -- on the "задача" category with the cursor on the nearest thing the story is asking
        -- for, and from there the ordinary keys do the rest - Home for how far and whether it
        -- is closing, the go key to set off, the cursor keys to pick a different quest. One
        -- press, one list, and choosing between two quests stops needing a key of its own.
        -- On a screen the same key answers the same question about a character rather than a
        -- map: the summary panel, which is what all the choices so far add up to.
        if nav ~= nil then nav.questGo() else perform("summary") end
    elseif cmd == "approach" then
        -- Closing on what the game's own target cycle has selected is the one move that cycle
        -- cannot make for itself: it selects, it does not walk. On Alt now, because in the
        -- open world it says the same thing as walking to the scanner's own selection.
        if nav ~= nil then nav.approach() else perform("details") end
    elseif cmd == "details" then
        -- Deliberately a key and not an announcement. The description of a value is said
        -- with it, because that is the choice being made; a tooltip, a sub-panel and a whole
        -- settings column are not, and reading them at every step would bury the one word
        -- that changed.
        local lines = M.detailsLines()
        if lines == nil then say("Подробностей нет") return end
        M.lines, M.cursor, M.linesFrom = lines, 0, "details"
        say(table.concat(lines, ". "))
    elseif cmd == "summary" then
        local lines = M.summaryLines()
        if lines == nil then perform("read") return end
        M.lines, M.cursor, M.linesFrom = lines, 0, "summary"
        say(table.concat(lines, ", "))
    elseif cmd == "range" then
        -- How far "around me" reaches - the question a player exploring blind asks most
        -- often, which is why it sits on a key of its own. On a screen the key keeps its old
        -- meaning, the details of what is selected: there distances mean nothing.
        if nav ~= nil then nav.radiusStep(1) else perform("details") end
    elseif cmd == "stop" then
        -- Alt+Pause: the deliberate stop, kept because the stick is a reflex and a reflex can
        -- be wrong about whether it worked. On a screen there is nothing walking, so the key
        -- keeps its plain meaning there.
        if nav ~= nil then nav.stop() else perform("where") end
    elseif cmd == "stopWalk" then
        -- The stick was pushed while the layer had the character walking somewhere. Taken from
        -- _G.Nav rather than navMode(): whatever is on screen, the character is moving and the
        -- player has just said they want it to stop.
        local n = _G.Nav
        if n ~= nil and n.walking ~= nil then n.stop() end
    elseif cmd == "catPrev" or cmd == "catNext" then
        local delta = (cmd == "catNext") and 1 or -1
        if nav ~= nil then nav.categoryStep(delta) else refreshLines() sayLine(delta * 10) end
    elseif cmd == "read" then
        -- Whatever is worth reading at this moment, in that order. In a fight that is the
        -- fight. On a screen it is the screen in full - a menu is text, and reading it out is
        -- the point. In the open world it is neither: "everything around you" is a wall of
        -- barrels that builds no picture, and the category and its count are already
        -- announced by the key that switches them. So there it repeats the last thing said,
        -- which is what a listener actually reaches for when a line goes past.
        if nav ~= nil then
            local c = soft(function() return nav.combat() end)
            if c ~= nil and c.inCombat then nav.combatSay() return end
        end
        local a = M.active(80)
        if a == nil or (nav ~= nil and #a.texts < 8) then
            -- In a session every changing HUD badge looks like a screen (§D12), so a handful
            -- of lines is not one; fall back to repeating rather than reading a badge out.
            perform("repeat")
            return
        end
        M.lines, M.cursor, M.linesFrom = M.linesOf(a), 0, "screen"
        say(table.concat(M.lines, ". "))
    elseif cmd == "where" then
        -- Where you are, largest first: the screen, the section of it, the control. The old
        -- wording said the widget's internal name ("Экран CharacterCreation_c") and took the
        -- focus from the first node in the tree flagged IsFocused, which on a screen with a
        -- summary panel is a line of the summary - so it answered "Интеллект, 10" while the
        -- player stood on the origin carousel.
        local a = M.active(120, 2500)
        if a == nil then say("Экран не читается") return end
        local parts = { screenTitle(a) }
        if M.tab ~= nil then parts[#parts + 1] = M.tab end
        local f = soft(function() return M.widgetFocus(a.node) end)
        local what = (f ~= nil and M.focusText(f)) or (a.focus and a.focus.text)
        if what ~= nil then parts[#parts + 1] = what end
        parts[#parts + 1] = #a.texts .. " строк"
        say(table.concat(parts, ", "))
    elseif cmd == "repeat" then
        if M.lastSaid then A.say(M.lastSaid, true) else say("нечего повторить") end
    elseif cmd == "next" then
        if nav ~= nil then nav.step(1) else refreshLines() sayLine(1) end
    elseif cmd == "prev" then
        if nav ~= nil then nav.step(-1) else refreshLines() sayLine(-1) end
    elseif cmd == "probe" then M.probeSelection("chord")
    end
end

local function drain()
    if #M.queue == 0 then return end
    local pending = M.queue
    M.queue = {}
    for i = 1, #pending do
        local r = try(perform, pending[i])
        if not r.ok then
            _P("[pad] command '" .. tostring(pending[i]) .. "' failed: " .. tostring(r.error))
        end
    end
end

-- the reader -------------------------------------------------------------------------

M.ticks = 0
M.period = 12           -- ticks between scans; 12 is ~5 Hz at 60 fps
M.nodeCap = 900
M.cost = 0
M.slowScans = 0
M.chainMisses = 0

--- The focused element of a screen, asked for directly.
---
--- The screen widget keeps a FocusedElement pointing straight at it. That was found by
--- dumping everything Options_c marks as selected, and it replaces both earlier approaches:
--- searching the subtree for IsFocused cost 19-24 ms and dropped the reader to 1 Hz, and
--- descending the IsKeyboardFocusWithin chain, while far cheaper, still walked the tree. Two
--- property reads now do it.
---
--- Returns nil when the screen holds no focus, which is an answer rather than a failure: it
--- is how a screen that keeps none is told apart from one that was scanned wrong.
--- Follow IsKeyboardFocusWithin down to the element that actually has the focus.
---
--- One walk of the focused path, not of the tree: at each level only the child that claims
--- focus within is descended, so the cost is the depth of the chain rather than the size of
--- the screen. That is why it is affordable as a fallback even though searching for
--- IsFocused outright was not (19-24 ms, which took the reader to 1 Hz).
--- The ancestors of the focused element, newest last. Kept because Noesis `Parent` is the
--- *logical* parent and comes back nil at the first template boundary - climbing it from a
--- control inside a template stops after two levels and never reaches the row it belongs
--- to. The descent below already passes through every ancestor, so recording them costs
--- nothing and is the only reliable ancestry available.
M.focusPath = {}

local function focusChain(node)
    local cur, guard = node, 0
    M.focusPath = { node }
    while cur ~= nil and guard < 40 do
        guard = guard + 1
        local ch, cn = A.kids(cur)
        local nxt = nil
        for i = 1, cn do
            local p = props(ch[i])
            if p.IsFocused == true then
                M.focusPath[#M.focusPath + 1] = ch[i]
                return ch[i]
            end
            if nxt == nil and p.IsKeyboardFocusWithin == true then nxt = ch[i] end
        end
        if nxt == nil then return nil end
        M.focusPath[#M.focusPath + 1] = nxt
        cur = nxt
    end
    return nil
end
M.focusChain = focusChain

--- The ancestors of a known node, root first, found by locating it rather than by
--- following a flag down.
---
--- focusChain takes the first child that reports IsKeyboardFocusWithin, and on character
--- creation more than one does - the flag is set all along the panel, not just on the row
--- in play - so it walks into a neighbouring setting and the caption comes back off by one
--- ("По выбору, Тип тела" for the body type). Searching for the element that actually has
--- the focus cannot drift: it either finds that node or reports nothing.
---
--- Pruned to the branches claiming focus, with one unpruned retry, because the pruned walk
--- is a few dozen nodes and the retry a few hundred - and it only ever runs for a control
--- whose own text was not enough.
local function pathTo(root, target)
    local id = tostring(target)
    local found = nil
    local function rec(o, stack, pruned, budget)
        if o == nil or found ~= nil or budget.n <= 0 then return end
        budget.n = budget.n - 1
        stack[#stack + 1] = o
        if tostring(o) == id then
            found = {}
            for i = 1, #stack do found[i] = stack[i] end
        else
            local ch, cn = A.kids(o)
            for i = 1, cn do
                if found ~= nil then break end
                if not pruned or props(ch[i]).IsKeyboardFocusWithin == true then
                    rec(ch[i], stack, pruned, budget)
                end
            end
        end
        stack[#stack] = nil
    end
    rec(root, {}, true, { n = 400 })
    if found == nil then rec(root, {}, false, { n = 1500 }) end
    M.focusPath = found or {}
    return found ~= nil
end
M.pathTo = pathTo

local function widgetFocus(node)
    local p = props(node)
    if p.FocusedElement ~= nil then
        -- Asking by name is safe here: GetAllProperties just proved it exists, so this
        -- cannot take the throwing path that costs 150x (E5).
        local live = soft(function() return node:GetProperty("FocusedElement") end)
        if type(live) == "userdata" then return live end
    end
    -- LoadGame_c keeps a real focus - its ExpanderButton reports IsFocused and
    -- IsKeyboardFocused - but exposes no FocusedElement on the widget, so the cheap ask
    -- comes back nil and the screen was read as one that holds no focus at all. That, not
    -- an unreachable view, is why the save list never announced anything (retires the
    -- "different device than Options_c" reading of §"что осталось" item 7).
    if p.IsKeyboardFocusWithin == true then return focusChain(node) end
    return nil
end
M.widgetFocus = widgetFocus

-- Reading a list-shaped screen ---------------------------------------------------
--
-- Options_c settled what these screens are made of:
--
--   ListBox HeaderCarouselList        the tabs; the open one is the ListBoxItem with
--     ListBoxItem IsSelected=true     IsSelected, and its text is a loca handle
--   ItemsControl Options              the rows
--     ContentPresenter AlternationIndex=0,1,2…    one per row - and this is what the
--       ls.LSTickBox                             screen's FocusedElement points at, so
--       ls.LSComboBox                            the row index comes free with the focus
--         ListBox RectList
--           ListBoxItem "Метрическая"
--           ListBoxItem "Имперская"  IsSelected=true
--
-- Which makes a proper linear readout possible: caption, value, position, without walking
-- the screen on every tick.

--- Localised text arrives as a handle ("h403a278dg5a07…") wherever the game stores a name
--- rather than a rendered string, exactly as Osi.GetDisplayName does (E10).
local function loca(v)
    if type(v) ~= "string" then return v end
    if v:match("^h%x%x%x%x%x%x%x%xg") == nil then return v end
    local t = soft(function() return Ext.Loca.GetTranslatedString(v) end)
    if type(t) == "string" and t ~= "" then return t end
    return v
end
M.loca = loca

--- One row: its caption, the value of the control in it, and what that control is.
---
--- The value cannot just be the row's text. A combo box keeps every option in the tree, so
--- collecting text from the row of a units setting yields "Метрическая, Имперская" - both of
--- them - when the value is whichever carries IsSelected.
local function readRow(node)
    local labels, value, kind = {}, nil, nil
    local seen = {}
    local function rec(o, depth)
        if o == nil or depth > 10 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        local p = props(o)
        if p.IsVisible == false then return end
        local cls, label = A.splitToString(A.realType(o))

        if cls:find("ListBox", 1, true) and not cls:find("Item", 1, true) then
            kind = kind or "список"
            local ch, cn = A.kids(o)
            for i = 1, cn do
                local cp = props(ch[i])
                if cp.IsSelected == true then
                    local parts = A.collectText(ch[i], 30, 6)
                    if #parts > 0 then value = loca(parts[1]) end
                end
            end
            return          -- never read the unselected options
        end

        if cls:find("TickBox", 1, true) or cls:find("CheckBox", 1, true) then
            kind = "флажок"
            if p.IsChecked ~= nil then
                value = (p.IsChecked == true) and "включено" or "выключено"
            end
        elseif cls:find("Slider", 1, true) then
            kind = "ползунок"
            if type(p.Value) == "number" then value = tostring(math.floor(p.Value + 0.5)) end
        end

        for _, s in ipairs(A.strings(p.Text, label)) do
            if A.looksLikeText(s) then
                s = loca(s:gsub("^%s+", ""):gsub("%s+$", ""))
                if not seen["t:" .. s] then
                    seen["t:" .. s] = true
                    labels[#labels + 1] = s
                end
            end
        end

        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(node, 0)

    local out = {}
    for i = 1, math.min(#labels, 3) do out[#out + 1] = labels[i] end
    if value ~= nil then out[#out + 1] = value end
    if kind ~= nil then out[#out + 1] = kind end
    if #out == 0 then return nil end
    return table.concat(out, ", ")
end
M.readRow = readRow

--- How long the current list is, and which tab it belongs to.
---
--- One walk, and only when the list itself has changed - on arriving at a screen, on a
--- bumper, or when the focused index runs past what was counted. The tab strip is the
--- shallowest ListBox on the screen; the value lists inside the rows sit far deeper.
local function listInfo(widgetNode, focusedNode)
    local fid = tostring(focusedNode)
    local byDepth, rowDepth = {}, nil
    local tabNode, tabDepth = nil, 999
    walkFrom(widgetNode, function(o, depth)
        local p = props(o)
        if p.AlternationIndex ~= nil then
            -- Alternation marks the items of every list on the screen, the tab strip and the
            -- combo boxes included, so the row's own level is what separates its siblings
            -- from everyone else's - and the level is found by meeting the focused node.
            byDepth[depth] = (byDepth[depth] or 0) + 1
            if tostring(o) == fid then rowDepth = depth end
        end
        if depth < tabDepth then
            local cls = select(1, A.splitToString(A.realType(o)))
            if cls:find("ListBox", 1, true) and not cls:find("Item", 1, true) then
                tabNode, tabDepth = o, depth
            end
        end
    end, 2500)
    local count = (rowDepth ~= nil) and (byDepth[rowDepth] or 0) or 0

    local tab = nil
    if tabNode ~= nil then
        walkFrom(tabNode, function(o)
            if tab ~= nil then return true end
            local p = props(o)
            if p.IsSelected == true then
                local parts = A.collectText(o, 30, 6)
                if #parts > 0 then tab = loca(parts[1]) end
            end
        end, 400)
    end
    return count, tab
end
M.listInfo = listInfo

-- A screen made of tabs, a panel and a summary ------------------------------------
--
-- Character creation is the first screen the layer meets that is not a list. It is a tab
-- strip along the top, one settings column for whichever tab is open, a sub-panel beside it,
-- and a summary of the character on the right. The bumpers move between tabs and the column
-- underneath is rebuilt each time. Three things were missing from the readout:
--
--   * **the tab itself**, which is the whole reason the bumper was pressed. Not because it
--     could not be found - the shallowest ListBox on a screen is its tab strip, which is
--     what the options screen already relies on - but because that code hangs off the
--     focused row's AlternationIndex, and the focus here is a spinner, which has none. So
--     the tab was read on Options and never on character creation.
--   * **the description beside the choice**. Every origin, race and class carries a
--     paragraph of prose, sitting in the panel as an ordinary text node a few levels from
--     the carousel that selects it - the most characterful text on the screen, and silent.
--   * **the summary**, which is the character sheet: race, class, the six abilities with
--     their values, initiative, hit points, proficiencies and skills.
--
-- All of it is reached from landmarks the game itself names, in one walk that stops at each
-- of them instead of descending: about 190 nodes rather than the screen's 1126, because the
-- panels hold everything and none of them has to be entered in order to be found.
--
--   ls.UIWidget CharacterCreation_c
--     Control gamePlayPage
--       ContentControl gameplaySubPanel       detail beside the column; usually empty
--       Control gameplayPanel                 the open tab's settings, and its prose
--       Control appearancePanel               the same slot on the Внешность tab
--       Grid tabNavigation
--         ListBox gameplayTabs                originTab raceTab subRaceTab classTab …
--           ListBoxItem raceTab IsSelected=true
--       Control summaryPanel                  the character sheet
--       ls.LSButton ToggleTooltips            "Подсказки (вкл)"
--
-- The options screen turns out to be built the same way, and nobody noticed for weeks: it
-- keeps a panel that explains whichever setting the cursor is on, and the layer read caption,
-- value and position off the row and stopped there. So "Кармические кубики, Вкл., флажок" was
-- announced and the sentence that says what karmic dice *are* was on the screen, unread.
--
--   ls.UIWidget Options_c
--     ListBox HeaderCarouselList            the tabs
--     ItemsControl Options                  the 33 rows - and 1050 of the screen's 1284 nodes
--     Grid PreviewScroll
--       StackPanel PreviewHolder
--         Run PreviewName                   the setting's own name, said already
--         TextBlock                         the paragraph, unnamed and unmarked
--
-- Which is why `Options` is a landmark here without anything reading it: a landmark is
-- recorded and not descended into, and pruning the rows is what brings PreviewScroll - past
-- node 1200 in a plain walk - inside the same 400-node budget the panels are found in.

local LANDMARKS = {
    gameplayTabs = "tabs", gameplayPanel = "panel", gameplaySubPanel = "sub",
    summaryPanel = "summary", appearancePanel = "appearance",
    PreviewScroll = "preview", Options = "rows",
}

--- The named panels of a screen, and the shallowest ListBox as a tab strip of last resort.
---
--- Hidden branches are pruned, which is what makes one function serve every tab: the
--- appearance tab swaps `gameplayPanel` for `appearancePanel` and only the live one is
--- returned. A landmark is recorded and not descended into - that pruning is the whole
--- economy here, since the three panels are 970 of the screen's 1126 nodes.
local function landmarks(node, budget)
    local out, n, seen = {}, 0, {}
    local stripDepth = 99
    local function rec(o, depth)
        if o == nil or n >= (budget or 400) or depth > 14 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local p = props(o)
        if p.IsVisible == false then return end
        local key = LANDMARKS[str(p.Name)]
        if key ~= nil then out[key] = o return end
        if depth < stripDepth then
            local cls = select(1, A.splitToString(A.realType(o)))
            if cls:find("ListBox", 1, true) and not cls:find("Item", 1, true) then
                out.strip, stripDepth = o, depth
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(node, 0)
    out.nodes = n
    return out
end
M.landmarks = landmarks

--- The entries of a tab strip, and which one is open.
---
--- Deduplicated by the item's own Name, and never by node identity: the visual and logical
--- trees hand back different Lua userdata for the same element, so a plain walk meets every
--- tab five times and "2 из 13" comes out as "15 из 65". Invisible entries are dropped -
--- the subclass and spell tabs are hidden until they apply, and counting them would put the
--- position out of step with what the bumpers actually visit.
local function tabItems(strip)
    local out, sel, seen = {}, nil, {}
    local function rec(o, depth)
        if o == nil or depth > 6 or #out >= 30 then return end
        local p = props(o)
        if p.IsVisible == false then return end
        local cls = select(1, A.splitToString(A.realType(o)))
        if cls:find("ListBoxItem", 1, true) then
            local text = A.collectText(o, 24, 5)[1]
            if text == nil then return end
            local id = str(p.Name)
            if id == "nil" then id = text end
            if seen[id] then return end
            seen[id] = true
            out[#out + 1] = { text = loca(text), selected = p.IsSelected == true }
            if p.IsSelected == true then sel = #out end
            return
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(strip, 0)
    return out, sel
end
M.tabItems = tabItems

--- Which section of the screen is open, said the way a player asks for it.
function M.tabState(widgetNode, marks)
    marks = marks or landmarks(widgetNode)
    local strip = marks.tabs or marks.strip
    if strip == nil then return nil end
    local items, sel = tabItems(strip)
    if sel == nil or #items < 2 then return nil end
    return { name = items[sel].text, index = sel, count = #items }
end

-- Prose is told from a label by its length, and nothing else works: the description is an
-- ordinary text node with no name, no class and no property to mark it as the important one
-- on the screen. The threshold is in bytes, and Russian costs two of them per letter, so 80
-- is about forty characters - comfortably above the longest caption here ("Случайно
-- выбранный персонаж", 27 letters) and far below the shortest description.
local PROSE_MIN = 80

--- The sentences under a node, in reading order.
local function proseUnder(node, cap, budget)
    local out, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or #out >= (cap or 4) or n >= (budget or 300) or depth > 24 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local p = props(o)
        if p.IsVisible == false then return end
        local cls, label = A.splitToString(A.realType(o))
        if A.NO_TEXT[cls] then return end
        for _, s in ipairs(A.strings(p.Text, label)) do
            if A.looksLikeText(s) and #s >= PROSE_MIN then
                s = loca(s:gsub("^%s+", ""):gsub("%s+$", ""))
                -- Adjacent only, for the reason given in visibleScan: the same sentence
                -- arrives twice, once on the text node and once on the Run inside it.
                if out[#out] ~= s then out[#out + 1] = s end
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(node, 0)
    return out
end
M.proseUnder = proseUnder

--- The name of the setting the preview panel is describing, and the description itself.
---
--- Not `proseUnder`, and the difference is the whole point. That one tells prose from a label
--- by length because on character creation there is nothing else to tell them apart by; here
--- the screen has already done the separating - everything under PreviewScroll is the
--- explanation, except the branch the game names PreviewName, which is the setting's own
--- caption. So the text is taken whole and no threshold is applied, which matters: the
--- shortest description on the Игра tab is "Отрегулировать интенсивность вибрации
--- контроллера." at 96 bytes against a PROSE_MIN of 80, and one shorter would have been
--- silently dropped.
---
--- A node with text of its own is not descended into, and that is the whole of the second
--- attempt at this. A description arrives in one of two layouts and the layer met the easy
--- one first: a single Run, where the TextBlock above it and the Run itself say the same
--- thing and the neighbour test collapses them. The other splits the paragraph across Runs
--- with LineBreaks between - the TextBlock still carries the whole of it - so collapsing
--- neighbours left the whole *and* both halves, and "Общая инициатива на полном экране" was
--- explained twice running. The container is the complete text and its Runs are that same
--- text cut up, so taking the container and stopping is right in both layouts.
---
--- Newlines are collapsed rather than kept. Several descriptions are laid out as a lead-in
--- and one paragraph per option ("Аватар: …", "Предыдущий: …"), and the sentence punctuation
--- already there is what a screen reader pauses on.
local function previewParts(node)
    local name, out, n, seen = nil, {}, 0, {}
    local function rec(o, depth, inName)
        if o == nil or #out >= 8 or n >= 200 or depth > 14 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local p = props(o)
        if p.IsVisible == false then return end
        -- The caption is a branch, not a node: the game puts the name on the holder and the
        -- text on a Run below it, so this has to be carried down rather than tested once.
        local named = inName or (str(p.Name) == "PreviewName")
        local cls, label = A.splitToString(A.realType(o))
        local said = false
        if not A.NO_TEXT[cls] then
            for _, s in ipairs(A.strings(p.Text, label)) do
                if A.looksLikeText(s) then
                    said = true
                    s = (loca(s):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
                    if s ~= "" then
                        if named then name = name or s
                        elseif out[#out] ~= s then out[#out + 1] = s end
                    end
                end
            end
        end
        if said then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1, named) end
    end
    rec(node, 0, false)
    if #out == 0 then return name, nil end
    return name, table.concat(out, " ")
end
M.previewParts = previewParts

--- The description that belongs to the choice under the cursor.
function M.selectionProse(marks)
    if marks == nil then return nil end
    -- The options screen first: it is the one screen where both could be found at once (the
    -- rows are pruned, but a future tab need not be), and its preview is the more specific
    -- answer - it is bound to the row the cursor is on, where a panel is bound to the screen.
    -- The name is dropped here and kept for the details key: the row has just been announced
    -- and saying "Кармические кубики. Кармические кубики позволяют…" is one word of answer
    -- behind one word of echo.
    if marks.preview ~= nil then
        local _, said = previewParts(marks.preview)
        if said ~= nil then return said end
    end
    local node = marks.panel or marks.appearance
    if node == nil then return nil end
    local parts = proseUnder(node, 4, 300)
    if #parts == 0 then return nil end
    return table.concat(parts, " ")
end

--- The game's own tooltip, when the player has asked for one.
---
--- On the pad that is the Back button - `UIPinTooltip` in the binding table, next to
--- `UIShowInfo` on the right stick - and the game answers by putting a whole widget named
--- `PinnedTooltips_c` on ContentRoot. Which is why searching the character-creation screen
--- for a tooltip found nothing: a tooltip here is a screen of its own, and it exists only
--- while it is pinned. `WorldTooltips` is a different thing and is never this - that is the
--- in-world highlight of everything interactable nearby.
local function tooltipNode(ws)
    for i = #ws, 1, -1 do
        local w = ws[i]
        local nm = tostring(w.name)
        if w.visible ~= false and nm:find("Tooltip", 1, true) and nm ~= "WorldTooltips" then
            return w.node, nm
        end
    end
    return nil
end
M.tooltipNode = tooltipNode

--- Everything the game has to say about the choice under the cursor, on demand.
---
--- The settings column whole, and not just the description in it. That is a deliberate
--- change of mind: reading only the prose was right for the origin and race tabs and useless
--- for the ones the screen is really made of. On Способности the column is a table - "Бонус
--- +2, Ловкость, Бонус +1, Интеллект, Очков умений распределено, Сила 8, Ловкость 17…" - and
--- on Навыки it is every skill with its modifier. None of that is prose, none of it is
--- reachable from the focused spinner, and all of it is the answer to "what am I choosing
--- between". A pinned tooltip, when there is one, is more specific still and wins outright.
function M.detailsLines()
    local ws = findWidgets()
    local tip = tooltipNode(ws)
    if tip ~= nil then
        local t = visibleScan(tip, 600, 40).texts
        if #t > 0 then return t end
    end

    local a = M.active(10)
    if a == nil then return nil end
    -- On a save screen "tell me more" is about the entry under the cursor: everything the
    -- game keeps about it, and what can be done with it.
    if M.saveScreens[str(a.name)] ~= false then
        local lines = soft(function() return M.saveDetails(a.node, nil, str(a.name)) end)
        if lines ~= nil and #lines > 0 then return lines end
    end
    local marks = landmarks(a.node)
    local out = {}
    -- On the options screen this key is the one that answers "say that again, all of it".
    -- The paragraph is spoken with the row, and moving on cuts it off - which is the right
    -- default and no use at all to someone who wanted to hear the end of it. Taken with the
    -- setting's own name, unlike the announcement, because arriving here from four rows
    -- further down needs to say which setting is being explained.
    if marks.preview ~= nil then
        local name, said = previewParts(marks.preview)
        if name ~= nil then out[#out + 1] = name end
        if said ~= nil then out[#out + 1] = said end
    end
    if marks.sub ~= nil then
        for _, s in ipairs(visibleScan(marks.sub, 400, 20).texts) do out[#out + 1] = s end
    end
    local node = marks.panel or marks.appearance
    if node ~= nil then
        for _, s in ipairs(visibleScan(node, 600, 60).texts) do out[#out + 1] = s end
    end
    if #out == 0 then return nil end
    return out
end

--- The character sheet: what the choices made so far add up to.
function M.summaryLines()
    local a = M.active(10)
    if a == nil then return nil end
    -- The same question on a save screen - what does all this add up to - is the campaigns
    -- and how much is in each.
    if M.saveScreens[str(a.name)] ~= false then
        local lines = soft(function() return M.saveSummary(a.node, str(a.name)) end)
        if lines ~= nil and #lines > 0 then return lines end
    end
    local marks = landmarks(a.node)
    if marks.summary == nil then return nil end
    local t = visibleScan(marks.summary, 900, 80).texts
    if #t == 0 then return nil end
    return t
end

--- The playthrough's name, which is on a descendant named Title.
---
--- Not the Expander's own ToString: that reads "Expander: ListBox", and not the first text
--- under it either, for the same reason - a text walk from the group header reaches the
--- template's own words before it reaches the save's. The template names the element that
--- holds the caption, so ask for it by name.
local function titleUnder(node)
    local found = nil
    local function rec(o, d)
        if o == nil or found ~= nil or d > 7 then return end
        local p = props(o)
        if str(p.Name) == "Title" then
            -- The caption is the whole of ToString here, not its tail: a node rendering a
            -- name has no class prefix at all ("Лаэзель", not "TextBlock: Лаэзель"), so
            -- splitToString hands it back as the class and the label comes out nil.
            local rt = A.realType(o)
            found = A.firstText(p.Text, select(2, A.splitToString(rt)), rt)
            -- In the journal the same node is a template placeholder ("[ForceUpdate]") with
            -- the words in a Run below it, so the walk has to go one level further before
            -- deciding there is no caption here.
            if found == nil then found = A.collectText(o, 20, 4)[1] end
            if found ~= nil then return end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1) end
    end
    rec(node, 0)
    return found
end

-- Save screens: a list the game navigates itself ------------------------------------
--
-- The load screen is where "read the widget" finally runs out. Its rows are there, realised
-- and visible - `ListBoxItem > ContentControl ControlRoot > Grid GridRoot > Title` with two
-- Runs named TitleName and Location - and every one of them is **empty**: the item template
-- binds to the row's data and the binding leaves nothing in the tree to read. That is why
-- expanding a campaign went silent while the group headers, whose caption is an ordinary text
-- node, read perfectly.
--
-- The data is right there though, and it is richer than the row ever was:
--
--   ls.UIWidget LoadGame_c
--     DataContext ui::DCWidget   SelectedSave, ExistingSaves, ExistingPlaythroughs,
--                                HasSaveGames, IsSaving
--     ...
--       ItemsControl SavegamesList          logical children: one record per campaign -
--         Expander Playthrough                ProtagonistName, Saves, LatestSave, IsSelected
--           ls.LSToggleButton ExpanderButton  the caption, and the Noesis focus
--           ListBox PlaythroughSavegames    logical children: one record per save -
--                                             Title, Type, TimeString, PlayTimeString,
--                                             LevelName, Difficulty, Validity, SaveID,
--                                             HasMods, HasMissingMods, IsHonourMode
--       Control PresenterControl            the detail panel, showing SelectedSave
--       StackPanel ButtonPrompts            LoadBtn / DelBtn / DelCampaignBtn / BackBtn
--
-- Two things follow, and both are why this needs its own reader rather than another patch to
-- the focus watcher.
--
-- **The game's cursor is not the Noesis focus here.** With a group expanded and the focus
-- still sitting on its ExpanderButton, the prompts read "Загрузить игру" and "Удалить
-- сохранение" and the detail panel showed a save - the game had moved on and the focus had
-- not. So the position is taken from the list's own `SelectedIndex` and the content from the
-- widget's `SelectedSave`, and the focus is used for one thing only: telling a header from a
-- row.
--
-- **The prompts are the screen's own answer to "what can I do here".** They change with what
-- is under the cursor - on a collapsed header LoadBtn reads "Вкл/выкл сворачивание списка" -
-- and each carries the input event the game binds to it, which names the pad button. That is
-- the whole set of operations on a save, straight from the game, with nothing hardcoded.

-- Which pad button raises an event, for reading the prompts out loud. Taken from the binding
-- table (§F13): the four face buttons are what the prompt strip ever uses.
local PROMPT_BUTTON = {
    UIAccept = "A", UICancel = "B", UIMessageBoxX = "X", UIMessageBoxY = "Y",
    UIDelete = "Y", UIMessageBoxA = "A", UIMessageBoxB = "B",
}

-- Confirmation boxes ----------------------------------------------------------------
--
-- Deleting a save raises `MessageBox_c`, a widget of its own on top of the screen. Three
-- things about it decide how it has to be read, and the first two are why it was silent:
--
--   * **it holds no focus at all**, while the screen underneath keeps its own - so the focus
--     search answers with the save list behind the box, and `M.active` does too, since a
--     widget with a focus wins there outright;
--   * **nothing in it is marked** - no IsSelected, no IsFocused, no highlight property
--     anywhere; the two buttons differ only in width;
--   * **and there is nothing to mark.** Each action carries a `BoundEvent`
--     (`UIMessageBoxA`, `UIMessageBoxB`), which is to say the box is not a list that is
--     navigated but two buttons that are pressed. "A - Да, B - Нет" is the whole of it, and
--     it is exact rather than a guess about where a highlight sits.
--
--   ls.UIWidget MessageBox_c
--     Grid bgFade > StackPanel
--       Title "Удалить сохранение"
--       ItemsControl ActionsList     logical children: the actions, named by loca handle,
--         ... ls.LSButton Btn > Run "Да"    each with BoundEvent and ActionCommandParameter
--
-- The same widget carries an `ls.LSTextBox Input` and a countdown, so naming a save and the
-- timed prompts land here too.

M.MODAL_NAMES = { MessageBox_c = true, MessageBox = true }
local MODAL_NAMES = M.MODAL_NAMES

-- Panels the player opens on purpose, which hold no Noesis focus of their own.
--
-- Looting was silent and this is why. Standing at an opened rucksack the tree carries
-- `Container_c` with twelve strings in it - the weight, the capacity, eight item names - so
-- nothing was hidden and nothing needed decoding. But the widget claims no focus, and a
-- session is exactly the case where nothing else does either (§D12), so the layer never
-- decided a screen was open: `M.active` walks the stack from the top and stops at the first
-- widget with *substance*, which up there is `Overlay` or `WorldContextMenu`, and the review
-- keys stayed with the world scanner.
--
-- So these win outright while they are visible, the way a message box does - and unlike a
-- message box they are not modal, they are simply what the player is looking at.
M.PANEL_NAMES = {
    Container_c = true,          -- a chest, a crate, a body, a rucksack on the sand
    Trade_c = true,              -- the same panel's other half
    PartyInventory_c = true,
    Inventory_c = true,
    Loot_c = true,
}

--- The confirmation box on top of everything, read whole: what it asks, and what answering
--- it costs a button-press.
-- The world context menu ---------------------------------------------------------------
--
-- X on the pad, and the most useful thing in the game that the layer could not see at all: it is
-- where "Вскрыть" lives - picking a lock with thieves' tools - along with "Использовать",
-- "Осмотреть", "Разделить" and everything else an object will allow. A player found it with OCR
-- and could not read a single line of it.
--
-- It is not in the widget tree, and no depth would have found it. `WorldContextMenu.xaml` is
-- nine lines: one `ls:LSEntityObject` named `WorldContextEntity`, with the menu attached as
--
--     <ls:LSEntityObject.ContextMenu><ls:ContextMenu .../></ls:LSEntityObject.ContextMenu>
--
-- - a **property**, and a popup that renders in a layer of its own. So the widget walks as an
-- empty box while the menu is on screen, which is exactly what it did.
--
-- Through the property it reads cleanly: `IsOpen`, `HasItems`, and a `FocusElement` that says
-- which row the player is on. The rows themselves are duplicated four to sixteen times over by
-- the template - split-screen holders, text and its shadow - so they are deduplicated by value
-- in first-appearance order, which is the order they are shown in.
M.ctxOpen = nil
M.ctxItems = nil
M.ctxFocus = nil

--- The popup object behind the context menu, or nil when there is none open.
function M.contextPopup(ws)
    local node = nil
    for i = 1, #ws do
        if ws[i].visible ~= false and str(ws[i].name) == "WorldContextMenu" then
            node = ws[i].node
            break
        end
    end
    if node == nil then return nil end

    local ent = nil
    local function find(o, d)
        if o == nil or d > 6 or ent ~= nil then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            local p = props(ch[i])
            if str(p.Name) == "WorldContextEntity" then ent = ch[i] return end
            find(ch[i], d + 1)
        end
    end
    find(node, 0)
    if ent == nil then return nil end

    local ep = props(ent)
    local menu = ep.ContextMenu
    if menu == nil then return nil end
    local mp = props(menu)
    if mp.IsOpen ~= true then return nil end
    return menu, mp
end

--- The strings under a node, in tree order, each one only the first time.
local function ctxStrings(o, limit)
    local out, seen, left = {}, {}, { n = limit or 2500 }
    local function rec(x, d)
        if x == nil or d > 16 or left.n <= 0 or #out >= 24 then return end
        local ch, cn = A.kids(x)
        for i = 1, cn do
            left.n = left.n - 1
            if left.n <= 0 then return end
            local p = props(ch[i])
            -- The row that names whose menu this is, not one of its actions.
            if not str(p.Name):find("PlayerName", 1, true) then
                local t = p.Text
                if type(t) == "string" and t ~= "" and A.looksLikeText(t) then
                    t = t:gsub("^%s+", ""):gsub("%s+$", "")
                    if not seen[t] then
                        seen[t] = true
                        out[#out + 1] = t
                    end
                end
                rec(ch[i], d + 1)
            end
        end
    end
    rec(o, 0)
    return out
end
M.ctxStrings = ctxStrings

function M.contextTick(ws)
    local menu, mp = M.contextPopup(ws)
    if menu == nil then
        if M.ctxOpen then
            M.ctxOpen, M.ctxItems, M.ctxFocus = nil, nil, nil
        end
        return false
    end

    -- Opened: the whole list, once. It is short - three or four rows on a door - and hearing it
    -- whole is the difference between a menu and a wall.
    if not M.ctxOpen then
        M.ctxOpen = true
        local items = ctxStrings(menu)
        M.ctxItems = items
        M.ctxFocus = nil
        if #items > 0 then
            say("Действия: " .. table.concat(items, ", "))
        else
            say("Действия, пусто")
        end
        return true
    end

    -- And which row the player is on, as they move. `FocusElement` is the menu's own answer, so
    -- no highlight has to be guessed at from colours.
    local focus = mp.FocusElement
    if focus ~= nil then
        local here = ctxStrings(focus, 200)[1]
        if here ~= nil and here ~= M.ctxFocus then
            M.ctxFocus = here
            say(here)
            return true
        end
    end
    return true
end

-- The camp panel ---------------------------------------------------------------------
--
-- The screen a player meets when they use the bedroll, and the one that stopped a tester dead:
-- "открыл окно, понятия не имею как тут выбирать". The layer read seven button captions off it
-- and not one number, so what the panel is *for* - putting food in a pot until there is enough
-- for the night - was invisible.
--
-- Measured on the live panel. The numbers are two text nodes, «Припасы» and «40/40», and that
-- pair is the whole state: supplies selected over supplies needed. Everything else in there is
-- an icon with a record behind it (`Index`, `Object`, `SelectedAmount`), one per stack of food -
-- a hundred and eighty of them, which is why this reads the summary and not the ring.
--
-- What the numbers mean, in the game's own terms: reaching the required amount buys a **long
-- rest**, which restores all health and spell slots and lets the night's scenes play; short of
-- it the game offers a **partial rest** instead, which does less and still spends the day.
--
-- Said on change rather than on a key, because the number is what the player is changing.
M.campKey = nil

function M.campTick(ws)
    local node = nil
    for i = #ws, 1, -1 do
        local w = ws[i]
        local n = str(w.name)
        if w.visible ~= false and (n == "MakeCamp" or n == "MakeCamp_c") then node = w.node break end
    end
    if node == nil then
        M.campKey = nil
        return false
    end

    -- Collected without pruning on class, for the reason the message box needed the same: the
    -- numbers hang inside decorative frames, and a walk that turns back at a frame never sees
    -- them.
    local texts, seen, budget = {}, {}, { n = 1200 }
    local function rec(o, depth)
        if o == nil or depth > 16 or budget.n <= 0 then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            budget.n = budget.n - 1
            if budget.n <= 0 then return end
            local p = props(ch[i])
            if p.IsVisible ~= false then
                local cls, label = A.splitToString(A.realType(ch[i]))
                if not A.NO_TEXT[cls] then
                    for _, s in ipairs(A.strings(p.Text, label)) do
                        if A.looksLikeText(s) then
                            s = s:gsub("^%s+", ""):gsub("%s+$", "")
                            if not seen[s] then
                                seen[s] = true
                                texts[#texts + 1] = s
                            end
                        end
                    end
                end
                rec(ch[i], depth + 1)
            end
        end
    end
    rec(node, 0)

    local have, need, rest, others = nil, nil, nil, {}
    for _, s in ipairs(texts) do
        local a, b = s:match("^(%d+)%s*/%s*(%d+)$")
        if a ~= nil then
            have, need = tonumber(a), tonumber(b)
        elseif s == "Припасы" then                       -- the label of the pair above
        elseif s:find("отдых") then rest = s             -- what this much food buys
        else others[#others + 1] = s end
    end
    if have == nil and rest == nil then return false end

    local key = tostring(have) .. "/" .. tostring(need) .. "|" .. tostring(rest)
    if key == M.campKey then return true end
    local first = (M.campKey == nil)
    M.campKey = key

    local parts = {}
    if first then parts[#parts + 1] = "Лагерь" end
    if have ~= nil then
        parts[#parts + 1] = "припасы " .. have .. " из " .. need
        -- The one thing the panel never says out loud and the player has to know: enough food
        -- is the difference between a night that heals everything and a nap.
        if first then
            parts[#parts + 1] = (need ~= nil and have >= need)
                and "хватает на долгий отдых" or "на долгий отдых не хватает"
        end
    end
    if rest ~= nil then parts[#parts + 1] = rest end
    if first then
        for i = 1, #others do parts[#parts + 1] = others[i] end
    end
    say(table.concat(parts, ". "))
    return true
end

function M.messageBox(ws)
    ws = ws or findWidgets()
    local node = nil
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false and MODAL_NAMES[str(w.name)] then node = w.node break end
    end
    if node == nil then return nil end

    -- Fifteen, not twelve.
    --
    -- Measured on the box the game raises before a long rest: its buttons sit at depth 4 and its
    -- **message sits at fifteen** -
    --
    --     MessageBox_c/bgFade/2/MessageBoxNineSlice/ContentParent/ContentHolder/1/
    --       MessageBoxNineSliceContent/MessageBoxControl/1/MessageScroller/1/1/2/Message/1
    --
    -- so a walk that stopped at twelve found every button and never the question. Which is
    -- exactly what a player met at camp: "A — Да, B — Нет" and no idea what was being asked.
    -- Eighteen leaves room for one more wrapper without inviting the whole screen in.
    local MAX_DEPTH = 18
    local MAX_PARTS = 24

    local title, body, list = nil, {}, nil
    local function rec(o, depth)
        if o == nil or depth > MAX_DEPTH or #body > MAX_PARTS then return end
        local p = props(o)
        if p.IsVisible == false then return end
        local nm = str(p.Name)
        if nm == "ActionsList" then list = o return end
        -- The seconds left on a timed box. A bare "-1" read out in the middle of a question is
        -- worse than nothing, and when it is a real countdown it changes every frame.
        if nm == "CountdownTimer" then return end
        -- A class whose own ToString is noise is skipped, but **not its children**.
        --
        -- Everywhere else in the layer NO_TEXT prunes the whole subtree, and everywhere else
        -- that is right: an Image has no text under it worth the walk. Here it was the single
        -- reason this box has never once been read. The frame around the message is
        -- `MessageBoxNineSlice`, an `ls.LSNineSliceImage`, and the message hangs **inside** it -
        -- so the walk turned back three steps in, found the buttons on the other branch, and
        -- announced a question no one had heard as "A - Да, B - Нет".
        local cls, label = A.splitToString(A.realType(o))
        local quiet = A.NO_TEXT[cls]
        for _, s in ipairs(quiet and {} or A.strings(p.Text, label)) do
            if A.looksLikeText(s) then
                s = loca(s:gsub("^%s+", ""):gsub("%s+$", ""))
                if nm == "Title" and title == nil then title = s
                elseif title ~= s and body[#body] ~= s then body[#body + 1] = s end
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(node, 0)

    local actions = {}
    if list ~= nil then
        local ch, cn = A.kids(list)
        for i = 1, cn do
            local p = props(ch[i])
            if p.BoundEvent ~= nil then
                -- The action's own name is the localisation handle of its caption, which is
                -- steadier than the button template built around it.
                local caption = loca(str(p.Name))
                if type(caption) ~= "string" or caption:find("^h%x") then
                    caption = A.collectText(ch[i], 20, 6)[1]
                end
                local button = PROMPT_BUTTON[str(p.BoundEvent)]
                if caption ~= nil then
                    actions[#actions + 1] = button and (button .. " — " .. caption) or caption
                end
            end
        end
        if #actions == 0 then
            for _, s in ipairs(A.collectText(list, 60, 8)) do actions[#actions + 1] = s end
        end
    end

    -- One sentence, not eight.
    --
    -- Larian's inline markup does not flatten: `<LSTag Tooltip="CampSupplies">припасов</LSTag>`
    -- becomes an element of its own between the plain runs, so the walk above collects the
    -- question in pieces -
    --
    --     "У вас достаточно" · "припасов" · ", чтобы восстановить все" · "ОЗ" · "и" · …
    --
    -- and every piece said as its own line is a sentence read like a shopping list. Depth-first
    -- order is already the reading order, so they only have to be glued: a space between two
    -- words, nothing before a comma. That is the whole rule, and it puts the sentence back the
    -- way it was written.
    local text = nil
    for _, s in ipairs(body) do
        if text == nil then text = s
        elseif s:find("^[,%.%!%?%;%:%)]") then text = text .. s
        else text = text .. " " .. s end
    end

    local lines = {}
    if title ~= nil then lines[#lines + 1] = title end
    if text ~= nil then lines[#lines + 1] = text end
    if #actions > 0 then lines[#lines + 1] = table.concat(actions, ", ") end
    if #lines == 0 then return nil end
    return { node = node, lines = lines, key = table.concat(lines, "|") }
end

local SAVE_KIND = { Autosave = "Автосохранение", QuickSave = "Быстрое сохранение" }

local MONTHS = { "января", "февраля", "марта", "апреля", "мая", "июня",
                 "июля", "августа", "сентября", "октября", "ноября", "декабря" }

--- "31/7/2026 02:19" as a date a voice can read.
---
--- Left alone if it does not parse: a different locale writes the date differently and a
--- half-understood string is worse than the game's own.
local function saveWhen(s)
    if type(s) ~= "string" then return nil end
    local d, m, y, hh, mm = s:match("^(%d+)/(%d+)/(%d+)%s+(%d+):(%d+)")
    if d == nil then return s end
    local month = MONTHS[tonumber(m)]
    if month == nil then return s end
    return tonumber(d) .. " " .. month .. " " .. y .. ", " .. hh .. ":" .. mm
end
M.saveWhen = saveWhen

--- "1ч 39м" spelled out - the game's own form is read as two letters.
local function savePlaytime(s)
    if type(s) ~= "string" then return nil end
    local h, m = s:match("^(%d+)%s*ч%s*(%d+)%s*м")
    if h == nil then return s end
    h, m = tonumber(h), tonumber(m)
    local parts = {}
    if h > 0 then parts[#parts + 1] = M.plural(h, "час") end
    if m > 0 or h == 0 then parts[#parts + 1] = M.plural(m, "минута") end
    return table.concat(parts, " ")
end

--- What a save is called. Autosaves and quicksaves are numbered slots with machine names
--- ("AutoSave_4"), and only a manual save carries something the player chose.
local function saveName(rec)
    local title = tostring(rec.Title or "")
    local word = SAVE_KIND[tostring(rec.Type)]
    if word == nil then
        if title == "" then return "Сохранение" end
        return title
    end
    local n = title:match("_(%d+)$")
    if n == nil then return word end
    return word .. " " .. n
end

--- The things that decide whether a save can be loaded at all, and the one that says it must
--- not be lost. Said with the entry rather than kept for the details, because a player
--- stepping through a list is choosing, and these are what the choice turns on.
local function saveFlags(rec)
    local out = {}
    if rec.IsHonourMode == true then out[#out + 1] = "режим чести" end
    if rec.HasMissingMods == true then out[#out + 1] = "не хватает модов" end
    if rec.Validity ~= nil and tostring(rec.Validity) ~= "Valid" then
        out[#out + 1] = "нельзя загрузить"
    end
    return out
end

--- The record behind a list item, or nil if this child is not one.
---
--- The logical children of these lists are the data items themselves, with the item presenter
--- among them - so the presence of SaveID is what separates a save from the machinery.
local function saveRecord(o)
    local p = soft(function() return o:GetAllProperties() end)
    if type(p) ~= "table" or p.SaveID == nil then return nil end
    return p
end

--- One entry, said the way a list is stepped through: what it is, where and when, and where
--- in the list it sits.
local function saveLine(rec, index, count)
    local parts = { saveName(rec) }
    local where = loca(rec.LevelName)
    if type(where) == "string" and where ~= "" and not where:find("^h%x") then
        parts[#parts + 1] = where
    end
    local when = saveWhen(rec.TimeString)
    if when ~= nil then parts[#parts + 1] = when end
    for _, f in ipairs(saveFlags(rec)) do parts[#parts + 1] = f end
    if index ~= nil and count ~= nil and count > 1 then
        parts[#parts + 1] = index .. " из " .. count
    end
    return table.concat(parts, ", ")
end
M.saveLine = saveLine

--- One campaign: whose it is, how much is in it, and whether it is open.
---
--- `short` is for the list of them all, where the word "кампания" before every name and the
--- position of a line being read in order are both noise.
local function groupLine(g, index, count, short)
    local parts = { g.name or "Прохождение" }
    if not short then parts[#parts + 1] = "кампания" end
    if g.count ~= nil and g.count > 0 then
        parts[#parts + 1] = M.plural(g.count, "сохранение")
    end
    parts[#parts + 1] = g.expanded and "развёрнуто" or "свёрнуто"
    if not short and index ~= nil and count ~= nil and count > 1 then
        parts[#parts + 1] = index .. " из " .. count
    end
    return table.concat(parts, ", ")
end
M.groupLine = groupLine

--- Is this widget a save screen? Answered from the model, so it holds for the load screen,
--- the in-game save screen and whatever else is built on the same context.
---
--- Remembered per screen name: the answer cannot change under one name, and the reader asks
--- on every pass.
M.saveScreens = {}

local function saveContext(widget, name)
    if name ~= nil and M.saveScreens[name] == false then return nil end
    local dc = props(widget).DataContext
    if type(dc) ~= "userdata" then
        if name ~= nil then M.saveScreens[name] = false end
        return nil
    end
    local dp = soft(function() return dc:GetAllProperties() end)
    if type(dp) ~= "table" or dp.ExistingSaves == nil then
        if name ~= nil then M.saveScreens[name] = false end
        return nil
    end
    if name ~= nil then M.saveScreens[name] = true end
    return dc, dp
end
M.saveContext = saveContext

--- The campaign groups, without descending into the rows.
---
--- The economy matters: an expanded campaign of 36 saves is 500-odd nodes of realised template
--- and none of it says anything. The walk therefore stops at three names - the expander
--- itself, its header button and its list - and reads the rest as data (the count comes from
--- the campaign's own `Saves` collection, which unlike most proxied userdata answers to `#`).
local function saveGroups(widget, wantSaves)
    local groups, n = {}, 0

    local function inGroup(o, g, depth)
        if o == nil or depth > 6 then return end
        local p = props(o)
        local nm = str(p.Name)
        if nm == "ExpanderButton" then
            if p.IsFocused == true or p.IsKeyboardFocused == true then g.focused = true end
            return
        end
        if nm == "PlaythroughSavegames" then
            local idx = tonumber(p.SelectedIndex)
            if idx ~= nil and idx >= 0 then g.index = idx + 1 end
            local ch, cn = A.kids(o)
            local saves = wantSaves and {} or nil
            local count = 0
            for i = 1, cn do
                local rec = saveRecord(ch[i])
                if rec ~= nil then
                    count = count + 1
                    if saves ~= nil then saves[count] = rec end
                end
            end
            if count > 0 then g.count, g.saves = count, saves end
            return                      -- never descend into the rows: they say nothing
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do inGroup(ch[i], g, depth + 1) end
    end

    local function rec(o, depth)
        if o == nil or depth > 20 or n > 500 then return end
        n = n + 1
        local p = props(o)
        if p.IsVisible == false then return end
        if p.IsExpanded ~= nil then
            local g = { expanded = p.IsExpanded == true }
            local dc = p.DataContext
            if type(dc) == "userdata" then
                local dp = soft(function() return dc:GetAllProperties() end)
                if type(dp) == "table" then
                    if type(dp.ProtagonistName) == "string" and dp.ProtagonistName ~= "" then
                        g.name = dp.ProtagonistName
                    end
                    if dp.Saves ~= nil then
                        local coll = soft(function() return dc:GetProperty("Saves") end)
                        local len = tonumber(soft(function() return #coll end))
                        if len ~= nil and len > 0 then g.count = len end
                    end
                end
            end
            -- The campaign's name is on a descendant named Title when the model does not
            -- give it up - the same place the group headers were read from before.
            if g.name == nil then g.name = titleUnder(o) end
            inGroup(o, g, 0)
            groups[#groups + 1] = g
            return
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end

    rec(widget, 0)
    M.saveWalk = n
    return groups
end
M.saveGroups = saveGroups

--- Where the game's cursor is on a save screen, and what it is on.
---
--- `focused` decides only one thing: whether the cursor is on a campaign header or inside its
--- list. Everything else comes from the model, because the focus here lags a step behind the
--- game's own navigation.
function M.saveState(widget, focused, wantSaves, name)
    local dc, dp = saveContext(widget, name)
    if dc == nil then return nil end

    local st = { saving = dp.IsSaving == true, hasSaves = dp.HasSaveGames == true }
    if dp.SelectedSave ~= nil then
        local live = soft(function() return dc:GetProperty("SelectedSave") end)
        if live ~= nil then st.rec = saveRecord(live) end
    end

    st.groups = saveGroups(widget, wantSaves)
    for i, g in ipairs(st.groups) do
        if g.focused then st.group, st.groupIndex = g, i end
    end
    -- With no focus anywhere - the state the screen is in for a moment after it opens - the
    -- campaign the game has selected is the one holding the save it is showing.
    if st.group == nil and st.rec ~= nil then
        for i, g in ipairs(st.groups) do
            if g.index ~= nil then st.group, st.groupIndex = g, i end
        end
    end

    local g = st.group
    st.index = g and g.index
    st.count = g and g.count
    -- On a header the game offers to fold the list; on a row it offers to load it. The
    -- expander state is the honest signal, and the list's own selection confirms it: a
    -- collapsed campaign selects nothing at all (SelectedIndex is -1).
    st.onRow = (g ~= nil and g.expanded and g.index ~= nil)
    if focused ~= nil and str(props(focused).Name) ~= "ExpanderButton" then
        st.onRow = st.onRow or (st.rec ~= nil)
    end
    return st
end

--- What can be done with what is under the cursor, in the game's own words.
---
--- Read rather than hardcoded: the captions change with the cursor, and the button that
--- raises each one is named by its BoundEvent.
function M.savePrompts(widget)
    -- Found by name and read from there, rather than by walking the screen for buttons: the
    -- save list sits before the strip in the tree, and an expanded campaign is enough nodes
    -- to exhaust any sane budget before the prompts are reached - the same trap the
    -- nine-slice frame set on character creation.
    local strip = nil
    local function find(o, depth)
        if o == nil or strip ~= nil or depth > 8 then return end
        local p = props(o)
        if p.IsVisible == false then return end
        local nm = str(p.Name)
        if nm == "ButtonPrompts" then strip = o return end
        if nm == "SavegamesListHolder" or nm == "PlaythroughSavegames" then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do find(ch[i], depth + 1) end
    end
    find(widget, 0)
    if strip == nil then return {} end

    local out, seen = {}, {}
    local ch, cn = A.kids(strip)
    for i = 1, cn do
        local p = props(ch[i])
        if p.IsVisible ~= false and p.IsEnabled ~= false then
            local text = A.collectText(ch[i], 40, 6)[1]
            if text ~= nil and A.looksLikeText(text) and not seen[text] then
                seen[text] = true
                local button = PROMPT_BUTTON[str(p.BoundEvent)]
                out[#out + 1] = button and (button .. " — " .. text) or text
            end
        end
    end
    return out
end

--- Everything the game knows about the save under the cursor, on demand.
function M.saveDetails(widget, st, name)
    st = st or M.saveState(widget, nil, false, name)
    if st == nil then return nil end
    local out = {}
    if st.rec ~= nil then
        local rec = st.rec
        out[#out + 1] = saveName(rec)
        if st.group ~= nil and st.group.name ~= nil then
            out[#out + 1] = "Кампания " .. st.group.name
        end
        local where = loca(rec.LevelName)
        if type(where) == "string" and not where:find("^h%x") then out[#out + 1] = where end
        local when = saveWhen(rec.TimeString)
        if when ~= nil then out[#out + 1] = when end
        local played = savePlaytime(rec.PlayTimeString)
        if played ~= nil then out[#out + 1] = "Время игры " .. played end
        local diff = loca(rec.Difficulty)
        if type(diff) == "string" and diff ~= "" and not diff:find("^h%x") then
            out[#out + 1] = "Сложность " .. diff
        end
        if type(rec.Description) == "string" and rec.Description ~= "" then
            out[#out + 1] = rec.Description
        end
        if rec.HasMods == true or rec.HasUnofficialMods == true then
            out[#out + 1] = "с модами"
        end
        for _, f in ipairs(saveFlags(rec)) do out[#out + 1] = f end
        if type(rec.Version) == "string" and rec.Version ~= "" then
            out[#out + 1] = "Версия " .. rec.Version
        end
        if st.index ~= nil and st.count ~= nil then
            out[#out + 1] = st.index .. " из " .. st.count
        end
    end
    local prompts = M.savePrompts(widget)
    if #prompts > 0 then out[#out + 1] = "Действия: " .. table.concat(prompts, ", ") end
    if #out == 0 then return nil end
    return out
end

--- The screen at a glance: every campaign, how much is in it, and when it was last played.
function M.saveSummary(widget, name)
    local st = M.saveState(widget, nil, false, name)
    if st == nil or #st.groups == 0 then return nil end
    local out = { M.plural(#st.groups, "кампания") }
    for i, g in ipairs(st.groups) do
        out[#out + 1] = groupLine(g, i, #st.groups, true)
    end
    return out
end

--- The whole screen as lines, for the review cursor - which is the only way to survey a save
--- list without moving the game's cursor through it one entry at a time.
function M.saveScreenLines(widget, name)
    local st = M.saveState(widget, nil, true, name)
    if st == nil or #st.groups == 0 then return nil end
    local out = {}
    for i, g in ipairs(st.groups) do
        out[#out + 1] = groupLine(g, i, #st.groups)
        if g.expanded and g.saves ~= nil then
            for j, rec in ipairs(g.saves) do
                out[#out + 1] = saveLine(rec, j, #g.saves)
            end
        end
    end
    return out
end

--- The lines of a screen for the review cursor: the save list where there is one, and the
--- widget's own text everywhere else.
---
--- On a save screen the widget's text is the title, the detail panel and the prompts - the
--- list itself is not in it, because the rows carry no text. Reviewing the screen and never
--- reaching the saves is the same silence as before, one step removed.
function M.linesOf(a)
    if a == nil then return {} end
    if a.node ~= nil and M.saveScreens[str(a.name)] ~= false then
        local lines = soft(function() return M.saveScreenLines(a.node, str(a.name)) end)
        if lines ~= nil and #lines > 0 then return lines end
    end
    return a.texts or {}
end

--- Is the game writing a save right now?
---
--- Quicksaving and autosaving are the two save operations with no screen at all: the game
--- puts a small panel on the always-on-top overlay and takes it away again, and a player who
--- cannot see it has no way of knowing whether F5 landed. `AlwaysOnTopOverlay > SavingPanel`
--- is that panel, and it is four nodes deep, so this is affordable on every pass.
local function savingNow(ws)
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false and str(w.name) == "AlwaysOnTopOverlay" then
            local found = nil
            local function rec(o, d)
                if o == nil or found ~= nil or d > 4 then return end
                local p = props(o)
                if str(p.Name) == "SavingPanel" then found = (p.IsVisible ~= false) return end
                local ch, cn = A.kids(o)
                for k = 1, cn do rec(ch[k], d + 1) end
            end
            rec(w.node, 0)
            return found
        end
    end
    return nil
end
M.savingNow = savingNow

-- The dice roll, and the tutorial hint --------------------------------------------------
--
-- Two panels that are up for seconds and were both going to be scraped out of the visual
-- tree. Neither needs to be. Mapped 2026-08-04 by recording a live session.

--- The record behind a widget: the model the template is bound to.
---
--- Not a property of the node. It arrives as a *child* that is not an element - it has no
--- size and no visibility, only a domain - which is why a walk that only follows elements
--- never sees it and every reader so far has gone through the tree instead.
local function dataOf(node)
    local ch, cn = A.kids(node)
    for i = 1, cn do
        local p = soft(function() return ch[i]:GetAllProperties() end)
        if type(p) == "table" and p.ActualWidth == nil and p.IsVisible == nil then
            return p
        end
    end
    return nil
end
M.dataOf = dataOf

--- Larian's inline markup, taken out of a sentence meant to be heard.
---
--- `<LSTag Tooltip="AbilityCheck">проверку</LSTag>` has to keep the word and lose the tag;
--- `<br>` is a paragraph break and becomes a full stop, because a screen reader run at speed
--- will otherwise weld the last word of one sentence to the first of the next.
local function unmarkup(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("<[Bb][Rr]%s*/?>", ". ")
    s = s:gsub("<[^<>]->", "")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("%.%s*%.", ".")
    if s == "" then return nil end
    return s
end
M.unmarkup = unmarkup

--- A dice roll, read from the model rather than from the dice.
---
--- Everything worth saying is on the widget's record: what is being attempted, the skill, the
--- ability, the number to beat, the bonus, the number rolled, and `Success` as a plain
--- boolean. Three of the fields are loca handles. None of it depends on the animation, and
--- two of the fields the tree does carry - the skill and the ability - are marked *invisible*
--- there, so the ordinary scan would have dropped exactly the two a player wants first.
---
--- The outcome is deliberately not said as soon as it is known. `FinalResult` and `Success`
--- are set while `RollState` is still `StartRoll` - measured at six seconds before the panel
--- showed "НЕУДАЧА!" - and during that window `HasBoostsToAdd` is true and the player can
--- still spend inspiration. Announcing then would call the roll while the move is still
--- theirs to make. `ResultReady` is the line.
---
--- Do not read the outcome off `ResultTxt` against `ResultTxtFail`: in the final state both
--- are visible. That was tried and it is ambiguous.
M.rollKey = nil

function M.rollTick(ws)
    local node = nil
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false and str(w.name) == "ActiveRoll" then node = w.node break end
    end
    if node == nil then
        M.rollKey = nil
        return false
    end
    local d = dataOf(node)
    if d == nil then return false end

    local state = str(d.RollState)
    local ready = (state == "ResultReady" or state == "Finished")
    local key = state .. "|" .. str(d.TargetNumber) .. "|" .. str(d.FinalResult) ..
                "|" .. str(d.Success) .. "|" .. str(d.SelectedDialogueLine)
    if key == M.rollKey then return true end
    M.rollKey = key

    local parts = {}
    if not ready then
        -- The setup, said once, while the roll is still the player's to shape.
        local line = unmarkup(str(d.SelectedDialogueLine))
        if line ~= nil and line ~= "nil" then parts[#parts + 1] = line end
        local skill = loca(str(d.SkillOrAbility))
        local check = loca(str(d.AbilityCheckText))
        if skill ~= nil and skill ~= "nil" then parts[#parts + 1] = skill end
        if check ~= nil and check ~= "nil" and check ~= skill then parts[#parts + 1] = check end
        local target = tonumber(d.TargetNumber)
        if target ~= nil then parts[#parts + 1] = "нужно " .. target end
        local bonus = tonumber(d.MaxBonusValue)
        if bonus ~= nil and bonus > 0 then
            parts[#parts + 1] = "можно добавить до " .. bonus
        end
        parts[#parts + 1] = "бросок — кнопка Y"
    else
        -- The result. The game writes the whole sentence itself, and it is better than one
        -- assembled here because it names the skill in the right case.
        local said = loca(str(d.SkillOrAbilityResultText))
        local rolled = tonumber(d.RolledNumber1)
        local total = tonumber(d.FinalResult)
        local target = tonumber(d.TargetNumber)
        if rolled ~= nil then
            local line = "выпало " .. rolled
            if total ~= nil and total ~= rolled then line = line .. ", итог " .. total end
            if target ~= nil then line = line .. " против " .. target end
            parts[#parts + 1] = line
        end
        parts[#parts + 1] = (d.Success == true) and "успех" or "провал"
        if said ~= nil and said ~= "nil" and said ~= "" then parts[#parts + 1] = said end
    end

    if #parts == 0 then return true end
    local text = table.concat(parts, ", ")
    _P("[pad] roll: " .. text)
    say(text)
    return true
end

--- A tutorial hint.
---
--- Two things make this panel unreadable by the ordinary scan, and both had to be met before
--- a word of it came out:
---
---   * **It arrives empty and fills a beat later.** `IsInitialized` goes false → true and the
---     title and body are empty nodes until it does, so reading on the frame the widget
---     appears reads nothing at all.
---   * **Its whole content sits inside an `ls.LSNineSliceImage`**, which `visibleScan` prunes
---     outright as a decorative frame - correctly, everywhere else, since one is thirty Image
---     nodes. Here the frame is the panel, and the scan reports five nodes and no text.
---
--- So the walk here is its own: it does not prune the frame, and it does not descend into a
--- node that has text of its own, because the body arrives both whole on a TextBlock and cut
--- into Runs with LineBreaks between them (the same shape as the options screen's preview).
M.tutorialKey = nil

local TUT_SKIP = { Image = true, Rectangle = true, ColumnDefinition = true,
                   RowDefinition = true, Path = true, Ellipse = true }

local function tutorialText(node)
    local out, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or #out >= 6 or n >= 300 or depth > 16 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local p = props(o)
        if p.IsVisible == false then return end
        local cls, label = A.splitToString(A.realType(o))
        if TUT_SKIP[cls] then return end
        local said = false
        for _, s in ipairs(A.strings(p.Text, label)) do
            if A.looksLikeText(s) then
                said = true
                local t = unmarkup(loca(s))
                if t ~= nil and out[#out] ~= t then out[#out + 1] = t end
            end
        end
        if said then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(node, 0)
    return out
end
M.tutorialText = tutorialText

function M.tutorialTick(ws)
    local node = nil
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false and str(w.name) == "ModalTutorial_c" then node = w.node break end
    end
    if node == nil then
        M.tutorialKey = nil
        return false
    end
    -- Nothing to read yet. Answered from the model rather than from an empty tree, so the
    -- difference between "not filled" and "nothing there" is never guessed at.
    local d = dataOf(node)
    if d ~= nil and d.IsInitialized == false then return true end

    local parts = tutorialText(node)
    if #parts == 0 then return true end

    -- The last part is the dismiss button ("Готово") and it is not the hint; it is said as an
    -- instruction instead, with the button that works, because on the pad this modal takes
    -- the controls until it is answered.
    local key = table.concat(parts, "|")
    if key == M.tutorialKey then return true end
    M.tutorialKey = key

    local body = {}
    for i = 1, #parts do
        -- "Общее обучение" is the category, and it is the same on every hint of this kind.
        if parts[i] ~= "Общее обучение" and parts[i] ~= "Готово" then
            body[#body + 1] = parts[i]
        end
    end
    local text = "Обучение. " .. table.concat(body, ". ") .. ". Закрыть — кнопка A"
    _P("[pad] tutorial: " .. text)
    say(text)
    return true
end

--- Is this the list itself under the focus, rather than something standing over it?
---
--- The three shapes the list ever focuses: the campaign header, the row container of a save
--- and the row itself. Anything else on a save screen - a confirmation box, the name field of
--- the save dialog - is not the list, and belongs to the ordinary reader.
local SAVE_LIST_NAMES = { ExpanderButton = true, ControlRoot = true,
                          PlaythroughSavegames = true, SavegamesList = true }

function M.inSaveList(node)
    if node == nil then return false end
    local p = props(node)
    if SAVE_LIST_NAMES[str(p.Name)] then return true end
    local cls = select(1, A.splitToString(A.realType(node)))
    return cls:find("ListBoxItem", 1, true) ~= nil
end

--- Say where the cursor is, when it has moved.
---
--- Two states and one key, because a header and a row are different places and the same
--- campaign is both. Arriving in a list says the campaign as well as the entry: that is the
--- one moment the player needs both, and afterwards the campaign would be noise on every step.
M.saveKey = nil
M.saveGroupKey = nil

function M.saveTick(widget, focused, name)
    local st = M.saveState(widget, focused, false, name)
    if st == nil then return false end

    local g = st.group
    local gkey = tostring(g and g.name) .. "|" .. tostring(g and g.expanded) .. "|" ..
                 tostring(st.groupIndex)
    local place = (st.onRow and st.rec ~= nil) and "s" or "g"
    local key = place .. "|" .. gkey
    if place == "s" then
        key = key .. "|" .. tostring(st.index) .. "|" .. tostring(st.rec.Title) ..
              "|" .. tostring(st.rec.TimeString)
    end
    if key == M.saveKey then return false end

    local movedGroup = (gkey ~= M.saveGroupKey)
    M.saveKey, M.saveGroupKey = key, gkey
    if g == nil then return false end

    -- Arriving in a campaign names it; stepping inside one does not, or the campaign would
    -- be said before every single entry and bury the one thing that changed.
    if place == "g" or movedGroup then
        pend(groupLine(g, st.groupIndex, #st.groups))
    end
    if place == "s" then
        pend(saveLine(st.rec, st.index, st.count))
    end
    return true
end

-- The journal: what the story wants, in words ---------------------------------------
--
-- On the crash-site beach the layer answered "задача не видна", and it was telling the truth:
-- the objective is read out of the Minimap's *text*, the game writes nothing there, the map
-- holds exactly one marker (the player) and the waypoint list is empty. Nothing in the client
-- ECS helps either - the played character carries 142 components and not one is a journal,
-- `MapMarkerStyle` holds no entities at all.
--
-- The journal itself does have it, as data:
--
--   ls.UIWidget JournalQuests_c
--     ls.LSToggleButton ExpanderButton   Title "Основное задание"     ← a category
--       ls.LSToggleButton ExpanderButton Title "Найти лекарство"      ← a quest
--         DATA  IsSelected, IsExpanded, QuestIsInProgress, HasPlayerSeenLastUpdate
--         DATA  Description (a loca handle), IsCompleted, ObjectivePriority   ← the objective
--
-- Two things follow. The objective is a localisation handle, so it reads as text only through
-- `Ext.Loca` - the tree shows the quest's name and never its task. And the widget is
-- destroyed when the journal closes, so it has to be **remembered**: the player opens the
-- journal once and the layer keeps the book, which is what makes `End` in the middle of a
-- field able to say what the story is asking for.

M.JOURNAL_WIDGETS = { JournalQuests_c = true, JournalQuests = true, JournalQuest_c = true }

M.book = nil
M.bookAt = 0

--- The quests and their tasks, read out of the open journal.
---
--- Written against what the screen actually is, which is not what it looks like. There is no
--- expander element to descend: `IsExpanded` exists **only on data records**, the captions sit
--- in a `Run` inside a `[ForceUpdate]` node named Title, and the task does not live under its
--- quest at all - it is in the detail panel on the right, which shows whichever quest is
--- selected. So the walk keeps two things in step: the caption last seen, which names the
--- quest a state record belongs to, and the tasks, which belong to the selected quest
--- wherever in the tree they turn up.
local function journalScan(widget)
    local quests, tasks, lastTitle = {}, {}, nil
    local budget = { n = 2000 }
    -- Measured 2026-08-06 on the open journal: 333 nodes, reached 513 times. Without this the
    -- walk compounds on every node that has more than one path into it - the same dump with
    -- the guard removed and the budget raised to sixty thousand still ran out. Which is why
    -- this used to come back with the quests and none of their tasks: the budget was gone
    -- before the walk ever reached the detail panel. `readRow` further up has carried the
    -- same guard from the start; this walk was written without it.
    local seen = {}

    -- One task per sentence, and the record wins.
    --
    -- With the guard in, the same objective arrives twice: once as a data record, which
    -- carries the loca handle and the game's own ObjectivePriority, and once as a rendered
    -- element in the detail panel, which carries neither. Both are wanted - the element is
    -- what still answers if the record moves again - but two entries for one task made
    -- `bookObjective` choose by priority between duplicates, and it chose the one without the
    -- handle, which costs the exact key and falls back to matching by text. So they are
    -- merged on the sentence, and whichever arrives second fills in what the first lacked.
    local byText = {}
    local function addTask(t)
        local prev = byText[t.text]
        if prev == nil then
            tasks[#tasks + 1] = t
            byText[t.text] = t
            return
        end
        if prev.handle == nil and t.handle ~= nil then
            prev.handle, prev.priority, prev.done = t.handle, t.priority, t.done
        end
    end

    local function rec(o, depth)
        if o == nil or budget.n <= 0 or depth > 24 then return end
        budget.n = budget.n - 1
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        local p = props(o)
        if p.IsVisible == false then return end

        -- A task: the text is a handle, and the priority is the order the game shows them in.
        --
        -- The handle is kept beside the text, not thrown away once it is rendered. It is the
        -- game's own key for this objective, and the shipped journal table (a11y-questdata)
        -- is keyed by it - which is what turns "Соединить нервы передатчика" into the UUID of
        -- the thing that sentence is about. Matching on the rendered text works too and is
        -- the fallback, but it is a string comparison in whatever language the game is in,
        -- and this is an exact key in no language at all.
        if p.ObjectivePriority ~= nil or (p.Description ~= nil and p.IsCompleted ~= nil) then
            local raw = str(p.Description)
            local text = loca(raw)
            if type(text) == "string" and text ~= "" and not text:find("^h%x")
               and not text:find("^ls::") then
                local handle = nil
                if type(raw) == "string" and raw:match("^h%x%x%x%x%x%x%x%xg") ~= nil then
                    handle = raw
                end
                addTask({ text = text, handle = handle,
                          done = p.IsCompleted == true,
                          priority = tonumber(p.ObjectivePriority) or 0 })
            end
            return
        end

        -- A quest's state, which follows its caption in the tree.
        if p.QuestIsInProgress ~= nil then
            quests[#quests + 1] = { title = lastTitle or "Задание",
                                    selected = p.IsSelected == true,
                                    inProgress = p.QuestIsInProgress == true,
                                    expanded = p.IsExpanded == true }
            return
        end

        if str(p.Name) == "Title" then
            local t = A.collectText(o, 20, 4)[1]
            if t ~= nil then lastTitle = t end
        end

        -- The task as the screen actually draws it.
        --
        -- The branch above wants a data record - Description as a loca handle, next to
        -- IsCompleted and ObjectivePriority - and that is how the panel was read when this was
        -- written. In this build no such record exists anywhere in the tree: the detail panel
        -- carries an element **named** Description with the sentence already rendered inside
        -- it. Measured with the journal open on «Бежать с наутилоида», where the only task on
        -- screen, «Найти способ бежать с наутилоида.», appeared exactly this way and nothing
        -- in the tree held IsCompleted at all.
        --
        -- No handle here, so no exact key - but the shipped journal table is also indexed by
        -- the rendered text, and that index exists for precisely this case.
        if str(p.Name) == "Description" then
            local t = A.collectText(o, 20, 4)[1]
            if type(t) == "string" and t ~= "" and not t:find("^h%x") and t ~= "[ForceUpdate]" then
                -- In the order the game lists them, which is the order it wants them read.
                -- Done-ness is not knowable from here: the completed ones sit under their own
                -- heading and the panel has a "hide completed" toggle, so what is on screen is
                -- what is still to do.
                -- A priority above anything the game issues, so that if the record never
                -- arrives these still order after the real ones rather than in front of them.
                addTask({ text = t, handle = nil, done = false,
                          priority = 100000 + #tasks })
            end
        end

        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(widget, 0)
    return quests, tasks
end
M.journalScan = journalScan

--- Keep the book while the journal is open, and hand it to the world reader.
---
--- Rate-limited rather than per pass: the walk is a thousand nodes, and the journal changes
--- only when the player moves in it. Nothing is said here - the focus reading does the
--- talking; this is only what makes it possible to say anything at all later.
function M.journalRefresh(widget, force)
    local t = now()
    if not force and (t - M.bookAt) < 1000 then return M.book end
    M.bookAt = t
    local quests, tasks = nil, nil
    soft(function() quests, tasks = journalScan(widget) end)
    if quests == nil or (#quests == 0 and (tasks == nil or #tasks == 0)) then return M.book end

    -- The tasks on display belong to the quest the journal has selected, so that is where
    -- they are filed. Without a selection they are still worth keeping: they are what the
    -- screen is showing, whatever it is showing it for.
    local selected = nil
    for _, q in ipairs(quests) do
        if q.selected then selected = q.title break end
    end
    if selected == nil and quests[1] ~= nil then selected = quests[1].title end

    M.book = { quests = quests, tasks = tasks or {}, title = selected, at = t }
    local nav = _G.Nav
    if nav ~= nil then
        nav.questBook = M.book
        -- Folded here rather than left for the world reader to notice.
        --
        -- The panel shows the tasks of the **selected** quest only, so the way the layer comes
        -- to know about more than one is the player walking the list - and that happens with
        -- the journal open, which is exactly when the world reader is not running. Waiting for
        -- it would mean only ever remembering whichever quest was selected when the journal
        -- closed.
        if nav.questFold ~= nil then soft(nav.questFold) end
    end
    _P("[pad] journal: " .. #quests .. " quests, " .. #(tasks or {}) .. " tasks, on '" ..
       tostring(selected) .. "'")
    return M.book
end

--- What the journal is showing about a quest, if this title is the one it has open.
function M.bookQuest(title)
    if M.book == nil or title == nil then return nil end
    for _, q in ipairs(M.book.quests) do
        if q.title == title then return q end
    end
    return nil
end

--- The task still to do, in the order the game lists them.
function M.questTask(q)
    if M.book == nil then return nil end
    -- The tasks belong to whichever quest is selected, so they are only its own to speak.
    if q ~= nil and M.book.title ~= nil and q.title ~= M.book.title then return nil end
    local best = nil
    for _, o in ipairs(M.book.tasks or {}) do
        if not o.done and (best == nil or o.priority < best.priority) then best = o end
    end
    return best and best.text or nil
end

-- What a skill actually does ------------------------------------------------------------
--
-- The wheel names a slot and stops there. "Направленный луч" tells a player nothing about what
-- it costs, how far it reaches, or what happens when it lands - and in a fight the wheel is the
-- whole interface, so the choice was being made from memory of a name.
--
-- None of it is on the widget. It is in the stats entry behind the spell, measured live on
-- 2026-08-06 rather than taken from a wiki:
--
--     Projectile_GuidingBolt
--       DisplayName / Description   loca handles
--       TargetRadius       18       the reach. `Range` is 0 on this spell and is *not* it
--       UseCosts           ActionPoint:1;SpellSlotsGroup:1:1:1
--       TooltipDamageList  DealDamage(4d6,Radiant)
--       TooltipAttackSave  RangedSpellAttack
--       Level 1            SpellSchool Evocation
--
-- The way in runs backwards from the widget. A wheel slot carries a loca handle for its name
-- and no id at all, so the id has to come from the other side: every spell the character knows
-- is in `SpellBook`, each with an id whose stats entry carries that same handle. One map per
-- character, and a slot resolves by the name it already has.
--
-- The English words in these tables are a closed set the engine spells itself - thirteen damage
-- types, eight schools, the attack and save kinds - so they are translated here rather than
-- read from loca, which has no handle for "the word Radiant as it appears inside
-- DealDamage(4d6,Radiant)".

local DAMAGE_RU = {
    Bludgeoning = "дробящий", Piercing = "колющий", Slashing = "рубящий",
    Acid = "кислотой", Cold = "холодом", Fire = "огнём", Force = "силовой",
    Lightning = "молнией", Necrotic = "некротический", Poison = "ядом",
    Psychic = "психический", Radiant = "излучением", Thunder = "звуковой",
}

local ATTACK_RU = {
    MeleeSpellAttack = "ближняя атака заклинанием",
    RangedSpellAttack = "дальняя атака заклинанием",
    MeleeWeaponAttack = "ближняя атака оружием",
    RangedWeaponAttack = "дальняя атака оружием",
    MeleeOffHandWeaponAttack = "атака второй рукой",
    RangedOffHandWeaponAttack = "дальняя атака второй рукой",
    MeleeUnarmedAttack = "безоружная атака",
    Strength = "спасбросок Силы", Dexterity = "спасбросок Ловкости",
    Constitution = "спасбросок Телосложения", Intelligence = "спасбросок Интеллекта",
    Wisdom = "спасбросок Мудрости", Charisma = "спасбросок Харизмы",
}

local SCHOOL_RU = {
    Abjuration = "ограждение", Conjuration = "вызов", Divination = "прорицание",
    Enchantment = "очарование", Evocation = "воплощение", Illusion = "иллюзия",
    Necromancy = "некромантия", Transmutation = "преобразование",
}

local COST_RU = {
    ActionPoint = "действие", BonusActionPoint = "бонусное действие",
    ReactionActionPoint = "реакция", Movement = "движение",
    -- Named as charges, not as the thing they power: "Ярость, бонусное действие, ярость" is
    -- what the plain word gave, and it reads as a stutter rather than as a price.
    WildShape = "заряд дикого облика", Rage = "заряд ярости",
    SorceryPoint = "единица чародейства",
    KiPoint = "ци", SuperiorityDie = "кость превосходства",
    BardicInspiration = "вдохновение барда", ChannelDivinity = "божественный канал",
    ChannelOath = "канал клятвы", LayOnHandsCharge = "наложение рук",
    DeflectMissiles = "отражение снарядов", WarPriestActionPoint = "действие жреца войны",
    ArcaneRecoveryPoint = "магическое восстановление",
    NaturalRecoveryPoint = "природное восстановление",
}

--- The character whose wheel this is.
local function localChar()
    local nav = _G.Nav
    if nav ~= nil and nav.me ~= nil then
        local me = soft(nav.me)
        if me ~= nil then return me end
    end
    return soft(function() return Ext.Entity.GetLocalPlayer() end)
end

M.spellBy = nil        -- loca handle of the name -> stats id
M.spellBookAt = nil

--- Every spell the character knows, keyed by the handle its name is displayed under.
---
--- Rebuilt on a timer rather than cached forever: the book changes on levelling, on equipping
--- and on swapping who is controlled, and fifteen entries is not worth being clever about.
local function spellIndex()
    local now = tonumber(soft(Ext.Utils.MonotonicTime)) or 0
    if M.spellBy ~= nil and M.spellBookAt ~= nil and (now - M.spellBookAt) < 8000 then
        return M.spellBy
    end
    local me = localChar()
    if me == nil then return M.spellBy end
    local book = soft(function() return me.SpellBook end)
    local list = book ~= nil and soft(function() return book.Spells end) or nil
    if list == nil then return M.spellBy end
    local n = tonumber(soft(function() return #list end)) or 0
    local by = {}
    for i = 1, n do
        local s = soft(function() return list[i] end)
        local id = nil
        if s ~= nil then
            id = soft(function() return s.Id.OriginatorPrototype end)
            if type(id) ~= "string" or id == "" then
                id = soft(function() return s.Id.Prototype end)
            end
        end
        if type(id) == "string" and id ~= "" then
            local e = soft(Ext.Stats.Get, id)
            local h = e ~= nil and soft(function() return e.DisplayName end) or nil
            if type(h) == "string" and h ~= "" and by[h] == nil then by[h] = id end
        end
    end
    M.spellBy, M.spellBookAt = by, now
    return by
end
M.spellIndex = spellIndex

function M.spellIdFor(handle)
    if type(handle) ~= "string" or handle == "" then return nil end
    local by = spellIndex()
    return by ~= nil and by[handle] or nil
end

-- Weapon actions do not carry dice. `Zone_Cleave` says
-- `DealDamage(MainMeleeWeapon/2, MainWeaponDamageType)`, because the numbers are whatever is in
-- the character's hand - and read out raw that came out as "урон MainMeleeWeapon/2
-- MainWeaponDamageType", which is worse than saying less.
local WEAPON_DMG = {
    MainMeleeWeapon = "оружия ближнего боя",
    OffhandMeleeWeapon = "оружия во второй руке",
    MainRangedWeapon = "дальнобойного оружия",
    OffhandRangedWeapon = "дальнобойного оружия во второй руке",
    UnarmedDamage = "без оружия",
    ThrownDamage = "брошенного предмета",
}

--- "DealDamage(4d6,Radiant)" and the several of them a spell can carry.
---
--- Returns the whole phrase, "урон" included, because half weapon damage does not fit behind a
--- fixed prefix: "половина урона оружия ближнего боя" and "урон 4к6 излучением" are different
--- shapes, not one shape with a different tail.
local function damageWords(s)
    if type(s) ~= "string" or s == "" then return nil end
    local out = {}
    for dice, kind in s:gmatch("DealDamage%(([^,%)]+)%s*,?%s*([^%)]*)%)") do
        dice = dice:gsub("%s+", "")
        local half = false
        local base = dice:match("^(.+)/2$")
        if base ~= nil then half, dice = true, base end

        local what
        if dice:match("^%d+d%d+$") or dice:match("^%d+$") then
            what = dice:gsub("d", "к")
            local kw = DAMAGE_RU[kind]
            if kw ~= nil then what = what .. " " .. kw end
        else
            -- A symbol rather than a number. Named if it is one of the handful the engine
            -- uses, and called plainly "оружия" if it is not - never spelled out.
            what = WEAPON_DMG[dice] or "оружия"
            local kw = DAMAGE_RU[kind]
            if kw ~= nil then what = what .. ", " .. kw end
        end
        out[#out + 1] = (half and "половина урона " or "урон ") .. what
    end
    if #out == 0 then return nil end
    return table.concat(out, " и ")
end
M.damageWords = damageWords

--- "ActionPoint:1;SpellSlotsGroup:1:1:1" - the action economy and the slot it burns.
local function costWords(s)
    if type(s) ~= "string" or s == "" then return nil end
    local out = {}
    for part in s:gmatch("[^;]+") do
        local bits = {}
        for b in part:gmatch("[^:]+") do bits[#bits + 1] = b end
        local kind = bits[1]
        if kind == "SpellSlotsGroup" then
            -- The last number is the ring the slot comes from.
            local lvl = tonumber(bits[#bits])
            out[#out + 1] = lvl and ("ячейка " .. lvl .. " круга") or "ячейка заклинания"
        elseif COST_RU[kind] ~= nil then
            local n = tonumber(bits[2]) or 1
            out[#out + 1] = n > 1 and (COST_RU[kind] .. " ×" .. n) or COST_RU[kind]
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, ", ")
end
M.costWords = costWords

--- What a spell is *for*, in one sentence, or nothing.
---
--- The mechanical facts say a great deal about Guiding Bolt and nothing at all about Rage,
--- whose whole meaning is prose - which is exactly what the player found: "услышал что-то про
--- бонусное действие, но не слишком понятно для чего она нужна".
---
--- Two texts exist and they are not interchangeable. Measured on `Shout_Rage`:
---
---   ExtraDescription  "Получить устойчивость к физическому урону и преимущество при
---                      проверках и испытаниях силы."          ← what it is for
---   Description       "Вы наносите дополнительно [1] оружием ближнего боя…"
---                     with DescriptionParams = LevelMapValue(RageDamage)
---
--- **A sentence with an unfilled hole in it is not said at all.** `[1]` is substituted by the
--- tooltip engine from `DescriptionParams`, which this layer cannot evaluate, and "вы наносите
--- дополнительно оружием ближнего боя" is worse than silence. So the text is rejected when a
--- placeholder survives, and the other one is tried instead.
local function purpose(e, limit)
    local function clean(h)
        if type(h) ~= "string" or h == "" then return nil end
        local t = unmarkup(loca(h))
        if type(t) ~= "string" then return nil end
        t = t:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if t == "" or t == h then return nil end
        if t:find("%[%d+%]") then return nil end        -- a hole the tooltip engine fills
        return t
    end
    -- The short "what it does" first; the numeric one only if that is missing or holed.
    local t = clean(soft(function() return e.ExtraDescription end))
          or clean(soft(function() return e.Description end))
    if t == nil then return nil end
    if #t <= (limit or 200) then return t end
    -- Cut on a sentence if there is one inside the budget, on a word otherwise.
    local cut = nil
    for i = 1, #t do
        local c = t:sub(i, i)
        if (c == "." or c == "!" or c == "?") and i <= (limit or 200) then cut = i end
    end
    if cut ~= nil and cut > 40 then return t:sub(1, cut) end
    local s = t:sub(1, limit or 200)
    return (s:gsub("%s+%S*$", "") .. "…")
end
M.purpose = purpose

--- "ApplyStatus(RAGE,100,10)" - the last number is how many turns it lasts.
local function durationWords(s)
    if type(s) ~= "string" then return nil end
    local turns = s:match("ApplyStatus%([^,]+,%s*%d+%s*,%s*(-?%d+)%s*%)")
    turns = tonumber(turns)
    if turns == nil or turns <= 0 then return nil end
    if turns >= 100 then return nil end          -- the engine's "until something else" numbers
    return M.plural(turns, "ход")
end
M.durationWords = durationWords

--- The hard facts about a spell, in the order a player choosing one needs them.
---
--- Costs and reach first, because in a fight those decide whether the slot can be used at all;
--- what it does to whoever it hits after that. The prose description is deliberately not in
--- here - it is long, it carries unresolved `[1]` placeholders the tooltip engine fills in, and
--- it goes under the review cursor instead.
function M.spellFacts(id)
    local e = soft(Ext.Stats.Get, id)
    if e == nil then return nil end
    local f = function(name) return soft(function() return e[name] end) end
    local out = {}

    local cost = costWords(str(f("UseCosts")))
    if cost ~= nil then out[#out + 1] = cost end

    -- `TargetRadius` is the reach on every spell measured so far; `Range` was 0 on the one that
    -- prompted this. Both are looked at, the larger wins, and a melee reach is named as such
    -- rather than read out as "дальность 1 м".
    local reach = tonumber(str(f("TargetRadius"))) or 0
    local range = tonumber(str(f("Range"))) or 0
    if range > reach then reach = range end
    if reach > 0 then
        if reach <= 2 then out[#out + 1] = "вплотную"
        else out[#out + 1] = "дальность " .. math.floor(reach + 0.5) .. " м" end
    end

    local area = tonumber(str(f("AreaRadius"))) or 0
    if area > 0 then out[#out + 1] = "область " .. math.floor(area + 0.5) .. " м" end

    local how = ATTACK_RU[str(f("TooltipAttackSave"))]
    if how ~= nil then out[#out + 1] = how end

    local dmg = damageWords(str(f("TooltipDamageList")))
    if dmg ~= nil then out[#out + 1] = dmg end

    local lvl = tonumber(str(f("Level")))
    local school = SCHOOL_RU[str(f("SpellSchool"))]
    if lvl ~= nil and lvl > 0 then
        out[#out + 1] = "заклинание " .. lvl .. " круга" .. (school and (", " .. school) or "")
    elseif school ~= nil then
        out[#out + 1] = "заговор, " .. school
    end

    local cd = str(f("Cooldown"))
    if cd == "OncePerRest" then out[#out + 1] = "раз до отдыха"
    elseif cd == "OncePerShortRest" then out[#out + 1] = "раз до короткого отдыха"
    elseif cd == "OncePerTurn" then out[#out + 1] = "раз за ход" end

    local dur = durationWords(str(f("TooltipStatusApply")))
    if dur ~= nil then out[#out + 1] = dur end

    -- What it is for, last and in a sentence of its own. The facts are what a player scans
    -- past; this is the part they stay for, and on a spell like Rage it is the only part that
    -- means anything. The whole text is under the review cursor either way.
    local why = purpose(e, 180)

    if #out == 0 and why == nil then return nil end
    local line = table.concat(out, ", ")
    if why ~= nil then line = (line ~= "" and (line .. ". ") or "") .. why end
    return line
end

--- The same spell at length, for the review cursor: the facts, then the game's own prose.
function M.spellLines(id)
    local out = {}
    local facts = M.spellFacts(id)
    if facts ~= nil then out[#out + 1] = facts end
    local e = soft(Ext.Stats.Get, id)
    if e == nil then
        if #out == 0 then return nil end
        return out
    end
    -- Both texts, and in the order they answer questions in: what it is for, then the numbers.
    -- Here the one with an unfilled `[1]` is kept rather than dropped - the review cursor is
    -- read deliberately, a line at a time, and a sentence missing one value still says more
    -- than no sentence. In the spoken line it is dropped; the two places want different things.
    for _, field in ipairs({ "ExtraDescription", "Description" }) do
        local h = soft(function() return e[field] end)
        if type(h) == "string" and h ~= "" then
            local text = unmarkup(loca(h))
            if type(text) == "string" then
                text = text:gsub("%[%d+%]", "…"):gsub("%s+", " ")
                            :gsub("^%s+", ""):gsub("%s+$", "")
                local dup = false
                for i = 1, #out do if out[i] == text then dup = true end end
                if text ~= "" and text ~= h and not dup then out[#out + 1] = text end
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Radial menus ----------------------------------------------------------------------
--
-- Two of them, and the pad opens both: a bumper raises `ActionRadials` (the hotbar as three
-- pages of a wheel, the bumpers turning the pages) and a trigger raises `shortcutsMenu` (the
-- character sheet, the spellbook, resting, the camp, waypoints, quicksave and quickload).
-- Neither can be read the way a list is.
--
--   ls.UIWidget ActionRadials
--     Grid MainHotbarListHolder > ListBox HotBarList
--       ListBoxItem            one per page; the one with the focus is the page in play
--         ls.PagedList > Canvas > ls.PageView > Grid radialRoot
--           ls.Radial HotBarRadial   SelectedIndex, -1 while the stick is centred
--             Canvas PART_ContentHolder
--               ls.LSRadialListItem  one per slot; its DataContext is the action -
--                                    Name (a loca handle), IconName, MainCost, SpellType…
--     StackPanel ActionButton        the panel describing whatever is pointed at
--
--   ls.UIWidget shortcutsMenu
--     ls.Radial MenuRadial       SelectedIndex, and the pointed item carries IsSelected
--       ls.LSRadialListItem ShortCutCharacterSheet / LongRestItem / WaypointsItem / …
--     StackPanel shortCutInfo    ActionTitle, Description, ExtraInfo
--     StackPanel SaveLoadErrors  SaveError, LoadError - why saving is refused right now
--
-- What makes them readable at all is that `SelectedIndex` is the stick: it is 0-based, it
-- matches the item marked IsSelected (measured: selIdx=11 against the twelfth item), and it
-- returns to -1 the moment the stick is let go. So the announcement follows the index, and
-- the resting state says nothing rather than repeating itself.

M.RADIAL_WIDGETS = { ActionRadials = "Круговое меню", shortcutsMenu = "Быстрое меню" }

-- The action economy, as the model spells it.
local RADIAL_COST = {
    Action = "действие", BonusAction = "бонусное действие",
    Movement = "движение", ReactionActionPoint = "реакция",
}

--- The wheel the stick is turning.
---
--- `ActionRadials` holds one per page and only the focused page answers to the stick, so the
--- page is decided by the focus of the ListBoxItem around it - overwritten at each one rather
--- than inherited, because IsKeyboardFocusWithin is set along the whole path from the root
--- and would otherwise make every page look current.
local function findRadial(node)
    local best, bestPage, page, pages = nil, nil, 0, 0
    local function rec(o, depth, current)
        if o == nil or depth > 16 then return end
        local p = props(o)
        if p.IsVisible == false then return end
        local cls = select(1, A.splitToString(A.realType(o)))
        -- `pages` is a key, not a number to say out loud. Measured 2026-08-06 with the wheel
        -- open: the tree holds **384** `ls.Radial` nodes and every one of them carries
        -- `SelectedIndex`, so no test on the node tells the page the player is on from the 383
        -- they are not. The count changes when the page does, which is all the key needs; what
        -- it is not is a page number, and it used to be announced as one.
        if cls:find("Radial", 1, true) and not cls:find("RadialListItem", 1, true) then
            pages = pages + 1
            if best == nil or (current and bestPage ~= true) then
                best, bestPage, page = o, current, pages
            end
            return                      -- never descend into the slots from here
        end
        if cls:find("ListBoxItem", 1, true) or cls:find("PageView", 1, true) then
            current = (p.IsKeyboardFocusWithin == true) or (p.IsFocused == true)
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1, current) end
    end
    rec(node, 0, false)
    return best, page, pages
end
M.findRadial = findRadial

--- The slots of a wheel, in order.
local function radialItems(radial)
    local holder = nil
    local function find(o, d)
        if o == nil or holder ~= nil or d > 5 then return end
        local p = props(o)
        if str(p.Name) == "PART_ContentHolder" then holder = o return end
        local ch, cn = A.kids(o)
        for i = 1, cn do find(ch[i], d + 1) end
    end
    find(radial, 0)
    if holder == nil then return {} end

    local out = {}
    local ch, cn = A.kids(holder)
    for i = 1, cn do
        local cls = select(1, A.splitToString(A.realType(ch[i])))
        if cls:find("RadialListItem", 1, true) then out[#out + 1] = ch[i] end
    end
    return out
end
M.radialItems = radialItems

--- What one slot is, from the model behind it.
---
--- The name is a localisation handle on the item's own data context - the visual slot is an
--- icon and nothing else, exactly like a save row.
local function radialSlot(item)
    if item == nil then return nil end
    local p = props(item)
    local rec = nil
    local dc = p.DataContext
    if type(dc) == "userdata" then
        local dp = soft(function() return dc:GetAllProperties() end)
        if type(dp) == "table" then rec = dp end
    end
    if rec == nil then return nil end

    -- The action is not on the slot, it is one level inside it. Measured 2026-08-06 with the
    -- wheel held open: the slot's own record carries `SlotType`, `SlotIndex`, `CanUse` and a
    -- `Content` - and **no `Name` at all**. Everything worth saying is on `Content`, including
    -- `PrototypeID`, which is the stats id itself, so no matching by name is needed:
    --
    --     Content.PrototypeID = Shout_Rage      Content.Name = hd0473bcf…  (the display name)
    --     Content.MainCost = BonusAction        Content.IconName = Action_Barbarian_Rage
    --     Content.PassiveName = NonLethal       on a passive slot instead
    --
    -- The layer looked for `rec.Name`, which has never existed, so a slot was announced by
    -- whatever the panel beside the wheel happened to say and nothing else.
    local content = nil
    if type(rec.Content) == "userdata" then
        content = soft(function() return rec.Content:GetAllProperties() end)
    end
    if type(content) ~= "table" then content = {} end

    local name = loca(content.Name or rec.Name)
    if type(name) ~= "string" or name == "" or name:find("^h%x") then name = nil end
    local parts = {}
    if name ~= nil then parts[#parts + 1] = name end

    -- Why it cannot be used, before what it does: in a fight that is the difference between a
    -- slot worth hearing out and one to move past.
    if rec.CanUse == false then parts[#parts + 1] = "недоступно" end

    -- What it does. The facts already carry the cost, so the wheel's own one-word version is
    -- only used when there is no stats entry behind the slot.
    local id = str(content.PrototypeID)
    if id == "" or id == "nil" then id = nil end
    if id == nil then id = M.spellIdFor(str(content.Name or rec.Name)) end

    local facts = id ~= nil and M.spellFacts(id) or nil
    if facts == nil then
        local passive = str(content.PassiveName)
        if passive ~= "" and passive ~= "nil" then
            id = passive
            facts = "пассивное умение"
        end
    end
    if facts ~= nil then
        parts[#parts + 1] = facts
    else
        local cost = RADIAL_COST[str(content.MainCost or rec.MainCost)]
        if cost ~= nil then parts[#parts + 1] = cost end
    end

    if type(rec.Count) == "number" and rec.Count > 1 then
        parts[#parts + 1] = rec.Count .. " шт."
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", "), rec, id
end
M.radialSlot = radialSlot

--- The panel beside the wheel: the name of what is pointed at, its description, and why it
--- cannot be used. `shortcutsMenu` names these; `ActionRadials` calls its own ActionButton.
local RADIAL_INFO = { shortCutInfo = "info", ActionTitle = "title", Description = "desc",
                      ExtraInfo = "extra", SaveLoadErrors = "errors",
                      ActionButtonDescription = "desc", RadialActionErrorMessage = "error",
                      AdditionalErrors = "errors", UpcastInfo = "extra" }

local function radialInfo(widget)
    local out = {}
    local function rec(o, depth)
        if o == nil or depth > 8 or #out > 6 then return end
        local p = props(o)
        if p.IsVisible == false then return end
        local key = RADIAL_INFO[str(p.Name)]
        if key ~= nil then
            for _, s in ipairs(A.collectText(o, 60, 6)) do
                if out[#out] ~= s then out[#out + 1] = s end
            end
            return
        end
        local cls = select(1, A.splitToString(A.realType(o)))
        if cls:find("Radial", 1, true) and not cls:find("RadialListItem", 1, true) then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(widget, 0)
    return out
end
M.radialInfo = radialInfo

--- Where the stick points, and on what.
function M.radialState(widget)
    local radial, page, pages = findRadial(widget)
    if radial == nil then return nil end
    local p = props(radial)
    local idx = tonumber(p.SelectedIndex)
    local items = radialItems(radial)
    local st = { page = page, pages = pages, count = #items,
                 index = (idx ~= nil and idx >= 0) and (idx + 1) or nil }
    if st.index ~= nil and items[st.index] ~= nil then
        st.text, st.rec, st.spell = radialSlot(items[st.index])
    end
    -- The panel is the other half of the answer, and for the shortcut wheel it is the only
    -- one: its slots carry no record, only a name like ShortCutCharacterSheet.
    st.info = radialInfo(widget)
    if st.text == nil and st.info[1] ~= nil then st.text = st.info[1] end
    return st
end

M.radialKey = nil

--- Say the wheel as it turns: the page when it changes, the slot when the stick moves.
function M.radialTick(ws)
    local widget, name = nil, nil
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false and M.RADIAL_WIDGETS[str(w.name)] then
            widget, name = w.node, str(w.name)
            break
        end
    end
    if widget == nil then
        if M.radialKey ~= nil then
            M.radialKey = nil
            -- Coming back out of a wheel, whatever is underneath has to name itself again.
            M.lastFocus, M.saveKey, M.lastScreen = nil, nil, nil
        end
        return false
    end

    local st = M.radialState(widget)
    if st == nil then return true end
    -- Under the review cursor: the game's own prose about the spell first, then whatever the
    -- panel beside the wheel says. The spoken line has to stay short enough to hear between two
    -- turns of the stick, so the long form lives on PageUp and PageDown instead of in it.
    local lines = st.info
    if st.spell ~= nil then
        local sl = M.spellLines(st.spell)
        if sl ~= nil then
            lines = {}
            for i = 1, #sl do lines[#lines + 1] = sl[i] end
            for i = 1, #st.info do lines[#lines + 1] = st.info[i] end
        end
    end
    M.lines, M.linesFrom = lines, "screen"

    local pageKey = name .. "|" .. tostring(st.page) .. "|" .. tostring(st.count)
    if pageKey ~= M.radialPage then
        M.radialPage = pageKey
        local parts = { M.RADIAL_WIDGETS[name] }
        -- No page number. See findRadial: the number that used to be said here counted 384
        -- controls the player has no way to be on.
        if st.count > 0 then parts[#parts + 1] = M.plural(st.count, "пункт") end
        pend(table.concat(parts, ", "))
    end

    -- Nothing under the stick: the wheel is at rest and has already said where it is.
    local key = pageKey .. "|" .. tostring(st.index) .. "|" .. tostring(st.text)
    if st.index == nil or st.text == nil then
        M.radialKey = key
        flush()
        return true
    end
    if key ~= M.radialKey then
        M.radialKey = key
        local line = st.text
        if st.count > 1 then line = line .. ", " .. st.index .. " из " .. st.count end
        _P("[pad] radial -> " .. line)
        pend(line)
    end
    flush()
    return true
end

-- The slot under the d-pad ------------------------------------------------------------
--
-- A panel now announces itself and can be read end to end, and that is still not looting. The
-- player opens a rucksack, hears "Контейнер, 12 строк", moves the d-pad - and nothing. What is
-- missing is not the text, which was all spoken on opening; it is **which** of it the game has
-- highlighted now.
--
-- There is no Noesis focus to follow in a controller panel, so the selection lives on the slot
-- itself. The dialogue answer list above shows the shape the game uses for exactly this:
-- `ls.LSListBoxItem IsSelected=true` among siblings that are all false. The wheel shows the
-- other shape, `SelectedIndex` on the control. Both are looked for, because the panel is not
-- required to pick the same one, and which answered is written to the log so the next panel
-- costs no guessing.
--
-- Cost is the reason this is on a timer rather than on every pass: the walk is the same one
-- that measured 12 ms over the container's 138 nodes, and a d-pad press does not need
-- answering sixty times a second.
M.SLOT_FLAGS = { "IsSelected", "IsCurrent", "IsHighlighted", "IsActive" }
M.SLOT_MS = 120
M.slotKey = nil
M.slotPanel = nil
M.slotAt = 0
M.slotState = nil
M.slotItems = nil       -- what the open container holds, from the ECS
M.slotItemsAt = nil

--- What was in the container a moment ago and is not now, by name.
---
--- Taking something is the one event in looting that makes a sound and no words: the game
--- plays a clink, the item is gone from the panel, and a player who cannot see the inventory
--- has no way to know what they just picked up. Compared by name rather than by entity,
--- because a stack that shrinks is the same entity with a different count.
local function itemGone(was, now)
    if was == nil or now == nil or was.items == nil or now.items == nil then return nil end
    local have = {}
    for i = 1, #now.items do
        local n = now.items[i].name
        if n ~= nil then have[n] = (have[n] or 0) + 1 end
    end
    for i = 1, #was.items do
        local n = was.items[i].name
        if n ~= nil then
            if (have[n] or 0) > 0 then have[n] = have[n] - 1 else return n end
        end
    end
    return nil
end
M.itemGone = itemGone

--- The selected slot inside a panel: which one, out of how many, and what it says.
---
--- Down the focus chain, not across the tree. Searching the panel for a marked slot was the
--- first attempt and it cannot work here: the container's tree carries **3037** nodes claiming
--- a selection-shaped property, and any budget that survives a frame runs out among the
--- chrome, hundreds of nodes above the items. The chain is twenty-two levels long and costs
--- one child scan each.
---
--- The last link is a node with `IsFocused` and no text of its own, so the name is looked for
--- by climbing back up: the nearest ancestor that says anything is the slot. And the position
--- is taken from the widest level on the chain - among two hundred nodes of layout, the one
--- with eleven siblings is the row of items, and its index is the one that moves.
function M.slotFind(node)
    local chain, cur, guard = {}, node, 0
    while cur ~= nil and guard < 40 do
        guard = guard + 1
        local ch, cn = A.kids(cur)
        local nxt, ni, done = nil, nil, false
        for i = 1, cn do
            local p = props(ch[i])
            if type(p) == "table" then
                if p.IsFocused == true then nxt, ni, done = ch[i], i, true break end
                if nxt == nil and p.IsKeyboardFocusWithin == true then nxt, ni = ch[i], i end
            end
        end
        if nxt == nil then break end
        chain[#chain + 1] = { node = nxt, index = ni, count = cn }
        if done then break end
        cur = nxt
    end
    if #chain == 0 then return nil end

    -- The deepest level with more than one sibling, not the widest one. Measured on an opened
    -- pouch: the chain runs 1/2 2/6 1/4 1/6 1/2 2/4 1/2 1/1 3/11 … 1/1 1/3, and pressing the
    -- d-pad moved only the **last** of those - 1/3, 2/3, 3/3. The eleven-sibling level nine
    -- deep never moved at all; it is layout. So the widest level was exactly the wrong pick.
    local sig, pos = {}, nil
    for i = 1, #chain do
        sig[#sig + 1] = chain[i].index .. "/" .. chain[i].count
    end
    for i = #chain, 1, -1 do
        if chain[i].count > 1 then pos = chain[i] break end
    end
    pos = pos or chain[#chain]

    -- Climbing back up for the words, and stopping at the first level that has any.
    --
    -- Up to the widest level and no further. That level is the row of items - eleven siblings
    -- among two hundred nodes of layout - so its subtree is the slot and nothing but; one step
    -- above it is the whole panel, and reading the panel back on every d-pad press is exactly
    -- what the review keys already do better.
    --
    -- The budget is the second argument, the *node* count, and the first attempt passed ten -
    -- which is less than a slot is made of, so the search came back empty from a subtree that
    -- had the name in it all along.
    local texts, from = nil, 1
    for i = 1, #chain do if chain[i] == pos then from = i break end end
    for i = #chain, from, -1 do
        local info = visibleScan(chain[i].node, 400, 8)
        if info ~= nil and #info.texts > 0 then texts = info.texts break end
    end
    texts = texts or {}

    -- A slot is an icon, a stack count and a name, in no dependable order. The longest string
    -- is the one being listened for; the numbers ride behind it.
    local text = nil
    for i = 1, #texts do
        if text == nil or #texts[i] > #text then text = texts[i] end
    end
    return { sig = table.concat(sig, " "), index = pos.index, count = pos.count,
             texts = texts, text = text, depth = #chain, how = "focus" }
end

-- Panels whose slots are read the same way but which must **not** join `PANEL_NAMES`.
--
-- The character sheet holds the player's own inventory and the slot reader never looked at it,
-- so the sheet answered with tab names, the weight and nothing else: 1451 nodes, eight strings,
-- and every item on it an icon.
--
-- A second table rather than an entry in the first, and that is the whole care here.
-- `PANEL_NAMES` also decides who owns the reader's pass and whether the review keys leave the
-- world scanner - and unlike a container, the character sheet already claims a Noesis focus of
-- its own, which is read today and works. Putting it there would trade a reading that works for
-- one still to be proven.
M.SLOT_PANELS = { CharacterPanel_c = true }

-- Widgets nobody has taught the layer about yet ------------------------------------
--
-- Two whole classes of thing turned out to be unread - the tutorial cards, and the dice rolls
-- with their results - and they share the shape that makes them hard to chase: each is up for a
-- moment, in the middle of play, and by the time anyone can ask what the thing was called it is
-- gone again. Asking the player to reproduce one on demand is asking them to fail a check on
-- purpose.
--
-- So every widget the game raises is written down the first time it is ever seen, with whatever
-- text it had, into a file that outlives the session. The next roll answers the question by
-- itself, with nobody watching at the moment it happens.

M.WIDGET_FILE = "A11y/widgets.json"
M.WIDGET_TRIES = 5          -- how many passes a name gets to produce its words

M.widgetSeen = nil

function M.widgetWatch(ws)
    if M.widgetSeen == nil then
        M.widgetSeen = {}
        local body = soft(function() return Ext.IO.LoadFile(M.WIDGET_FILE) end)
        if type(body) == "string" and #body > 0 then
            local t = soft(function() return Ext.Json.Parse(body) end)
            if type(t) == "table" then M.widgetSeen = t end
        end
    end

    local fresh = false
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false then
            local name = str(w.name)
            local rec = M.widgetSeen[name]
            -- A card is often drawn a frame before its words arrive, so an empty first sighting
            -- is not the answer. It gets a few more passes and then stops costing anything -
            -- without the cap this would rescan every wordless HUD badge forever.
            if rec == nil or ((rec.texts == nil or #rec.texts == 0) and
                              (tonumber(rec.tries) or 0) < M.WIDGET_TRIES) then
                local info = soft(function() return visibleScan(w.node, 300, 20) end)
                M.widgetSeen[name] = {
                    texts = info and info.texts or {},
                    nodes = info and info.nodes or 0,
                    tries = ((rec and tonumber(rec.tries)) or 0) + 1,
                }
                fresh = true
            end
        end
    end

    if fresh then
        local body = soft(function()
            return Ext.Json.Stringify(M.widgetSeen, { Beautify = true, MaxDepth = 6 })
        end)
        if body ~= nil then soft(function() Ext.IO.SaveFile(M.WIDGET_FILE, body) end) end
    end
    return fresh
end

--- Say the slot as the d-pad moves it.
function M.slotTick(ws)
    local panel = nil
    for i = #ws, 1, -1 do
        local w = ws[i]
        local n = str(w.name)
        if w.visible ~= false and (M.PANEL_NAMES[n] or M.SLOT_PANELS[n]) then panel = w break end
    end
    if panel == nil then
        if M.slotPanel ~= nil then
            -- Out of the panel and back to the world: whatever is underneath has to name
            -- itself again, the same way it does on leaving a wheel.
            M.slotPanel, M.slotKey, M.slotState = nil, nil, nil
            M.lastFocus, M.lastScreen = nil, nil
        end
        return false
    end

    local t = now()
    if (t - M.slotAt) < M.SLOT_MS then return false end
    M.slotAt = t

    local pname = str(panel.name)
    local st = soft(function() return M.slotFind(panel.node) end)
    M.slotState = st
    if st == nil then return false end
    local first = (M.slotPanel ~= pname)

    -- The contents come first, and before the "has anything changed" test, because taking an
    -- item is a change the widget need not show at all: the clink plays, the panel keeps the
    -- same shape, and the only evidence is that the container is one item lighter.
    --
    -- The name is not in the panel either - the slot is an icon over a stack count - so both
    -- the announcement and this comparison come from Nav.openContainer.
    local nav, took = _G.Nav, nil
    if nav ~= nil and (first or M.slotItemsAt == nil or (t - M.slotItemsAt) > 400) then
        local was = M.slotItems
        M.slotItems = soft(function()
            -- Whose list this is. See SLOT_PANELS: the sheet is about the character, and asking
            -- the world for the nearest open container while a sheet is up answers with a crate.
            if M.SLOT_PANELS[pname] then return nav.myInventory() end
            return nav.openContainer()
        end)
        M.slotItemsAt = t
        if not first then took = itemGone(was, M.slotItems) end
    end

    -- The whole chain, not just the slot's own index: a panel can move the selection at any
    -- level of it - a column, a tab, a row - and every one of those is a move the player made
    -- and must hear about.
    local key = pname .. "|" .. st.sig .. "|" .. tostring(st.text)
    if key == M.slotKey and took == nil then return false end
    M.slotPanel, M.slotKey = pname, key

    local label = nil
    local c = M.slotItems
    if c ~= nil and c.items ~= nil and c.items[st.index] ~= nil then
        -- The index is a position in a grid; the list is what the ECS holds. On a container
        -- panel those line up, because the panel *is* the container. On the character sheet the
        -- grid is one of several - tabs, equipment, filters, the camp stash - so the join is
        -- trusted only when the row is exactly as long as the inventory.
        --
        -- Naming the wrong item is worse than naming none. The player cannot see the mistake and
        -- will act on it, and a layer that is confidently wrong is the one failure this whole
        -- thing exists to remove.
        if not M.SLOT_PANELS[pname] or st.count == #c.items then
            label = c.items[st.index].name
        end
    end
    -- A slot past the end of the contents is an empty square, and saying so keeps the d-pad
    -- audible: silence at the edge of a grid is indistinguishable from a layer that stopped.
    label = label or st.text or "пусто"

    -- Kept for calibration, not for the player. Whether the widget's slot index really lines up
    -- with the order the ECS hands the inventory back in is a claim about a grid nobody here can
    -- see, and it has to be checked against what the game highlights rather than assumed. The
    -- console is ANSI, so the names cannot be printed - they are read out of this instead.
    M.slotLast = { panel = pname, sig = st.sig, index = st.index, count = st.count,
                   label = label, widget = st.text, ecs = c and #c.items or nil,
                   names = (function()
                       if c == nil or c.items == nil then return nil end
                       local n = {}
                       for i = 1, #c.items do n[i] = c.items[i].name end
                       return n
                   end)() }
    -- And a short history of them. Calibrating the join means comparing a *sequence* of d-pad
    -- presses against what the game highlighted, and reading one value per round trip would cost
    -- the player a press and a wait for each. Twelve is enough to see whether the index walks.
    --
    -- The **whole chain**, not the level this pass happened to pick. The first calibration
    -- recorded only the chosen level and answered nothing: the rows came back 4, 47, 2 and 19
    -- long while the player walked a ten-item inventory, which proves the pick is wrong and says
    -- nothing about which level is right. With every level written down, the one that steps 1, 2,
    -- 3 as the d-pad moves is visible in a single sitting instead of one guess per round trip.
    M.slotSeen = M.slotSeen or {}
    M.slotSeen[#M.slotSeen + 1] = { i = st.index, n = st.count, label = label,
                                    widget = st.text, panel = pname, sig = st.sig }
    while #M.slotSeen > 12 do table.remove(M.slotSeen, 1) end

    _P("[pad] slot " .. st.sig .. " [" .. tostring(st.index) .. "/" .. tostring(st.count) ..
       "] (ecs " .. tostring(c and #c.items or "-") .. ")" ..
       (took and " took" or ""))

    -- Taken is said whatever else happened, including on the pass that opened the panel: it is
    -- the one thing here the player cannot find out any other way.
    if took ~= nil then pend("Взято: " .. took) end
    -- The pass that opens the panel says the panel, not the slot: the title and the line count
    -- are what the player needs first, and the selection has not moved yet. Recorded silently
    -- so the first press of the d-pad is heard as a change.
    if not first and label ~= nil then
        local line = label
        if st.count > 1 then line = line .. ", " .. st.index .. " из " .. st.count end
        pend(line)
    end
    return flush()
end

-- Lines nobody is saying to us -----------------------------------------------------
--
-- A companion remarks on something as you walk past it, a guard shouts across a room, somebody
-- barks in a fight. All of it is subtitled on screen, and none of it was ever read: the
-- dialogue reader only runs while `Dialogue_c` is up, and none of this is that. For a player
-- whose game is in English and whose language is not, this is the half of the writing that was
-- simply missing.
--
-- Measured 2026-08-06, and it is not in the tree at all - `OverheadInfo_c` walks 67 nodes and
-- carries no strings. The line is on the shared data context that every widget hangs off:
--
--     CurrentSpeaker            who is talking
--     CurrentSubtitle           the line itself, already rendered
--     CurrentSubtitleDuration   how long it will be up
--
-- A record rather than a tree, which makes this cheap, exact and language-independent - the
-- same shape the tutorial bank and the roll panel turned out to have.

M.lastSubtitle = nil

--- The shared data context, taken off whichever widget is nearest.
---
--- Every widget hangs off the same one, so the first that answers is as good as any; the test
--- is that the field is there at all, because a widget with its own local context would answer
--- with something else entirely.
local function uiData(ws)
    for i = 1, #ws do
        local p = props(ws[i].node)
        local dc = p ~= nil and p.DataContext or nil
        if type(dc) == "userdata" then
            local d = soft(function() return dc:GetAllProperties() end)
            if type(d) == "table" and d.CurrentSubtitle ~= nil then return d end
        end
    end
    return nil
end
M.uiData = uiData

function M.subtitleTick(ws)
    -- The conversation belongs to the dialogue reader, and this record carries its lines too.
    -- Reading both would say every line of every dialogue twice.
    --
    -- Two tests, not one. The flag is what the dialogue reader last decided; the widget is what
    -- is on screen now. The box blinks out for a pass on some transitions, and one pass is all
    -- it takes to say a line the dialogue reader is about to say again.
    if M.inDialogue then M.lastSubtitle = nil return false end
    for i = 1, #ws do
        if ws[i].visible ~= false and str(ws[i].name):find("Dialogue", 1, true) then
            M.lastSubtitle = nil
            return false
        end
    end

    local d = uiData(ws)
    if d == nil then return false end
    local line = str(d.CurrentSubtitle)
    if line == "" or line == "nil" then
        M.lastSubtitle = nil
        return false
    end
    if line == M.lastSubtitle then return false end
    M.lastSubtitle = line

    local who = str(d.CurrentSpeaker)
    local what = unmarkup(line) or line
    if who ~= "" and who ~= "nil" then what = who .. ". " .. what end
    _P("[pad] subtitle: " .. what)
    -- Behind whatever is being said rather than over it. Somebody talking in the world is news,
    -- not an answer to a question the player just asked, and cutting off a row readout to
    -- deliver a passing remark is how the last round of this went wrong.
    say(what, false)
    return true
end

-- Dialogue -------------------------------------------------------------------------
--
-- The one thing that has to work for the game to be playable at all, and it turned out to
-- be readable straight off the widget - which retires the §E8 dead end, where the server's
-- dialogue manager gave the right number of answer nodes but their text could not be pulled
-- out of the proxied userdata.
--
--   ls.UIWidget Dialogue_c
--     Run "Лаэзель:"                             the speaker
--     Run "Не сейчас. Нам нужно попасть в рубку." the line
--     ls.LSListBox answerList
--       ls.LSListBoxItem IsSelected=true   → "Кто ты и почему ты мне помогаешь?"
--       ls.LSListBoxItem IsSelected=false  → "Трудно удержаться от вопросов…"
--       ls.LSListBoxItem IsSelected=false  → "Уйти."
--     ls.LSButton SelectButton / DialogueHistoryButton / SkipDialoguePrompt
--
-- IsSelected on the answer items is what makes moving through them announceable.

-- Fragments the template leaves in the tree: an update marker, the two debug captions, the
-- engine version, and the pieces a skill-check line is assembled from.
local DIALOGUE_NOISE = {
    ["[ForceUpdate]"] = true, ["%"] = true, ["."] = true, [".."] = true,
    ["DIALOG:"] = true, ["CONTEXT:"] = true,
}

-- Branches of the dialogue widget that are not the spoken line: the answers (read
-- separately), the buttons under the box, the trade notice that stays in the tree while
-- hidden, and the two debug captions.
local DIALOGUE_SKIP = {
    ButtonsContainer = true, TradeNotification = true, SkipDialoguePrompt = true,
    TooltipHolder = true, DialogueFilename = true, DialogueContext = true,
    StopListeningButton = true,
    -- The echo of the answer just chosen ("Выбранный ответ: …"), which belongs to the
    -- history rather than to what is being said now.
    AnswerSelected = true,
    -- Button captions ("Выбрать", "История диалогов", "Пропустить").
    ContentString = true,
}

-- This node's own ToString is the whole line, and its children are the same line split into
-- speaker and text - so taking both gives every line twice.
local DIALOGUE_COMBINED = { TextBodyContainer = true }

-- The captions of the buttons under the box. `DIALOGUE_SKIP` catches them by node name where
-- they are on a node with a name, and "Продолжить" is the one that gets through: it arrives as
-- a fragment of its own and is joined onto the end of nearly every line, which is the phrase
-- the player kept hearing appear out of nowhere and which broke the scene every time.
--
-- Dropped from the **line** only, and never from the answers - "Продолжить." is a legitimate
-- answer, the one that carries a conversation forward, so putting it in `DIALOGUE_NOISE` would
-- blank out the option the player is being asked to choose.
local DIALOGUE_BUTTON = {
    ["Продолжить"] = true, ["Пропустить"] = true, ["Выбрать"] = true,
    ["История диалогов"] = true, ["Перестать слушать"] = true, ["Далее"] = true,
}

local function dialogueNoise(s)
    if DIALOGUE_NOISE[s] then return true end
    if s:find("^DIALOG:") or s:find("^CONTEXT:") then return true end
    if s:find("^v%d+%.%d+") then return true end
    if s:find("^%s*%%?%s*$") then return true end
    return false
end

--- Visible text of a subtree in reading order, optionally skipping one branch.
---
--- Visibility is not pruned here the way it is elsewhere: the dialogue box hangs its lines
--- under a BackgroundDialogue that is itself marked invisible while its children are not, so
--- pruning on the parent would throw the whole conversation away.
local function textsOf(root, skip, cap)
    local out, seen, visited = {}, {}, {}
    skip = skip or {}
    local function rec(o, depth)
        if o == nil or #out >= (cap or 24) or depth > 24 then return end
        local id = tostring(o)
        if visited[id] or skip[id] then return end
        visited[id] = true
        local p = props(o)
        local _, label = A.splitToString(A.realType(o))
        for _, s in ipairs(A.strings(p.Text, label)) do
            if A.looksLikeText(s) then
                s = loca(s:gsub("^%s+", ""):gsub("%s+$", ""))
                if not seen[s] and not dialogueNoise(s) then
                    seen[s] = true
                    out[#out + 1] = s
                end
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(root, 0)
    return out
end
M.textsOf = textsOf

--- The conversation as it stands: who is talking, what was said, and the answers on offer.
---
--- One pass over the widget. Three passes (find the landmarks, read the answers, read the
--- line) cost 13 ms and drove the reader's own throttle down to 1 Hz, which is useless for
--- following a conversation - so everything is collected in a single descent, with the
--- answers filled in while inside the answer list and the line outside it.
function M.dialogue()
    local ws = findWidgets()
    local node = nil
    for i = 1, #ws do
        if ws[i].visible ~= false and tostring(ws[i].name):find("Dialogue", 1, true) then
            node = ws[i].node
        end
    end
    if node == nil then return nil end

    local out = { answers = {}, selected = 0 }
    local said, visited = {}, {}
    local saidSeen = {}
    -- The strict reading, alongside the broad one. Measured 2026-08-06 by dumping the whole box
    -- with every node named: the line and the speaker have nodes of their own -
    --
    --   BodyAndAnswersContainer > DialogueContainer > TextBodyContainer > speakerName
    --
    -- - so the line can be taken from where it lives instead of collected from the whole widget
    -- and filtered afterwards. That is what finally gets rid of "Продолжить" on the end of every
    -- line: a button caption is not under `TextBodyContainer`, whatever language it is in.
    --
    -- Both are collected because the strict one is only known to be right for the shape that was
    -- measured. If it comes back empty the broad reading is used exactly as before, so a box
    -- built differently still speaks rather than going silent.
    local bodyParts, bodySeen = {}, {}
    local speakerParts, speakerSeen = {}, {}

    -- Deduplication is per destination, not global. Sharing one set let a line collected
    -- first swallow the identical text of an answer, and the answers came out blank.
    local function take(s, into, seen)
        if not A.looksLikeText(s) then return end
        s = loca(s:gsub("^%s+", ""):gsub("%s+$", ""))
        if dialogueNoise(s) or seen[s] then return end
        seen[s] = true
        into[#into + 1] = s
    end

    local function rec(o, depth, inAnswers, current, inBody, inSpeaker)
        -- The answers sit deep: the text of one is a Run at depth 28 under a span inside a
        -- wrap panel inside the list item. A cap of 24 cut every one of them off and the
        -- options came out blank.
        if o == nil or depth > 40 or #said > 20 then return end
        local id = tostring(o)
        if visited[id] then return end
        visited[id] = true

        local p = props(o)
        local name = str(p.Name)
        if DIALOGUE_SKIP[name] then return end

        local cls, label = A.splitToString(A.realType(o))
        if name == "answerList" then inAnswers = true end
        if name == "TextBodyContainer" then inBody = true end
        if name == "speakerName" then inSpeaker = true end
        if inAnswers and current == nil and cls:find("ListBoxItem", 1, true) then
            current = { parts = {}, seen = {}, selected = p.IsSelected == true }
            out.answers[#out.answers + 1] = current
            if current.selected then out.selected = #out.answers end
        end

        local into = current and current.parts or said
        local seen = current and current.seen or saidSeen
        if not DIALOGUE_COMBINED[name] then
            take(p.Text, into, seen)
            take(label, into, seen)
            -- The speaker branch is tested first: `speakerName` sits *inside*
            -- `TextBodyContainer`, so both flags are true there and the name would otherwise be
            -- collected as part of the line it introduces.
            if current == nil and inSpeaker then
                take(p.Text, speakerParts, speakerSeen)
                take(label, speakerParts, speakerSeen)
            elseif current == nil and inBody then
                take(p.Text, bodyParts, bodySeen)
                take(label, bodyParts, bodySeen)
            end
        end

        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1, inAnswers, current, inBody, inSpeaker) end
    end
    rec(node, 0, false, nil, false, false)

    for i = 1, #out.answers do
        out.answers[i].text = table.concat(out.answers[i].parts, ", ")
        out.answers[i].parts, out.answers[i].seen = nil, nil
    end
    if out.answers[#out.answers] ~= nil and out.answers[#out.answers].text == "" then
        table.remove(out.answers)
    end

    -- The same line turns up twice, once split across runs and once whole on the node above
    -- them, so anything contained in another fragment is dropped.
    local function longest(list)
        local keep = {}
        for i = 1, #list do
            local contained = false
            for j = 1, #list do
                if i ~= j and #list[j] > #list[i] and list[j]:find(list[i], 1, true) then
                    contained = true break
                end
            end
            if not contained then keep[#keep + 1] = list[i] end
        end
        return keep
    end

    if #bodyParts > 0 then
        -- The strict reading. Nothing has to be filtered out of it because nothing else was
        -- ever let in: the line is what stands under the node the line lives on.
        if #speakerParts > 0 then
            local who = table.concat(longest(speakerParts), " "):gsub("%s*:%s*$", "")
            if who ~= "" then out.speaker = who end
        end
        out.line = table.concat(longest(bodyParts), " ")
    else
        -- The reading for a box shaped some way that has not been measured. The speaker is
        -- whichever fragment ends in a colon - not necessarily the first, since the box also
        -- carries an echo of the answer just chosen - and the button captions have to be taken
        -- out by name afterwards.
        local rest = {}
        for i = 1, #said do
            local s = said[i]
            if out.speaker == nil and s:find(":%s*$") then
                out.speaker = s:gsub("%s*:%s*$", "")
            else
                rest[#rest + 1] = s
            end
        end
        local keep = longest(rest)
        local spoken = {}
        for i = 1, #keep do
            local bare = keep[i]:gsub("^%s+", ""):gsub("[%s%.]+$", "")
            if not DIALOGUE_BUTTON[bare] then spoken[#spoken + 1] = keep[i] end
        end
        out.line = table.concat(spoken, " ")
    end

    if out.line == "" then out.line = nil end
    return out
end

--- What makes two readings of the box the same line.
---
--- The speaker is not always a fragment of its own. The same sentence came out of the tree
--- three passes running as `speaker="Шэдоухарт"` + line, then as no speaker and
--- `"Шэдоухарт: …"` in one piece, then as the first form again - and keyed on speaker and line
--- separately that is three different lines, so it was announced three times over. Stripping
--- punctuation and case collapses both shapes onto one key: the colon, the trailing full stop
--- and the split all stop mattering.
local function lineKeyOf(speaker, line)
    local s = (tostring(speaker or "") .. " " .. tostring(line or "")):lower()
    return (s:gsub("[%s%p]+", " "):gsub("^ ", ""):gsub(" $", ""))
end
M.lineKeyOf = lineKeyOf

--- Speak the conversation as it changes: the line when it is new, the highlighted answer
--- when it moves. Nothing here is focus-driven - in a session no element is focused at all.
function M.dialogueTick()
    local d = M.dialogue()
    if d == nil then
        if M.inDialogue then
            M.inDialogue = false
            M.lastLine, M.lastAnswer, M.answerSet = nil, nil, nil
            _P("[pad] dialogue ended")
            say("Диалог закончен")
        end
        return false
    end
    M.inDialogue = true

    -- The answers as they stand, as a set and as a position in it. Keeping the set apart from
    -- the position is the whole fix for answers talking over the line: the game puts the
    -- options up the moment the node is entered and the voice runs on for seconds after that,
    -- so "an option is highlighted" is not the same event as "the player chose to look at it".
    local answerSet = {}
    for i = 1, #d.answers do answerSet[i] = d.answers[i].text end
    local setKey = table.concat(answerSet, "|")
    local here = d.selected > 0 and (d.selected .. "|" .. tostring(answerSet[d.selected])) or nil

    -- An empty speaker is no speaker. It comes out as "" rather than nil when the fragment the
    -- name was in held only the colon, and "" is truthy in Lua - which is how lines got
    -- announced with a full stop in front of them.
    local speaker = d.speaker
    if type(speaker) ~= "string" or speaker == "" then speaker = nil end

    local lineKey = lineKeyOf(speaker, d.line)
    if d.line ~= nil and lineKey ~= M.lastLine then
        M.lastLine = lineKey
        -- Whatever is highlighted at this moment counts as already announced. It was not the
        -- player who put it there.
        M.lastAnswer, M.answerSet = here, setKey
        if #answerSet > 0 then M.lines, M.cursor, M.linesFrom = answerSet, 0, "screen" end
        local what = speaker and (speaker .. ". " .. d.line) or d.line
        _P("[pad] dialogue: " .. what)
        say(what)
        return true
    end

    -- The options arrived after the line - the usual case, and the one that cut the subtitle in
    -- half. Nothing is said here at all.
    --
    -- Saying how many there are was the first attempt and it was wrong twice over: it landed in
    -- the middle of the voice-over, and it answers a question the player can answer themselves
    -- by walking the list, which they have to do anyway to choose. The count now rides on the
    -- announcement of each option instead, where it costs no separate utterance. The options go
    -- under the review cursor here so PageUp and PageDown read them without choosing anything.
    if setKey ~= "" and setKey ~= M.answerSet then
        M.answerSet, M.lastAnswer = setKey, here
        M.lines, M.cursor, M.linesFrom = answerSet, 0, "screen"
        _P("[pad] answers up: " .. tostring(#answerSet))
        return true
    end

    -- Only a move speaks, and a move interrupts: the player asked for this one by pressing a
    -- direction, so it is an answer to them and goes in front of anything still being read.
    if d.selected > 0 and here ~= M.lastAnswer then
        M.lastAnswer = here
        M.cursor = d.selected
        local text = d.answers[d.selected].text
        local where = #answerSet > 1 and (d.selected .. " из " .. #answerSet) or tostring(d.selected)
        _P("[pad] answer " .. where .. ": " .. text)
        say(where .. ". " .. text)
    end
    return true
end

-- Keeping the input scheme ---------------------------------------------------------
--
-- The whole keyboard story rests on the game's control scheme being set to Controller, and
-- the game drops back to Auto whenever the physical pad is unplugged - after which the
-- keyboard cannot navigate, so the setting cannot be reached by keyboard to fix it.
--
-- `GlobalSwitches.ControllerMode` is read-only ("Cannot set property
-- GlobalSwitches::ControllerMode - property is read-only"), unlike the boolean switches
-- next to it, so it cannot simply be written back. What is left is the control the options
-- screen itself binds to: set the selection on that list and the game applies the value
-- through its own binding.

M.SCHEME_ROW = "Режим ввода"
M.SCHEME_WANTED = "Контроллер"

-- Keyed by ASCII because the console input buffer is ANSI and a Russian argument arrives as
-- question marks (§9 rule 3). The values live here, in a file read as UTF-8.
M.SCHEMES = { auto = "Авто", keyboard = "Клавиатура", controller = "Контроллер" }

function M.scheme(key)
    return M.setInputScheme(M.SCHEMES[key] or M.SCHEME_WANTED)
end

--- Find a row of the open screen by caption, and the value list inside it.
function M.findRow(caption)
    local a = M.active(10)
    if a == nil then return nil, "no active screen" end
    local found = nil
    walkFrom(a.node, function(o, depth)
        if found ~= nil then return true end
        local p = props(o)
        if p.AlternationIndex == nil or p.IsVisible == false then return end
        local text = readRow(o)
        if text ~= nil and text:find(caption, 1, true) then
            found = { node = o, alt = p.AlternationIndex, text = text, depth = depth }
            return true
        end
    end, 2500)
    if found == nil then return nil, "row not found" end

    -- The control that holds the value, and the options it offers. The combo box is what
    -- carries SelectedIndex; the ListBox inside it only presents the items, and those sit
    -- three levels further down through an ItemsPresenter rather than as direct children -
    -- reading the children of the list itself returned one entry and three blanks.
    local combo, items = nil, {}
    walkFrom(found.node, function(o)
        local cls = select(1, A.splitToString(A.realType(o)))
        if combo == nil and cls:find("ComboBox", 1, true) then combo = o end
        if cls:find("ListBoxItem", 1, true) then
            local cp = props(o)
            local parts = A.collectText(o, 30, 6)
            if parts[1] ~= nil then
                items[#items + 1] = { node = o, text = loca(parts[1]),
                                      selected = cp.IsSelected, index = #items + 1 }
            end
        end
    end, 400)
    found.combo = combo
    found.items = items
    return found
end

--- Put the control scheme back to Controller by driving the options control itself.
---
--- Every write form is tried and recorded rather than assumed: Noesis binds SetProperty on
--- nodes, but whether a dependency property accepts a write - and whether the game's binding
--- notices - is exactly the kind of thing that returns ok and does nothing (§С1).
function M.setInputScheme(wanted)
    wanted = wanted or M.SCHEME_WANTED
    local row, err = M.findRow(M.SCHEME_ROW)
    if row == nil then
        _P("[pad] setInputScheme: " .. tostring(err))
        return nil, err
    end

    local out = { row = row.text, alt = row.alt, hasCombo = row.combo ~= nil, items = {},
                  attempts = {} }
    local target = nil
    for i, it in ipairs(row.items) do
        out.items[i] = tostring(it.text) .. (it.selected == true and " *" or "")
        if it.text == wanted then target = it end
    end
    if row.combo == nil or target == nil then
        _P("[pad] setInputScheme: combo=" .. tostring(row.combo ~= nil) ..
           " items=" .. #row.items .. " target=" .. tostring(target ~= nil))
        A.write("scheme_probe", out)
        return nil, "no target"
    end

    out.before = tostring(props(row.combo).SelectedIndex)
    out.targetIndex = target.index
    local forms = {
        { "combo.SelectedIndex", function() row.combo:SetProperty("SelectedIndex", target.index - 1) end },
        { "item.IsSelected", function() target.node:SetProperty("IsSelected", true) end },
        { "combo.SelectedItem", function() row.combo:SetProperty("SelectedItem", target.node) end },
    }
    for _, f in ipairs(forms) do
        local r = try(f[2])
        local idx = soft(function() return props(row.combo).SelectedIndex end)
        local mode = soft(function() return Ext.Utils.GetGlobalSwitches().ControllerMode end)
        out.attempts[f[1]] = { ok = r.ok, err = r.error, selectedIndex = tostring(idx),
                               controllerMode = tostring(mode) }
        _P("[pad] scheme via " .. f[1] .. " ok=" .. tostring(r.ok) ..
           " idx=" .. tostring(idx) .. " mode=" .. tostring(mode) ..
           " err=" .. tostring(r.error))
    end
    A.write("scheme_probe", out)
    return out
end

-- What a control is, said out loud. Larian's class names carry the role, so the type comes
-- for free from ToString() - and for the ones that hold a value, the value is a property.
local KIND = {
    LSComboBox = "список", LSCheckBox = "флажок", LSRadioButton = "переключатель",
    LSSlider = "ползунок", LSTextBox = "поле ввода", LSListBoxItem = nil,
    LSButton = nil, LSMenuButton = nil,
}

local function kindOf(cls)
    for name, word in pairs(KIND) do
        if cls:find(name, 1, true) then return word, name end
    end
    return nil, nil
end

--- What to say about the focused node: its label, what kind of control it is, and its value.
---
--- A focused row often has no text of its own - LoadGame_c announced "ExpanderButton", which
--- is a Name and not a label - because the text lives in the template around it. And a row
--- in Options_c reads as its value alone ("NVIDIA GeForce RTX 3060") with the label sitting
--- one level up, so the parent supplies the missing half.
--- A save-list group header, said as something other than "ExpanderButton".
---
--- The load screen is a list of playthroughs, each an Expander whose header is a toggle
--- button with no text of its own - its caption is the playthrough's name, and that sits on
--- the Expander a few levels up, in the ToString tail rather than in any Text property.
--- Without this the focus lands on a control that announces its own class name, which is
--- the whole of what the screen used to say.
local function expanderText(o, p)
    for i = #M.focusPath, 1, -1 do
        local q = M.focusPath[i]
        local qcls = select(1, A.splitToString(A.realType(q)))
        if qcls:find("Expander", 1, true) then
            local qp = props(q)
            local name = titleUnder(q) or "Прохождение"
            local state = (qp.IsExpanded == true) and "развёрнуто" or "свёрнуто"

            -- The journal is built from the same control, and a quest announced as "группа
            -- сохранений" is worse than no wording at all. Here the useful second half is
            -- not what kind of thing this is but what it is asking for.
            local quest = M.bookQuest(name)
            if quest ~= nil then
                local parts = { name, state }
                local task = M.questTask(quest)
                if task ~= nil then parts[#parts + 1] = task end
                return table.concat(parts, ", ")
            end

            -- Position among the groups. The expanders are siblings inside the list's
            -- panel, one ContentPresenter each, so counting them is a single level.
            local where = ""
            local holder = M.focusPath[i - 1]
            local panel = M.focusPath[i - 2]
            if holder ~= nil and panel ~= nil then
                local ch, cn = A.kids(panel)
                local n, idx = 0, nil
                for k = 1, cn do
                    n = n + 1
                    if tostring(ch[k]) == tostring(holder) then idx = n end
                end
                if idx ~= nil and n > 1 then where = ", " .. idx .. " из " .. n end
            end
            return name .. ", группа сохранений, " .. state .. where
        end
    end
    return nil
end

local function focusText(o)
    local p = props(o)
    local cls = select(1, A.splitToString(A.realType(o)))
    local own = select(1, A.describe(o))
    if own == str(p.Name) then own = nil end

    if str(p.Name) == "ExpanderButton" then
        local t = expanderText(o, p)
        if t ~= nil then return t end
    end

    -- No label from the parent. The idea was to pick up the caption of an options row whose
    -- focused half is only the value, but it cannot be told apart from a list this way: the
    -- text walk is capped at 40 nodes, so a menu of eighteen buttons comes back as two or
    -- three strings and reads as a row - which is how every entry ended up announced as
    -- "Продолжить, <the actual item>". A row needs to be identified from the structure
    -- (VisualParent, AlternationIndex), not guessed from how much text a capped walk found,
    -- and that is the next piece of work rather than a heuristic to keep patching.
    local label = nil
    if own == nil then
        local parent = p.Parent
        if parent ~= nil then
            local parts = A.collectText(parent, 40, 5)
            local take = {}
            for i = 1, math.min(#parts, 3) do take[i] = parts[i] end
            own = #take > 0 and table.concat(take, ", ") or nil
        end
    end

    local word = kindOf(cls)
    local value = nil
    if p.IsChecked ~= nil then value = (p.IsChecked == true) and "включено" or "выключено"
    elseif type(p.Value) == "number" then value = tostring(math.floor(p.Value + 0.5)) end

    local out = {}
    if label ~= nil then out[#out + 1] = label end
    if own ~= nil then out[#out + 1] = own end
    if value ~= nil then out[#out + 1] = value end
    if word ~= nil then out[#out + 1] = word end
    if #out == 0 then return nil end
    return table.concat(out, ", ")
end
M.focusText = focusText

--- The landmarks of the screen on display, with screens that have none asked only once.
---
--- The walk is bounded but it is not free, and on a screen with no panel of prose - the save
--- list - paying for it on every focus change buys nothing. So the answer "there is nothing
--- of the sort here" is remembered per screen and the walk skipped. The options screen used
--- to be the example given here and is now the opposite one: it has a panel of prose, per
--- row, and skipping the walk on it was what kept the explanations silent.
M.proseScreen = nil
M.proseHere = nil
M.proseWatch = 0
M.lastProse = nil

local function panelMarks(widget)
    if M.proseScreen ~= widget.name then
        M.proseScreen, M.proseHere = widget.name, nil
    end
    if M.proseHere == false then return nil end
    local marks = landmarks(widget.node)
    M.proseHere = (marks.panel ~= nil or marks.appearance ~= nil or marks.preview ~= nil)
    return marks
end

--- Rate-limit by measured cost, not by hope.
---
--- The previous version ran two full walks at 10 Hz and took 50-58 ms per tick against a
--- 16 ms frame; the game did not survive the session. A scan that overruns halves its own
--- rate and says so, so no screen - however heavy - can drag the game down again.
local function throttle(cost)
    M.cost = cost
    if cost > 15000 then
        M.slowScans = M.slowScans + 1
        if M.period < 60 then
            M.period = math.min(60, M.period * 2)
            _P("[pad] scan took " .. math.floor(cost / 1000) .. " ms - backing off to every " ..
               M.period .. " ticks")
        end
    elseif cost < 6000 and M.period > 12 then
        M.period = math.max(12, math.floor(M.period / 2))
    end
end

-- Diagnosis carried by the reader itself.
--
-- The screen widgets are destroyed when the screen closes - Options_c is simply not in the
-- tree a moment later - so its structure can only be captured while the tester is standing
-- on it. Rather than ask for another button press, the reader takes one structural snapshot
-- per screen the first time it sees it. That is what the linear item list has to be built
-- from: which nodes are focusable, how the tabs are marked, and where the row boundaries are.
-- Off by default: it did its job (Options_c gave up the tab strip, the row container and the
-- alternation index that the linear readout is built on) and it is not cheap - one dump of
-- 1439 nodes cost 64 ms and tripped the reader's own throttle. Turn it on deliberately,
-- for a screen not yet understood.
M.autoDump = false
M.dumped = {}
M.focusTrace = {}

local function dumpStructure(widget, forced)
    if not forced and (not M.autoDump or M.dumped[widget.name]) then return end
    M.dumped[widget.name] = true
    local rows = {}
    walkFrom(widget.node, function(o, depth, i)
        local p = props(o)
        local cls, label = A.splitToString(A.realType(o))
        local text = nil
        if A.looksLikeText(p.Text) then text = p.Text
        elseif A.looksLikeText(label) then text = label end
        rows[#rows + 1] = { i = i, depth = depth, class = cls, name = str(p.Name),
                            visible = p.IsVisible, focusable = p.Focusable,
                            focused = p.IsFocused, within = p.IsKeyboardFocusWithin,
                            selected = p.IsSelected, alt = p.AlternationIndex,
                            opacity = p.Opacity, text = text }
    end, 1600)
    _P("[pad] structure of " .. tostring(widget.name) .. ": " .. #rows .. " nodes")
    A.write("struct_" .. tostring(widget.name), { screen = widget.name, count = #rows, rows = rows })
end

--- Dump the structure of whatever is on screen right now, on demand.
---
--- The automatic snapshot fires once per screen name, which is right for a run but useless
--- while iterating on the same screen - and the screen widget is gone the moment the screen
--- closes, so re-entering to get a second look is not free either.
function M.dumpNow(tag)
    local a = M.active(10)
    if a == nil then _P("[pad] dumpNow: no active screen") return nil end
    dumpStructure({ name = (tag and (a.name .. "_" .. tag)) or a.name, node = a.node }, true)
    return a.name
end

--- The chain from the focused node up to the screen, which is what says where the current
--- list begins and which container the tabs live in.
local function ancestry(o, maxUp)
    local out, cur = {}, o
    for _ = 1, maxUp or 14 do
        local p = props(cur)
        local cls = select(1, A.splitToString(A.realType(cur)))
        local ch, cn = A.kids(cur)
        out[#out + 1] = cls .. "/" .. str(p.Name) .. " kids=" .. cn ..
                        (p.AlternationIndex ~= nil and (" alt=" .. tostring(p.AlternationIndex)) or "") ..
                        (p.IsSelected ~= nil and (" sel=" .. tostring(p.IsSelected)) or "")
        if p.Parent == nil then break end
        cur = p.Parent
    end
    return out
end
M.ancestry = ancestry

-- Watching the interface, not the setting.
--
-- What the layer reads is the controller UI - the screens suffixed _c - and the game raises
-- those by itself the moment the pad is touched, which is what the input option's default
-- "Auto" means. So there is nothing to force and nothing to restore: pick up the pad and the
-- layer has something to read, reach for the mouse and it has not. Earlier this watched
-- GlobalSwitches.ControllerMode and demanded 2, which made every ordinary launch look broken
-- - 0 is Auto, and Auto is the normal state of an installed game. The mode is still recorded
-- for the log, never required; tools/set-input-mode.ps1 still pins it to 2, which is useful
-- only for driving the game from outside with a keyboard and no pad in hand.
--
-- Said once per change, never repeated: silence with no explanation reads as a crash, and a
-- line every half-second reads as a broken mod.
M.MODE_CONTROLLER = 2
M.lastMode = nil
M.controllerUi = nil

-- The _c widgets blink out for a moment on ordinary menu transitions - measured on the main
-- menu, where moving the focus between entries produced "no controller screens" followed by
-- "controller screens up" within a second. Announcing the loss immediately turned that into a
-- stutter of "Геймпадный интерфейс выключен / Геймпадный интерфейс". A loss therefore has to
-- hold for a few passes to count; a return is believed at once, because that direction is
-- never wrong and the player is waiting to hear it.
M.uiMisses = 0
M.UI_GRACE = 3

--- Whether the controller interface has ever been seen this session, and whether the player has
--- been told it is missing.
---
--- The layer used to open every session by announcing "нужен геймпад" and then, a second later,
--- "геймпадный интерфейс" - because at startup the menu's `_c` screens are built a beat after
--- the layer is, so the first settled observation is almost always "not up" and the second is
--- "up". Neither is a change the player asked about, and both landed on top of the loading
--- screen's tip, which is the one thing on that screen worth hearing. So the first observation
--- of a session is now silent in both directions.
---
--- The genuine case it used to cover - a machine where the interface never comes up at all,
--- which is the whole layer failing - is answered instead by silence that lasts: a count of
--- passes rather than a transition, said once, and only if the interface has never been up.
M.UI_ALARM = 40
M.uiEverUp = false
M.uiAlarmed = false

--- Is there a screen on the tree that the layer can read?
---
--- Cheap on purpose - the widget list straight off ContentRoot, about fifteen nodes, none of
--- them descended into. Returns nil, not false, while there are no widgets at all: that is a
--- loading screen or a client state still being built, and "no controller interface" said
--- there would be an announcement about nothing.
local function controllerUiUp()
    local ws = findWidgets()
    if #ws == 0 then return nil end
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false and type(w.name) == "string" and w.name:sub(-2) == "_c" then
            return true
        end
    end
    return false
end

--- The one thing still asserted: without this flag any keypress - including the Alt+Tab used
--- to leave the game - tears the controller interface down and takes the layer's eyes with
--- it. The layer's own commands are on the keyboard, so it matters here more than anywhere.
--- The game clears the flag on its own, hence the re-assert.
local function holdMixedInput()
    local im = soft(Ext.ClientInput.GetInputManager)
    if im == nil then return end
    if soft(function() return im.ControllerAllowKeyboardMouseInput end) ~= true then
        soft(function() im.ControllerAllowKeyboardMouseInput = true end)
    end
end

local function watchMode()
    holdMixedInput()

    local up = controllerUiUp()
    if up == nil then return end
    if up then
        M.uiMisses = 0
        M.uiEverUp = true
    else
        M.uiMisses = M.uiMisses + 1
        -- Never up, and it has gone on long enough to be the layer being broken rather than
        -- one screen replacing another. Said once, behind whatever is being read.
        if not M.uiEverUp and not M.uiAlarmed and M.uiMisses >= M.UI_ALARM then
            M.uiAlarmed = true
            _P("[pad] controller interface never came up")
            say("Геймпадный интерфейс не включён. В параметрах игры режим ввода должен быть «Контроллер»", false)
        end
        if M.uiMisses < M.UI_GRACE then return end
    end
    if up == M.controllerUi then return end
    local was = M.controllerUi
    M.controllerUi = up
    M.lastMode = tonumber(soft(function()
        return Ext.Utils.GetGlobalSwitches().ControllerMode
    end))

    -- The starting state is not news. Only a change from a state that was actually observed
    -- is, and it is said behind what is being read rather than over it: the player is in the
    -- middle of a tip or a line, and this is a note about the layer, not an answer to them.
    if was == nil then
        _P("[pad] controller screens " .. (up and "up" or "not up") ..
           " at start (ControllerMode " .. tostring(M.lastMode) .. ")")
        return
    end

    if not up then
        _P("[pad] no controller screens (ControllerMode " .. tostring(M.lastMode) .. ")")
        say("Геймпадный интерфейс выключен", false)
    else
        _P("[pad] controller screens up (ControllerMode " .. tostring(M.lastMode) .. ")")
        say("Геймпадный интерфейс", false)
    end
end

--- The per-tick pass: which widget is up, and where its focus is.
---
--- Deliberately does not collect text. Reading a screen's text is what costs milliseconds,
--- and the text only changes when the screen does - so it is gathered once on arrival and
--- reused, while the tick itself walks the widget list and one focus chain.
local function readerTick()
    drain()
    M.ticks = M.ticks + 1
    if M.ticks % 30 == 0 then watchMode() end
    if M.ticks % M.period ~= 0 then return end

    -- A conversation takes precedence over everything else on screen, and it is read on its
    -- own terms: in a session nothing is focused, so there is no focus to follow.
    local t0 = micros()
    if M.dialogueTick() then throttle(micros() - t0) return end

    -- A fight announces itself: the turn passing and the target cursor are the two things
    -- that cannot be asked for after the fact. The target especially - the player presses
    -- left and right exactly to hear what comes next, so it is checked every pass, while the
    -- turn is checked twice a second.
    -- Silent while a panel is open. These are the world's own announcements - the target
    -- cursor, the world cursor, the turn order - and they went on talking underneath
    -- character creation, which is a screen inside a running session: "Манекен, спутник,
    -- 2 из 2, назад, 1 м" between two rows of the character sheet.
    local nav = _G.Nav
    if nav ~= nil and not M.screenUp then
        -- Did the walk the layer ordered actually get anywhere: arrival, or a stop short of
        -- it. Silence after "иду" is the same to a listener as a layer that has died.
        soft(function() nav.walkTick() end)
        -- And whether "стоп" was obeyed: an order to stand still that queued behind a walk is
        -- indistinguishable, from the inside, from one that worked.
        soft(function() nav.stopTick() end)
        -- The world list, kept true as the player walks through it rather than as of the last
        -- key they pressed. Silent: it rebuilds, it never speaks.
        if M.ticks % 15 == 0 then soft(function() nav.scanTick() end) end
        local saidTarget = soft(function() return nav.targetTick() end)
        -- What the game writes under the world cursor, for the same reason: the player is
        -- aiming in order to hear where the aim landed, and the game has already worked out
        -- the verb, the distance and whether the move is even possible.
        --
        -- But never in the same breath as the target. Stepping the d-pad through a fight
        -- rewrites both, and the cursor's version - "Урон:, Атака основной рукой, Недостаточно
        -- движения" - arrived second and overwrote the one that names who is being aimed at.
        -- The speech bridge carries one line per tick (E6), so second means instead of.
        if not saidTarget then soft(function() nav.cursorTick() end) end
        if M.ticks % 30 == 0 then
            -- Before anything that reads the world: a level change invalidates the index, and
            -- an index from the level before is what sends a character through a door they
            -- never opened.
            soft(function() nav.levelWatch() end)
            -- Walking into a named place is what the game puts on screen and the layer never
            -- said. It goes with the level watch because it answers the same question at the
            -- next scale down: not "which region" but "which part of it".
            soft(function() nav.placeTick() end)
            -- And whether the view has drifted off the character, which takes the footsteps
            -- with it. Silent unless it has, and silent altogether where the camera's position
            -- cannot be read.
            soft(function() nav.cameraTick() end)
            soft(function() nav.combatTick() end)
            -- One objective finishing and the next appearing is the one thing in a quest a
            -- blind player cannot notice at all, and it is exactly when the navigator button
            -- starts leading somewhere else.
            soft(function() nav.questTick() end)
        end
    end

    local ws = findWidgets()

    -- A pinned tooltip takes the whole pass. It is the one thing on screen the player asked
    -- for by name - Back on the pad - and answering it a beat later, behind a row readout,
    -- would be answering a different question. Only when its text is new: it stays pinned and
    -- follows the focus, so it would otherwise be repeated every pass.
    local tip = tooltipNode(ws)
    if tip == nil then
        M.lastTip = nil
    else
        local joined = table.concat(visibleScan(tip, 600, 40).texts, ". ")
        if joined ~= "" and joined ~= M.lastTip then
            M.lastTip = joined
            _P("[pad] tooltip: " .. joined)
            say(joined)
            throttle(micros() - t0)
            return
        end
    end

    -- Saving, when it happens without a screen: F5 and the autosaves. Said behind whatever is
    -- being spoken rather than over it - it is news, not an answer to anything the player just
    -- asked - and only the finish is announced when a start was seen, so a panel that is
    -- already down when the layer starts says nothing.
    local saving = savingNow(ws)
    if saving ~= nil and saving ~= M.saving then
        if saving then
            M.saving = true
            say("Сохранение", false)
        elseif M.saving == true then
            M.saving = false
            say("Сохранено", false)
        end
    end

    -- Somebody talking in the world. Not a pass of its own: a remark does not stop the player
    -- doing what they were doing, so this speaks and lets the rest of the pass run.
    soft(function() return M.subtitleTick(ws) end)

    -- A tutorial modal takes the pass whole, and takes it before the confirmation box does,
    -- because on the pad it is one: it holds the controls until it is answered with A, and
    -- nothing underneath it can be acted on meanwhile.
    if soft(function() return M.tutorialTick(ws) end) then
        throttle(micros() - t0)
        return
    end

    -- A roll takes the pass for the plainest reason there is: it is a decision with a number
    -- attached and a button waiting, and everything else on screen at that moment is scenery.
    if soft(function() return M.rollTick(ws) end) then
        throttle(micros() - t0)
        return
    end

    -- The world context menu takes the pass whole, for the same reason a modal does: it holds
    -- the input until it is answered, and it is a popup rather than a screen, so nothing else in
    -- this pass would ever mention it.
    if soft(function() return M.contextTick(ws) end) then
        throttle(micros() - t0)
        return
    end

    -- A confirmation box takes the pass whole. It is the one thing on screen that must be
    -- heard before anything else - answering "удалить сохранение?" costs one button - and
    -- neither the focus search below nor M.active would ever reach it: the box holds no
    -- focus and the screen under it keeps one.
    local box = soft(function() return M.messageBox(ws) end)
    if box ~= nil then
        -- Said once the wording has stopped moving.
        --
        -- The box is built over several frames: the runs of the sentence arrive one at a time,
        -- so the key changes on every pass while it fills, and keying on the text alone read the
        -- same question six times over - measured at camp, six utterances for one press of A.
        -- Waiting for two passes that agree costs about a tenth of a second and ends it.
        if box.key ~= M.modalKey then
            if box.key == M.modalSettling then
                M.modalKey = box.key
                M.modalSettling = nil
                M.lines, M.cursor, M.linesFrom = box.lines, 0, "screen"
                _P("[pad] message box: " .. table.concat(box.lines, ". "))
                say(table.concat(box.lines, ". "))
            else
                M.modalSettling = box.key
            end
        end
        throttle(micros() - t0)
        return
    end
    M.modalSettling = nil

    -- The camp panel: how many supplies are in the pot, and what that buys.
    --
    -- Not a pass of its own - the player is moving a cursor over a ring of food and wants to
    -- keep hearing what is under it - so this speaks the state and lets the rest of the pass
    -- run. See M.campTick for why it is worth saying at all.
    soft(function() return M.campTick(ws) end)
    if M.modalKey ~= nil then
        -- The box is gone. Where the player stands has not been said since it went up, and
        -- after an answer to a question about deleting something it is the first thing they
        -- need: forget what was last announced so this pass says it again.
        M.modalKey = nil
        M.saveKey, M.saveGroupKey, M.lastFocus, M.lastScreen = nil, nil, nil, nil
    end

    -- A wheel takes the pass for the same reason a box does: the stick moves a selection that
    -- lives in the control's own SelectedIndex, and the focus - which sits on the page, not
    -- on the slot - has nothing to say about it.
    if soft(function() return M.radialTick(ws) end) then
        throttle(micros() - t0)
        return
    end

    -- A panel takes the pass for the same reason: its selection moves inside a tree that does
    -- not otherwise change, so nothing below would ever notice.
    if soft(function() return M.slotTick(ws) end) then
        throttle(micros() - t0)
        return
    end

    -- The journal is remembered while it is open, because it is gone the moment it closes and
    -- what it holds is the only answer to "where does the story want me" the game gives.
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false and M.JOURNAL_WIDGETS[str(w.name)] then
            soft(function() M.journalRefresh(w.node, w.name ~= M.lastScreen) end)
            break
        end
    end

    local widget, focused = nil, nil
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false then
            local f = widgetFocus(w.node)
            if f ~= nil then widget, focused = w, f break end
        end
    end
    -- Whether a screen is up at all, which is what decides whose the keyboard commands are
    -- this moment (see navMode). Cleared here and confirmed below, after the size of the
    -- focused widget is known: "something reports focus" is not the same claim as "a screen
    -- is open", and getting that wrong the other way would take the world scanner away from
    -- a player standing in a field.
    M.screenUp = false

    -- A panel the player opened owns the pass, and owns it before anything is asked about
    -- focus. Two things had to be true at once for looting to be silent, and this fixes both:
    -- the panel loses the focus race to whatever badge is above it in the stack, and the
    -- no-focus branch below returns early on a settled tree - so a container that stayed open
    -- and unchanged never got another chance to claim the keys. Set here, ahead of both.
    for i = #ws, 1, -1 do
        local w = ws[i]
        if w.visible ~= false and M.PANEL_NAMES[str(w.name)] then
            widget, focused = nil, nil
            M.screenUp = true
            break
        end
    end

    -- Which screens exist and which are up. Cheap, and it is what says whether anything has
    -- happened at all - without it, a screen that keeps no focus would be scanned in full on
    -- every single tick, which is the cost that took the reader down to 1 Hz.
    local sig = ""
    for i = 1, #ws do
        sig = sig .. tostring(ws[i].name) .. (ws[i].visible == false and "0" or "1") .. ","
    end
    local settled = (sig == M.lastWidgetSig)
    M.lastWidgetSig = sig

    -- Only when the set of widgets changed, which is exactly when a card, a roll or a panel has
    -- appeared. On a settled tree this costs nothing at all.
    if not settled then soft(function() M.widgetWatch(ws) end) end

    if widget == nil then
        -- A save screen is read whether or not anything on it holds a focus: its cursor is
        -- the list's own selection and it moves while the tree stands still, so the settled
        -- shortcut below would sit on it. Only for screens already known to be one - the
        -- probe costs two property reads and the answer never changes for a given name.
        for i = #ws, 1, -1 do
            local w = ws[i]
            if w.visible ~= false and M.saveScreens[str(w.name)] == true then
                if soft(function() return M.saveTick(w.node, nil, str(w.name)) end) then
                    flush()
                    throttle(micros() - t0)
                    return
                end
                break
            end
        end

        -- Nothing focused anywhere: name the screen by its content instead, the only way to
        -- read one that keeps no focus at all (Options_c, LoadGame_c). Once.
        if settled then throttle(micros() - t0) return end
        local a = M.active(40)
        throttle(micros() - t0)
        if a == nil then
            -- Transitions pass through a moment where only the badges are up. Waiting a beat
            -- before calling a screen unreadable keeps that from being announced every time
            -- one screen replaces another.
            M.blank = (M.blank or 0) + 1
            if M.blank == 5 and M.lastScreen ~= "<none>" then
                M.lastScreen, M.lastFocus = "<none>", nil
                M.lines, M.cursor, M.linesFrom = {}, 0, "screen"
                _P("[pad] no readable screen")
                say("Экран не читается")
            end
            return
        end
        M.blank = 0

        -- In a session nothing is focused, so every HUD widget that changes looks like a
        -- new screen: quick-saving announced "Лаэзель, 4 строк" and "Осмотреть, 3 строк",
        -- and walking around does the same continuously. The panels a player actually opens
        -- - inventory, journal, character sheet - are far larger than a badge, so the size
        -- of what is on it separates a screen worth naming from HUD chatter. Out of a
        -- session this does not apply: menus are announced however short they are.
        if M.navMode ~= nil and M.navMode() ~= nil and #a.texts < 8 then
            M.lastScreen = a.name
            return
        end

        if a.name ~= M.lastScreen then
            M.lastScreen, M.lastFocus = a.name, nil
            M.lines, M.cursor, M.linesFrom = M.linesOf(a), 0, "screen"
            M.chainMisses = M.chainMisses + 1
            _P("[pad] screen -> " .. tostring(a.name) .. " (" .. a.nodes .. " nodes, " ..
               #a.texts .. " strings, no focus, " .. math.floor(M.cost / 1000) .. " ms)")
            -- No focus to follow here. Say the title, and the once-per-session reminder that
            -- the review cursor is how such a screen gets read at all.
            pend(screenTitle(a) .. ", " .. M.plural(#M.lines, "строка"))
            if not M.hintGiven then
                M.hintGiven = true
                pend("Обзор — PageUp и PageDown")
            end
            -- A save screen names where its cursor already is, in the same breath as the
            -- screen: arriving on it and hearing only "Загрузить игру" is arriving nowhere.
            soft(function() M.saveTick(a.node, nil, str(a.name)) end)
            flush()
            -- The screens that keep no focus are exactly the ones whose structure is needed
            -- most, and they never reach the branch below, which is why Options_c went
            -- undumped through a whole pass.
            dumpStructure({ name = a.name, node = a.node })
        end
        return
    end
    M.blank = 0

    if widget.name ~= M.lastScreen then
        M.lastScreen = widget.name
        M.lastFocus = nil
        M.saidCaption = nil
        M.tab, M.lastProse = nil, nil
        -- One expensive pass per screen, for the review cursor and the title.
        local info = visibleScan(widget.node, M.nodeCap, 80)
        M.lines, M.cursor, M.linesFrom =
            M.linesOf({ name = widget.name, node = widget.node, texts = info.texts }), 0, "screen"
        -- The same measure the no-focus branch uses to tell a screen from a HUD badge, and
        -- taken here for the same reason: a panel a player has opened is many lines, a badge
        -- that happens to claim focus is a handful. Measured once per screen - it is the
        -- expensive scan above - and reused until the screen changes.
        M.screenBig = (#info.texts >= 8)
        _P("[pad] screen -> " .. tostring(widget.name) .. " (" .. info.nodes ..
           " nodes, " .. #info.texts .. " strings)")
        pend(screenTitle({ name = widget.name, texts = info.texts }))
        dumpStructure(widget)
    end
    M.screenUp = (M.screenBig == true)

    -- A save screen is read from its model before anything else on it is considered. The
    -- focus here is a step behind the game - with a campaign expanded it stays on the header
    -- while the cursor is already three saves down the list - so following it would announce
    -- the wrong place, and the rows it points at carry no text to announce anyway.
    if M.saveScreens[str(widget.name)] ~= false then
        local said = soft(function() return M.saveTick(widget.node, focused, str(widget.name)) end)
        throttle(micros() - t0)
        if said then flush() return end
        -- Nothing new about the list. Whether that is the end of it depends on what holds the
        -- focus: a campaign header is the list and was just read from the model, so falling
        -- through would only announce it again as "ExpanderButton". Anything else - a
        -- confirmation box over the screen, the name field of the save dialog - is not part
        -- of the list at all and is exactly what the ordinary reader is for.
        if M.saveScreens[str(widget.name)] == true and M.inSaveList(focused) then
            flush()
            return
        end
    else
        throttle(micros() - t0)
    end

    -- A row in a list announces itself as caption, value and position. The index comes from
    -- the focused node's own AlternationIndex, so nothing has to be searched for; the length
    -- and the tab are counted once and reused until the list actually changes.
    local fp = props(focused)
    local alt = tonumber(fp.AlternationIndex)
    local text
    local dedup, pendingCaption = nil, nil
    local marks = nil
    if alt ~= nil then
        -- Recount only when the list can have changed: a new screen, a bumper (which is how
        -- tabs are switched), or an index that runs past what was counted.
        if M.listScreen ~= widget.name or M.listCount == nil
           or alt + 1 > M.listCount or M.listDirty then
            local count, tab = listInfo(widget.node, focused)
            M.listCount = (count > 0) and count or nil
            M.listScreen, M.listDirty, M.tabDirty = widget.name, false, false
            if tab ~= nil and tab ~= M.tab then
                M.tab = tab
                pend(tab)
            end
        end
        text = readRow(focused)
        if text ~= nil and M.listCount and M.listCount > 1 then
            text = text .. ", " .. (alt + 1) .. " из " .. M.listCount
        end
    elseif M.tabDirty or widget.name ~= M.tabScreen or M.ticks % 120 == 0 then
        -- The same question for a screen whose focus is not a list row. Character creation is
        -- the case: the focused element is a spinner with no AlternationIndex, so the branch
        -- above never ran and thirteen sections were switched between in silence.
        --
        -- Asked when a bumper has been pressed, when the screen has changed, and on a slow
        -- heartbeat for the tabs the game turns over by itself - never on every pass, since
        -- the walk is ~190 nodes, which is nothing for a keypress and too much for a tick.
        M.tabDirty, M.tabScreen = false, widget.name
        marks = landmarks(widget.node)
        local t = M.tabState(widget.node, marks)
        if t ~= nil and t.name ~= M.tab then
            M.tab = t.name
            pend(t.name .. ", " .. t.index .. " из " .. t.count)
            -- The column under the tab is a different one now, so its first control has to
            -- be said again even if it happens to read the same as the last tab's.
            M.lastFocus, M.lastProse = nil, nil
        end
    end
    -- Controls whose own text is not the whole story: a save group's header does carry the
    -- playthrough name, but not that it is a group, whether it is open, or which of them it
    -- is. Those come from the row it sits in, so the focused path is walked first.
    if text == nil and str(fp.Name) == "ExpanderButton" then focusChain(widget.node) end

    -- Character creation is a column of spinners: a caption, then a control holding the
    -- current value between two arrows. The focused element is the spinner, so on its own
    -- it reads "1" or "Женщина" - true, and useless. The caption belongs to an ancestor,
    -- and it does not change while the focus stays put, so it is found once per element
    -- and the value is re-read every pass (the arrows change it without moving the focus).
    if text == nil and str(fp.Name) == "base" then
        -- A `base` node is not always a spinner with its caption elsewhere. Plenty of them
        -- already read whole, because both halves are inside: "Интеллект, 10" in the summary,
        -- "Раса, Эльф" and "Лицо, Голова 3" on their carousels, "Атлетика, (×2)" among the
        -- skills. Running the walk below on one of those takes its first word for the value
        -- and then borrows a caption from the row above - which is how standing on Интеллект
        -- in the character sheet came out as "Сила, Интеллект".
        --
        -- Exactly two, and not "two or more". A carousel leaves its unselected options in the
        -- tree, so the body type reads [Тип тела | 1 | 2 | 3 | 4] and the voice reads all
        -- eight voices; those belong to the walk below, which finds the value the game has
        -- selected instead of listing what it could be. Two parts is a caption and a value
        -- and cannot be a menu.
        --
        -- The budget is 60 nodes and 8 levels, and it is load-bearing in both directions.
        -- Raising it to 200/10 - measured - turns "Идентифицирует себя как, Мужчина" into
        -- that plus Женщина and Иное, and "Голос" into all eight. Lowering the reach is what
        -- leaves the ability-bonus pickers on the Способности tab reading "Бонус +1" without
        -- the ability they apply to: their name sits deeper than this. That one wants a
        -- collector that skips unselected ListBoxItems, the way readRow already does, rather
        -- than a bigger number - see the notes for the next session.
        local own = A.collectText(focused, 60, 8)
        if #own == 2 then
            text = table.concat(own, ", ")
            dedup = text
        end
    end
    if text == nil and str(fp.Name) == "base" then
        -- One walk up the focused path: the first ancestor that says anything is the value
        -- (the spinner's own subtree is chrome - a frame, a fill, two arrow buttons - and
        -- the text sits below all of it), and the first one after that which says something
        -- *different* is the caption. Taking "the first ancestor with two strings" instead
        -- reads the row above when a value happens to stand alone.
        --
        -- Recomputed every pass, never cached: a node handle does not survive to the next
        -- tick (§9 rule 1), and the arrows change the value without moving the focus, so a
        -- cached reading would go stale exactly when the player is changing it.
        pathTo(widget.node, focused)
        local value, vi = nil, nil
        for i = #M.focusPath, 1, -1 do
            local parts = A.collectText(M.focusPath[i], 60, 8)
            if parts[1] ~= nil then value, vi = parts[1], i break end
        end

        -- The caption is on the row, and the row has to be told apart from the panel that
        -- holds every row: both are ancestors and both start with a caption, but the panel
        -- starts with the *first* row's. A row is small - a caption and a handful of
        -- options - so the size of what an ancestor says is the discriminator. Without it
        -- the random-character button, which is a row of its own with no caption at all,
        -- borrowed "Тип тела" from the setting above it.
        local caption = nil
        if vi ~= nil then
            for i = vi - 1, math.max(1, vi - 4), -1 do
                local parts = A.collectText(M.focusPath[i], 200, 10)
                if parts[1] ~= nil and parts[1] ~= value then
                    if #parts <= 8 then caption = parts[1] end
                    break
                end
            end
        end
        -- Say the caption once. Moving along a carousel repeats the same row, and
        -- "Играть за существующего персонажа Baldur's Gate 3, Лаэзель" for every character
        -- in the list buries the one word that changed. The caption comes back as soon as
        -- the focus moves to a different setting.
        if value ~= nil then
            if caption ~= nil and caption ~= M.saidCaption then
                text = caption .. ", " .. value
            else
                text = value
            end
            -- What was read, not what was said: suppressing the caption shortens the
            -- utterance, and if that shortened form were the change key then dropping the
            -- caption would itself look like a change and every row would be said twice.
            dedup = tostring(caption) .. "|" .. value
            pendingCaption = caption
        end
    end
    if text == nil then text = focusText(focused) end
    -- Still nothing sayable. Walk the path and try once more - the same ancestry, reached
    -- the other way round. Lazy on purpose: the descent is cheap but not free, and on a
    -- screen whose focus reads fine it is waste.
    if text == nil then
        focusChain(widget.node)
        text = focusText(focused)
    end
    local key = str(fp.Name) .. "|" .. tostring(dedup or text)
    if key ~= M.lastFocus then
        M.lastFocus = key
        M.saidCaption = pendingCaption
        if #M.focusTrace < 60 then
            M.focusTrace[#M.focusTrace + 1] = { screen = widget.name, text = text,
                                                chain = ancestry(focused) }
        end
        if text ~= nil then
            _P("[pad] focus -> " .. tostring(text) .. " [" .. tostring(widget.name) .. "]")
            pend(text)
            -- The description that belongs to the choice, said with it and only when it is
            -- new. This is the prose the screen is really made of - every origin, race and
            -- class has a paragraph - and it changes with the value, not with the focus, so
            -- moving down the column does not repeat it. It is long on purpose: a player
            -- flipping past a race they know cuts it off by pressing again, which is what
            -- interrupting speech is for.
            local prose = M.selectionProse(marks or panelMarks(widget))
            if prose ~= nil and prose ~= M.lastProse then
                M.lastProse = prose
                pend(prose)
            end
            -- The description is bound separately from the value and can be a frame behind
            -- it. Watch it for a moment after every change, and speak it on its own if it
            -- catches up late - queued, not interrupting, so it falls in after the value
            -- rather than cutting it in half.
            M.proseWatch = 4
        end
    elseif M.proseWatch > 0 then
        M.proseWatch = M.proseWatch - 1
        local prose = M.selectionProse(marks or panelMarks(widget))
        if prose ~= nil and prose ~= M.lastProse then
            M.lastProse, M.proseWatch = prose, 0
            say(prose, false)
        end
    end
    -- No click of our own: in controller mode the game moves the focus itself and plays its
    -- own move and select sounds (§С4). Ours would double them.
    flush()
end

function M.readerStart(quiet)
    M.readerStop()
    local id = Ext.Events.Tick:Subscribe(readerTick)
    if id == nil then _P("[pad] FAILED: Tick:Subscribe returned nil") return false end
    M.readerId = id
    _G.A11Y_READER = id
    M.lastScreen, M.lastFocus, M.ticks, M.period = nil, nil, 0, 12
    _P("[pad] reader running (" .. tostring(id) .. ")")
    -- Silent on the ordinary path. The bootstrap says "Доступность включена" a tick later and
    -- means the same thing; two lines at startup only meant the first was cut off by the
    -- second, and both landed on the loading screen's tip. Started by hand from the console it
    -- still answers, because then it is the answer to a question somebody just asked.
    if quiet ~= true then say("Чтение экранов включено") end
    return true
end

function M.readerStop()
    local id = M.readerId or _G.A11Y_READER
    if id ~= nil then soft(function() Ext.Events.Tick:Unsubscribe(id) end) end
    M.readerId = nil
    _G.A11Y_READER = nil
end

-- diagnosis ---------------------------------------------------------------------------

-- Property names that could carry a highlight. Options_c and LoadGame_c mark no Noesis
-- focus at all, so something else has to be tracking the selected row - and rather than
-- guess which, take everything truthy whose name points that way and let two dumps at two
-- positions say which one moved.
local SELECT_HINTS = { "focus", "select", "highlight", "current", "active", "checked",
                       "ispressed", "mouseover", "hover", "index" }

--- Everything the active screen marks as selected, whatever it calls it.
function M.probeSelection(tag)
    local a = M.active(60, 2000)
    if a == nil then _P("[pad] probeSelection: no active screen") say("Нечего снимать") return nil end

    local hits = {}
    walkFrom(a.node, function(o, depth, i)
        local p = props(o)
        if p.IsVisible == false then return end
        for k, v in pairs(p) do
            local lk = tostring(k):lower()
            local interesting = false
            for j = 1, #SELECT_HINTS do
                if lk:find(SELECT_HINTS[j], 1, true) then interesting = true break end
            end
            if interesting and v ~= false and v ~= nil and v ~= 0 and v ~= "" then
                local cls, label = A.splitToString(A.realType(o))
                hits[#hits + 1] = { i = i, depth = depth, class = cls, name = str(p.Name),
                                    prop = tostring(k), value = str(v),
                                    label = label, text = p.Text }
            end
        end
    end, 2000)

    M.probes = M.probes or {}
    M.probes[#M.probes + 1] = { tag = tostring(tag), screen = a.name, count = #hits, hits = hits }
    _P("[pad] probeSelection(" .. tostring(tag) .. ") on " .. tostring(a.name) .. ": " ..
       #hits .. " marks")
    A.write("selection_" .. tostring(a.name) .. "_" .. #M.probes,
            { screen = a.name, tag = tag, index = #M.probes, count = #hits, hits = hits,
              texts = a.texts })
    say("Снято, " .. #hits .. " меток")
    return hits
end

--- Compare two selection probes: whatever moved between them is the highlight.
function M.probeDiff(a, b)
    local x, y = (M.probes or {})[a or 1], (M.probes or {})[b or 2]
    if x == nil or y == nil then _P("[pad] need two probes") return nil end
    local function key(h) return h.class .. "|" .. h.name .. "|" .. h.prop .. "|" .. tostring(h.text) end
    local inX = {}
    for _, h in ipairs(x.hits) do inX[key(h)] = h.value end
    local changed, added = {}, {}
    for _, h in ipairs(y.hits) do
        local k = key(h)
        if inX[k] == nil then added[#added + 1] = k .. " = " .. h.value
        elseif inX[k] ~= h.value then changed[#changed + 1] = k .. ": " .. inX[k] .. " -> " .. h.value end
        inX[k] = nil
    end
    local removed = {}
    for k, v in pairs(inX) do removed[#removed + 1] = k .. " = " .. v end
    table.sort(changed) table.sort(added) table.sort(removed)
    _P("[pad] probeDiff: " .. #changed .. " changed, " .. #added .. " added, " ..
       #removed .. " removed")
    for i = 1, math.min(#added, 20) do _P("   + " .. added[i]) end
    for i = 1, math.min(#changed, 20) do _P("   ~ " .. changed[i]) end
    A.write("selection_diff", { changed = changed, added = added, removed = removed })
    return changed, added, removed
end

--- The shape of the tree down to a few levels, with the weight of each branch.
function M.outline(tag, maxDepth)
    maxDepth = maxDepth or 6
    local rows = {}
    local total = A.walk(function(o, depth, i)
        if depth > maxDepth then return end
        local p = props(o)
        local cls, label = A.splitToString(A.realType(o))
        local rec = { i = i, depth = depth, class = cls, name = str(p.Name),
                      visible = p.IsVisible }
        if A.looksLikeText(label) then rec.label = label end
        if A.looksLikeText(p.Text) then rec.text = p.Text end
        if depth == maxDepth then
            local info = visibleScan(o, 2500, 4)
            rec.subtree = info.nodes
            rec.first = info.texts[1]
        end
        rows[#rows + 1] = rec
    end, 8000)
    _P("[pad] outline(" .. tostring(tag) .. "): " .. #rows .. " rows over " .. total .. " nodes")
    A.write("outline_" .. tostring(tag or "now"),
            { tag = tag, nodes = total, depth = maxDepth, count = #rows, rows = rows })
    return rows
end

--- The screen widgets, with what each one holds.
function M.screens(tag)
    local ws = findWidgets()
    local rows = {}
    for i = 1, #ws do
        local w = ws[i]
        local info = visibleScan(w.node, 1500, 8)
        rows[#rows + 1] = { i = i, name = w.name, visible = w.visible, nodes = info.nodes,
                            focus = info.focus and info.focus.text, texts = info.texts }
        _P("   " .. i .. ". " .. tostring(w.name) .. " vis=" .. tostring(w.visible) ..
           " nodes=" .. info.nodes .. " focus=" .. tostring(info.focus and info.focus.text) ..
           " first=" .. tostring(info.texts[1]))
    end
    A.write("screens_" .. tostring(tag or "now"), { count = #ws, rows = rows })
    return rows
end

--- Every node the tree flags as focused, anywhere - including the stale focus of the screen
--- hidden underneath, which is the trap this whole module exists to avoid.
function M.focusAll(tag)
    local hits = {}
    local total = A.walk(function(o, depth, i)
        local p = props(o)
        if p.IsFocused == true or p.IsKeyboardFocused == true then
            local cls, label = A.splitToString(A.realType(o))
            hits[#hits + 1] = { i = i, depth = depth, class = cls, name = str(p.Name),
                                text = select(1, A.describe(o)),
                                isFocused = p.IsFocused, isKeyboardFocused = p.IsKeyboardFocused,
                                focusWithin = p.IsKeyboardFocusWithin, visible = p.IsVisible }
        end
    end, 6000)
    _P("[pad] focusAll(" .. tostring(tag) .. "): " .. #hits .. " over " .. total .. " nodes")
    A.write("focus_all_" .. tostring(tag or "now"), { nodes = total, count = #hits, hits = hits })
    return hits
end

-- entry points --------------------------------------------------------------------------

function M.start()
    M.padStart()
    M.keysStart()
    M.readerStart(true)
    -- The world half listens for the server's answers - a destination it refused, above all,
    -- which the player has to hear rather than infer from a character that did not move.
    local nav = _G.Nav
    if nav ~= nil and nav.listen ~= nil then soft(nav.listen) end
    return true
end

function M.stop()
    M.readerStop()
    M.keysStop()
    M.padStop()
    _P("[pad] stopped")
end

function M.status()
    local a = M.active(60)
    local out = { reader = tostring(M.readerId), period = M.period,
                  lastScanMs = math.floor(M.cost / 1000), slowScans = M.slowScans,
                  screen = a and a.name, nodes = a and a.nodes,
                  focus = a and a.focus and a.focus.text,
                  lines = a and #a.texts, cursor = M.cursor, review = M.review,
                  tab = M.tab, listCount = M.listCount,
                  chainMisses = M.chainMisses, lastSaid = M.lastSaid,
                  buttonsSeen = M.unknown, texts = a and a.texts,
                  dumped = M.dumped, focusTrace = M.focusTrace }
    A.write("pad_status", out)
    _P("[pad] status: screen=" .. tostring(out.screen) .. " nodes=" .. tostring(out.nodes) ..
       " focus=" .. tostring(out.focus) .. " scan=" .. out.lastScanMs .. " ms period=" ..
       M.period)
    return out
end

_P("[pad] a11y-pad loaded. Pad.start() / Pad.status() / Pad.probeSelection('tag')")
return M
