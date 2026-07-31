-- Character creation, whole tree, from the root.
--
-- From the root and not from the screen widget on purpose: a Noesis Popup lives in its own
-- visual root, so a tooltip - if the game builds one - is invisible to a walk of
-- CharacterCreation_c. Hidden branches are kept too, for the same reason: a tooltip that has
-- not been asked for yet is in the tree with IsVisible false.
local A = _G.A11y
local out = {}
local lines = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local root = soft(Ext.ClientUI.GetRoot)
if root == nil then
    Ext.Utils.Print("[probe] no root")
    return
end

local n, seen = 0, {}
local CAP = 6000

local function rec(o, depth)
    if o == nil or n >= CAP or depth > 40 then return end
    local id = tostring(o)
    if seen[id] then return end
    seen[id] = true
    n = n + 1

    local rt = A.realType(o)
    local cls, label = A.splitToString(rt)
    if A.NO_TEXT[cls] then return end

    local p = A.props(o)
    local text = nil
    if type(p.Text) == "string" and p.Text ~= "" then text = p.Text end
    if text == nil and type(label) == "string" and label ~= "" then text = label end
    if text ~= nil then text = text:gsub("[\r\n]+", " / ") end

    local flags = {}
    if p.IsVisible == false then flags[#flags + 1] = "hid" end
    if p.IsSelected == true then flags[#flags + 1] = "SEL" end
    if p.IsFocused == true then flags[#flags + 1] = "FOC" end
    if p.IsKeyboardFocusWithin == true then flags[#flags + 1] = "within" end
    if p.AlternationIndex ~= nil then flags[#flags + 1] = "alt=" .. tostring(p.AlternationIndex) end
    if p.IsChecked ~= nil then flags[#flags + 1] = "chk=" .. tostring(p.IsChecked) end
    if type(p.Opacity) == "number" and p.Opacity < 1 then
        flags[#flags + 1] = "op=" .. string.format("%.2f", p.Opacity)
    end

    lines[#lines + 1] = string.format("%d|%s%s|%s|%s|%s|%s",
        n, string.rep(" ", depth), tostring(depth), cls, tostring(p.Name),
        table.concat(flags, ","), tostring(text))

    local ch, cn = A.kids(o)
    for i = 1, cn do rec(ch[i], depth + 1) end
end

rec(root, 0)

Ext.IO.SaveFile("A11y/cc_tree.txt", table.concat(lines, "\n"))
Ext.Utils.Print("[probe] cc_tree written: " .. n .. " nodes")
return { nodes = n }
