-- Hit-testing the mouse-mode UI from outside, so the pointer can be aimed without eyes.
--
-- Why this exists: the layer only works with the game's control scheme set to Controller
-- (§D9), and that setting lives behind the options screen, which in mouse mode cannot be
-- reached at all - Command:Execute() refuses the entries that carry a CommandParameter and
-- OpenOptions is one of them (§С1). The one input the game does accept in that state is a
-- real OS mouse click (tools/mouse.ps1). What was missing was where to click.
--
-- Noesis answers that itself. Every FrameworkElement reports IsMouseOver, so moving the
-- real pointer and asking the tree who is under it is a closed loop that needs no vision.
-- Two things had to be learned the hard way:
--
--   * the caption is not hit-testable. A button's text sits in a TextBlock whose
--     ActualWidth reads 0, so the deepest node the pointer hits is the button's border and
--     its label has to be read downwards, from that node's children;
--   * a sweep cannot report through the console. GetAllProperties logs
--     "Don't know how to fetch property ContentPresenter:DataContext of type
--     'ls.LocaString'" twice per row on the options screen, which buries every probe line
--     in the screen buffer long before the sweep ends. Probes accumulate in Lua and one
--     JSON file is written at the end.
--
--     Ms = load(Ext.IO.LoadFile("A11y/a11y-mouse.lua"))()
--     Ms.mark('960_400')   probe the current pointer position under that tag
--     Ms.flush('sweep1')   write everything gathered so far
--     Ms.under()           one probe, printed

local A = _G.A11y
if A == nil then
    _P("[ms] a11y-menu is not loaded - push it first")
    error("a11y-mouse needs A11y")
end
local P = _G.Pad
if P == nil then
    _P("[ms] a11y-pad is not loaded - push it first")
    error("a11y-mouse needs Pad")
end

local M = {}
local soft, props = A.soft, A.props

M.marks = {}

--- Captions the sweep needs, keyed by ASCII: the console input buffer is ANSI and a non-Latin
--- argument arrives as question marks (§9 rule 3), so the text lives in this file and the
--- console passes a key.
---
--- These are Russian and stay Russian, alone in this repository. This module is not part of
--- the layer - it is not in the load order, nothing a player runs reaches it, and it exists to
--- aim a real mouse pointer at the options screen of the one machine it was written on. Making
--- it multilingual would mean handles for forty captions to serve a debugging tool; if you need
--- it on a game in another language, replace the values.
M.CAPTIONS = {
    options = "Параметры", newgame = "Новая игра", load = "Загрузить игру",
    multi = "Сетевая игра", mods = "Менеджер модов", credits = "Авторы",
    quit = "Выход из игры", cont = "Продолжить",
    scheme = "Режим ввода", controller = "Контроллер", keyboard = "Клавиатура",
    auto = "Авто", back = "Назад", accept = "Принять", apply = "Применить",
    game = "Игра", reset = "Сбросить",
    -- Character creation: the steps down the left of the screen. The pad reaches them with
    -- the bumpers, which no key is bound to (the keyboard rows of the binding table are
    -- placeholders), so from outside the game they can only be clicked.
    race = "Раса", subrace = "Подраса", cclass = "Класс", subclass = "Подкласс",
    deity = "Божество", spells = "Заклинания", background = "Происхождение",
    abilities = "Способности", racialskills = "Расовые навыки", skills = "Навыки",
    proficient = "Навыки с мастерством", appearance = "Внешность",
    review = "Обзор персонажа", feats = "Фокусы",
}

--- The label of one node, without descending.
local function ownLabel(o)
    local p = props(o)
    return A.firstText(p.Text, select(2, A.splitToString(A.realType(o))))
end
M.ownLabel = ownLabel

