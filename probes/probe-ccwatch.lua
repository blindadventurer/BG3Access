-- Watch character creation while a human navigates it, and write down what changed.
--
-- One pruned walk of CharacterCreation_c finds the four landmarks the screen is built from -
-- the tab strip, the settings column, the sub-panel beside it and the summary - and stops
-- descending as soon as it has each, so the walk is ~150 nodes rather than 1126. Everything
-- else is read out of those.
--
-- Also records the widget list every pass: a tooltip, if the game builds one, arrives as a
-- new ls.UIWidget under ContentRoot and nothing else would show it.

local A, Pad = _G.A11y, _G.Pad
local W = {}

local LANDMARKS = {
    gameplayTabs = true, gameplayPanel = true, gameplaySubPanel = true,
    summaryPanel = true, appearancePanel = true,
}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

--- The landmarks, in one walk that never enters them.
local function landmarks(node)
    local out, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or n > 900 or depth > 20 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local p = A.props(o)
        if p.IsVisible == false then return end
        local name = tostring(p.Name)
        if LANDMARKS[name] then out[name] = o return end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(node, 0)
    out._nodes = n
    return out
end

--- Visible text under a node, in reading order, adjacent duplicates collapsed.
local function texts(node, cap, maxNodes)
    local out, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or #out >= (cap or 40) or n >= (maxNodes or 600) or depth > 24 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local p = A.props(o)
        if p.IsVisible == false then return end
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

--- The tab strip: every item, and which one carries IsSelected.
--- Deduplicated by the item's own Name. Node identity cannot do it: the visual and logical
--- trees hand back different userdata for the same element, so every tab arrives five times.
local function tabs(listBox)
    local out, sel, byName = {}, nil, {}
    local ch, cn = A.kids(listBox)
    local function scan(o, depth)
        if o == nil or depth > 6 then return end
        local p = A.props(o)
        local cls = select(1, A.splitToString(A.realType(o)))
        if cls:find("ListBoxItem", 1, true) then
            local name = tostring(p.Name)
            if byName[name] then return end
            byName[name] = true
            -- The caption is a node named "label" whose own ToString is the caption with no
            -- class prefix at all, so collectText is the honest way to it.
            local t = A.collectText(o, 24, 5)
            out[#out + 1] = { name = name, text = t[1],
                              selected = p.IsSelected == true, hidden = p.IsVisible == false }
            if p.IsSelected == true then sel = #out end
            return
        end
        local kk, kn = A.kids(o)
        for i = 1, kn do scan(kk[i], depth + 1) end
    end
    for i = 1, cn do scan(ch[i], 0) end
    return out, sel
end

W.entries = {}
W.widgetSig = nil
W.sig = nil
W.ticks = 0

local function pass()
    local t0 = soft(Ext.Utils.MicrosecTime) or 0
    local ws = soft(Pad.findWidgets) or {}
    local names = {}
    for i = 1, #ws do
        if ws[i].visible ~= false then names[#names + 1] = tostring(ws[i].name) end
    end
    local wsig = table.concat(names, ",")

    local cc = nil
    for i = 1, #ws do
        if ws[i].visible ~= false and tostring(ws[i].name):find("CharacterCreation", 1, true) then
            cc = ws[i].node
        end
    end
    if cc == nil then
        if wsig ~= W.widgetSig then
            W.widgetSig = wsig
            W.entries[#W.entries + 1] = { widgets = names, note = "no character creation" }
        end
        return
    end

    local L = landmarks(cc)
    local tabList, tabSel = nil, nil
    if L.gameplayTabs ~= nil then tabList, tabSel = tabs(L.gameplayTabs) end
    local tabName = tabList and tabSel and tabList[tabSel].text or nil

    local focus = soft(Pad.widgetFocus, cc)
    local focusText = focus and select(1, A.describe(focus)) or nil
    local focusName = focus and tostring(A.props(focus).Name) or nil

    -- The ancestry of the focused control, with what each level says. This is what the
    -- caption rule is built on - "the first ancestor above the value that says something
    -- different" - and it is the only way to see why a tab it does not fit reads as its bare
    -- value ("Бонус +1" with no idea which ability it belongs to).
    local chain = nil
    if focus ~= nil and soft(Pad.pathTo, cc, focus) then
        chain = {}
        local path = Pad.focusPath
        for i = math.max(1, #path - 6), #path do
            local o = path[i]
            local p = A.props(o)
            local parts = A.collectText(o, 200, 10) or {}
            local take = {}
            for k = 1, math.min(#parts, 8) do take[k] = parts[k] end
            chain[#chain + 1] = i .. " " .. select(1, A.splitToString(A.realType(o))) ..
                "/" .. tostring(p.Name) .. " n=" .. #parts .. " [" ..
                table.concat(take, " | ") .. "]"
        end
    end

    local sig = tostring(tabName) .. "|" .. tostring(focusName) .. "|" .. tostring(focusText) ..
                "|" .. wsig
    if sig == W.sig then return end
    W.sig, W.widgetSig = sig, wsig

    local rec = {
        widgets = names,
        walked = L._nodes,
        tab = tabName,
        tabIndex = tabSel,
        tabs = {},
        focusName = focusName,
        focusText = focusText,
        chain = chain,
    }
    for i = 1, #(tabList or {}) do
        local t = tabList[i]
        rec.tabs[i] = tostring(t.text) .. "/" .. t.name .. (t.selected and " *" or "") ..
                      (t.hidden and " (hidden)" or "")
    end
    if L.gameplayPanel ~= nil then rec.panel = texts(L.gameplayPanel, 40, 400) end
    if L.gameplaySubPanel ~= nil then rec.subPanel = texts(L.gameplaySubPanel, 30, 400) end
    if L.appearancePanel ~= nil then rec.appearance = texts(L.appearancePanel, 20, 300) end
    -- The summary is not logged: it is the same character sheet on every entry and it was
    -- two thirds of a 263 KB file. The tooltip is, whenever the player has pinned one.
    for i = 1, #ws do
        local w = ws[i]
        local nm = tostring(w.name)
        if w.visible ~= false and nm:find("Tooltip", 1, true) and nm ~= "WorldTooltips" then
            rec.tooltip = texts(w.node, 40, 600)
            rec.tooltipWidget = nm
        end
    end

    rec.us = (soft(Ext.Utils.MicrosecTime) or 0) - t0
    W.entries[#W.entries + 1] = rec
    if #W.entries > 60 then table.remove(W.entries, 1) end
    A.write("ccwatch", { count = #W.entries, entries = W.entries })
end

function W.tick()
    W.ticks = W.ticks + 1
    if W.ticks % 15 ~= 0 then return end
    soft(pass)
end

function W.start()
    W.stop()
    W.id = Ext.Events.Tick:Subscribe(W.tick)
    _G.A11Y_CCWATCH = W.id
    Ext.Utils.Print("[ccwatch] running")
    return true
end

function W.stop()
    local id = W.id or _G.A11Y_CCWATCH
    if id ~= nil then soft(function() Ext.Events.Tick:Unsubscribe(id) end) end
    W.id, _G.A11Y_CCWATCH = nil, nil
end

W.start()
return W
