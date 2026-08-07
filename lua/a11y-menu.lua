-- Accessibility layer for the BG3 main menu: find the entries, walk them, speak them.
--
-- Pushed into a running game by tools/push-lua.ps1, which copies this file into the
-- Script Extender folder and runs one console line:
--     A11y = load(Ext.IO.LoadFile("A11y/a11y-menu.lua"))()
--
-- Speech leaves through the file bridge measured in probe E6 (0.49 ms median write)
-- and is voiced by tools/speak.ps1 via prism.dll -> NVDA.
--
-- Rules carried over from the §9 experiments:
--   * never GetProperty() a guessed name — a miss throws and logs, 150x the cost (E5)
--   * input events live under their bare names, NOT the EclLua* ones in the IDE
--     helpers, and Subscribe() returns nil instead of throwing when the name is
--     wrong (finding §А) — so every subscription is checked
--   * VisualChild/Child are both walked, deduplicated by identity (E4)

local M = {}
M.DIR = "A11y/"

-- The layer's own words are written in English and said in the language the game is being
-- played in. `T` is the whole of that at a call site, and it is deliberately harmless: with
-- no a11y-lang loaded it is the identity function, so every module here still runs on its own
-- at the console and simply speaks English.
local Lang = _G.Lang
local T = (Lang ~= nil and Lang.t) or function(s) return s end
M.Lang = Lang
M.T = T

-- helpers ---------------------------------------------------------------------

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

M.try, M.soft = try, soft

local function plain(v, d)
    d = d or 0
    local t = type(v)
    if t == "nil" or t == "boolean" or t == "number" or t == "string" then return v end
    if d > 3 then return "<depth>" end
    if t == "table" then
        local o, n = {}, 0
        for k, vv in pairs(v) do
            n = n + 1
            -- 200 was too low and silently cost real data: a structural dump of 1600 nodes
            -- arrived as 201 rows plus a "truncated" marker, and the analysis that followed
            -- was drawn from an eighth of the screen without anything saying so.
            if n > 5000 then o["..."] = "truncated" break end
            o[tostring(k)] = plain(vv, d + 1)
        end
        return o
    end
    return tostring(v)
end

function M.write(name, data)
    local body = soft(Ext.Json.Stringify, plain(data), { Beautify = true, MaxDepth = 20 })
    Ext.IO.SaveFile(M.DIR .. name .. ".json", body or "{}")
    _P("[a11y] wrote " .. name .. ".json")
end

-- speech bridge ---------------------------------------------------------------

M.seq = 0

--- Hand one utterance to the companion. interrupt=false queues behind current speech.
function M.say(text, interrupt)
    if type(text) ~= "string" or text == "" then return nil end
    M.seq = M.seq + 1
    local flag = (interrupt == false) and "0" or "1"
    soft(Ext.IO.SaveFile, M.DIR .. "speech.txt", M.seq .. "|" .. flag .. "|" .. text)
    return M.seq
end

-- tree ------------------------------------------------------------------------

local function realType(o) return soft(function() return o:ToString() end) or "?" end
M.realType = realType

--- The one sanctioned way to read node state: one call, then read the table.
local function props(o)
    local p = soft(function() return o:GetAllProperties() end)
    if type(p) == "table" then return p end
    return {}
end
M.props = props

local function kids(o)
    local out, n = {}, 0
    local vc = soft(function() return o.VisualChildrenCount end)
    if type(vc) == "number" then
        for i = 0, vc do
            local c = soft(function() return o:VisualChild(i) end)
            if c ~= nil then n = n + 1 out[n] = c end
        end
    end
    local cc = soft(function() return o.ChildrenCount end)
    if type(cc) == "number" then
        for i = 0, cc do
            local c = soft(function() return o:Child(i) end)
            if c ~= nil then n = n + 1 out[n] = c end
        end
    end
    return out, n
end
M.kids = kids

--- Depth-first walk of the whole UI, visiting each node once.
--- Deduplication matters: the visual and logical trees overlap heavily, and
--- without it the walk inflates (suspected cause of the missing dialogue text in E4).
--- A visit that returns a truthy value stops the walk. Searching for a single node (the
--- focused one, usually found early) then costs a fraction of a full traversal, which
--- matters because every node read logs warnings for properties the binding cannot fetch.
function M.walk(visit, maxNodes)
    local root = soft(Ext.ClientUI.GetRoot)
    if root == nil then return 0, "no root" end
    maxNodes = maxNodes or 8000
    local n, seen, stop = 0, {}, false
    local function rec(o, depth)
        if stop or o == nil or n >= maxNodes or depth > 40 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        if visit(o, depth, n) then stop = true return end
        local ch, cn = kids(o)
        for i = 1, cn do
            if stop then return end
            rec(ch[i], depth + 1)
        end
    end
    rec(root, 0)
    return n, stop
end

-- menu entries ----------------------------------------------------------------

-- Larian's own control classes; ls.LSButton is what the main menu is built from (E4).
local ITEM_TYPES = { "LSButton", "LSMenuButton", "LSListBoxItem", "LSCheckBox",
                     "LSComboBox", "LSRadioButton", "LSSlider" }

--- ToString() gives "ls.LSButton: Продолжить" — class and label in one call (E4).
local function splitToString(s)
    local cls, label = s:match("^([%w%.%_]+):%s*(.*)$")
    if cls == nil then return s, nil end
    if label == "" then label = nil end
    return cls, label
end
M.splitToString = splitToString

local function isItemType(cls)
    for i = 1, #ITEM_TYPES do
        if cls:find(ITEM_TYPES[i], 1, true) then return true end
    end
    return false
end

--- Ordered list of actionable entries currently on screen. Nodes are kept so we
--- can act on them; the walk order is the visual order of the tree.
function M.collect()
    local items = {}
    M.walk(function(o, depth, i)
        local rt = realType(o)
        local cls, label = splitToString(rt)
        if not isItemType(cls) then return end
        local p = props(o)
        if p.IsVisible == false then return end
        if label == nil and type(p.Text) == "string" and p.Text ~= "" then label = p.Text end
        if label == nil then return end
        items[#items + 1] = {
            node = o, label = label, class = cls, depth = depth, order = i,
            enabled = p.IsEnabled, visible = p.IsVisible,
            -- Name is a stable id (ContinueButton, CloseBtn) where the label is
            -- localised; BoundEvent names the input event the game itself binds to
            -- this button, which doubles as its role (UICancel = back, UIAccept = ok).
            name = p.Name, boundEvent = p.BoundEvent,
            commandParameter = p.CommandParameter, hasCommand = p.Command ~= nil,
        }
    end)
    M.items = items
    return items
end

