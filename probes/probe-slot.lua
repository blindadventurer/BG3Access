-- Which slot is the D-pad standing on?
--
-- The loot panel now announces itself and can be read end to end, and that is still not
-- looting: the player moves the d-pad, the game highlights a different item, and the layer
-- says nothing because it is reading a *list*, not a *cursor*. Everything the panel holds was
-- already spoken once, on opening; what is missing is which of it is under the selection now.
--
-- There is no Noesis focus in a controller panel to follow (§D12), so the selection lives in a
-- property on the slot itself. This finds out which one - by name and by value - and what text
-- hangs off the node that carries it.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-slot", "SL")
--     Mods.BG3Access.SL.dump()          -- move the d-pad, run it again, compare
--     Mods.BG3Access.SL.diff()          -- what changed since the last dump

local A, Pad = _G.A11y, _G.Pad
local W = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

W.PANEL = "Container_c"

-- Anything whose name suggests "this is the one". Deliberately wide: the runtime's own word
-- for it is what is being looked for, so guessing it in advance would defeat the point.
local MARKS = { "Select", "Highlight", "Current", "Hover", "Focus", "Active", "Index" }

local function marky(name)
    for i = 1, #MARKS do
        if name:find(MARKS[i], 1, true) then return true end
    end
    return false
end

local function panelNode()
    if Pad == nil then return nil end
    local ws = soft(Pad.findWidgets) or {}
    for i = 1, #ws do
        if tostring(ws[i].name) == W.PANEL and ws[i].visible ~= false then return ws[i].node end
    end
    return nil
end
W.panelNode = panelNode

--- The first few strings under a node, which is how a slot is recognised by ear.
local function textUnder(o, budget)
    local out = {}
    local function rec(x, d)
        if x == nil or d > 6 or #out >= 4 or budget.n <= 0 then return end
        local ch, cn = A.kids(x)
        for i = 1, cn do
            budget.n = budget.n - 1
            if budget.n <= 0 then return end
            local p = soft(function() return ch[i]:GetAllProperties() end)
            if type(p) == "table" then
                local t = p.Text or p.Content or p.Label
                if type(t) == "string" and #t > 0 then out[#out + 1] = t end
                rec(ch[i], d + 1)
            end
        end
    end
    rec(o, 0)
    return out
end

--- Every node in the panel carrying a mark that is not false, with what it says.
function W.dump(quiet)
    local node = panelNode()
    if node == nil then _P("[slot] " .. W.PANEL .. " is not up") return nil end

    local rows, budget = {}, { n = 6000 }
    local function rec(o, d)
        if o == nil or d > 20 or budget.n <= 0 then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            budget.n = budget.n - 1
            if budget.n <= 0 then return end
            local p = soft(function() return ch[i]:GetAllProperties() end)
            if type(p) == "table" then
                local hits = {}
                for k, v in pairs(p) do
                    local ks = tostring(k)
                    -- `false` is every slot that is *not* the one; only a positive says where
                    -- the cursor is. A number is kept whatever it is - an index of 0 is an
                    -- answer, and `SelectedIndex` is the shape this most likely takes.
                    if marky(ks) then
                        if v == true then hits[#hits + 1] = ks .. "=true"
                        elseif type(v) == "number" then hits[#hits + 1] = ks .. "=" .. tostring(v)
                        elseif type(v) == "string" and #v > 0 and #v < 40 then
                            hits[#hits + 1] = ks .. "=" .. v
                        end
                    end
                end
                if #hits > 0 then
                    table.sort(hits)
                    rows[#rows + 1] = { depth = d, marks = table.concat(hits, " "),
                                        text = table.concat(textUnder(ch[i], { n = 300 }), " / ") }
                end
                rec(ch[i], d + 1)
            end
        end
    end
    rec(node, 0)

    if not quiet then
        _P("[slot] " .. #rows .. " marked nodes in " .. W.PANEL)
        for i = 1, math.min(#rows, 24) do
            _P("[slot]   d" .. rows[i].depth .. " " .. rows[i].marks ..
               "  << " .. (rows[i].text ~= "" and rows[i].text or "-"))
        end
    end
    W.last = rows
    return rows
end

--- What changed since the last dump. Run it, move the d-pad, run it again: whatever differs
--- between the two is the selection, and nothing else is.
function W.diff()
    local before = W.last
    if before == nil then
        W.dump(true)
        _P("[slot] marked. Move the d-pad, then call SL.diff() again")
        return nil
    end
    local after = W.dump(true)
    if after == nil then return nil end

    local function key(r) return "d" .. r.depth .. "|" .. r.marks .. "|" .. r.text end
    local was = {}
    for _, r in ipairs(before) do was[key(r)] = true end
    local now = {}
    for _, r in ipairs(after) do now[key(r)] = true end

    local gained, lost = {}, {}
    for _, r in ipairs(after) do if not was[key(r)] then gained[#gained + 1] = key(r) end end
    for _, r in ipairs(before) do if not now[key(r)] then lost[#lost + 1] = key(r) end end

    _P("[slot] now marked: " .. (#gained > 0 and table.concat(gained, " ;; ") or "nothing new"))
    _P("[slot] no longer:  " .. (#lost > 0 and table.concat(lost, " ;; ") or "nothing"))
    W.last = after
    return gained, lost
end

_P("[probe-slot] loaded. SL.dump() / SL.diff() - panel = " .. W.PANEL)
return W
