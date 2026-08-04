-- Where the options screen keeps the sentence that explains a setting.
--
-- The screen shows a paragraph for whatever the cursor is on - found by OCR, never by the
-- layer, which reads caption, value and kind and stops there. This finds the node that
-- carries it: dump every text-bearing node of Options_c with its ancestry, and take two
-- dumps a selection apart so the one text that changed names itself.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-opttip", "OT")
--     Mods.BG3Access.OT.dump("a")   ... move to another setting ...
--     Mods.BG3Access.OT.dump("b")
--     Mods.BG3Access.OT.diff()

local A, Pad = _G.A11y, _G.Pad
local T = { snaps = {} }

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

local function widget(name)
    local ws = soft(Pad.findWidgets) or {}
    for i = 1, #ws do
        if str(ws[i].name) == name and ws[i].visible ~= false then return ws[i].node end
    end
    return nil
end
T.widget = widget

--- Every visible node that says something, with the path of names above it.
---
--- The path is the point. A paragraph found at depth 22 is useless on its own; what makes
--- it reachable from the reader is the named ancestor it hangs under, and the only way to
--- learn that name is to carry the trail down.
function T.dump(tag, screen)
    local node = widget(screen or "Options_c")
    if node == nil then
        Ext.Utils.Print("[opttip] " .. tostring(screen or "Options_c") .. " is not up")
        return nil
    end

    local lines, texts, n, seen = {}, {}, 0, {}
    local function rec(o, depth, trail)
        if o == nil or n >= 4000 or depth > 30 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1

        local p = A.props(o)
        if p.IsVisible == false then return end
        local cls, label = A.splitToString(A.realType(o))
        local nm = str(p.Name)
        local here = (nm ~= "nil" and nm ~= "") and (trail .. "/" .. nm) or trail

        local said = {}
        for _, s in ipairs(A.strings(p.Text, label)) do
            if A.looksLikeText(s) then said[#said + 1] = Pad.loca(s) end
        end

        local flags = {}
        if p.IsSelected == true then flags[#flags + 1] = "SEL" end
        if p.IsFocused == true then flags[#flags + 1] = "FOC" end
        if p.IsMouseOver == true then flags[#flags + 1] = "hover" end
        if p.IsKeyboardFocusWithin == true then flags[#flags + 1] = "within" end
        if p.AlternationIndex ~= nil then flags[#flags + 1] = "alt=" .. str(p.AlternationIndex) end

        if #said > 0 or #flags > 0 then
            local body = table.concat(said, " ~ "):gsub("[\r\n]+", " / ")
            lines[#lines + 1] = string.format("%d|d%d|%s|%s|%s|%s",
                n, depth, cls, here, table.concat(flags, ","), body)
            for _, s in ipairs(said) do
                if #s > 24 then texts[#texts + 1] = here .. "  ::  " .. s:gsub("[\r\n]+", " / ") end
            end
        end

        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1, here) end
    end
    rec(node, 0, "")

    local file = "A11y/opttip_" .. tostring(tag or "now") .. ".txt"
    Ext.IO.SaveFile(file, table.concat(lines, "\n"))
    T.snaps[tostring(tag or "now")] = texts
    Ext.Utils.Print("[opttip] " .. file .. ": " .. n .. " nodes, " .. #lines ..
                    " with something, " .. #texts .. " long")
    return n
end

--- What the long texts of two snapshots do not have in common.
function T.diff(a, b)
    local A1, B1 = T.snaps[a or "a"] or {}, T.snaps[b or "b"] or {}
    local inA = {}
    for _, s in ipairs(A1) do inA[s] = true end
    local inB = {}
    for _, s in ipairs(B1) do inB[s] = true end
    local out = {}
    for _, s in ipairs(A1) do if not inB[s] then out[#out + 1] = "- " .. s end end
    for _, s in ipairs(B1) do if not inA[s] then out[#out + 1] = "+ " .. s end end
    Ext.IO.SaveFile("A11y/opttip_diff.txt", table.concat(out, "\n"))
    Ext.Utils.Print("[opttip] diff: " .. #out .. " lines, opttip_diff.txt")
    for i = 1, math.min(#out, 12) do Ext.Utils.Print("  " .. out[i]) end
    return #out
end

--- The preview panel as it stands, appended to one file.
---
--- One line per press, so a walk down the whole tab answers in one file whether every row
--- has a paragraph, how short the shortest is, and what a section header shows.
T.tips = {}
function T.tip()
    local node = widget("Options_c")
    if node == nil then return nil end
    local name, body, n, seen = nil, {}, 0, {}
    local function rec(o, depth, inName)
        if o == nil or n >= 400 or depth > 16 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1
        local p = A.props(o)
        if p.IsVisible == false then return end
        local mine = inName or (str(p.Name) == "PreviewName")
        local cls, label = A.splitToString(A.realType(o))
        for _, s in ipairs(A.strings(p.Text, label)) do
            if A.looksLikeText(s) then
                s = Pad.loca(s)
                if mine then name = name or s
                elseif body[#body] ~= s then body[#body + 1] = s end
            end
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1, mine) end
    end
    local ws = soft(Pad.findWidgets) or {}
    for i = 1, #ws do
        if str(ws[i].name) == "Options_c" then
            -- Only the preview branch, found by name, so the sweep costs nothing.
            local hold = nil
            soft(Pad.walkFrom, ws[i].node, function(o)
                if hold ~= nil then return true end
                if str(A.props(o).Name) == "PreviewScroll" then hold = o return true end
            end, 2000)
            if hold ~= nil then rec(hold, 0, false) end
        end
    end
    local joined = table.concat(body, " ~ ")
    T.tips[#T.tips + 1] = string.format("%s  ::  %d  ::  %s", tostring(name), #joined, joined)
    Ext.IO.SaveFile("A11y/opttip_sweep.txt", table.concat(T.tips, "\n"))
    return #T.tips
end

--- Every node under PreviewScroll in traversal order, with its address.
---
--- The reader collapses a repeated sentence only when the two copies are neighbours, and on
--- this panel the paragraph came out twice. Whether that is one element reached twice under
--- two addresses, or two elements, is the difference between "dedup by text" and "widen the
--- adjacency test", and it is not guessable from the readout.
function T.order()
    local node = widget("Options_c")
    if node == nil then return nil end
    local hold = nil
    soft(Pad.walkFrom, node, function(o)
        if hold ~= nil then return true end
        if str(A.props(o).Name) == "PreviewScroll" then hold = o return true end
    end, 2000)
    if hold == nil then Ext.Utils.Print("[opttip] no PreviewScroll") return nil end

    local lines, n, seen = {}, 0, {}
    local function rec(o, depth)
        if o == nil or n >= 300 or depth > 16 then return end
        local id = tostring(o)
        if seen[id] then
            lines[#lines + 1] = string.format("  (seen again) %s", id)
            return
        end
        seen[id] = true
        n = n + 1
        local p = A.props(o)
        local cls, label = A.splitToString(A.realType(o))
        local said = {}
        for _, s in ipairs(A.strings(p.Text, label)) do
            if A.looksLikeText(s) then said[#said + 1] = Pad.loca(s) end
        end
        local body = table.concat(said, " ~ "):gsub("%s+", " ")
        lines[#lines + 1] = string.format("%d|d%d|%s|name=%s|vis=%s|%s|%s", n, depth,
            cls:sub(1, 40), str(p.Name), tostring(p.IsVisible), id, body:sub(1, 60))
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(hold, 0)
    Ext.IO.SaveFile("A11y/opttip_order.txt", table.concat(lines, "\n"))
    Ext.Utils.Print("[opttip] opttip_order.txt: " .. n .. " nodes, " .. #lines .. " lines")
    return n
end

--- Which widgets are up at all, in case the paragraph lives on a screen of its own.
function T.screens()
    local ws = soft(Pad.findWidgets) or {}
    for i = 1, #ws do
        local w = ws[i]
        if w.visible ~= false then
            local info = soft(Pad.visibleScan, w.node, 300, 8) or { nodes = 0, texts = {} }
            Ext.Utils.Print("[opttip] " .. str(w.name) .. " n=" .. tostring(info.nodes) ..
                            " [" .. table.concat(info.texts, " | ") .. "]")
        end
    end
end

Ext.Utils.Print("[opttip] ready: OT.dump(tag) / OT.diff(a,b) / OT.screens()")
return T
