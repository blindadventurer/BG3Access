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
    HOME = "goto",                          -- walk to the selected entry / top of the screen
    END = "quest",                          -- the objective, or the summary of the screen
    DELETE = "approach", DEL = "approach",  -- close on the target / details of the selection
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
    M.lines, M.linesFrom = a.texts, "screen"
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
    elseif cmd == "quest" then
        -- One key for "where does the story want me": the objective, its object, and the walk
        -- there - and when there is no objective, the nearest map marker (Nav.questGo).
        -- On a screen the same key answers the same question about a character rather than a
        -- map: the summary panel, which is what all the choices so far add up to.
        if nav ~= nil then nav.questGo() else perform("summary") end
    elseif cmd == "approach" then
        -- Closing on what the game's own target cycle has selected is the one move that cycle
        -- cannot make for itself: it selects, it does not walk.
        -- On a screen there is nothing to walk to and "where am I" is already on Pause, so
        -- the key asks the screen to say more about whatever is selected.
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
        M.lines, M.cursor, M.linesFrom = a.texts, 0, "screen"
        say(table.concat(a.texts, ". "))
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

local LANDMARKS = {
    gameplayTabs = "tabs", gameplayPanel = "panel", gameplaySubPanel = "sub",
    summaryPanel = "summary", appearancePanel = "appearance",
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

--- The description that belongs to the choice under the cursor.
function M.selectionProse(marks)
    local node = marks and (marks.panel or marks.appearance)
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
    local marks = landmarks(a.node)
    local out = {}
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
    local marks = landmarks(a.node)
    if marks.summary == nil then return nil end
    local t = visibleScan(marks.summary, 900, 80).texts
    if #t == 0 then return nil end
    return t
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

    -- Deduplication is per destination, not global. Sharing one set let a line collected
    -- first swallow the identical text of an answer, and the answers came out blank.
    local function take(s, into, seen)
        if not A.looksLikeText(s) then return end
        s = loca(s:gsub("^%s+", ""):gsub("%s+$", ""))
        if dialogueNoise(s) or seen[s] then return end
        seen[s] = true
        into[#into + 1] = s
    end

    local function rec(o, depth, inAnswers, current)
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
        end

        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1, inAnswers, current) end
    end
    rec(node, 0, false, nil)

    for i = 1, #out.answers do
        out.answers[i].text = table.concat(out.answers[i].parts, ", ")
        out.answers[i].parts, out.answers[i].seen = nil, nil
    end
    if out.answers[#out.answers] ~= nil and out.answers[#out.answers].text == "" then
        table.remove(out.answers)
    end

    -- The speaker is whichever fragment ends in a colon - not necessarily the first, since
    -- the box also carries an echo of the answer just chosen.
    local rest = {}
    for i = 1, #said do
        local s = said[i]
        if out.speaker == nil and s:find(":%s*$") then
            out.speaker = s:gsub("%s*:%s*$", "")
        else
            rest[#rest + 1] = s
        end
    end

    -- The same line turns up twice, once split across runs and once whole on the node above
    -- them, so anything contained in another fragment is dropped.
    local keep = {}
    for i = 1, #rest do
        local contained = false
        for j = 1, #rest do
            if i ~= j and #rest[j] > #rest[i] and rest[j]:find(rest[i], 1, true) then
                contained = true break
            end
        end
        if not contained then keep[#keep + 1] = rest[i] end
    end

    out.line = table.concat(keep, " ")
    if out.line == "" then out.line = nil end
    return out
end

--- Speak the conversation as it changes: the line when it is new, the highlighted answer
--- when it moves. Nothing here is focus-driven - in a session no element is focused at all.
function M.dialogueTick()
    local d = M.dialogue()
    if d == nil then
        if M.inDialogue then
            M.inDialogue = false
            M.lastLine, M.lastAnswer = nil, nil
            _P("[pad] dialogue ended")
            say("Диалог закончен")
        end
        return false
    end
    M.inDialogue = true

    local lineKey = tostring(d.speaker) .. "|" .. tostring(d.line)
    if d.line ~= nil and lineKey ~= M.lastLine then
        M.lastLine = lineKey
        M.lastAnswer = nil
        local what = d.speaker and (d.speaker .. ". " .. d.line) or d.line
        if #d.answers > 0 then what = what .. ". " .. M.plural(#d.answers, "вариант") end
        _P("[pad] dialogue: " .. what)
        say(what)
        return true
    end

    if d.selected > 0 then
        local a = d.answers[d.selected]
        local key = d.selected .. "|" .. a.text
        if key ~= M.lastAnswer then
            M.lastAnswer = key
            _P("[pad] answer " .. d.selected .. ": " .. a.text)
            say(d.selected .. ". " .. a.text)
        end
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
            if found ~= nil then return end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], d + 1) end
    end
    rec(node, 0)
    return found
end

local function expanderText(o, p)
    for i = #M.focusPath, 1, -1 do
        local q = M.focusPath[i]
        local qcls = select(1, A.splitToString(A.realType(q)))
        if qcls:find("Expander", 1, true) then
            local qp = props(q)
            local name = titleUnder(q) or "Прохождение"
            local state = (qp.IsExpanded == true) and "развёрнуто" or "свёрнуто"

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
--- The walk is bounded but it is not free, and on a screen with no panel of prose - the
--- options screen, the save list - paying for it on every focus change buys nothing. So the
--- answer "there is nothing of the sort here" is remembered per screen and the walk skipped.
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
    M.proseHere = (marks.panel ~= nil or marks.appearance ~= nil)
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
    else
        M.uiMisses = M.uiMisses + 1
        if M.uiMisses < M.UI_GRACE then return end
    end
    if up == M.controllerUi then return end
    local was = M.controllerUi
    M.controllerUi = up
    M.lastMode = tonumber(soft(function()
        return Ext.Utils.GetGlobalSwitches().ControllerMode
    end))

    if not up then
        _P("[pad] no controller screens (ControllerMode " .. tostring(M.lastMode) .. ")")
        if was == nil then say("Нужен геймпад") else say("Геймпадный интерфейс выключен") end
    else
        _P("[pad] controller screens up (ControllerMode " .. tostring(M.lastMode) .. ")")
        if was ~= nil then say("Геймпадный интерфейс") end
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
        soft(function() nav.targetTick() end)
        -- What the game writes under the world cursor, for the same reason: the player is
        -- aiming in order to hear where the aim landed, and the game has already worked out
        -- the verb, the distance and whether the move is even possible.
        soft(function() nav.cursorTick() end)
        if M.ticks % 30 == 0 then
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

    -- Which screens exist and which are up. Cheap, and it is what says whether anything has
    -- happened at all - without it, a screen that keeps no focus would be scanned in full on
    -- every single tick, which is the cost that took the reader down to 1 Hz.
    local sig = ""
    for i = 1, #ws do
        sig = sig .. tostring(ws[i].name) .. (ws[i].visible == false and "0" or "1") .. ","
    end
    local settled = (sig == M.lastWidgetSig)
    M.lastWidgetSig = sig

    if widget == nil then
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
            M.lines, M.cursor, M.linesFrom = a.texts, 0, "screen"
            M.chainMisses = M.chainMisses + 1
            _P("[pad] screen -> " .. tostring(a.name) .. " (" .. a.nodes .. " nodes, " ..
               #a.texts .. " strings, no focus, " .. math.floor(M.cost / 1000) .. " ms)")
            -- No focus to follow here. Say the title, and the once-per-session reminder that
            -- the review cursor is how such a screen gets read at all.
            if M.hintGiven then
                say(screenTitle(a) .. ", " .. #a.texts .. " строк")
            else
                M.hintGiven = true
                say(screenTitle(a) .. ", " .. #a.texts .. " строк. Обзор — клик левого стика")
            end
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
        M.lines, M.cursor, M.linesFrom = info.texts, 0, "screen"
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
    throttle(micros() - t0)

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

function M.readerStart()
    M.readerStop()
    local id = Ext.Events.Tick:Subscribe(readerTick)
    if id == nil then _P("[pad] FAILED: Tick:Subscribe returned nil") return false end
    M.readerId = id
    _G.A11Y_READER = id
    M.lastScreen, M.lastFocus, M.ticks, M.period = nil, nil, 0, 12
    _P("[pad] reader running (" .. tostring(id) .. ")")
    say("Чтение экранов включено")
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
    M.readerStart()
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