--- Human-readable dump of the entries, for the console and for JSON.
function M.list()
    local items = M.collect()
    _P("[a11y] " .. #items .. " entries")
    local flat = {}
    for i, it in ipairs(items) do
        local line = i .. ". " .. it.label .. "  [" .. it.class .. " d" .. it.depth ..
                     " enabled=" .. tostring(it.enabled) .. "]"
        _P("  " .. line)
        flat[i] = { i = i, label = it.label, class = it.class, depth = it.depth,
                    order = it.order, enabled = it.enabled, visible = it.visible,
                    name = it.name, boundEvent = it.boundEvent,
                    hasCommand = it.hasCommand, commandParameter = it.commandParameter }
    end
    M.write("menu_items", { state = tostring(soft(Ext.Utils.GetGameState)),
                            count = #items, items = flat })
    return #items
end

-- recon: does the game have a focus concept we can mirror? -------------------

local FOCUS_HINTS = { "focus", "select", "highlight", "mouseover", "ispressed",
                      "isactive", "checked", "current" }

--- Every property that is currently true and whose name smells like focus or
--- selection, anywhere in the tree. If the menu tracks a focused entry, it shows here.
function M.focusScan()
    local hits = {}
    local visited = M.walk(function(o, depth, i)
        local p = props(o)
        for k, v in pairs(p) do
            if v == true then
                local lk = tostring(k):lower()
                for j = 1, #FOCUS_HINTS do
                    if lk:find(FOCUS_HINTS[j], 1, true) then
                        local cls, label = splitToString(realType(o))
                        hits[#hits + 1] = { i = i, depth = depth, prop = tostring(k),
                                            class = cls, label = label }
                        break
                    end
                end
            end
        end
    end)
    _P("[a11y] focusScan: " .. #hits .. " truthy focus-ish props over " .. visited .. " nodes")
    for i = 1, math.min(#hits, 25) do
        local h = hits[i]
        _P("  " .. h.prop .. " on " .. h.class .. " " .. tostring(h.label))
    end
    M.write("focus_scan", { visited = visited, count = #hits, hits = hits })
    return hits
end

--- Full property and method surface of one entry — this is what decides how we
--- activate it (a Focus() we can call, or geometry we can click).
local ZERO_ARG_METHODS = { "Focus", "BringIntoView", "GetVisualOffset", "GetDesiredSize",
                           "GetRenderSize", "GetActualSize", "CaptureMouse", "ReleaseMouseCapture",
                           "GetVisualParent", "UpdateLayout", "InvalidateVisual" }

function M.probeNode(index)
    local items = M.items or M.collect()
    local it = items[index or 1]
    if it == nil then _P("[a11y] no entry " .. tostring(index)) return nil end

    local p = props(it.node)
    local values, names = {}, {}
    for k, v in pairs(p) do
        names[#names + 1] = tostring(k)
        values[tostring(k)] = plain(v)
    end
    table.sort(names)

    local methods = {}
    for _, name in ipairs(ZERO_ARG_METHODS) do
        local r = try(function() return it.node[name](it.node) end)
        methods[name] = { ok = r.ok, value = plain(r.value), err = r.error }
    end

    local out = { index = index or 1, label = it.label, class = it.class,
                  propNames = names, values = values, methods = methods }
    _P("[a11y] probeNode " .. (index or 1) .. " '" .. it.label .. "' — " ..
       #names .. " props; see node_probe.json")
    M.write("node_probe", out)
    return out
end

--- Cheap fingerprint of the current screen. Comparing two of these is how we tell
--- whether an activation attempt actually did anything — the entry list alone is not
--- enough, since a panel can open without removing what was behind it.
function M.summary(tag)
    local total, buttons, names, labels = 0, 0, {}, {}
    total = M.walk(function(o, depth, i)
        local rt = realType(o)
        local cls, label = splitToString(rt)
        if cls:find("LSButton", 1, true) then buttons = buttons + 1 end
        local p = props(o)
        local nm = p.Name
        if type(nm) == "string" and nm ~= "" then names[#names + 1] = nm end
        if label and label ~= "" and #labels < 60 then labels[#labels + 1] = label end
    end)
    table.sort(names)
    local out = { tag = tag or "screen", nodes = total, buttons = buttons,
                  namedCount = #names, names = names, labels = labels,
                  state = tostring(soft(Ext.Utils.GetGameState)) }
    _P("[a11y] summary " .. tostring(tag) .. ": " .. total .. " nodes, " ..
       buttons .. " buttons, " .. #names .. " named")
    M.write("summary_" .. tostring(tag or "screen"), out)
    return out
end

--- Every readable string in the tree, uncapped, with where it sits.
---
--- Used to answer one question: when a sub-screen is open, is its content in the tree
--- reachable from GetRoot() at all? If the text is absent, the panel is a separate Noesis
--- view and no amount of focus watching on this root will ever see it - which is the same
--- wall E4 hit with dialogue text.
function M.textDump(tag)
    local rows = {}
    local total = M.walk(function(o, depth, i)
        local cls, label = splitToString(realType(o))
        local p = props(o)
        -- M.looksLikeText, not the local: that one is declared further down the file and a
        -- function defined up here cannot see it lexically.
        local isText = M.looksLikeText
        local picked = nil
        if isText(p.Text) then picked = p.Text
        elseif isText(label) then picked = label end
        if picked ~= nil then
            rows[#rows + 1] = { i = i, depth = depth, class = cls, text = picked,
                                name = p.Name, focused = p.IsFocused,
                                visible = p.IsVisible }
        end
    end)
    _P("[a11y] textDump " .. tostring(tag) .. ": " .. #rows .. " strings over " ..
       total .. " nodes")
    M.lastRows = rows
    M.write("text_" .. tostring(tag or "dump"),
            { tag = tag, nodes = total, count = #rows, rows = rows })
    return #rows, rows
end

--- E3 concluded BG3 has no ICommand anywhere. GetAllProperties on an ls.LSButton
--- says otherwise: Command, CommandBindings and InputBindings are all present and
--- non-null. If the command can be invoked, a menu entry can be activated directly —
--- no synthetic mouse, no gamepad mode. Inspection only: CanExecute is side-effect
--- free by contract, Execute is left to M.fire() so it is never a surprise.
function M.probeCommand(index)
    local items = M.items or M.collect()
    local it = items[index or 1]
    if it == nil then _P("[a11y] no entry " .. tostring(index)) return nil end

    local p = props(it.node)
    local out = { index = index or 1, label = it.label, name = tostring(p.Name) }
    local cmd = p.Command
    out.hasCommand = cmd ~= nil
    if cmd == nil then
        _P("[a11y] entry " .. out.index .. " has no Command")
        M.write("command_probe", out)
        return out
    end

    out.commandType = tostring(soft(Ext.Types.GetObjectType, cmd))
    out.commandStr = soft(function() return cmd:ToString() end)

    -- Some entries execute without error yet do nothing, so record everything on the
    -- button that could carry the missing piece: a parameter, a target, a binding.
    out.buttonProps = {}
    for k, v in pairs(p) do
        local lk = tostring(k):lower()
        if lk:find("command") or lk:find("param") or lk:find("target") or
           lk:find("click") or lk:find("event") or lk == "name" or lk == "datacontext" or
           lk == "isenabled" or lk == "isvisible" or lk == "soundid" then
            out.buttonProps[tostring(k)] = plain(v)
        end
    end
    out.dataContextType = tostring(soft(Ext.Types.GetObjectType, p.DataContext))
    out.dataContextStr = soft(function() return p.DataContext:ToString() end)
    local dcp = soft(function() return p.DataContext:GetAllProperties() end)
    if type(dcp) == "table" then
        out.dataContextProps = {}
        for k, v in pairs(dcp) do out.dataContextProps[tostring(k)] = plain(v) end
    end
    local cp = soft(function() return cmd:GetAllProperties() end)
    if type(cp) == "table" then
        out.commandProps = {}
        for k, v in pairs(cp) do out.commandProps[tostring(k)] = plain(v) end
    end

    -- Which of these are bound at all? The binding resolves obj:X() through a
    -- property lookup, so an unbound name fails with "Property does not exist".
    out.calls = {}
    local dc = p.DataContext
    local forms = {
        { "CanExecute()",   function() return cmd:CanExecute() end },
        { "CanExecute(nil)", function() return cmd:CanExecute(nil) end },
        { "CanExecute(dc)", function() return cmd:CanExecute(dc) end },
    }
    for _, f in ipairs(forms) do
        local r = try(f[2])
        out.calls[f[1]] = { ok = r.ok, value = plain(r.value), err = r.error }
    end

    _P("[a11y] command on '" .. it.label .. "' type=" .. tostring(out.commandType))
    for k, v in pairs(out.calls) do
        _P("   " .. k .. " ok=" .. tostring(v.ok) .. " value=" .. tostring(v.value))
    end
    M.write("command_probe", out)
    return out
end

--- Activate an entry through its command.
---
--- The argument matters and is easy to get wrong: Execute() takes the button's own
--- CommandParameter (a string like "CloseWidget"), not its DataContext. Passing the
--- DataContext returns cleanly and does nothing at all — which is how "Отменить" and
--- "Параметры" first looked like proof that commands were inert.
function M.fire(index)
    local items = M.items or M.collect()
    local it = items[index]
    if it == nil then _P("[a11y] no entry " .. tostring(index)) return false end
    local p = props(it.node)
    local cmd = p.Command
    if cmd == nil then
        -- The same node yielded a Command when probed from the console, so record what
        -- the property read actually returns here rather than guessing at the cause.
        local names = {}
        for k in pairs(p) do names[#names + 1] = tostring(k) end
        table.sort(names)
        local raw = try(function() return it.node:GetAllProperties() end)
        M.write("fire_fail", {
            index = index, label = it.label,
            toString = realType(it.node),
            propCount = #names, propNames = names,
            rawOk = raw.ok, rawErr = raw.error,
            rawType = type(raw.value),
            collected = { name = tostring(it.name), boundEvent = tostring(it.boundEvent),
                          hasCommand = it.hasCommand, enabled = tostring(it.enabled) },
            rawKeys = M.rawKeys,
        })
        _P("[a11y] '" .. it.label .. "' has no Command (" .. #names ..
           " props, rawOk=" .. tostring(raw.ok) .. ") -> fire_fail.json")
        return false
    end

    -- Execute wants a live Noesis object. GetAllProperties flattens CommandParameter
    -- to a string ("CloseWidget"), which Execute rejects outright, so the object has
    -- to come from GetProperty. Guessing a property name is normally banned (E5: a
    -- miss throws and logs), but here GetAllProperties already proved the name exists.
    local forms = {}
    if p.CommandParameter ~= nil then
        local live = soft(function() return it.node:GetProperty("CommandParameter") end)
        if live ~= nil then forms[#forms + 1] = { "CommandParameter", live } end
    end
    forms[#forms + 1] = { "nil", nil }
    forms[#forms + 1] = { "DataContext", p.DataContext }

    for _, f in ipairs(forms) do
        local r = try(function() return cmd:Execute(f[2]) end)
        _P("[a11y] fire '" .. it.label .. "' via " .. f[1] ..
           " -> ok=" .. tostring(r.ok) .. " err=" .. tostring(r.error))
        if r.ok then return true, f[1] end
    end
    return false
end

--- The 323 named input events (E11), filtered. Tells us whether the game has
--- UIUp/UIDown/UIAccept style navigation we could drive instead of synthesising clicks.
function M.inputEvents(pattern)
    local im = soft(Ext.ClientInput.GetInputManager)
    if im == nil then _P("[a11y] no input manager") return nil end
    local defs = soft(function() return im.InputDefinitions end)
    if defs == nil then _P("[a11y] no InputDefinitions field") return nil end

    local all, matched = {}, {}
    soft(function()
        for id, d in pairs(defs) do
            local name = soft(function() return tostring(d.EventName) end)
            if name then
                local e = { id = tostring(id), name = name,
                            category = soft(function() return tostring(d.CategoryName) end) }
                all[#all + 1] = e
                if pattern == nil or name:lower():find(pattern:lower()) then
                    matched[#matched + 1] = e
                end
            end
        end
    end)
    table.sort(matched, function(a, b) return a.name < b.name end)
    _P("[a11y] input events: " .. #all .. " total, " .. #matched .. " matching " ..
       tostring(pattern))
    for i = 1, math.min(#matched, 40) do
        _P("  " .. matched[i].name .. " (id " .. matched[i].id .. ")")
    end
    M.write("input_events", { total = #all, pattern = pattern, matched = matched, all = all })
    return matched
end

--- Can we aim the game's own cursor from Lua, and does the tree notice?
---
--- This decides whether the layer can drive a real pointer instead of a private cursor.
--- A real pointer would fix three things at once: entries whose CommandParameter cannot
--- be marshalled (Параметры, Авторы, Менеджер модов), list rows that need selecting
--- rather than invoking (the campaign rows), and the missing native hover feedback.
--- E2 proved WindowCursorPos is writable in a loaded session; the question is the menu.
function M.hoverProbe(x, y)
    local ph = soft(Ext.ClientUI.GetPickingHelper, 1)
    if ph == nil then
        _P("[a11y] hoverProbe: no picking helper on this screen")
        return nil
    end
    local before = soft(function() return tostring(ph.WindowCursorPos) end)
    local wrote = try(function() ph.WindowCursorPos = { x, y } end)
    if not wrote.ok then
        wrote = try(function() ph.WindowCursorPos = { x = x, y = y } end)
    end
    local after = soft(function() return tostring(ph.WindowCursorPos) end)

    local hovered = {}
    local items = M.collect()
    for i = 1, #items do
        local p = props(items[i].node)
        if p.IsMouseOver == true then
            hovered[#hovered + 1] = i .. ":" .. items[i].label
        end
    end
    _P("[a11y] hover(" .. x .. "," .. y .. ") wrote=" .. tostring(wrote.ok) ..
       " pos " .. tostring(before) .. " -> " .. tostring(after) ..
       " hovered=[" .. table.concat(hovered, ", ") .. "]")
    return hovered
end

--- Everything the input manager exposes.
---
--- Looking for the current input mode: the game rebuilds its UI for a controller and
--- only then maintains a real focus, which would remove the need to fake a pointer or
--- marshal a CommandParameter. If the mode is settable from here, no virtual gamepad
--- driver is needed at all.
function M.inputManagerDump()
    local im = soft(Ext.ClientInput.GetInputManager)
    if im == nil then _P("[a11y] no input manager") return nil end

    local out = { fields = {}, enumerated = {} }
    soft(function()
        for k, v in pairs(im) do
            local key = tostring(k)
            out.enumerated[#out.enumerated + 1] = key
            local t = type(v)
            if t == "boolean" or t == "number" or t == "string" then
                out.fields[key] = v
            else
                out.fields[key] = t .. ": " .. tostring(soft(function() return tostring(v) end))
            end
        end
    end)
    table.sort(out.enumerated)

    -- pairs() comes back empty on some proxied objects, so try likely names directly.
    out.probed = {}
    for _, n in ipairs({ "InputMode", "CurrentInputMode", "LastInputDevice", "InputDevice",
                         "IsControllerMode", "ControllerMode", "UsingController",
                         "GamepadMode", "ActiveDevice", "PlayerDevices", "DeviceMap",
                         "InputDefinitions", "InputScheme", "RawInputMode" }) do
        local r = try(function() return im[n] end)
        if r.ok and r.value ~= nil then
            out.probed[n] = type(r.value) .. ": " ..
                            tostring(soft(function() return tostring(r.value) end))
        end
    end

    _P("[a11y] input manager: " .. #out.enumerated .. " enumerable fields")
    for k, v in pairs(out.probed) do _P("   " .. k .. " = " .. tostring(v)) end
    M.write("input_manager", out)
    return out
end

--- Reflect over the input structures that look like a way into controller mode.
---
--- InputInjects and DeviceEventInjects are the engine's own injection queues; if an
--- entry can be appended, controller input can be synthesised without a virtual pad
--- driver. ControllerAllowKeyboardMouseInput looks like the flag that keeps the
--- controller UI up while still accepting the keyboard.
local function typeMembers(name)
    local ti = soft(Ext.Types.GetTypeInfo, name)
    if ti == nil then return nil end
    local out = { kind = tostring(soft(function() return tostring(ti.Kind) end)) }
    local members = {}
    soft(function()
        for k, v in pairs(ti.Members) do
            local tn = soft(function() return tostring(v.TypeName) end)
            if tn == nil then tn = soft(function() return tostring(v) end) end
            members[tostring(k)] = tn
        end
    end)
    out.members = members
    return out
end

function M.inputTypes()
    local out = { types = {} }
    for _, n in ipairs({ "input::InjectInputData", "input::InjectDeviceEvent",
                         "input::InputDevice", "input::InputScheme",
                         "input::FireEventDesc", "input::InputRaw",
                         "input::InputValueSet", "input::InputEventDesc" }) do
        out.types[n] = typeMembers(n)
    end

    local im = soft(Ext.ClientInput.GetInputManager)
    if im ~= nil then
        -- Which devices does the game currently know about, and what is each player on?
        out.devices = {}
        soft(function()
            for i, dev in ipairs(im.PerDeviceData) do
                local d = { i = i }
                soft(function()
                    for k, v in pairs(dev) do
                        local t = type(v)
                        d[tostring(k)] = (t == "boolean" or t == "number" or t == "string")
                            and v or (t .. ":" .. tostring(soft(function() return tostring(v) end)))
                    end
                end)
                out.devices[#out.devices + 1] = d
            end
        end)
        out.playerDevices = {}
        soft(function()
            for i, v in ipairs(im.PlayerDevices) do out.playerDevices[i] = v end
        end)
        out.playerDeviceIDs = {}
        soft(function()
            for i, v in ipairs(im.PlayerDeviceIDs) do out.playerDeviceIDs[i] = v end
        end)
        out.injectQueueLengths = {
            inputInjects = soft(function() return #im.InputInjects end),
            deviceEventInjects = soft(function() return #im.DeviceEventInjects end),
            events = soft(function() return #im.Events end),
        }

        -- Is the controller/KBM coexistence flag writable at all?
        out.flagBefore = soft(function() return im.ControllerAllowKeyboardMouseInput end)
        local w = try(function() im.ControllerAllowKeyboardMouseInput = true end)
        out.flagWriteOk, out.flagWriteErr = w.ok, w.error
        out.flagAfter = soft(function() return im.ControllerAllowKeyboardMouseInput end)
        -- Put it back; this probe must not change how the game behaves.
        soft(function() im.ControllerAllowKeyboardMouseInput = out.flagBefore end)

        out.scheme = {}
        soft(function()
            for k, v in pairs(im.InputScheme) do
                local t = type(v)
                out.scheme[tostring(k)] = (t == "boolean" or t == "number" or t == "string")
                    and v or (t .. ":" .. tostring(soft(function() return tostring(v) end)))
            end
        end)
    end

    _P("[a11y] inputTypes: flag write ok=" .. tostring(out.flagWriteOk) ..
       " before=" .. tostring(out.flagBefore) .. " after=" .. tostring(out.flagAfter))
    _P("[a11y] devices=" .. tostring(out.devices and #out.devices) ..
       " playerDevices=" .. tostring(out.playerDevices and #out.playerDevices))
    M.write("input_types", out)
    return out
end

-- Named input events, from the manager's own registry (E11). The engine consumes
-- DeviceEventInjects each frame, so a successful append shows up as behaviour, not as a
-- lasting queue length.
M.EVENT = {
    UIUp = 245, UIDown = 246, UILeft = 243, UIRight = 244,
    UIAccept = 223, UICancel = 225, UIEnter = 83, UIHome = 89, UIEnd = 90,
}

--- What is actually bound to what.
---
--- Injected keyboard input reaches the game - InjectKeyPress("ESCAPE") raised UICancel
--- and closed a panel. So the arrows failing to navigate is a binding gap, not an
--- injection one: UIUp/UIDown are wired to a controller, not to keys. If the binding
--- table is readable and writable, giving the keyboard those events is the cleanest fix
--- available, because everything downstream stays the game's own code.
function M.bindings(eventFilter)
    local im = soft(Ext.ClientInput.GetInputManager)
    if im == nil then return nil end
    local scheme = soft(function() return im.InputScheme end)
    if scheme == nil then _P("[a11y] no InputScheme") return nil end

    local out = { players = {}, rawToBinding = {}, deviceLists = {} }

    -- InputBindings is per player: map of event id -> list of bindings.
    soft(function()
        for pi, byEvent in ipairs(scheme.InputBindings) do
            local rec = { player = pi, events = {}, count = 0 }
            soft(function()
                for eventId, list in pairs(byEvent) do
                    rec.count = rec.count + 1
                    local id = tonumber(tostring(eventId)) or tostring(eventId)
                    if eventFilter == nil or id == eventFilter then
                        local binds = {}
                        soft(function()
                            for bi, b in ipairs(list) do
                                local one = {}
                                soft(function()
                                    for k, v in pairs(b) do
                                        one[tostring(k)] = tostring(soft(function() return tostring(v) end))
                                    end
                                end)
                                binds[bi] = one
                            end
                        end)
                        rec.events[tostring(id)] = binds
                    end
                end
            end)
            out.players[#out.players + 1] = rec
        end
    end)

    soft(function()
        for i, m in ipairs(scheme.RawToBinding) do
            if i > 40 then break end
            local one = {}
            soft(function()
                for k, v in pairs(m) do
                    one[tostring(k)] = tostring(soft(function() return tostring(v) end))
                end
            end)
            out.rawToBinding[i] = one
        end
    end)

    soft(function()
        for i, lst in ipairs(scheme.DeviceLists) do
            local ids = {}
            soft(function() for j, v in ipairs(lst) do ids[j] = v end end)
            out.deviceLists[i] = ids
        end
    end)

    for _, p in ipairs(out.players) do
        _P("[a11y] player " .. p.player .. ": " .. p.count .. " bound events")
    end
    _P("[a11y] rawToBinding sampled=" .. #out.rawToBinding ..
       " deviceLists=" .. #out.deviceLists)
    M.write("bindings", out)
    return out
end

--- Find the real injection structures by name.
---
--- InjectDeviceEvent is only {DeviceId, EventId} with no value, which reads more like a
--- device-level event than an input one - and injecting it moves nothing. FireEventDesc
--- by contrast carries an input::InputEvent, i.e. a value. So enumerate the type registry
--- and dump every injection-shaped type properly instead of guessing names.
function M.injectTypes()
    local all = soft(Ext.Types.GetAllTypes)
    if all == nil then _P("[a11y] GetAllTypes unavailable") return nil end

    local names = {}
    soft(function()
        for k, v in pairs(all) do
            local n = type(k) == "string" and k or tostring(v)
            if n:find("nject") or n:find("InputEvent") or n:find("InputValue") or
               n:find("InputBinding") then
                names[#names + 1] = n
            end
        end
    end)
    table.sort(names)

    local out = { matched = names, types = {} }
    for _, n in ipairs(names) do
        local ti = soft(Ext.Types.GetTypeInfo, n)
        if ti ~= nil then
            local rec = { kind = tostring(soft(function() return tostring(ti.Kind) end)),
                          members = {} }
            soft(function()
                for mk, mv in pairs(ti.Members) do
                    rec.members[tostring(mk)] =
                        tostring(soft(function() return tostring(mv.TypeName) end))
                end
            end)
            out.types[n] = rec
        end
    end

    _P("[a11y] injection-shaped types: " .. #names)
    for _, n in ipairs(names) do _P("   " .. n) end
    M.write("inject_types", out)
    return out
end

--- The one focused element, in one line.
---
--- BG3 does keep a real Noesis keyboard focus even with mouse and keyboard: the window
--- taking focus puts IsFocused on the first entry. Nothing in mouse mode ever moves it,
--- which is the gap the layer has to fill.
function M.focusNow()
    local found = nil
    M.walk(function(o, depth, i)
        if found ~= nil then return end
        local p = props(o)
        if p.IsFocused == true then
            local cls, label = splitToString(realType(o))
            found = { class = cls, label = label, name = p.Name, index = i }
        end
    end)
    if found == nil then
        _P("[a11y] focus: none")
    else
        _P("[a11y] focus: " .. tostring(found.label) .. " [" .. tostring(found.name) ..
           " " .. tostring(found.class) .. "]")
    end
    return found
end

-- Step labels live here, keyed by ASCII, because console lines cannot carry non-ASCII:
-- the input buffer is ANSI and a Russian string literal breaks the Lua chunk outright.
-- This file is read as UTF-8 by Ext.IO.LoadFile, so the text is safe on this side.
M.STEP = {
    start    = T"start",
    tab1     = T"tab one",
    tab2     = T"tab two",
    shifttab = T"shift tab",
    down     = T"arrow down",
    up       = T"arrow up",
    evdown   = T"key down event",
    evpad    = T"pad down event",
    accept   = T"accept",
}

--- Speak where the focus is, so a test can be followed from inside the game.
--- Takes an ASCII step key, not the phrase itself.
function M.focusSay(step)
    local f = M.focusNow()
    local what = (f and f.label) or T"no focus"
    local prefix = step and (M.STEP[step] or tostring(step))
    M.say(prefix and (prefix .. ": " .. what) or what, true)
    return f
end

--- The queue is only drained when AllowDeviceEvents is set; with the flag clear an
--- appended entry simply sits there forever. Turning it on is part of arming injection.
function M.armInjection()
    local im = soft(Ext.ClientInput.GetInputManager)
    if im == nil then return false end
    local before = soft(function() return im.AllowDeviceEvents end)
    soft(function() im.AllowDeviceEvents = true end)
    local after = soft(function() return im.AllowDeviceEvents end)
    _P("[a11y] AllowDeviceEvents " .. tostring(before) .. " -> " .. tostring(after))
    return after == true
end

--- Fire a named input event as if a device had produced it.
---
--- This is the injection the API is missing: Ext.ClientInput has no InjectInputEvent,
--- but the input manager holds the queue the engine reads, and InjectDeviceEvent is
--- just {DeviceId, EventId}. If this lands, the game moves its own focus, plays its own
--- sounds and activates with its own parameters — no pointer, no virtual pad driver.
function M.injectEvent(deviceId, eventId)
    local im = soft(Ext.ClientInput.GetInputManager)
    if im == nil then _P("[a11y] no input manager") return false end
    local entry = { DeviceId = deviceId, EventId = eventId }

    local forms = {
        { "append", function()
            local a = im.DeviceEventInjects
            a[#a + 1] = entry
        end },
        { "slot1", function() im.DeviceEventInjects[1] = entry end },
        { "replace", function() im.DeviceEventInjects = { entry } end },
    }
    for _, f in ipairs(forms) do
        local r = try(f[2])
        local len = soft(function() return #im.DeviceEventInjects end)
        _P("[a11y] inject dev=" .. tostring(deviceId) .. " ev=" .. tostring(eventId) ..
           " via " .. f[1] .. " ok=" .. tostring(r.ok) ..
           " queue=" .. tostring(len) .. " err=" .. tostring(r.error))
        if r.ok then return true, f[1] end
    end
    return false
end

--- Which entries does the game consider hovered right now?
---
--- IsMouseOver tracks the real OS pointer — writing the picking helper's WindowCursorPos
--- does not move it (that aims world picking, not UI hit-testing). So this is the oracle:
--- something outside the game moves the real pointer, and this reports where it landed.
function M.hovered()
    local items = M.collect()
    local out = {}
    for i = 1, #items do
        local p = props(items[i].node)
        if p.IsMouseOver == true then
            out[#out + 1] = { index = i, label = items[i].label, name = items[i].name }
        end
    end
    return out, items
end

M.hoverMap = {}

--- Record what is under the pointer and tag it with the coordinate it was put at.
--- Driven from outside in a loop, this maps screen positions to menu entries without
--- any geometry from Noesis, which exposes sizes but no positions.
function M.hoverMark(x, y)
    local hits = M.hovered()
    local labels = {}
    for i = 1, #hits do labels[#labels + 1] = hits[i].label end
    M.hoverMap[#M.hoverMap + 1] = { x = x, y = y, hits = labels }
    _P("[a11y] mark " .. x .. "," .. y .. " -> [" .. table.concat(labels, ", ") .. "]")
    return labels
end

function M.hoverDump()
    M.write("hover_map", { count = #M.hoverMap, marks = M.hoverMap })
    return #M.hoverMap
end

function M.hoverReset() M.hoverMap = {} end

--- Each button carries its own SoundID (UI_HUD_MainMenu_Continue, UI_Shared_Cancel).
--- Since the layer moves a cursor the game knows nothing about, the game plays no
--- hover or click sound — so we need to play those ourselves. Find out with what.
function M.audioApi()
    local out = {}
    if Ext.Audio == nil then
        _P("[a11y] no Ext.Audio")
        M.write("audio_api", { available = false })
        return nil
    end
    for _, n in ipairs({ "PlaySound", "PostEvent", "PlayExternalSound", "StopSound",
                         "SetState", "SetSwitch", "SetRTPCValue", "GetRTPCValue",
                         "LoadEvent", "PrepareEvent", "PauseAllSounds", "ResumeAllSounds" }) do
        out[n] = tostring(soft(function() return type(Ext.Audio[n]) end))
    end
    local names = {}
    soft(function() for k in pairs(Ext.Audio) do names[#names + 1] = tostring(k) end end)
    table.sort(names)
    _P("[a11y] Ext.Audio probed, " .. #names .. " enumerable names -> audio_api.json")
    for k, v in pairs(out) do
        if v == "function" then _P("   " .. k .. " = function") end
    end
    M.write("audio_api", { available = true, candidates = out, enumerated = names })
    return out
end

--- The game's settings, straight from the model.
---
--- The options screen is rendered from a Noesis view this API cannot reach, so reading its
--- widgets is a dead end. GetGlobalSwitches is the object that screen edits, which means an
--- accessible settings UI can be built over the data and skip the view entirely.
--- Read-only: writing an unknown switch could change how the game behaves, so that is a
--- separate, deliberate step once we know what the fields are.
function M.globalSwitches()
    local gs = soft(Ext.Utils.GetGlobalSwitches)
    if gs == nil then _P("[a11y] GetGlobalSwitches returned nil") return nil end

    local out = { scalars = {}, others = {}, names = {} }
    soft(function()
        for k, v in pairs(gs) do
            local key = tostring(k)
            out.names[#out.names + 1] = key
            local t = type(v)
            if t == "boolean" or t == "number" or t == "string" then
                out.scalars[key] = v
            else
                out.others[key] = t .. ": " .. tostring(soft(function() return tostring(v) end))
            end
        end
    end)
    table.sort(out.names)

    local nScalar = 0
    for _ in pairs(out.scalars) do nScalar = nScalar + 1 end
    local nOther = 0
    for _ in pairs(out.others) do nOther = nOther + 1 end

    out.typeName = tostring(soft(Ext.Types.GetObjectType, gs))
    _P("[a11y] globalSwitches: " .. #out.names .. " fields (" .. nScalar ..
       " scalar, " .. nOther .. " structured), type=" .. tostring(out.typeName))
    M.write("global_switches", out)
    return out
end

--- Is GlobalSwitches writable? Tested on one cosmetic field and put straight back.
function M.switchWriteTest(field)
    field = field or "ShowTextBackground"
    local gs = soft(Ext.Utils.GetGlobalSwitches)
    if gs == nil then _P("[a11y] no GlobalSwitches") return nil end

    local before = soft(function() return gs[field] end)
    if type(before) ~= "boolean" then
        _P("[a11y] " .. field .. " is " .. type(before) .. ", expected boolean")
        return nil
    end

    local w = try(function() gs[field] = not before end)
    local after = soft(function() return gs[field] end)
    -- Restore regardless of what happened above: this must leave no trace.
    soft(function() gs[field] = before end)
    local restored = soft(function() return gs[field] end)

    local out = { field = field, before = before, writeOk = w.ok, writeErr = w.error,
                  after = after, restored = restored,
                  stuck = (after == before) and w.ok }
    _P("[a11y] switchWrite " .. field .. ": " .. tostring(before) .. " -> " ..
       tostring(after) .. " -> " .. tostring(restored) ..
       " ok=" .. tostring(w.ok) .. " err=" .. tostring(w.error))
    M.write("switch_write", out)
    return out
end

--- The screens we cannot read as widgets, read as data instead.
---
--- BG3's UI is MVVM: every element carries a DataContext (ui::DCWidget) holding the real
--- model. The load screen's context exposed ExistingSaves, ExistingPlaythroughs,
--- HasSaveGames and SelectedPlaythrough - a save list as data, with no dependence on
--- layout or on the view being reachable at all.
function M.dataContexts()
    local seen, contexts = {}, {}
    M.walk(function(o, depth, i)
        local p = props(o)
        local dc = p.DataContext
        if dc == nil or type(dc) ~= "userdata" then return end
        local id = tostring(dc)
        if seen[id] then return end
        seen[id] = true

        local rec = { id = id, node = splitToString(realType(o)), depth = depth,
                      type = tostring(soft(Ext.Types.GetObjectType, dc)),
                      scalars = {}, structured = {} }
        local dcp = soft(function() return dc:GetAllProperties() end)
        if type(dcp) == "table" then
            for k, v in pairs(dcp) do
                local t = type(v)
                if t == "boolean" or t == "number" or t == "string" then
                    rec.scalars[tostring(k)] = v
                else
                    rec.structured[tostring(k)] = t .. ": " ..
                        tostring(soft(function() return tostring(v) end))
                end
            end
        end
        contexts[#contexts + 1] = rec
    end)
    _P("[a11y] dataContexts: " .. #contexts .. " distinct")
    M.write("data_contexts", { count = #contexts, contexts = contexts })
    return contexts
end

--- Read the save list out of whichever DataContext carries it.
function M.saves()
    local dc = nil
    M.walk(function(o, depth, i)
        local p = props(o)
        local d = p.DataContext
        if d == nil or type(d) ~= "userdata" then return end
        local dp = soft(function() return d:GetAllProperties() end)
        if type(dp) == "table" and dp.ExistingSaves ~= nil then dc = d return true end
    end)
    if dc == nil then
        _P("[a11y] no DataContext with ExistingSaves on this screen")
        M.write("saves", { found = false })
        return nil
    end

    local out = { found = true, type = tostring(soft(Ext.Types.GetObjectType, dc)),
                  collections = {} }
    -- GetAllProperties flattens a collection to a string, so take the live object by name -
    -- safe here because the property is known to exist.
    for _, name in ipairs({ "ExistingSaves", "ExistingPlaythroughs" }) do
        local coll = soft(function() return dc:GetProperty(name) end)
        local rec = { name = name, kind = type(coll),
                      str = tostring(soft(function() return tostring(coll) end)),
                      count = soft(function() return #coll end), items = {} }
        soft(function()
            for i, item in ipairs(coll) do
                if i > 30 then break end
                local one = { i = i, str = tostring(soft(function() return tostring(item) end)) }
                local ip = soft(function() return item:GetAllProperties() end)
                if type(ip) == "table" then
                    one.fields = {}
                    for k, v in pairs(ip) do
                        local t = type(v)
                        one.fields[tostring(k)] = (t == "boolean" or t == "number" or t == "string")
                            and v or (t .. ":" .. tostring(soft(function() return tostring(v) end)))
                    end
                end
                rec.items[#rec.items + 1] = one
            end
        end)
        out.collections[name] = rec
        _P("[a11y] " .. name .. ": kind=" .. rec.kind .. " count=" .. tostring(rec.count) ..
           " read=" .. #rec.items)
    end
    M.write("saves", out)
    return out
end

--- How does one actually enumerate a Noesis collection?
---
--- `#` returns 1 and ipairs yields a single empty entry for ExistingPlaythroughs even
--- though three campaigns exist, so neither applies here - the same trap as the dialogue
--- nodes in E8, where pairs/# behave nothing like a table on proxied userdata.
function M.probeCollection(prop)
    prop = prop or "ExistingPlaythroughs"
    local dc = nil
    M.walk(function(o)
        local p = props(o)
        local d = p.DataContext
        if d == nil or type(d) ~= "userdata" then return end
        local dp = soft(function() return d:GetAllProperties() end)
        if type(dp) == "table" and dp[prop] ~= nil then dc = d return true end
    end)
    if dc == nil then _P("[a11y] no context with " .. prop) return nil end

    local coll = soft(function() return dc:GetProperty(prop) end)
    local out = { prop = prop, kind = type(coll),
                  typeName = tostring(soft(Ext.Types.GetObjectType, coll)),
                  str = tostring(soft(function() return tostring(coll) end)),
                  attempts = {} }

    local function attempt(label, fn)
        local r = try(fn)
        out.attempts[label] = { ok = r.ok, value = plain(r.value), err = r.error }
        _P("   " .. label .. " -> ok=" .. tostring(r.ok) ..
           " v=" .. tostring(r.value) .. " err=" .. tostring(r.error))
    end

    attempt("#coll",        function() return #coll end)
    attempt(".Count",       function() return coll.Count end)
    attempt(":Count()",     function() return coll:Count() end)
    attempt("[0]",          function() return tostring(coll[0]) end)
    attempt("[1]",          function() return tostring(coll[1]) end)
    attempt(":Get(0)",      function() return tostring(coll:Get(0)) end)
    attempt(":GetItem(0)",  function() return tostring(coll:GetItem(0)) end)
    attempt("props",        function()
        local p = coll:GetAllProperties()
        local names = {}
        for k in pairs(p) do names[#names + 1] = tostring(k) end
        table.sort(names)
        return table.concat(names, ",")
    end)
    attempt("pairsCount",   function()
        local n = 0
        for _ in pairs(coll) do n = n + 1 end
        return n
    end)

    M.write("collection_" .. prop, out)
    return out
end

--- Climb above the root and look for siblings.
---
--- Every walk so far started at GetRoot() and went down, and some screens (options, load)
--- never appear there while the main menu stays put - they are rendered from another view.
--- Nodes expose a readable Parent, so the root may itself be one child among several. If a
--- higher ancestor exists, walking from there reaches everything.
function M.climb()
    local root = soft(Ext.ClientUI.GetRoot)
    if root == nil then _P("[a11y] no root") return nil end

    local chain, node = {}, root
    for level = 1, 20 do
        local cls = splitToString(realType(node))
        local p = props(node)
        chain[#chain + 1] = {
            level = level, class = cls,
            children = soft(function() return node.ChildrenCount end),
            visualChildren = soft(function() return node.VisualChildrenCount end),
            hasParent = p.Parent ~= nil,
        }
        _P("[a11y] level " .. level .. ": " .. tostring(cls) ..
           " children=" .. tostring(chain[#chain].children) ..
           " visual=" .. tostring(chain[#chain].visualChildren) ..
           " parent=" .. tostring(p.Parent ~= nil))
        if p.Parent == nil then break end
        node = p.Parent
    end

    -- Count what a walk from the topmost ancestor reaches, versus from the root.
    local top = node
    local fromTop, fromRoot = 0, 0
    local seen = {}
    local function count(o, depth)
        if o == nil or depth > 40 or fromTop >= 20000 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        fromTop = fromTop + 1
        local ch, cn = kids(o)
        for i = 1, cn do count(ch[i], depth + 1) end
    end
    count(top, 0)
    fromRoot = M.walk(function() end)

    _P("[a11y] climb: " .. #chain .. " levels, fromTop=" .. fromTop ..
       " fromRoot=" .. fromRoot)
    M.write("climb", { chain = chain, fromTop = fromTop, fromRoot = fromRoot,
                       topClass = splitToString(realType(top)) })
    return fromTop, fromRoot
end

--- Full API surface of the UI namespace, to a file rather than the console.
---
--- Only one root is exposed (GetRoot ignores any argument and always returns the same
--- Panel), yet a sub-screen collapses the walked tree to 79 nodes - its content lives in a
--- view this root does not reach. So the question is whether anything else here can hand
--- us the other views.
function M.apiDump()
    local out = {}
    for _, ns in ipairs({ "ClientUI", "UI", "ClientInput", "Utils" }) do
        local t = Ext[ns]
        if t ~= nil then
            local names = {}
            soft(function()
                for k, v in pairs(t) do names[#names + 1] = tostring(k) .. "=" .. type(v) end
            end)
            table.sort(names)
            out[ns] = names
            _P("[a11y] Ext." .. ns .. ": " .. #names .. " entries")
        end
    end
    M.write("api_surface", out)
    return out
end

--- What can we actually call to synthesise input?
function M.inputApi()
    local names = { "InjectKeyPress", "InjectMouseButton", "InjectMouseMove", "InjectMouseWheel",
                    "InjectControllerAxis", "InjectControllerButton", "InjectInputEvent",
                    "InjectEvent", "GetInputManager", "GetMouseCursorPos", "SetMouseCursorPos",
                    "GetInputEvents", "SetInputEnabled" }
    local out = {}
    for _, n in ipairs(names) do
        out[n] = tostring(soft(function() return type(Ext.ClientInput[n]) end))
    end
    local ui = {}
    for _, n in ipairs({ "GetRoot", "GetPickingHelper", "GetCursorControl", "GetStateMachine",
                         "GetDragDrop", "SetState", "GetViewportSize" }) do
        ui[n] = tostring(soft(function() return type(Ext.ClientUI[n]) end))
    end
    _P("[a11y] ClientInput/ClientUI surface -> input_api.json")
    M.write("input_api", { clientInput = out, clientUI = ui })
    return out, ui
end

-- live reader ------------------------------------------------------------------

M.index = 0
M.running = false
M.mode = nil
M.rawKeys = {}
M.queue = {}
M.cursorKey = nil

-- Escape is deliberately in this table but never prevented: the game's own cancel
-- must keep working, so the layer only listens and re-reads the screen afterwards.
-- That also guarantees a native way out if the layer itself misbehaves.
local NAV = {
    DOWN = "next", UP = "prev",
    HOME = "first", END = "last",
    RETURN = "activate", KP_ENTER = "activate",
    TAB = "where",
    ESCAPE = "back",
}

-- The layer moves a cursor the game knows nothing about, so the game plays neither its
-- hover click nor its activation sound. We post them ourselves through Wwise.
--
-- "Global" is the built-in sound object — any other name raises "Unknown built-in sound
-- object name". PostEvent returns false for an event the game does not know, which makes
-- it an existence oracle; these four were confirmed that way, while UI_Shared_Rollover,
-- UI_Shared_Navigate, UI_Shared_Back and the buttons' own SoundID values all came back
-- false and are not usable.
M.sounds = {
    move     = "UI_Shared_Hover",
    activate = "UI_Shared_Accept",
    blocked  = "UI_Shared_Tick",
}

function M.sound(kind)
    local ev = M.sounds[kind]
    if ev == nil or Ext.Audio == nil then return false end
    return soft(function() return Ext.Audio.PostEvent("Global", ev) end) == true
end

-- BoundEvent names the input event the game binds to a button. For entries whose
-- command needs a CommandParameter (which the binding flattens to a string and
-- Execute then rejects), pressing the bound key is the way in.
local BOUND_KEY = { UICancel = "ESCAPE", UIAccept = "RETURN" }

local function keyName(e)
    local k = soft(function() return tostring(e.Key) end)
    if k == nil then return nil end
    return k:upper()
end

local function isPressed(e)
    local v = soft(function() return e.Pressed end)
    if type(v) == "boolean" then return v end
    local s = soft(function() return tostring(e.Event) end)
    if type(s) == "string" then return s:lower():find("down") ~= nil end
    return nil
end

--- Record the raw shape of the first few key events so the field names above can be
--- confirmed against the runtime rather than assumed.
local function recordRaw(e)
    if #M.rawKeys >= 6 then return end
    local rec = {}
    for _, f in ipairs({ "Key", "Pressed", "Repeat", "Modifiers", "Event",
                         "CanPreventAction", "ActionPrevented" }) do
        rec[f] = tostring(soft(function() return e[f] end))
    end
    M.rawKeys[#M.rawKeys + 1] = rec
end

--- Noesis node handles expire quickly — a reference collected on one frame is dead by
--- the next, and touching it fails with "whose lifetime has expired". So the cursor
--- remembers a stable identity instead of a node, and every action re-resolves the node
--- from a fresh walk within the same tick it uses it.
local function stableKey(it)
    if type(it.name) == "string" and it.name ~= "" then return "n:" .. it.name end
    return "l:" .. tostring(it.label)
end

--- Where the cursor sits in a freshly collected list, or 0 if it is not there anymore.
function M.locate(items)
    if M.cursorKey == nil then return 0 end
    for i = 1, #items do
        if stableKey(items[i]) == M.cursorKey then return i end
    end
    return 0
end

function M.speakCurrent(withPosition)
    local items = M.items or {}
    local it = items[M.index]
    if it == nil then M.say(T"empty", true) return end
    local text = it.label
    if it.enabled == false then text = text .. T", unavailable" end
    if withPosition then text = text .. ", " .. M.index .. T" of " .. #items end
    M.say(text, true)
end

function M.move(delta)
    local items = M.collect()
    if #items == 0 then M.say(T"no entries", true) return end

    local cur = M.locate(items)
    local idx
    if cur == 0 then
        idx = (delta > 0) and 1 or #items
    else
        idx = cur + delta
        if idx > #items then idx = 1 end
        if idx < 1 then idx = #items end
    end

    M.index = idx
    M.cursorKey = stableKey(items[idx])
    M.sound("move")            -- click first, then the label: matches how focus reads
    M.speakCurrent(false)
end

--- Read the screen again a moment after something was activated, once the game has
--- had a few frames to build the new panel, and say what we landed on.
function M.announceLater(ms)
    local function report()
        local items = M.collect()
        if #items == 0 then
            M.index, M.cursorKey = 0, nil
            M.say(T"screen with no entries", true)
            return
        end
        M.index = 1
        M.cursorKey = stableKey(items[1])
        M.say(#items .. T" entries. " .. items[1].label, true)
    end
    local wait = Ext.Timer and Ext.Timer.WaitForRealtime
    if type(wait) == "function" then
        if soft(wait, ms or 400, report) == nil then report() end
    else
        report()
    end
end

--- Press the current entry.
---
--- Two mechanisms, because neither covers everything: a parameterless ICommand can
--- be executed directly, while an entry carrying a CommandParameter cannot (the
--- binding hands the parameter over as a string and Execute demands a live object) —
--- for those, the key the game itself binds to the button does the job.
function M.activate()
    -- Fresh walk, then act in this same tick: the node collected when the arrow key was
    -- pressed has already expired by now.
    local items = M.collect()
    local idx = M.locate(items)
    if idx == 0 then idx = M.index end
    local it = items[idx]
    if it == nil then M.say(T"nothing to press", true) return false end
    if it.enabled == false then
        M.sound("blocked")
        M.say(it.label .. T", unavailable", true)
        return false
    end
    M.index = idx

    local ok, via = false, nil
    if it.hasCommand and it.commandParameter == nil then
        ok, via = M.fire(idx)
    end
    if not ok and it.boundEvent ~= nil then
        local key = BOUND_KEY[tostring(it.boundEvent)]
        if key ~= nil then
            local r = try(function() return Ext.ClientInput.InjectKeyPress(key, 0) end)
            ok, via = r.ok, "key " .. key
            _P("[a11y] activate via " .. via .. " -> ok=" .. tostring(r.ok) ..
               " err=" .. tostring(r.error))
        end
    end

    if ok then
        M.sound("activate")
        _P("[a11y] activated '" .. it.label .. "' via " .. tostring(via))
        M.announceLater()
    else
        M.sound("blocked")
        M.say(it.label .. T", could not press", true)
    end
    return ok
end

--- Run one queued action. Called from Tick, never from the input handler.
local function perform(action)
    if action == "next" then M.move(1)
    elseif action == "prev" then M.move(-1)
    elseif action == "first" then M.index = 0 M.move(1)
    elseif action == "last" then M.index = 0 M.move(-1)
    elseif action == "where" then
        local items = M.collect()
        local at = M.locate(items)
        if at > 0 then M.index = at end
        M.speakCurrent(true)
    elseif action == "activate" then M.activate()
    elseif action == "back" then M.announceLater(500) end
end

--- Drain the queue on the frame after the keystroke.
---
--- Everything that touches the UI has to happen here rather than in the key handler.
--- Inside a KeyInput callback the Noesis property read is degraded: ToString still
--- returns the label, but GetAllProperties comes back without Command, BoundEvent or
--- IsEnabled, so an entry looks unpressable. The identical call from outside that
--- callback returns all 36 properties. Deferring by one frame is the whole fix.
local function drain()
    if #M.queue == 0 then return end
    local pending = M.queue
    M.queue = {}
    for i = 1, #pending do
        local r = try(perform, pending[i])
        if not r.ok then _P("[a11y] action '" .. tostring(pending[i]) .. "' failed: " ..
                            tostring(r.error)) end
    end
end

local function onKey(e)
    recordRaw(e)
    local pressed = isPressed(e)
    if pressed == false then return end
    local k = keyName(e)
    if k == nil then return end
    local action = NAV[k]
    if action == nil then return end

    -- Suppression has to be synchronous — it is the one thing that cannot be deferred.
    -- Escape stays unprevented so the game's own cancel keeps working (E1).
    if action ~= "back" then soft(function() e:PreventAction() end) end

    M.queue[#M.queue + 1] = action
end

-- Watch the game's own focus instead of driving a private cursor.
--
-- Nothing in mouse-and-keyboard mode moves the Noesis focus - Focus() is not bound,
-- Tab traversal does nothing, arrows are unbound, injected UI events change nothing and
-- SetState is deprecated. A controller does move it, and that is the whole point of this
-- watcher: if focus tracks a gamepad, the game supplies focus, highlight and sound, and
-- the layer only has to say what happened. That also makes this the prototype, not just
-- a probe.
M.watchLast = nil
M.watchTicks = 0
M.undescribed = 0

-- ToString() gives "Class: content", and for a container the content is the type name of
-- whatever it holds, not text: a focused panel reads as "ContentControl: Grid". Taking
-- that as a label makes the layer announce layout structure instead of the screen, so
-- these tokens are never treated as text.
local LAYOUT_WORDS = {
    Grid = true, Border = true, StackPanel = true, Canvas = true, Panel = true,
    DockPanel = true, WrapPanel = true, UniformGrid = true, Viewbox = true,
    ContentPresenter = true, ContentControl = true, ItemsPresenter = true,
    Decorator = true, Control = true, UserControl = true, Popup = true,
    Image = true, Rectangle = true, Ellipse = true, Path = true, Run = true,
    TextBlock = true, ScrollViewer = true, Separator = true, Track = true,
    Thumb = true, RepeatButton = true, ScrollBar = true, ItemsControl = true,
}

local function looksLikeText(s)
    if type(s) ~= "string" then return false end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return false end
    if LAYOUT_WORDS[s] then return false end
    if s:find("^ls%.") then return false end               -- a Larian class name
    if s:find("Presenter$") or s:find("Panel$") then return false end
    -- Template placeholders. Character creation is built from them: the value of every
    -- spinner is a control whose ToString is "[ForceUpdate]", with the text a level below,
    -- so without this every option reads as "[ForceUpdate], <the actual value>".
    if s:find("^%[") and s:find("%]$") then return false end
    -- An unresolved localisation handle: "h403a278dg5a07g4880g8cbfg8f7a32371774". The game
    -- leaves them in the tree beside the resolved string, and the options screen read one out
    -- loud in the middle of a sentence. Thirty-odd characters of hex is never something a
    -- player is meant to hear.
    if s:find("^h%x%x%x%x%x%x%x%x") and #s > 20 then return false end
    -- The same thing in its other spelling, used where a string id was never localised.
    if s:find("^ResStr_%w+$") then return false end
    return true
end
M.looksLikeText = looksLikeText

--- The first of several candidates that reads as text, trimmed.
---
--- Written because `for _, s in ipairs({ p.Text, label })` is a trap: most nodes have no
--- Text at all, and a table whose first entry is nil ends ipairs immediately - so the
--- label, the one that usually carries the caption, was never looked at. Every silent node
--- on every screen had this as at least a contributing cause.
local function firstText(...)
    local n = select("#", ...)
    for i = 1, n do
        local s = select(i, ...)
        if looksLikeText(s) then return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    end
    return nil
end
M.firstText = firstText

--- The same candidates, all of them, in order and without the holes.
local function strings(...)
    local out, n = {}, select("#", ...)
    for i = 1, n do
        local s = select(i, ...)
        if type(s) == "string" then out[#out + 1] = s end
    end
    return out
end
M.strings = strings

--- Classes that cannot hold text and are not worth descending into.
---
--- This is not an optimisation, it is a correctness fix. A framed control in this game is
--- drawn with a nine-slice: `Control #Frame` holds an `ls.LSNineSliceImage` whose grid is
--- some thirty `Image` nodes plus its Column/RowDefinitions. A character-creation spinner
--- puts that frame *before* the presenter holding its value, so a walk with any sane node
--- budget spends all of it on the frame and returns nothing - which is why every setting
--- read as its caption alone, with the value missing.
local NO_TEXT = {
    Image = true, Rectangle = true, Ellipse = true, Line = true, Path = true,
    Shape = true, ColumnDefinition = true, RowDefinition = true,
    ["ls.LSNineSliceImage"] = true,
}
M.NO_TEXT = NO_TEXT

--- Text of a node and its descendants, in reading order, deduplicated.
---
--- Inside sub-screens the focus lands on a container or a list row whose own ToString
--- carries no label - the text sits in children. Announcing only the focused node itself
--- is why the menu read fine and every panel went silent.
local function collectText(o, maxNodes, maxDepth)
    local parts, seen, n = {}, {}, 0
    local function rec(node, depth)
        if node == nil or n >= (maxNodes or 60) or depth > (maxDepth or 6) then return end
        local cls, label = splitToString(realType(node))
        if NO_TEXT[cls] then return end
        n = n + 1
        local p = props(node)
        for _, s in ipairs(strings(label, p.Text)) do
            if looksLikeText(s) then
                s = s:gsub("^%s+", ""):gsub("%s+$", "")
                if not seen[s] then seen[s] = true parts[#parts + 1] = s end
            end
        end
        local ch, cn = kids(node)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(o, 0)
    return parts
end
M.collectText = collectText

--- What to say about the focused element.
function M.describe(o)
    local cls, label = splitToString(realType(o))
    local p = props(o)
    if looksLikeText(p.Text) then return p.Text, cls end
    if looksLikeText(label) then return label, cls end

    local parts = collectText(o)
    if #parts > 0 then
        -- Keep it short: a focused row usually reads as a few fields, not a whole panel.
        local take = {}
        for i = 1, math.min(#parts, 4) do take[i] = parts[i] end
        return table.concat(take, ", "), cls
    end
    if type(p.Name) == "string" and p.Name ~= "" then return p.Name, cls end
    return nil, cls
end

M.lastNodes = nil
M.autoDumps = 0

--- Keep the controller UI from being torn down by a stray keypress.
---
--- The game switches its whole interface back to mouse-and-keyboard on any keyboard
--- input - even the Alt+Tab used to leave the game, which is why nothing observed from
--- outside reflected what the tester actually had on screen. This flag exists precisely
--- to let both coexist, and the game may clear it, so it is re-asserted periodically.
local function holdControllerMode()
    local im = soft(Ext.ClientInput.GetInputManager)
    if im == nil then return end
    local cur = soft(function() return im.ControllerAllowKeyboardMouseInput end)
    if cur ~= true then
        soft(function() im.ControllerAllowKeyboardMouseInput = true end)
        _P("[a11y] re-asserted ControllerAllowKeyboardMouseInput (was " ..
           tostring(cur) .. ")")
    end
end

M.absent = 0
M.dumpedThisAbsence = false

local function watchTick()
    M.watchTicks = M.watchTicks + 1
    if M.watchTicks % 120 == 0 then holdControllerMode() end
    if M.watchTicks % 6 ~= 0 then return end       -- ~10 Hz

    -- GetAllProperties, not GetProperty("IsFocused"): the walk also reaches non-visual
    -- objects (ls.VMInputEvent, Boxed<String>) which have no such property, and asking by
    -- name throws there - the expensive path that logs every miss. The abort keeps the cost
    -- down instead: the focused node is usually found early and the walk stops there.
    local node, info = nil, nil
    local total = M.walk(function(o, depth, i)
        local p = props(o)
        if p.IsFocused == true then
            node = o
            info = { depth = depth, index = i, name = p.Name }
            return true                             -- stop the walk here
        end
    end)

    -- GetRoot() does not follow the active screen: it stays bound to the main menu's view
    -- and returns either that tree or nil. Every "snapshot of a sub-screen" turned out to be
    -- the main menu again (442 nodes, the same 42 strings), so options and load are separate
    -- views this root never reaches - reading them has to go through the data model instead.
    -- Say so out loud rather than going quiet: silence is indistinguishable from a dead mod.
    if total < 20 then
        M.transitions = (M.transitions or 0) + 1
        if not M.saidUnreadable then
            M.saidUnreadable = true
            M.watchLast = "<unreadable>"
            _P("[a11y] root unreachable (" .. total .. " nodes) - screen not readable")
            M.say(T"This screen cannot be read through the tree", true)
        end
        return
    end
    M.saidUnreadable = false

    if node == nil then
        M.absent = M.absent + 1
        if M.watchLast ~= "<none>" then
            M.watchLast = "<none>"
            _P("[a11y] focus lost (" .. total .. " nodes)")
        end
        -- Dump once per absence episode, and only after it has held for about a second:
        -- the node count jitters between 442 and 483 on a single screen, so reacting to
        -- size alone fired the whole dump budget on the main menu.
        -- No screen-wide readout here any more: the dump always came back as the main menu,
        -- which made it actively misleading - it announced content that was not on screen.
        if M.absent >= 10 and not M.dumpedThisAbsence then
            M.dumpedThisAbsence = true
            M.say(T"focus lost", true)
        end
        return
    end

    M.absent = 0
    M.dumpedThisAbsence = false
    M.lastNodes = total

    local text, cls = M.describe(node)
    local key = tostring(info.name) .. "|" .. tostring(cls) .. "|" .. tostring(text)
    if key == M.watchLast then return end
    M.watchLast = key

    if text == nil then
        -- Record the shape of anything we cannot name, so the gap is diagnosable.
        M.undescribed = M.undescribed + 1
        if M.undescribed <= 3 then
            local names = {}
            for k in pairs(props(node)) do names[#names + 1] = tostring(k) end
            table.sort(names)
            M.write("focus_undescribed" .. M.undescribed, {
                class = cls, name = tostring(info.name), depth = info.depth,
                propNames = names,
                childText = collectText(node, 120, 10),
            })
        end
        _P("[a11y] focus -> " .. tostring(cls) .. " (no text) #" .. M.undescribed)
        return
    end

    _P("[a11y] focus -> " .. text .. " [" .. tostring(cls) .. "]")
    M.say(text, true)
end

--- Drop every hook a previous load left behind, whichever module instance owns it.
--- Reloading replaces the A11y global but not the live subscriptions, so old handlers keep
--- answering keys from an unreachable closure.
function M.dropAll()
    for _, g in ipairs({ "A11Y_SUB", "A11Y_TICK", "A11Y_WATCH" }) do
        local id = _G[g]
        if id ~= nil then
            local ev = (g == "A11Y_SUB") and Ext.Events.KeyInput or Ext.Events.Tick
            soft(function() ev:Unsubscribe(id) end)
            _P("[a11y] dropped " .. g .. " = " .. tostring(id))
            _G[g] = nil
        end
    end
    M.running, M.subId, M.tickId, M.watchId = false, nil, nil, nil
end

function M.watchStart()
    if _G.A11Y_WATCH ~= nil then
        soft(function() Ext.Events.Tick:Unsubscribe(_G.A11Y_WATCH) end)
        _G.A11Y_WATCH = nil
    end
    local id = Ext.Events.Tick:Subscribe(watchTick)
    if id == nil then _P("[a11y] FAILED: Tick:Subscribe returned nil") return false end
    _G.A11Y_WATCH = id
    M.watchId = id
    M.watchLast = nil
    M.lastNodes = nil
    M.autoDumps = 0
    holdControllerMode()
    _P("[a11y] focus watcher running (" .. tostring(id) .. ")")
    M.say(T"Focus watcher on. Move the pad. Screens with no focus will be read whole.", true)
    return true
end

function M.watchStop()
    if M.watchId then soft(function() Ext.Events.Tick:Unsubscribe(M.watchId) end) end
    M.watchId = nil
    _G.A11Y_WATCH = nil
    _P("[a11y] focus watcher stopped")
end

function M.start()
    if M.running then _P("[a11y] already running") return true end

    -- Reloading builds a fresh module table, but the previous KeyInput subscription
    -- survives with the old closure attached — without this, every push stacks another
    -- live handler and each keystroke gets handled several times over.
    if _G.A11Y_SUB ~= nil then
        soft(function() Ext.Events.KeyInput:Unsubscribe(_G.A11Y_SUB) end)
        _P("[a11y] dropped stale subscription " .. tostring(_G.A11Y_SUB))
        _G.A11Y_SUB = nil
    end
    if _G.A11Y_TICK ~= nil then
        soft(function() Ext.Events.Tick:Unsubscribe(_G.A11Y_TICK) end)
        _G.A11Y_TICK = nil
    end

    local id = Ext.Events.KeyInput:Subscribe(onKey)
    -- Subscribe returns nil for a wrong event name instead of throwing (§А).
    if id == nil then
        _P("[a11y] FAILED: KeyInput:Subscribe returned nil")
        return false
    end
    M.subId = id
    _G.A11Y_SUB = id

    -- Tick is one of the events that works under its own name (unlike the input ones).
    local tick = Ext.Events.Tick:Subscribe(drain)
    if tick == nil then
        _P("[a11y] FAILED: Tick:Subscribe returned nil")
        soft(function() Ext.Events.KeyInput:Unsubscribe(id) end)
        _G.A11Y_SUB = nil
        return false
    end
    M.tickId = tick
    _G.A11Y_TICK = tick

    M.queue = {}
    M.running = true
    M.index = 0
    local n = #M.collect()
    _P("[a11y] running, subscription " .. tostring(id) .. ", " .. n .. " entries")
    M.say(T"Menu speech on. " .. n .. T" entries. Arrows move, Enter selects.", true)
    return true
end

function M.stop()
    if M.subId then soft(function() Ext.Events.KeyInput:Unsubscribe(M.subId) end) end
    if M.tickId then soft(function() Ext.Events.Tick:Unsubscribe(M.tickId) end) end
    M.subId, M.tickId = nil, nil
    _G.A11Y_SUB, _G.A11Y_TICK = nil, nil
    M.running = false
    _P("[a11y] stopped")
    M.say(T"Menu speech off", true)
end

--- Everything the recon needs, in one call.
function M.recon()
    M.inputApi()
    M.inputEvents("ui")
    M.list()
    M.focusScan()
    M.probeNode(1)
    _P("[a11y] recon done")
end

_P("[a11y] a11y-menu loaded (client). A11y.recon() / A11y.start()")
return M
