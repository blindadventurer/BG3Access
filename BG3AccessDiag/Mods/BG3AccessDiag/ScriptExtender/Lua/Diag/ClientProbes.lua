--- Client-side host viability probes (§9 of bg3-host-port-research.md).
--- E1 key suppression, E2 picking TargetOverride, E3 Noesis ICommand, E4 tree
--- completeness, E5 traversal cost, E6 file bridge RTT, E8 dialog manager on the
--- client, E9 hot reload survival, E10 versions, E11 input definitions.

local C = Ext.Require("Diag/Common.lua")
local M = {}

-- ---------------------------------------------------------------- tree walking

local PROPS = {
    "Name", "Text", "Content", "Header", "ToolTip", "Visibility", "Opacity",
    "IsEnabled", "IsVisible", "IsFocused", "Tag", "Label", "Value", "Command",
}

local function typeName(o)
    return C.soft(Ext.Types.GetObjectType, o) or "?"
end

local function readProp(o, name)
    local r = C.try(function() return o:GetProperty(name) end)
    if not r.ok then return nil end
    return r.value
end

--- Children of a Noesis element via both the visual and the logical tree.
--- Index base is not documented, so probe it.
local function childrenOf(o)
    local out = {}
    local vc = C.soft(function() return o.VisualChildrenCount end)
    if type(vc) == "number" and vc > 0 then
        for i = 0, vc - 1 do
            local ch = C.soft(function() return o:VisualChild(i) end)
            if ch ~= nil then out[#out + 1] = ch end
        end
        if #out == 0 then
            for i = 1, vc do
                local ch = C.soft(function() return o:VisualChild(i) end)
                if ch ~= nil then out[#out + 1] = ch end
            end
        end
    end
    return out, vc
end

local walkStats

local function walk(o, depth, sink, maxNodes, maxDepth)
    if o == nil or walkStats.nodes >= maxNodes or depth > maxDepth then return nil end
    walkStats.nodes = walkStats.nodes + 1
    if depth > walkStats.maxDepthSeen then walkStats.maxDepthSeen = depth end

    local node = { t = typeName(o), d = depth }
    for _, p in ipairs(PROPS) do
        local v = readProp(o, p)
        if v ~= nil then
            local tv = type(v)
            if tv == "string" or tv == "number" or tv == "boolean" then
                if not (tv == "string" and v == "") then node[p] = v end
            elseif tv == "userdata" then
                local tn = typeName(v)
                node[p] = "<" .. tn .. ">"
                if p == "Command" then
                    walkStats.commands = walkStats.commands + 1
                    -- CanExecute is a pure query: proves we can reach and call the
                    -- command object without triggering anything.
                    local ce = C.try(function() return v:CanExecute(nil) end)
                    walkStats.commandProbes[#walkStats.commandProbes + 1] = {
                        type = tn,
                        owner = node.t,
                        name = node.Name or node.Text or node.Content,
                        canExecuteOk = ce.ok,
                        canExecute = ce.ok and ce.value or nil,
                        error = (not ce.ok) and ce.error or nil,
                    }
                end
            end
        end
    end

    local kids = childrenOf(o)
    if #kids > 0 then
        node.c = {}
        for _, k in ipairs(kids) do
            local kn = walk(k, depth + 1, sink, maxNodes, maxDepth)
            if kn then node.c[#node.c + 1] = kn end
        end
        if #node.c == 0 then node.c = nil end
    end

    if node.Text or node.Content or node.Header then
        walkStats.textNodes = walkStats.textNodes + 1
    end
    return node
end

local function newWalkStats()
    return { nodes = 0, textNodes = 0, commands = 0, maxDepthSeen = 0, commandProbes = {} }
end

--- Walk the whole UI root. Returns tree, stats, elapsed microseconds.
function M.walkRoot(maxNodes, maxDepth)
    local root = C.soft(Ext.ClientUI.GetRoot)
    if root == nil then return nil, { error = "GetRoot() returned nil" }, 0 end
    walkStats = newWalkStats()
    local t0 = C.now()
    local tree = walk(root, 0, nil, maxNodes or 30000, maxDepth or 60)
    local dt = C.now() - t0
    return tree, walkStats, dt
end

-- ------------------------------------------------- E4 tree + E3 ICommand + E5

function M.E4_E3_E5_tree(tag)
    tag = tag or "unknown"
    local tree, stats, dt = M.walkRoot()
    local sm = C.soft(Ext.ClientUI.GetStateMachine)
    local smInfo = nil
    if sm ~= nil then
        smInfo = {
            rootState = C.soft(function() return tostring(sm.RootState) end),
            state = C.soft(function() return tostring(sm.State) end),
            statesCount = C.soft(function() return #sm.States end),
        }
    end

    -- E5: repeat the walk to get a distribution, not one sample.
    local samples = {}
    for _ = 1, 5 do
        local _, _, d = M.walkRoot()
        samples[#samples + 1] = d
    end
    table.sort(samples)

    local section = {
        tag = tag,
        gameState = tostring(C.soft(Ext.Utils.GetGameState)),
        stateMachine = smInfo,
        walk = stats and {
            nodes = stats.nodes,
            textNodes = stats.textNodes,
            maxDepth = stats.maxDepthSeen,
            commandsFound = stats.commands,
        } or nil,
        E5_traversalMicros = {
            first = dt,
            min = samples[1],
            median = samples[3],
            max = samples[#samples],
            samples = samples,
        },
        E3_commandProbes = stats and stats.commandProbes or nil,
    }
    C.report("E3_E4_E5_ui_" .. tag, section)
    C.dump("uitree_" .. tag .. ".json", tree)
    return section
end

-- ------------------------------------------------------- E2 picking helper

function M.E2_picking()
    local out = {}
    local h = C.try(Ext.ClientUI.GetPickingHelper, 0)
    out.getPickingHelper = { ok = h.ok, error = h.error }
    if not h.ok or h.value == nil then
        C.report("E2_picking", out)
        return out
    end
    local ph = h.value

    out.fields = {
        activated       = C.soft(function() return ph.Activated end),
        isMoving        = C.soft(function() return ph.IsMoving end),
        playerId        = C.soft(function() return ph.PlayerId end),
        windowCursorPos = C.soft(function() return { ph.WindowCursorPos[1], ph.WindowCursorPos[2] } end),
        pickingDirection= C.soft(function() return { ph.PickingDirection[1], ph.PickingDirection[2], ph.PickingDirection[3] } end),
        selectableCount = C.soft(function() return #ph.SelectableObjects end),
        hasSelection    = C.soft(function() return ph.Selection ~= nil end),
        targetOverride  = C.soft(function()
            local t = ph.TargetOverride
            if t == nil then return nil end
            return { t[1], t[2], t[3] }
        end),
    }

    -- The load-bearing question: is TargetOverride writable from Lua?
    local probe = { 12.5, 34.5, 56.5 }
    local w = C.try(function() ph.TargetOverride = probe end)
    out.writeTargetOverride = { ok = w.ok, error = w.error }
    if w.ok then
        local rb = C.soft(function()
            local t = ph.TargetOverride
            if t == nil then return nil end
            return { t[1], t[2], t[3] }
        end)
        out.readBack = rb
        out.stuck = (rb ~= nil and math.abs((rb[1] or 0) - probe[1]) < 0.01)
        -- restore
        C.try(function() ph.TargetOverride = nil end)
    end

    -- Same question for the cursor position, the other half of a mouse-free aim.
    local cw = C.try(function() ph.WindowCursorPos = { 100.0, 100.0 } end)
    out.writeWindowCursorPos = { ok = cw.ok, error = cw.error }

    C.report("E2_picking", out)
    return out
end

-- ------------------------------------------------------ E1 key suppression

M.keyLog = {}
M.suppress = { enabled = false, key = nil, hits = 0 }

local function onKey(e)
    if #M.keyLog < 40 then
        M.keyLog[#M.keyLog + 1] = {
            key = tostring(e.Key),
            mods = tostring(e.Modifiers),
            pressed = e.Pressed,
            repeated = e.Repeat,
            canPreventAction = C.soft(function() return e.CanPreventAction end),
            actionPrevented = C.soft(function() return e.ActionPrevented end),
            stopped = C.soft(function() return e.Stopped end),
        }
    end
    if M.suppress.enabled and tostring(e.Key) == M.suppress.key then
        M.suppress.hits = M.suppress.hits + 1
        local r = C.try(function() e:PreventAction() end)
        M.suppress.lastPreventOk = r.ok
        M.suppress.lastPreventError = r.error
        M.suppress.afterPrevent = C.soft(function() return e.ActionPrevented end)
    end
end

--- Inject `key`, wait, and report what the UI state machine did. Run once with
--- suppression off and once with it on: the difference is the answer to E1.
function M.E1_suppression(key, done)
    key = key or "M"
    local result = { key = key }

    local function snapshot()
        local sm = C.soft(Ext.ClientUI.GetStateMachine)
        if sm == nil then return { error = "no state machine" } end
        return {
            state = C.soft(function() return tostring(sm.State) end),
            root = C.soft(function() return tostring(sm.RootState) end),
            statesCount = C.soft(function() return #sm.States end),
        }
    end

    local function phase(name, suppressOn, after)
        M.suppress.enabled = suppressOn
        M.suppress.key = key
        M.suppress.hits = 0
        local before = snapshot()
        local inj = C.try(Ext.ClientInput.InjectKeyPress, key)
        Ext.Timer.WaitForRealtime(700, function()
            local afterState = snapshot()
            result[name] = {
                suppressionEnabled = suppressOn,
                injectOk = inj.ok,
                injectError = inj.error,
                handlerSawInjectedKey = M.suppress.hits,
                preventCallOk = M.suppress.lastPreventOk,
                preventCallError = M.suppress.lastPreventError,
                actionPreventedAfterCall = M.suppress.afterPrevent,
                stateBefore = before,
                stateAfter = afterState,
                stateChanged = (before.state ~= afterState.state),
            }
            M.suppress.enabled = false
            -- close whatever opened, so the next phase starts clean
            C.try(Ext.ClientInput.InjectKeyPress, key)
            Ext.Timer.WaitForRealtime(700, after)
        end)
    end

    phase("phaseA_noSuppression", false, function()
        phase("phaseB_withSuppression", true, function()
            result.observedKeyEvents = M.keyLog
            result.verdict =
                (result.phaseA_noSuppression and result.phaseA_noSuppression.stateChanged
                 and result.phaseB_withSuppression and not result.phaseB_withSuppression.stateChanged)
                and "SUPPRESSION WORKS"
                or "INCONCLUSIVE - see phases"
            C.report("E1_key_suppression", result)
            if done then done(result) end
        end)
    end)
end

-- ------------------------------------------------------ E6 file bridge RTT

function M.E6_bridge(rounds, done)
    rounds = rounds or 20
    local out = { rounds = rounds, rtts = {}, loadContext = nil }

    -- Which LoadFile context can read back what SaveFile wrote?
    C.soft(Ext.IO.SaveFile, C.DIR .. "ctxprobe.txt", "hello")
    local a = C.soft(Ext.IO.LoadFile, C.DIR .. "ctxprobe.txt")
    local b = C.soft(Ext.IO.LoadFile, C.DIR .. "ctxprobe.txt", "user")
    local c = C.soft(Ext.IO.LoadFile, C.DIR .. "ctxprobe.txt", "data")
    out.loadContext = { default = a, user = b, data = c }
    local ctx = (a == "hello" and nil) or (b == "hello" and "user") or (c == "hello" and "data") or nil
    out.usableContext = (a == "hello") and "default" or ((b == "hello") and "user" or ((c == "hello") and "data" or "NONE"))

    if out.usableContext == "NONE" then
        out.note = "SaveFile output is not readable back via LoadFile; the bridge must be one-way (game -> companion)."
        C.report("E6_bridge", out)
        if done then done(out) end
        return
    end

    local seq = 0
    local sent = 0
    local tick

    local function readPong()
        if ctx then return C.soft(Ext.IO.LoadFile, C.DIR .. "pong.txt", ctx) end
        return C.soft(Ext.IO.LoadFile, C.DIR .. "pong.txt")
    end

    local function sendPing()
        seq = seq + 1
        sent = C.now()
        C.soft(Ext.IO.SaveFile, C.DIR .. "ping.txt", tostring(seq))
    end

    tick = function()
        local v = readPong()
        if v ~= nil and tonumber(v) == seq then
            out.rtts[#out.rtts + 1] = C.now() - sent
            if #out.rtts >= rounds then
                table.sort(out.rtts)
                out.minMicros = out.rtts[1]
                out.medianMicros = out.rtts[math.max(1, math.floor(#out.rtts / 2))]
                out.maxMicros = out.rtts[#out.rtts]
                C.report("E6_bridge", out)
                if done then done(out) end
                return
            end
            sendPing()
        end
        Ext.Timer.WaitForRealtime(5, tick)
    end

    out.note = "companion watcher must copy A11yDiag/ping.txt -> A11yDiag/pong.txt"
    sendPing()
    Ext.Timer.WaitForRealtime(5, tick)

    -- Give up after 30s so a missing watcher does not hang the run.
    Ext.Timer.WaitForRealtime(30000, function()
        if #out.rtts < rounds then
            out.timedOut = true
            out.completed = #out.rtts
            C.report("E6_bridge", out)
        end
    end)
end

-- --------------------------------------------------- E8 dialog manager (client)

function M.E8_dialog()
    local out = {}
    local r = C.try(Ext.Utils.GetDialogManager)
    out.available = r.ok and r.value ~= nil
    out.error = r.error
    if not out.available then
        C.report("E8_dialog_client", out)
        return out
    end
    local mgr = r.value
    out.dialogs = {}
    C.try(function()
        for id, inst in pairs(mgr.Dialogs) do
            local d = {
                id = id,
                state = C.soft(function() return inst.State end),
                dialogId = C.soft(function() return inst.DialogId end),
                resource = C.soft(function() return tostring(inst.DialogResourceUUID) end),
                localHighlighted = C.soft(function() return inst.LocalHighlightedAnswer end),
                hostHighlighted = C.soft(function() return inst.HostHighlightedAnswer end),
                isPaused = C.soft(function() return inst.IsPaused end),
                speakerCount = C.soft(function() return #inst.Speakers end),
                answers = {},
            }
            C.try(function()
                for i, sel in ipairs(inst.NodeSelection) do
                    d.answers[i] = {
                        lineId = C.soft(function() return sel.LineId end),
                        nodeUuid = C.soft(function() return tostring(sel.Node.UUID) end),
                        flags = C.soft(function() return tostring(sel.Node.Flags) end),
                    }
                end
            end)
            out.dialogs[#out.dialogs + 1] = d
        end
    end)
    out.activeDialogCount = #out.dialogs
    C.report("E8_dialog_client", out)
    return out
end

-- ------------------------------------------------- E11 input definitions

function M.E11_input()
    local out = {}
    local r = C.try(Ext.ClientInput.GetInputManager)
    out.available = r.ok and r.value ~= nil
    out.error = r.error
    if not out.available then
        C.report("E11_input", out)
        return out
    end
    local im = r.value
    out.inputScheme = C.soft(function() return tostring(im.InputScheme) end)
    out.pressedModifiers = C.soft(function() return tostring(im.PressedModifiers) end)
    out.allowDeviceEvents = C.soft(function() return im.AllowDeviceEvents end)

    local defs = {}
    C.try(function()
        local n = 0
        for id, d in pairs(im.InputDefinitions) do
            n = n + 1
            if n > 400 then break end
            defs[#defs + 1] = { id = id, def = C.plain(d, 2) }
        end
        out.inputDefinitionCount = n
    end)
    out.inputDefinitionsSample = defs
    C.dump("input_definitions.json", defs)
    C.report("E11_input", out)
    return out
end

-- ------------------------------------------------------------ E9 / E10

M.resetCount = 0

function M.E10_env()
    C.report("E10_env", C.env())
end

function M.E9_reset()
    C.report("E9_reset", {
        resetCompletedSeen = M.resetCount,
        note = "type `reset` in the SE console, then run !a11y_reset again",
    })
end

function M.init()
    Ext.Events.EclLuaKeyInput:Subscribe(onKey)
    Ext.Events.ResetCompleted:Subscribe(function()
        M.resetCount = M.resetCount + 1
    end)

    Ext.RegisterConsoleCommand("a11y_ui", function(_, tag) M.E4_E3_E5_tree(tag or "manual") end)
    Ext.RegisterConsoleCommand("a11y_pick", function() M.E2_picking() end)
    Ext.RegisterConsoleCommand("a11y_keys", function(_, k) M.E1_suppression(k) end)
    Ext.RegisterConsoleCommand("a11y_bridge", function() M.E6_bridge() end)
    Ext.RegisterConsoleCommand("a11y_dialog", function() M.E8_dialog() end)
    Ext.RegisterConsoleCommand("a11y_input", function() M.E11_input() end)
    Ext.RegisterConsoleCommand("a11y_reset", function() M.E9_reset() end)
    Ext.RegisterConsoleCommand("a11y_all", function() M.runAll("manual") end)

    C.log("client probes registered")
end

--- Everything that is safe to run unattended.
function M.runAll(tag)
    M.E10_env()
    C.try(M.E11_input)
    C.try(M.E2_picking)
    C.try(M.E8_dialog)
    C.try(function() M.E4_E3_E5_tree(tag or "auto") end)
    Ext.Timer.WaitForRealtime(1500, function()
        C.try(function() M.E6_bridge(20) end)
    end)
    Ext.Timer.WaitForRealtime(6000, function()
        C.try(function() M.E1_suppression("M") end)
    end)
end

return M