--- Walk the widget that is actually up, collecting every node the pointer is over.
---
--- They nest - the chain runs from the screen root down to the leaf - so the answer is the
--- deepest one, plus whatever text hangs under it. The downward read is deliberately
--- shallow: from a panel root it would return the first caption on the whole screen and
--- every background probe would look like a hit.
function M.under(quiet)
    local a = P.active(60)
    if a == nil then
        if not quiet then _P("[ms] no active screen") end
        return nil
    end
    local chain = {}
    local n = 0
    local function rec(o, depth)
        if o == nil or n > 4000 then return end
        n = n + 1
        local p = props(o)
        if p.IsMouseOver == true then
            chain[#chain + 1] = { depth = depth, cls = select(1, A.splitToString(A.realType(o))),
                                  name = p.Name, own = ownLabel(o), node = o }
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(a.node, 0)

    -- Up the chain until something says its name. What the pointer actually lands on is a
    -- leaf image - Image#highlight on a settings row, ls.LSNineSliceImage#Box on a framed
    -- one - and those hold no text at all. The caption belongs to the row a few levels
    -- above. Walking up from the leaf and stopping at the first node that yields any text
    -- lands on that row, because everything below it is chrome; going the other way would
    -- return the whole screen from the panel root.
    local deepest = chain[#chain]
    local text, from = nil, nil
    for i = #chain, 1, -1 do
        local parts = A.collectText(chain[i].node, 24, 4)
        local take = {}
        for j = 1, math.min(#parts, 4) do take[j] = parts[j] end
        if #take > 0 then
            text = table.concat(take, ", ")
            from = chain[i].depth
            break
        end
    end

    local named = nil
    for i = #chain, 1, -1 do
        if type(chain[i].name) == "string" and chain[i].name ~= "" then named = chain[i].name break end
    end

    local out = { screen = a.name, hits = #chain, scanned = n, text = text, from = from,
                  name = named, cls = deepest and deepest.cls, depth = deepest and deepest.depth,
                  chain = chain }
    if not quiet then
        _P("[ms] " .. tostring(a.name) .. " hits=" .. #chain ..
           " deepest=" .. tostring(out.cls) .. " name=" .. tostring(named) ..
           " text=" .. tostring(text))
    end
    return out
end

--- The same question asked of the whole tree rather than the active screen.
---
--- A Noesis popup - which is what a combo box drops down - is not a child of the screen
--- widget. It renders in its own visual root, so a walk of the active screen never sees it
--- and every probe over an open dropdown reports the row underneath it instead. Reading
--- screens from the root is wrong for the usual reason (a stale focus below a modal, §D3),
--- but IsMouseOver is genuinely spatial: only what is under the pointer says true.
function M.underRoot(quiet)
    local chain = {}
    local n = 0
    A.walk(function(o)
        n = n + 1
        local p = props(o)
        if p.IsMouseOver == true then
            chain[#chain + 1] = { cls = select(1, A.splitToString(A.realType(o))),
                                  name = p.Name, own = ownLabel(o), node = o,
                                  w = p.ActualWidth, h = p.ActualHeight }
        end
    end, 12000)

    local text, fromCls = nil, nil
    for i = #chain, 1, -1 do
        local parts = A.collectText(chain[i].node, 24, 4)
        local take = {}
        for j = 1, math.min(#parts, 3) do take[j] = parts[j] end
        if #take > 0 then text = table.concat(take, ", ") fromCls = chain[i].cls break end
    end

    local out = { hits = #chain, scanned = n, text = text, fromCls = fromCls, chain = chain }
    if not quiet then
        _P("[ms] root hits=" .. #chain .. " text=" .. tostring(text) ..
           " from=" .. tostring(fromCls))
    end
    return out
end

--- Probe from the root and record it, for sweeping over popups.
function M.markRoot(tag)
    local r = M.underRoot(true)
    local tail = {}
    for i = math.max(1, #r.chain - 4), #r.chain do
        tail[#tail + 1] = tostring(r.chain[i].cls) ..
            (r.chain[i].name and r.chain[i].name ~= "" and ("#" .. r.chain[i].name) or "")
    end
    M.marks[#M.marks + 1] = { tag = tag, hits = r.hits, text = r.text,
                              fromCls = r.fromCls, tail = table.concat(tail, " > ") }
    return M.marks[#M.marks]
end

--- Open the combo box of a named settings row, so its items are laid out and can be aimed
--- at. The list is virtualised: while the drop-down is shut the items exist with no size
--- and IsVisible false, which is why a sweep finds nothing to click.
function M.openCombo(key)
    local caption = M.CAPTIONS[key] or key
    local row = P.findRow(caption)
    if row == nil or row.combo == nil then
        _P("[ms] openCombo: no combo for " .. caption)
        return false
    end
    -- Same tick as the lookup: a node handle does not survive to the next one (§9 rule 1).
    local r = A.try(function() row.combo:SetProperty("IsDropDownOpen", true) end)
    local p = props(row.combo)
    _P("[ms] openCombo " .. caption .. " ok=" .. tostring(r.ok) ..
       " open=" .. tostring(p.IsDropDownOpen) .. " idx=" .. tostring(p.SelectedIndex) ..
       " err=" .. tostring(r.error))
    return r.ok
end

--- Record one probe. Nothing is printed: on a 761-node screen the property warnings would
--- bury it. Tag is the pointer position the caller used.
function M.mark(tag)
    local r = M.under(true)
    local rec = { tag = tag }
    if r ~= nil then
        rec.hits, rec.text, rec.name, rec.cls, rec.depth, rec.from =
            r.hits, r.text, r.name, r.cls, r.depth, r.from
        -- The last few classes say what kind of thing is under the pointer even when the
        -- caption is a data-bound string the walk cannot reach.
        local tailv = {}
        for i = math.max(1, #r.chain - 3), #r.chain do
            tailv[#tailv + 1] = tostring(r.chain[i].cls) ..
                (r.chain[i].name and ("#" .. tostring(r.chain[i].name)) or "")
        end
        rec.tail = table.concat(tailv, " > ")
    end
    M.marks[#M.marks + 1] = rec
    return rec
end

function M.flush(name)
    A.write(name or "sweep", { count = #M.marks, marks = M.marks })
    M.marks = {}
end

function M.clear() M.marks = {} end

--- Where a captioned element sits, by asking every row of the screen who is under the
--- pointer - used to confirm a click landed on what was intended.
function M.find(key)
    local caption = M.CAPTIONS[key] or key
    local a = P.active(60)
    if a == nil then _P("[ms] no active screen") return nil end
    local hits = {}
    local function rec(o, depth)
        if o == nil or #hits > 20 then return end
        local t = ownLabel(o)
        if t ~= nil and t:find(caption, 1, true) then
            local p = props(o)
            hits[#hits + 1] = { depth = depth, text = t, cls = select(1, A.splitToString(A.realType(o))),
                                name = p.Name, visible = p.IsVisible, over = p.IsMouseOver,
                                selected = p.IsSelected, enabled = p.IsEnabled }
        end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(a.node, 0)
    _P("[ms] find '" .. caption .. "' -> " .. #hits .. " on " .. tostring(a.name))
    for i, h in ipairs(hits) do
        _P("   " .. i .. ". d=" .. h.depth .. " " .. tostring(h.cls) ..
           " vis=" .. tostring(h.visible) .. " over=" .. tostring(h.over) ..
           " sel=" .. tostring(h.selected))
    end
    A.write("find_" .. tostring(key), { caption = caption, screen = a.name, hits = hits })
    return hits
end

-- Aiming at a named row -----------------------------------------------------------
--
-- Reading downwards from whatever the pointer hits does not identify a settings row: the
-- hit is an Image#highlight covering the row, and the row's caption is a ContentPresenter
-- bound to an ls.LocaString, which GetAllProperties cannot fetch ("Don't know how to fetch
-- property ContentPresenter:DataContext of type 'ls.LocaString'"). So the caption is not
-- under the hit at all, and a downward read walks up to the list and returns the *first*
-- row's label for every probe on the panel.
--
-- The question is turned around instead. The row is found once by its caption, and the
-- sweep asks that node whether the pointer is on it. Noesis exposes Parent, so the climb
-- from caption to row container is a property read rather than a search.

--- The node whose own label is the caption, and its ancestors.
local function captionNode(caption)
    local a = P.active(60)
    if a == nil then return nil, nil, "no active screen" end
    local hit = nil
    local function rec(o, depth)
        if o == nil or hit ~= nil then return end
        local t = ownLabel(o)
        if t ~= nil and t == caption then hit = { node = o, depth = depth } return end
        local ch, cn = A.kids(o)
        for i = 1, cn do rec(ch[i], depth + 1) end
    end
    rec(a.node, 0)
    if hit == nil then return nil, a, "caption not found" end
    return hit, a
end
M.captionNode = captionNode

--- Is the pointer on the row that carries this caption?
---
--- Answers for the caption node itself and for each ancestor up to `levels`, because the
--- clickable control is not the text - it is a container some way above it, and which one
--- differs between a combo row and a checkbox row.
function M.rowProbe(key, tag, levels)
    local caption = M.CAPTIONS[key] or key
    local hit, a, err = captionNode(caption)
    local rec = { tag = tag, key = key, screen = a and a.name }
    if hit == nil then
        rec.error = err
        M.marks[#M.marks + 1] = rec
        return rec
    end

    local up = {}
    local o = hit.node
    for i = 0, (levels or 10) do
        if o == nil then break end
        local p = props(o)
        up[#up + 1] = { level = i, cls = select(1, A.splitToString(A.realType(o))),
                        name = p.Name, over = p.IsMouseOver == true }
        o = p.Parent
    end
    rec.depth = hit.depth
    -- The lowest ancestor the pointer is actually on: that is the row, and its level says
    -- how far above the caption the clickable box sits.
    for _, u in ipairs(up) do
        if u.over then rec.overAt = u.level rec.overCls = u.cls rec.overName = u.name break end
    end
    local parts = {}
    for _, u in ipairs(up) do
        parts[#parts + 1] = u.level .. ":" .. tostring(u.cls) ..
            (u.name and u.name ~= "" and ("#" .. u.name) or "") .. (u.over and "*" or "")
    end
    rec.chain = table.concat(parts, " ")
    M.marks[#M.marks + 1] = rec
    return rec
end

--- Same question for every caption at once, so one sweep maps a whole screen.
--- Keys are ASCII; the captions come from M.CAPTIONS.
function M.rowsProbe(tag, keys)
    for _, k in ipairs(keys) do M.rowProbe(k, tag .. "/" .. k) end
end

--- One file answering "where are we and did that click land".
---
--- Written for the input-mode tool, which has to check each step before taking the next:
--- clicking blind through the options screen is how a setting ends up changed that nobody
--- asked for. Goes to a file rather than the console, which on a large screen is unreadable.
function M.state(tag)
    local mode = A.soft(function() return Ext.Utils.GetGlobalSwitches().ControllerMode end)
    local a = P.active(8)
    local rec = { tag = tag, mode = tostring(mode), screen = tostring(a and a.name) }

    local row = A.soft(function() return P.findRow(P.schemeRow()) end)
    if row ~= nil and row.combo ~= nil then
        local cp = props(row.combo)
        rec.row = tostring(row.text)
        rec.comboOpen = tostring(cp.IsDropDownOpen)
        rec.selectedIndex = tostring(cp.SelectedIndex)
    end

    local r = M.underRoot(true)
    rec.under = tostring(r and r.text)
    rec.underCls = tostring(r and r.fromCls)
    -- Compared here, not by the caller: the console cannot carry a Russian argument (§9
    -- rule 3), and the class of the node the text was found on is not stable enough to
    -- check against - it is a Border as often as a ComboBoxItem.
    rec.isController = tostring(r ~= nil and r.text == M.CAPTIONS.controller)

    A.write("state_" .. tostring(tag), rec)
    return rec
end

_P("[ms] a11y-mouse loaded. Ms.mark/Ms.rowProbe(key,tag)/Ms.flush(name)/Ms.under()/Ms.state(tag)")
return M
