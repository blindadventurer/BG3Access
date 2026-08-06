-- What the camp and rest screens actually carry.
--
-- The player met both of them blind: the layer read seven button labels off MakeCamp and not one
-- number, so "how does resting work, and what are these supplies" had to be answered with OCR.
--
-- The markup says where the answers are. `Mods/MainUI/GUI/Pages/MakeCamp_c.xaml` binds
-- `PartyCampSupplies`, `RequiredPartySupplies` and `SelectedSuppliesAmount`;
-- `RestPanel_c.xaml` names `OptionDescription`, `OptionWarning` and the four options
-- (CampItem, ShortRestItem, LongRestItem, FastTravelItem). None of that is text in the tree -
-- it is the record the template is bound to, the same place the dice roll keeps its numbers.
--
-- This probe only looks. It presses nothing and changes nothing.
--
--     Mods.BG3Access.A11yBoot.loadDev("probe-rest", "PR")
--     Mods.BG3Access.PR.all()

local A, Pad = _G.A11y, _G.Pad
local W = {}

local function soft(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function str(v) return tostring(soft(function() return tostring(v) end)) end

--- Every widget on screen right now, with how big it is.
function W.screens()
    local ws = soft(Pad.findWidgets) or {}
    local out = {}
    for i = 1, #ws do
        local w = ws[i]
        out[#out + 1] = { name = str(w.name), visible = (w.visible ~= false) }
    end
    A.write("rest_screens", out)
    for i = 1, #out do
        _P("[rest] screen " .. out[i].name .. (out[i].visible and "" or " (hidden)"))
    end
    return out
end

-- A value worth writing down: a number, a short string, a bool. Anything longer is a sentence,
-- which is also worth writing down; anything else is an object and only its type matters.
local function value(v)
    local t = type(v)
    if t == "number" or t == "boolean" then return v end
    if t == "string" then return (#v > 400) and (v:sub(1, 400) .. "...") or v end
    return nil
end

--- Walk one screen and collect both halves: the elements' own text, and every bound record.
---
--- The split is the one `dataOf` makes - an element carries ActualWidth or IsVisible, a record
--- carries neither - except that here nothing is filtered by name, because the point is to find
--- out what the names are.
function W.dump(want, depth, budget)
    want = tostring(want or "MakeCamp")
    local ws = soft(Pad.findWidgets) or {}
    local node, found = nil, nil
    for i = 1, #ws do
        local n = str(ws[i].name)
        if ws[i].visible ~= false and n:lower():find(want:lower(), 1, true) then
            node, found = ws[i].node, n
        end
    end
    if node == nil then
        _P("[rest] no visible widget matching " .. want)
        return nil
    end

    local out = { screen = found, texts = {}, records = {} }
    local left = { n = budget or 3000 }
    local seen = {}

    local function walk(o, d, path)
        if o == nil or d > (depth or 14) or left.n <= 0 then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            left.n = left.n - 1
            if left.n <= 0 then return end
            local kid = ch[i]
            local p = soft(function() return kid:GetAllProperties() end)
            if type(p) == "table" then
                local isElement = (p.ActualWidth ~= nil or p.IsVisible ~= nil)
                if isElement then
                    local t = p.Text
                    if type(t) == "string" and t ~= "" and not seen["t:" .. t] then
                        seen["t:" .. t] = true
                        out.texts[#out.texts + 1] = { text = t, at = path }
                    end
                    walk(kid, d + 1, path .. "/" .. tostring(p.Name or i))
                else
                    -- A bound record. Its keys are the answer to the whole question.
                    local rec = {}
                    for k, v in pairs(p) do
                        local val = value(v)
                        if val ~= nil then rec[tostring(k)] = val
                        else rec[tostring(k)] = "<" .. type(v) .. ">" end
                    end
                    if next(rec) ~= nil then
                        out.records[#out.records + 1] = { at = path, fields = rec }
                    end
                end
            end
        end
    end

    walk(node, 0, found)
    _P("[rest] " .. found .. ": " .. #out.texts .. " texts, " .. #out.records .. " records, " ..
       ((budget or 3000) - left.n) .. " nodes walked")
    A.write("rest_dump_" .. want, out)
    return out
end

--- The message box in tree order, with nothing deduplicated and nothing skipped.
---
--- `dump` answered what is in there and made the next question obvious: the sentence is in
--- pieces. Larian's inline markup - `<LSTag Tooltip="CampSupplies">припасов</LSTag>` - is not
--- flattened into the run that holds it; the tagged word becomes a sibling element of its own,
--- so the plain parts and the tagged parts sit in different places in the tree and a reader that
--- takes them in the order it happens to meet them says
---
---     "У вас достаточно , чтобы восстановить все  и  ... припасов ОЗ ячейки заклинаний"
---
--- This walks the whole box depth-first, keeps the index of every step, and writes text in the
--- order the walk found it - which is the only thing that can settle how to put the sentence
--- back together.
function W.msg(want)
    want = tostring(want or "MessageBox")
    local ws = soft(Pad.findWidgets) or {}
    local node, found = nil, nil
    for i = 1, #ws do
        local n = str(ws[i].name)
        if ws[i].visible ~= false and n:lower():find(want:lower(), 1, true) then
            node, found = ws[i].node, n
        end
    end
    if node == nil then _P("[rest] no visible " .. want) return nil end

    local out, left = {}, { n = 4000 }
    local function walk(o, d, path)
        if o == nil or d > 20 or left.n <= 0 then return end
        local ch, cn = A.kids(o)
        for i = 1, cn do
            left.n = left.n - 1
            if left.n <= 0 then return end
            local p = soft(function() return ch[i]:GetAllProperties() end)
            if type(p) == "table" then
                local here = path .. "/" .. tostring(i) ..
                             (p.Name ~= nil and p.Name ~= "" and (":" .. tostring(p.Name)) or "")
                local t = p.Text
                if type(t) == "string" and t ~= "" then
                    out[#out + 1] = { at = here, text = t, vis = p.IsVisible }
                end
                if p.ActualWidth ~= nil or p.IsVisible ~= nil then walk(ch[i], d + 1, here) end
            end
        end
    end
    walk(node, 0, found)

    _P("[rest] " .. found .. ": " .. #out .. " text nodes in tree order")
    A.write("rest_msg", out)
    return out
end

-- Waiting for the screen instead of asking the player to hold it open.
--
-- These panels are opened by pressing a button and closed by the next one, and coordinating
-- "open it now, tell me, hold still" over a chat window is a worse way to spend a tester's
-- evening than a poll that costs nothing. It arms itself, fires once per screen it has never
-- dumped, and lets go after all of them are seen.
W.watching = nil
W.got = nil

function W.watch(names)
    W.got = W.got or {}
    local want = names or { "MakeCamp", "RestPanel" }
    if W.watching ~= nil then
        soft(function() Ext.Events.Tick:Unsubscribe(W.watching) end)
        W.watching = nil
    end
    W.watching = soft(function()
        return Ext.Events.Tick:Subscribe(function()
            local ws = soft(Pad.findWidgets) or {}
            for i = 1, #ws do
                if ws[i].visible ~= false then
                    local n = str(ws[i].name)
                    for _, w in ipairs(want) do
                        if n:lower():find(w:lower(), 1, true) and not W.got[n] then
                            W.got[n] = true
                            _P("[rest] caught " .. n)
                            -- Both halves, in one frame: what is in there, and in what order.
                            -- These boxes live for seconds and the second question cannot be
                            -- asked after the fact.
                            soft(function() W.dump(w) end)
                            soft(function() W.msg(w) end)
                        end
                    end
                end
            end
        end)
    end)
    _P("[rest] watching for " .. table.concat(want, ", ") .. ": " .. tostring(W.watching))
    return W.watching
end

function W.unwatch()
    if W.watching ~= nil then
        soft(function() Ext.Events.Tick:Unsubscribe(W.watching) end)
        W.watching = nil
    end
    _P("[rest] not watching")
end

function W.all()
    W.screens()
    for _, name in ipairs({ "MakeCamp", "RestPanel", "Rest", "Camp" }) do
        W.dump(name)
    end
    _P("[rest] done")
end

_P("[probe-rest] loaded. PR.screens() / PR.dump(\"MakeCamp\") / PR.all()")
return W
