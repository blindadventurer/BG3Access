-- The load and save screens: dump their shape, then watch a human walk them.
--
-- Two questions, and one probe for each. What is a save row made of - the campaign group, the
-- entries inside it, the detail panel beside them, the buttons along the bottom? And what
-- moves when the player navigates inside an expanded group: the Noesis focus (which the
-- reader follows) or something the game marks itself (which it does not)? The second is why
-- the screen goes quiet: E3 established that the save list inside a group is navigated by the
-- game, not by Noesis, and the layer only ever watched the focus.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-load", "PL")
--     Mods.BG3Access.PL.dump("open")     -- whole tree, hidden branches included
--     Mods.BG3Access.PL.start()          -- log every change while the player moves
--     Mods.BG3Access.PL.stop()

local A, Pad = _G.A11y, _G.Pad
local W = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

-- one line per node ------------------------------------------------------------------

--- Everything about a node that could carry a selection, a state or a caption.
---
--- Hidden branches are kept, unlike everywhere in the layer proper: a confirmation dialog and
--- the detail panel of an unselected save both sit in the tree with IsVisible false, and what
--- this probe is for is finding out where they are before they are up.
local function nodeLine(o, depth, n)
    local p = A.props(o)
    local cls, label = A.splitToString(A.realType(o))

    local text = nil
    if type(p.Text) == "string" and p.Text ~= "" then text = p.Text end
    if text == nil and type(label) == "string" and label ~= "" then text = label end
    if text ~= nil then text = text:gsub("[\r\n]+", " / ") end

    local flags = {}
    local function flag(cond, s) if cond then flags[#flags + 1] = s end end
    flag(p.IsVisible == false, "hid")
    flag(p.IsSelected == true, "SEL")
    flag(p.IsFocused == true, "FOC")
    flag(p.IsKeyboardFocused == true, "kbfoc")
    flag(p.IsKeyboardFocusWithin == true, "within")
    flag(p.IsExpanded ~= nil, "expanded=" .. str(p.IsExpanded))
    flag(p.IsEnabled == false, "disabled")
    flag(p.Focusable == true, "focusable")
    flag(p.IsMouseOver == true, "hover")
    flag(p.AlternationIndex ~= nil, "alt=" .. str(p.AlternationIndex))
    flag(p.IsChecked ~= nil, "chk=" .. str(p.IsChecked))
    flag(type(p.Opacity) == "number" and p.Opacity < 1,
         "op=" .. string.format("%.2f", type(p.Opacity) == "number" and p.Opacity or 1))

    return string.format("%d|%s%d|%s|%s|%s|%s", n, string.rep(" ", depth), depth,
                         cls, str(p.Name), table.concat(flags, ","), tostring(text))
end

--- The whole tree from the root, so a Popup - which lives in its own visual root and is
--- invisible to a walk of the screen widget - is caught too.
function W.dump(tag)
    local root = soft(Ext.ClientUI.GetRoot)
    if root == nil then Ext.Utils.Print("[load] no root") return nil end

    local lines, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or n >= 8000 or depth > 40 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local cls = select(1, A.splitToString(A.realType(o)))
        lines[#lines + 1] = nodeLine(o, depth, n)
        if A.NO_TEXT[cls] then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(root, 0)

    local name = "A11y/load_tree_" .. tostring(tag or "now") .. ".txt"
    Ext.IO.SaveFile(name, table.concat(lines, "\n"))
    Ext.Utils.Print("[load] " .. name .. ": " .. n .. " nodes")
    return n
end

-- watching -----------------------------------------------------------------------------

W.entries = {}
W.sig = nil
W.ticks = 0

--- Text under a node, in reading order, adjacent repeats collapsed.
local function texts(node, cap, maxNodes, keepHidden)
    local out, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or #out >= (cap or 30) or n >= (maxNodes or 400) or depth > 24 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local p = A.props(o)
        if p.IsVisible == false and not keepHidden then return end
        local cls, label = A.splitToString(A.realType(o))
        if A.NO_TEXT[cls] then return end
        for _, s in ipairs(A.strings(p.Text, label)) do
            if A.looksLikeText(s) then
                s = s:gsub("^%s+", ""):gsub("%s+$", "")
                if out[#out] ~= s then out[#out + 1] = s end
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(node, 0)
    return out
end
W.texts = texts

--- Every node on the screen the game marks in a way that could be a highlight, with what it
--- says. This is the question the whole probe exists for: if the save under the cursor is
--- marked IsSelected rather than focused, the reader will never see it move.
local function marked(node)
    local out = {}
    Pad.walkFrom(node, function(o, depth, i)
        local p = A.props(o)
        if p.IsVisible == false then return end
        local cls = select(1, A.splitToString(A.realType(o)))
        local why = nil
        if p.IsFocused == true then why = "FOC"
        elseif p.IsKeyboardFocused == true then why = "kbfoc"
        elseif p.IsSelected == true then why = "SEL"
        elseif p.IsExpanded == true then why = "expanded" end
        if why == nil then return end
        local t = texts(o, 6, 120)
        out[#out + 1] = why .. " " .. cls .. "/" .. str(p.Name) ..
                        (p.AlternationIndex ~= nil and (" alt=" .. str(p.AlternationIndex)) or "") ..
                        " [" .. table.concat(t, " | ") .. "]"
    end, 2500)
    return out
end

--- Every list row on the screen, whatever list it belongs to, with its depth - which is what
--- separates the campaign groups from the saves inside one of them.
local function rows(node)
    local out = {}
    Pad.walkFrom(node, function(o, depth, i)
        local p = A.props(o)
        if p.IsVisible == false or p.AlternationIndex == nil then return end
        if #out >= 40 then return end
        local cls = select(1, A.splitToString(A.realType(o)))
        local t = texts(o, 8, 200)
        out[#out + 1] = "d" .. depth .. " alt=" .. str(p.AlternationIndex) .. " " ..
                        cls .. "/" .. str(p.Name) ..
                        (p.IsSelected == true and " SEL" or "") ..
                        (p.IsFocused == true and " FOC" or "") ..
                        " [" .. table.concat(t, " | ") .. "]"
    end, 2500)
    return out
end

local function screenNode()
    local ws = soft(Pad.findWidgets) or {}
    local names, node, name = {}, nil, nil
    for i = 1, #ws do
        if ws[i].visible ~= false then
            local nm = str(ws[i].name)
            names[#names + 1] = nm
            if nm:find("Load", 1, true) or nm:find("Save", 1, true) or
               nm:find("Message", 1, true) or nm:find("Popup", 1, true) or
               nm:find("Dialog", 1, true) then
                node, name = ws[i].node, nm
            end
        end
    end
    return node, name, names
end

--- The save list as data.
---
--- rowProbe answered the first half: the row template is bound and reads empty, but the
--- ListBox hands back a `SelectedItem` carrying the whole record - Title, Type, TimeString,
--- PlayTimeString, LevelName, Difficulty, Validity, HasMods. So the question left is the rest
--- of the list: whether the items can be enumerated (a count, and each entry in order), and
--- what the playthrough list above them offers in the same way.
function W.model()
    local node = select(1, screenNode())
    if node == nil then Ext.Utils.Print("[load] no load screen") return nil end

    local out = {}

    local function record(o)
        local rec = { str = str(o), kind = type(o),
                      type = str(soft(Ext.Types.GetObjectType, o)) }
        local p = soft(function() return o:GetAllProperties() end)
        if type(p) == "table" then
            rec.props = {}
            local n = 0
            for k, v in pairs(p) do
                n = n + 1
                if n <= 40 then rec.props[tostring(k)] = str(v) end
            end
            rec.propCount = n
        end
        return rec
    end

    --- A control by name, and everything it says about its items.
    local function listOf(name, wantExpanded)
        local found, expanded = nil, false
        Pad.walkFrom(node, function(o)
            local p = A.props(o)
            if p.IsExpanded == true then expanded = true end
            if str(p.Name) == name and (not wantExpanded or expanded) then found = o return true end
        end, 2500)
        if found == nil then return { missing = true } end

        local p = A.props(found)
        local rec = { name = name, selectedIndex = str(p.SelectedIndex),
                      hasItems = str(p.HasItems), children = {} }
        if p.SelectedItem ~= nil then
            local live = soft(function() return found:GetProperty("SelectedItem") end)
            if live ~= nil then rec.selectedItem = record(live) end
        end

        -- The logical children of an ItemsControl. In the collapsed dump these came back as
        -- one empty node per save (7, 36 and 1 against three campaigns), which is either the
        -- item containers or the data items themselves - and only their properties can say.
        local ch, cn = A.kids(found)
        rec.childCount = cn
        for i = 1, math.min(cn, 8) do rec.children[i] = record(ch[i]) end

        -- Enumeration, every way it could work. `#` and ipairs behave nothing like a table on
        -- proxied userdata (§E8), so each form is tried and recorded rather than assumed.
        if p.Items ~= nil then
            local items = soft(function() return found:GetProperty("Items") end)
            rec.items = { str = str(items), kind = type(items) }
            local function attempt(label, fn)
                local ok, v = pcall(fn)
                rec.items[label] = ok and str(v) or ("ERR " .. str(v))
            end
            attempt("#", function() return #items end)
            attempt("Count", function() return items.Count end)
            attempt("Count()", function() return items:Count() end)
            attempt("[0]", function() return items[0] end)
            attempt("[1]", function() return items[1] end)
            attempt("Get(0)", function() return items:GetItem(0) end)
            local n = 0
            pcall(function() for _ in pairs(items) do n = n + 1 end end)
            rec.items.pairsCount = n
        end
        return rec
    end

    out.saves = listOf("PlaythroughSavegames", true)
    out.playthroughs = listOf("SavegamesList", false)

    -- The screen's own model, which is where the whole list lives if the controls do not
    -- give it up: ExistingSaves / ExistingPlaythroughs / SelectedPlaythrough were read off a
    -- DataContext here once already (§С7).
    local wp = A.props(node)
    if wp.DataContext ~= nil then out.widgetContext = record(wp.DataContext) end

    Ext.Utils.Print("[load] model -> load_model.json")
    A.write("load_model", out)
    return out
end

--- The list in order, flat.
---
--- `model` proved the shape: the logical children of a save ListBox are the data items
--- themselves (one FrameworkElement for the presenter, then one record per save), and the
--- widget's own DataContext carries SelectedSave. What it could not show is what a record
--- says, because `A.write` flattens below three levels - so everything here is written as one
--- line per entry instead of a nested table.
function W.groups()
    local node = select(1, screenNode())
    if node == nil then Ext.Utils.Print("[load] no load screen") return nil end
    local out = { saves = {}, playthroughs = {}, collections = {} }

    local function fields(o, keys)
        local p = soft(function() return o:GetAllProperties() end)
        if type(p) ~= "table" then return "no props" end
        local parts = {}
        if keys == nil then
            local names = {}
            for k in pairs(p) do names[#names + 1] = tostring(k) end
            table.sort(names)
            keys = names
        end
        for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. str(p[k]) end
        return table.concat(parts, " ")
    end

    -- Every save ListBox on the screen, in order, with what each of its items says.
    Pad.walkFrom(node, function(o, depth)
        local p = A.props(o)
        if str(p.Name) ~= "PlaythroughSavegames" then return end
        local ch, cn = A.kids(o)
        local group = { list = "d" .. depth .. " selIdx=" .. str(p.SelectedIndex) ..
                                " kids=" .. cn, items = {} }
        for i = 1, cn do
            local kp = soft(function() return ch[i]:GetAllProperties() end)
            if type(kp) == "table" and kp.SaveID ~= nil then
                group.items[#group.items + 1] = #group.items + 1 .. ". " ..
                    fields(ch[i], { "Title", "Type", "TimeString", "PlayTimeString",
                                    "LevelName", "Difficulty", "Validity", "IsSelected",
                                    "SaveID", "HasMods", "HasMissingMods", "IsHonourMode" })
            else
                group.items[#group.items + 1] = #group.items + 1 .. ". <" ..
                    str(soft(Ext.Types.GetObjectType, ch[i])) .. ">"
            end
        end
        out.saves[#out.saves + 1] = group
    end, 2500)

    -- The campaign list: five properties per entry, and this is where a name and a count
    -- would live if the group header did not have to be read out of the visual tree.
    Pad.walkFrom(node, function(o)
        local p = A.props(o)
        if str(p.Name) ~= "SavegamesList" then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            out.playthroughs[#out.playthroughs + 1] = i .. ". " ..
                str(soft(Ext.Types.GetObjectType, ch[i])) .. " " .. fields(ch[i])
        end
        return true
    end, 2500)

    -- The two collections on the widget's own context. Neither `#` nor ipairs works on
    -- proxied userdata (§E8), so every form is tried and the answer recorded.
    local dc = A.props(node).DataContext
    if type(dc) == "userdata" then
        for _, name in ipairs({ "ExistingSaves", "ExistingPlaythroughs" }) do
            local coll = soft(function() return dc:GetProperty(name) end)
            local rec = { name = name, str = str(coll), kind = type(coll) }
            local ok, n = pcall(function() return #coll end)
            rec.len = ok and str(n) or ("ERR " .. str(n))
            local cnt = 0
            pcall(function() for _ in pairs(coll) do cnt = cnt + 1 end end)
            rec.pairs = cnt
            local first = {}
            pcall(function()
                for i, item in ipairs(coll) do
                    if i > 6 then break end
                    first[#first + 1] = i .. ": " .. fields(item, { "Title", "Name", "Type" })
                end
            end)
            rec.first = table.concat(first, " / ")
            out.collections[#out.collections + 1] = rec
        end
        out.selectedSave = fields(soft(function() return dc:GetProperty("SelectedSave") end) or {},
                                  { "Title", "Type", "TimeString", "LevelName", "Validity" })
    end

    Ext.Utils.Print("[load] groups -> load_groups.json")
    A.write("load_groups", out)
    return out
end

--- The prompts along the bottom: what can be done here, and with which button.
---
--- Their captions change with what is under the cursor - on a group header LoadBtn reads
--- "Вкл/выкл сворачивание списка" - so they are the screen's own answer to "what are my
--- options", which is the question a player who cannot see the glyphs has to ask out loud.
--- BoundEvent is the piece that names the button: it is the input event the game binds to
--- this prompt, and the binding table maps that to a pad button (§F13).
function W.prompts()
    local node = select(1, screenNode())
    if node == nil then Ext.Utils.Print("[load] no load screen") return nil end
    local out = {}
    Pad.walkFrom(node, function(o, depth)
        local p = A.props(o)
        local cls = select(1, A.splitToString(A.realType(o)))
        if not cls:find("LSButton", 1, true) and not cls:find("Toggle", 1, true) then return end
        local rec = { name = str(p.Name), class = cls, depth = depth,
                      visible = str(p.IsVisible), enabled = str(p.IsEnabled),
                      text = table.concat(texts(o, 6, 200), " | ") }
        for _, k in ipairs({ "BoundEvent", "Command", "CommandParameter", "SoundID",
                             "InputEvent", "Event", "ToolTip", "Tag" }) do
            if p[k] ~= nil then rec[k] = str(p[k]) end
        end
        out[#out + 1] = rec
    end, 2500)
    Ext.Utils.Print("[load] prompts: " .. #out .. " -> load_prompts.json")
    A.write("load_prompts", { count = #out, buttons = out })
    return out
end

--- The confirmation box, every property of every node.
---
--- Deleting a save raises `MessageBox_c` - a widget of its own over the screen, holding a
--- title and an ActionsList of buttons ("Да", "Нет"). Nothing in it reports IsFocused,
--- IsKeyboardFocused or IsSelected, so which button the player is about to press is not
--- readable the ordinary way, and on a destructive action that is the one thing that has to
--- be. This dumps the lot so the difference between the two buttons can be found by
--- comparing them.
function W.msgbox()
    local ws = soft(Pad.findWidgets) or {}
    local node = nil
    for i = 1, #ws do
        if ws[i].visible ~= false and str(ws[i].name):find("MessageBox", 1, true) then
            node = ws[i].node
        end
    end
    if node == nil then Ext.Utils.Print("[load] no message box up") return nil end

    local rows = {}
    Pad.walkFrom(node, function(o, depth, i)
        local p = A.props(o)
        local cls, label = A.splitToString(A.realType(o))
        local rec = { i = i, depth = depth, class = cls, name = str(p.Name),
                      label = str(label), props = {} }
        for k, v in pairs(p) do
            local t = type(v)
            if t == "boolean" or t == "number" or t == "string" then
                rec.props[tostring(k)] = str(v)
            end
        end
        rows[#rows + 1] = rec
    end, 400)
    Ext.Utils.Print("[load] msgbox: " .. #rows .. " nodes -> load_msgbox.json")
    A.write("load_msgbox", { count = #rows, rows = rows })
    return #rows
end

-- one save row, in full ----------------------------------------------------------------

--- Everything about the rows of an expanded group.
---
--- The tree dump says the template is there and empty: `ListBoxItem > ContentControl
--- ControlRoot > Grid GridRoot > Title` with two Runs named TitleName and Location, and not
--- one of them carries a string. So the caption of a save is not in the visual tree the way a
--- button's is - it is bound to the item's data. This asks the other side: what the row's
--- DataContext holds, and what the ListBox itself offers as items.
function W.rowProbe()
    local node = select(1, screenNode())
    if node == nil then Ext.Utils.Print("[load] no load screen") return nil end

    local list, expander = nil, nil
    Pad.walkFrom(node, function(o)
        local p = A.props(o)
        if p.IsExpanded == true then expander = o end
        if expander ~= nil and str(p.Name) == "PlaythroughSavegames" then list = o return true end
    end, 2500)
    if list == nil then
        Ext.Utils.Print("[load] no expanded group - open one first")
        return nil
    end

    local out = { rows = {}, list = {} }

    -- The list control itself: how many items it thinks it has, and where they come from.
    local lp = A.props(list)
    for k, v in pairs(lp) do out.list[tostring(k)] = str(v) end
    for _, name in ipairs({ "Items", "ItemsSource", "SelectedItem", "SelectedIndex" }) do
        if lp[name] ~= nil then
            local live = soft(function() return list:GetProperty(name) end)
            local rec = { kind = type(live), str = str(live),
                          type = str(soft(Ext.Types.GetObjectType, live)) }
            if type(live) == "userdata" then
                local ip = soft(function() return live:GetAllProperties() end)
                if type(ip) == "table" then
                    rec.props = {}
                    for k, v in pairs(ip) do rec.props[tostring(k)] = str(v) end
                end
                rec.count = soft(function() return #live end)
            end
            out.list["live:" .. name] = rec
        end
    end

    -- Every row: its own state, its data, and the text nodes inside it.
    local kids, kn = A.kids(list)
    local i = 0
    local function scanRow(o, depth, rec)
        if o == nil or depth > 8 then return end
        local p = A.props(o)
        local cls, label = A.splitToString(A.realType(o))
        local nm = str(p.Name)
        if nm ~= "nil" or A.looksLikeText(label) or A.looksLikeText(p.Text) then
            rec.nodes[#rec.nodes + 1] = string.rep(" ", depth) .. cls .. "/" .. nm ..
                " text=" .. str(p.Text) .. " label=" .. str(label) ..
                " dc=" .. str(soft(Ext.Types.GetObjectType, p.DataContext))
        end
        local ch, cn = A.kids(o)
        for k = 1, cn do scanRow(ch[k], depth + 1, rec) end
    end

    for k = 1, kn do
        local o = kids[k]
        local p = A.props(o)
        i = i + 1
        local rec = { i = i, class = select(1, A.splitToString(A.realType(o))),
                      name = str(p.Name), selected = str(p.IsSelected),
                      focused = str(p.IsFocused), focusable = str(p.Focusable),
                      alt = str(p.AlternationIndex), visible = str(p.IsVisible),
                      nodes = {}, texts = texts(o, 10, 200) }
        -- The row's model. A Noesis item template binds to whatever sits here, so if the
        -- caption is anywhere reachable at all, it is in this object.
        local dc = p.DataContext
        rec.dcType = str(soft(Ext.Types.GetObjectType, dc))
        if type(dc) == "userdata" then
            local dp = soft(function() return dc:GetAllProperties() end)
            if type(dp) == "table" then
                rec.dc = {}
                for kk, vv in pairs(dp) do rec.dc[tostring(kk)] = str(vv) end
            end
        end
        if i <= 3 then scanRow(o, 0, rec) end
        out.rows[#out.rows + 1] = rec
    end

    Ext.Utils.Print("[load] rowProbe: " .. #out.rows .. " rows -> load_rows.json")
    A.write("load_rows", out)
    return out
end

local function pass()
    local t0 = soft(Ext.Utils.MicrosecTime) or 0
    local node, name, names = screenNode()
    if node == nil then
        local wsig = "none:" .. table.concat(names, ",")
        if wsig ~= W.sig then
            W.sig = wsig
            W.entries[#W.entries + 1] = { widgets = names, note = "no load/save screen" }
        end
        return
    end

    local focus = soft(Pad.widgetFocus, node)
    local focusName, focusText, chain = nil, nil, nil
    if focus ~= nil then
        local fp = A.props(focus)
        focusName = select(1, A.splitToString(A.realType(focus))) .. "/" .. str(fp.Name) ..
                    (fp.AlternationIndex ~= nil and (" alt=" .. str(fp.AlternationIndex)) or "")
        focusText = select(1, A.describe(focus))
        if soft(Pad.pathTo, node, focus) then
            chain = {}
            local path = Pad.focusPath or {}
            for i = math.max(1, #path - 8), #path do
                local o = path[i]
                local p = A.props(o)
                local parts = texts(o, 8, 200)
                chain[#chain + 1] = i .. " " .. select(1, A.splitToString(A.realType(o))) ..
                    "/" .. str(p.Name) ..
                    (p.AlternationIndex ~= nil and (" alt=" .. str(p.AlternationIndex)) or "") ..
                    (p.IsExpanded ~= nil and (" exp=" .. str(p.IsExpanded)) or "") ..
                    " [" .. table.concat(parts, " | ") .. "]"
            end
        end
    end

    local mk = marked(node)
    local sig = table.concat(names, ",") .. "|" .. tostring(focusName) .. "|" ..
                tostring(focusText) .. "|" .. table.concat(mk, ";")
    if sig == W.sig then return end
    W.sig = sig

    W.entries[#W.entries + 1] = {
        widgets = names, screen = name,
        focusName = focusName, focusText = focusText, chain = chain,
        marked = mk, rows = rows(node), all = texts(node, 60, 2500),
        us = (soft(Ext.Utils.MicrosecTime) or 0) - t0,
    }
    if #W.entries > 60 then table.remove(W.entries, 1) end
    A.write("loadwatch", { count = #W.entries, entries = W.entries })
end

function W.tick()
    W.ticks = W.ticks + 1
    if W.ticks % 15 ~= 0 then return end
    soft(pass)
end

function W.start()
    W.stop()
    W.id = Ext.Events.Tick:Subscribe(W.tick)
    _G.A11Y_LOADWATCH = W.id
    Ext.Utils.Print("[load] watcher running")
    return true
end

function W.stop()
    local id = W.id or _G.A11Y_LOADWATCH
    if id ~= nil then soft(function() Ext.Events.Tick:Unsubscribe(id) end) end
    W.id, _G.A11Y_LOADWATCH = nil, nil
end

Ext.Utils.Print("[load] probe-load ready: PL.dump('tag') / PL.start() / PL.stop()")
return W
