-- Where the mod manager keeps a mod's description.
--
-- The browse list's record carries a name, a size, a download count and an install state, and
-- nothing a player would read: no description, no author, no dependencies. Those only exist
-- once the card is opened (`InDetailsView=true`), and a structural dump does not reach them -
-- the widget is over three thousand nodes and probe-screens stops at two thousand.
--
-- So this does not walk for elements. It walks for **models**: every child anywhere in the
-- widget that is not an element, grouped by the set of fields it carries. One line per distinct
-- shape, with the node that owns it and a sample - which is enough to say which model is the
-- card and which of its fields is the text, without guessing at a single name.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-moddetails", "MD")
--     Mods.BG3Access.MD.run()

local A, Pad = _G.A11y, _G.Pad
local M = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

M.MAX = 12000

--- Element or model, told apart by what it carries rather than by its type - see
--- probe-screens: an element has a size and a visibility, a model has a domain.
local function propsOf(o)
    return soft(function() return o:GetAllProperties() end)
end

local function isElement(p)
    return type(p) == "table" and (p.ActualWidth ~= nil or p.IsVisible ~= nil
                                   or p.IsHitTestVisible ~= nil)
end

function M.run(tag)
    local ws = soft(Pad.findWidgets) or {}
    local node = nil
    for i = 1, #ws do
        if str(ws[i].name) == "ModBrowser_c" and ws[i].visible ~= false then node = ws[i].node end
    end
    if node == nil then Ext.Utils.Print("[md] ModBrowser_c is not up") return nil end

    local shapes, order, n, seen = {}, {}, 0, {}

    local function note(owner, p)
        local names = {}
        for k in pairs(p) do names[#names + 1] = tostring(k) end
        table.sort(names)
        local key = table.concat(names, ",")
        local s = shapes[key]
        if s == nil then
            -- The sample keeps the long values whole: the point of the exercise is to find a
            -- description, and a description truncated to forty characters looks exactly like
            -- a caption.
            local parts = {}
            for _, k in ipairs(names) do
                local v = p[k]
                local t = type(v)
                if t == "boolean" or t == "number" or t == "string" then
                    local sv = str(v)
                    if #sv > 400 then sv = sv:sub(1, 400) .. "...<" .. #sv .. " bytes>" end
                    parts[#parts + 1] = k .. "=" .. sv
                end
            end
            s = { count = 0, owner = owner, fields = key, sample = table.concat(parts, "  ") }
            shapes[key] = s
            order[#order + 1] = key
        end
        s.count = s.count + 1
    end

    local function rec(o, depth, ownerName)
        if o == nil or n >= M.MAX or depth > 40 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1

        local p = propsOf(o)
        local name = ownerName
        if type(p) == "table" and p.Name ~= nil and str(p.Name) ~= "" and str(p.Name) ~= "nil" then
            name = str(p.Name)
        end

        local ch, cn = A.kids(o)
        for i = 1, cn do
            local cp = propsOf(ch[i])
            if type(cp) == "table" and not isElement(cp) then
                note(name, cp)
            else
                rec(ch[i], depth + 1, name)
            end
        end
    end
    rec(node, 0, "ModBrowser_c")

    local out = { "nodes walked: " .. n, "distinct models: " .. #order, "" }
    for _, key in ipairs(order) do
        local s = shapes[key]
        out[#out + 1] = string.format("== x%d  under %s", s.count, tostring(s.owner))
        out[#out + 1] = "   " .. s.sample
        out[#out + 1] = ""
    end
    local file = "A11y/mod_models_" .. tostring(tag or "now") .. ".txt"
    Ext.IO.SaveFile(file, table.concat(out, "\n"))
    Ext.Utils.Print("[md] " .. file .. ": " .. n .. " nodes, " .. #order .. " models")
    return #order
end

--- Every text-bearing node of the widget, with the nearest named ancestor.
---
--- The models turned out to carry no description at all - the card renders it as text, and the
--- structural dump never reached it because it stops at two thousand nodes and the widget is
--- four thousand. So this is the other half of the same question: not "which model holds the
--- text" but "which node does", and the named ancestor is what a reader would search for.
function M.texts(tag)
    local ws = soft(Pad.findWidgets) or {}
    local node = nil
    for i = 1, #ws do
        if str(ws[i].name) == "ModBrowser_c" and ws[i].visible ~= false then node = ws[i].node end
    end
    if node == nil then Ext.Utils.Print("[md] ModBrowser_c is not up") return nil end

    local out, n, seen = {}, 0, {}
    local function rec(o, depth, owner, hidden)
        if o == nil or n >= M.MAX or depth > 40 then return end
        local id = tostring(o)
        if seen[id] then return end
        seen[id] = true
        n = n + 1

        local p = A.props(o)
        local name = owner
        if p.Name ~= nil and str(p.Name) ~= "" and str(p.Name) ~= "nil" then name = str(p.Name) end
        local hid = hidden or (p.IsVisible == false)

        local cls, label = A.splitToString(A.realType(o))
        for _, s in ipairs(A.strings(p.Text, label)) do
            if type(s) == "string" and s ~= "" and s ~= "nil" then
                s = s:gsub("[\r\n]+", " / ")
                out[#out + 1] = string.format("%s%d|%s|%s|%d bytes|%s",
                    hid and "HID " or "", depth, tostring(name), cls, #s, s)
            end
        end

        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1, name, hid) end
    end
    rec(node, 0, "ModBrowser_c", false)

    local file = "A11y/mod_texts_" .. tostring(tag or "now") .. ".txt"
    Ext.IO.SaveFile(file, table.concat(out, "\n"))
    Ext.Utils.Print("[md] " .. file .. ": " .. n .. " nodes, " .. #out .. " strings")
    return #out
end

Ext.Utils.Print("[md] probe-moddetails ready: MD.run() / MD.texts()")
return M
