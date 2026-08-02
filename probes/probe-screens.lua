-- Which panel does which pad button raise, and what is inside it.
--
-- The pad cannot be pressed from outside: injected device events move nothing (§С5, measured
-- again in controller mode), and the triggers and bumpers have no keyboard binding to send a
-- real key to instead - unlike the journal, map, inventory and character sheet, which are
-- keyboard-bound and can be opened from the terminal. So for those screens the player presses
-- and this watches.
--
-- One record per change of the visible widget set: every widget that is up, how big it is,
-- what it says first, whether it holds a focus - and the buttons pressed in the seconds
-- before, taken from the layer's own pad log, which is what ties a panel to the button that
-- opened it.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-screens", "PS")
--     Mods.BG3Access.PS.start()   ... press things ...   Mods.BG3Access.PS.stop()

local A, Pad = _G.A11y, _G.Pad
local W = { entries = {}, lines = {}, sig = nil, ticks = 0 }

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

-- Snapshot a panel the first time it is seen ------------------------------------------
--
-- The load screen settled how these are read: the rows of a list are realised, visible and
-- **empty**, because the item template binds to data and leaves nothing in the tree. So a
-- structural dump that only walks the visual tree answers half the question. This one walks
-- both: every node with its flags and text, and - for anything whose logical children are
-- data rather than elements - the record behind each child, which is where the caption, the
-- state and the selection actually live.
--
-- A data item is told from an element by its type: Noesis::BaseComponent against
-- Noesis::FrameworkElement.

W.WATCH = { ActionRadials = true, shortcutsMenu = true, PartyLineActive_c = true,
            -- The journal and the map: the only places the game says where the story goes.
            -- Both spellings, because the controller UI suffixes its own widgets with _c and
            -- which one is built is not decided here.
            JournalQuests_c = true, JournalQuest_c = true, Journal_c = true, Journal = true,
            JournalMap_c = true, JournalMap = true, Map_c = true, MainPanels_c = true }
W.dumped = {}

--- Element or data?
---
--- Not by type name: `Ext.Types.GetObjectType` answers with the bound type, which for these
--- elements is neither FrameworkElement nor their own class, and taking it as the test made
--- every child look like data and the first snapshots came back three lines long. What does
--- separate them is what they carry: an element has a size and a visibility, a record has a
--- domain (Title, SaveID, ProtagonistName) and nothing else.
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

--- `hidden` takes a widget that is in the tree but not on display. A screen closed a moment
--- ago is often still there with its model intact, which is a snapshot for free - no asking
--- the player to open it again while a console line is typed.
function W.dumpWidget(name, tag, hidden)
    local ws = soft(Pad.findWidgets) or {}
    local node = nil
    for i = 1, #ws do
        if str(ws[i].name) == name and (hidden or ws[i].visible ~= false) then
            node = ws[i].node
        end
    end
    if node == nil then Ext.Utils.Print("[screens] " .. name .. " is not up") return nil end

    local lines, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or n >= 2000 or depth > 40 then return end
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
        flag(p.IsKeyboardFocused == true, "kbfoc")
        flag(p.IsKeyboardFocusWithin == true, "within")
        flag(p.IsEnabled == false, "disabled")
        flag(p.Focusable == true, "focusable")
        flag(p.IsChecked ~= nil, "chk=" .. str(p.IsChecked))
        flag(p.IsExpanded ~= nil, "exp=" .. str(p.IsExpanded))
        flag(p.AlternationIndex ~= nil, "alt=" .. str(p.AlternationIndex))
        flag(p.SelectedIndex ~= nil, "selIdx=" .. str(p.SelectedIndex))

        lines[#lines + 1] = string.format("%d|%s%d|%s|%s|%s|%s", n, string.rep(" ", depth),
            depth, cls, str(p.Name), table.concat(flags, ","), tostring(text))

        local ch, cn = A.kids(o)
        for i = 1, cn do
            if isElement(ch[i]) then
                rec(ch[i], depth + 1)
            else
                -- The data behind the template, which is where a bound caption lives.
                n = n + 1
                lines[#lines + 1] = string.format("%d|%sDATA|%s", n,
                    string.rep(" ", depth + 1), tostring(recordOf(ch[i])))
            end
        end
    end
    rec(node, 0)

    local file = "A11y/panel_" .. name .. "_" .. tostring(tag or "now") .. ".txt"
    Ext.IO.SaveFile(file, table.concat(lines, "\n"))
    Ext.Utils.Print("[screens] " .. file .. ": " .. n .. " lines")
    return n
end

--- What a watched panel currently marks, and what it says.
---
--- Moving the stick over a radial changes neither the widget list nor anything the pad log
--- sees - the sticks are axes - so without this the whole point of the exercise, which entry
--- is under the cursor and how the panel says so, never reaches the record.
local function panelState(ws)
    local out = nil
    for i = 1, #ws do
        local w = ws[i]
        local nm = str(w.name)
        if w.visible ~= false and W.WATCH[nm] then
            local marks, texts = {}, {}
            soft(Pad.walkFrom, w.node, function(o, depth)
                local p = A.props(o)
                if p.IsVisible == false then return end
                local cls, label = A.splitToString(A.realType(o))
                if #texts < 24 then
                    for _, s in ipairs(A.strings(p.Text, label)) do
                        if A.looksLikeText(s) and texts[#texts] ~= s then
                            texts[#texts + 1] = s
                        end
                    end
                end
                local why = nil
                if p.IsFocused == true then why = "FOC"
                elseif p.IsKeyboardFocused == true then why = "kbfoc"
                elseif p.IsSelected == true then why = "SEL"
                elseif p.IsChecked == true then why = "checked"
                elseif p.IsMouseOver == true then why = "hover" end
                if why ~= nil and #marks < 12 then
                    local t = A.collectText(o, 20, 5)
                    marks[#marks + 1] = why .. " " .. cls .. "/" .. str(p.Name) ..
                        (p.AlternationIndex ~= nil and (" alt=" .. str(p.AlternationIndex)) or "") ..
                        (p.SelectedIndex ~= nil and (" selIdx=" .. str(p.SelectedIndex)) or "") ..
                        " [" .. table.concat(t, " | ") .. "]"
                end
            end, 800)
            out = out or {}
            out[#out + 1] = { panel = nm, marks = marks, texts = texts }
        end
    end
    return out
end

local function pass(why)
    local t0 = soft(Ext.Utils.MicrosecTime) or 0
    local ws = soft(Pad.findWidgets) or {}

    local sig = ""
    for i = 1, #ws do
        sig = sig .. str(ws[i].name) .. (ws[i].visible == false and "0" or "1") .. ","
    end
    -- The selection inside a watched panel is part of the signature: that is the thing that
    -- moves while nothing else on screen does.
    local panels = panelState(ws)
    for _, p in ipairs(panels or {}) do
        sig = sig .. p.panel .. ":" .. table.concat(p.marks, ";") .. ":" ..
              table.concat(p.texts, "|") .. ","
    end
    -- A button that changes what is *inside* a widget - the action bar filling with a
    -- different page - leaves the widget list identical, so a press is a reason to record on
    -- its own and not only a change of the set.
    if sig == W.sig and why == nil then return end
    W.sig = sig

    local rec = { why = why or "widgets changed", widgets = {}, buttons = {}, panels = panels }
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false then
            local info = soft(Pad.visibleScan, w.node, 600, 10) or { nodes = 0, texts = {} }
            local focus = soft(Pad.widgetFocus, w.node)
            local ft = focus and select(1, A.describe(focus)) or nil
            local fname = focus and str(A.props(focus).Name) or nil
            rec.widgets[#rec.widgets + 1] = str(w.name) .. " n=" .. tostring(info.nodes) ..
                (focus ~= nil and (" FOCUS " .. tostring(fname) .. "/" .. tostring(ft)) or "") ..
                " [" .. table.concat(info.texts, " | ") .. "]"
        end
    end

    -- The pad log the layer keeps anyway: the last few presses, newest last.
    local log = Pad.log or {}
    for i = math.max(1, #log - 8), #log do
        local e = log[i]
        if e ~= nil then
            rec.buttons[#rec.buttons + 1] = str(e.button) .. (e.pressed and " down" or " up") ..
                                            " @" .. str(e.t)
        end
    end

    -- One snapshot per panel, the first time it is up and has something in it. Waiting for
    -- the player to hold it open while a command is typed at the console is not a workable
    -- loop, and these panels are gone the moment the button is released.
    -- Twice per panel: once as it comes up, and once after the player has moved around in
    -- it, because what marks the current entry is only visible in the difference.
    for i = 1, #ws do
        local w = ws[i]
        local nm = str(w.name)
        if w.visible ~= false and W.WATCH[nm] then
            local info = soft(Pad.visibleScan, w.node, 200, 4)
            if info ~= nil and info.nodes > 20 then
                W.dumped[nm] = (W.dumped[nm] or 0) + 1
                if W.dumped[nm] == 1 or W.dumped[nm] == 5 then
                    soft(W.dumpWidget, nm, "auto" .. W.dumped[nm])
                end
            end
        end
    end

    -- Written as flat text, not through A.write: that one flattens anything below three
    -- levels to "<depth>", and the marks of a panel sit at four - which is how a whole round
    -- of pressing and dumping came back as forty lines of "<depth>".
    local out = W.lines
    out[#out + 1] = "== " .. tostring(#W.entries + 1) .. " " .. tostring(rec.why) ..
                    "  buttons: " .. table.concat(rec.buttons, " ")
    for _, s in ipairs(rec.widgets) do out[#out + 1] = "   W " .. s end
    for _, p in ipairs(panels or {}) do
        for _, m in ipairs(p.marks) do out[#out + 1] = "   M " .. p.panel .. " " .. m end
        if #p.texts > 0 then
            out[#out + 1] = "   T " .. p.panel .. " [" .. table.concat(p.texts, " | ") .. "]"
        end
    end
    while #out > 400 do table.remove(out, 1) end

    rec.us = (soft(Ext.Utils.MicrosecTime) or 0) - t0
    W.entries[#W.entries + 1] = rec
    if #W.entries > 40 then table.remove(W.entries, 1) end
    soft(Ext.IO.SaveFile, "A11y/screens_watch.txt", table.concat(out, "\n"))
end

W.pending = 0
W.lastLogN = 0

function W.tick()
    W.ticks = W.ticks + 1
    -- A press is recorded a fifth of a second later: the panel it raises is not there on the
    -- frame the button goes down, and a hold-to-open radial takes longer still.
    local n = #(Pad.log or {})
    if n ~= W.lastLogN then
        W.lastLogN = n
        W.pending = 12
    end
    if W.pending > 0 then
        W.pending = W.pending - 1
        if W.pending == 0 then soft(pass, "after a press") return end
    end
    if W.ticks % 10 ~= 0 then return end
    soft(pass)
end

function W.start()
    W.stop()
    W.id = Ext.Events.Tick:Subscribe(W.tick)
    _G.A11Y_SCREENWATCH = W.id
    Ext.Utils.Print("[screens] watching")
    return true
end

function W.stop()
    local id = W.id or _G.A11Y_SCREENWATCH
    if id ~= nil then soft(function() Ext.Events.Tick:Unsubscribe(id) end) end
    W.id, _G.A11Y_SCREENWATCH = nil, nil
end

Ext.Utils.Print("[screens] probe-screens ready: PS.start() / PS.stop()")
return W
