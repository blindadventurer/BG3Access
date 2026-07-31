--- Server-side host viability probes.
--- E7 entity scan cost/composition, E8 dialog manager on the server, plus a check
--- that the Osiris drive-paths the design depends on actually resolve.

local C = Ext.Require("Diag/Common.lua")
local M = {}

local CATEGORY_COMPONENTS = {
    character   = "IsCharacter",
    item        = "IsItem",
    displayName = "DisplayName",
    canInteract = "CanInteract",
    lootable    = "CanBeLooted",
    disarmable  = "CanBeDisarmed",
    health      = "Health",
    transform   = "Transform",
    offStage    = "OffStage",
    interaction = "ObjectInteraction",
}

local function hostEntity()
    local guid = C.soft(function() return Osi.GetHostCharacter() end)
    if guid == nil then return nil, nil end
    return C.soft(Ext.Entity.Get, guid), guid
end

local function positionOf(entity)
    return C.soft(function()
        local t = entity.Transform.Transform.Translate
        return { t[1], t[2], t[3] }
    end)
end

-- ------------------------------------------------------------------- E7

function M.E7_scan()
    local out = {}
    local ent, guid = hostEntity()
    out.hostCharacter = guid
    if ent == nil then
        out.error = "no host character (not in a session?)"
        C.report("E7_scan", out)
        return out
    end
    local pos = positionOf(ent)
    out.position = pos
    if pos == nil then
        out.error = "could not read Transform"
        C.report("E7_scan", out)
        return out
    end

    out.radii = {}
    for _, r in ipairs({ 5, 10, 20, 30, 50 }) do
        local t0 = C.now()
        local res = C.try(Ext.Entity.GetEntitiesAroundPosition, pos, r + 0.0)
        local dt = C.now() - t0
        local entry = { radius = r, micros = dt, ok = res.ok, error = res.error }
        if res.ok and res.value ~= nil then
            local list = res.value
            entry.count = #list
            local cats = {}
            for k in pairs(CATEGORY_COMPONENTS) do cats[k] = 0 end
            local named = {}
            local t1 = C.now()
            for i = 1, #list do
                local e = list[i]
                for cat, comp in pairs(CATEGORY_COMPONENTS) do
                    if C.soft(function() return e[comp] ~= nil end) then
                        cats[cat] = cats[cat] + 1
                    end
                end
                if #named < 40 then
                    local nm = C.soft(function() return e.DisplayName.Name:Get() end)
                    if nm ~= nil and nm ~= "" then
                        local d = C.soft(function()
                            local t = e.Transform.Transform.Translate
                            local dx, dy, dz = t[1] - pos[1], t[2] - pos[2], t[3] - pos[3]
                            return math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) * 10) / 10
                        end)
                        named[#named + 1] = { name = nm, dist = d }
                    end
                end
            end
            entry.classifyMicros = C.now() - t1
            entry.categories = cats
            entry.sampleNames = named
        end
        out.radii[#out.radii + 1] = entry
    end

    -- Pathfinding to something 10m away, since the scanner must gate on reachability.
    local pf = {}
    local target = { pos[1] + 8.0, pos[2], pos[3] + 8.0 }
    local t0 = C.now()
    local pr = C.try(Ext.Level.BeginPathfindingImmediate, ent, target)
    pf.beginOk = pr.ok
    pf.beginError = pr.error
    if pr.ok and pr.value ~= nil then
        local fr = C.try(Ext.Level.FindPath, pr.value)
        pf.findOk = fr.ok
        pf.found = fr.ok and fr.value or nil
        pf.findError = fr.error
        C.try(Ext.Level.ReleasePath, pr.value)
    end
    pf.micros = C.now() - t0
    out.pathfinding = pf

    C.report("E7_scan", out)
    return out
end

-- ------------------------------------------------------------------- E8

function M.E8_dialog()
    local out = {}
    local r = C.try(Ext.Utils.GetDialogManager)
    out.available = r.ok and r.value ~= nil
    out.error = r.error
    if not out.available then
        C.report("E8_dialog_server", out)
        return out
    end
    local mgr = r.value
    out.dialogs = {}
    C.try(function()
        for id, inst in pairs(mgr.Dialogs) do
            local d = {
                id = id,
                state = C.soft(function() return inst.State end),
                resource = C.soft(function() return tostring(inst.DialogResourceUUID) end),
                localHighlighted = C.soft(function() return inst.LocalHighlightedAnswer end),
                answers = {},
            }
            C.try(function()
                for i, sel in ipairs(inst.NodeSelection) do
                    d.answers[i] = { lineId = C.soft(function() return sel.LineId end) }
                end
            end)
            out.dialogs[#out.dialogs + 1] = d
        end
    end)
    out.activeDialogCount = #out.dialogs
    C.report("E8_dialog_server", out)
    return out
end

-- ------------------------------------------- Osiris drive-path availability

local OSI_QUERIES = {
    { "GetHostCharacter", 0 },
    { "GetPosition", 1 },
    { "IsInCombat", 1 },
    { "GetDisplayName", 1 },
}

function M.osiris()
    local out = { queries = {}, note = "calls are only checked for resolvability, never invoked" }
    local ent, guid = hostEntity()
    out.hostCharacter = guid

    local q = {}
    q.GetHostCharacter = C.try(function() return Osi.GetHostCharacter() end)
    if guid then
        q.GetPosition = C.try(function() local x, y, z = Osi.GetPosition(guid); return { x, y, z } end)
        q.IsInCombat = C.try(function() return Osi.IsInCombat(guid) end)
        q.GetDisplayName = C.try(function() return Osi.GetDisplayName(guid) end)
    end
    for k, v in pairs(q) do
        out.queries[k] = { ok = v.ok, value = C.plain(v.value), error = v.error }
    end

    C.report("osiris", out)
    return out
end

function M.combat()
    local out = {}
    local _, guid = hostEntity()
    if guid == nil then
        out.error = "no host character"
        C.report("combat", out)
        return out
    end
    out.inCombat = C.soft(function() return Osi.IsInCombat(guid) end)
    local cg = C.soft(function() return Osi.CombatGetGuidFor(guid) end)
    out.combatGuid = cg
    if cg ~= nil and cg ~= "" then
        out.active = C.soft(function() return Osi.CombatGetActiveEntity(cg) end)
        out.partyCount = C.soft(function() return Osi.CombatGetInvolvedPartyMembersCount(cg) end)
    end
    local ent = C.soft(Ext.Entity.Get, guid)
    if ent then
        out.health = C.soft(function()
            return { hp = ent.Health.Hp, maxHp = ent.Health.MaxHp, temp = ent.Health.TemporaryHp }
        end)
        out.actionResources = C.soft(function()
            local n = 0
            for _ in pairs(ent.ActionResources.Resources) do n = n + 1 end
            return n
        end)
        out.spellCount = C.soft(function() return #ent.SpellBook.Spells end)
    end
    C.report("combat", out)
    return out
end

function M.init()
    Ext.RegisterConsoleCommand("a11y_scan", function() M.E7_scan() end)
    Ext.RegisterConsoleCommand("a11y_sdialog", function() M.E8_dialog() end)
    Ext.RegisterConsoleCommand("a11y_osi", function() M.osiris() end)
    Ext.RegisterConsoleCommand("a11y_combat", function() M.combat() end)
    Ext.RegisterConsoleCommand("a11y_sall", function() M.runAll() end)
    C.log("server probes registered")
end

function M.runAll()
    C.report("E10_env", C.env())
    C.try(M.osiris)
    C.try(M.E7_scan)
    C.try(M.E8_dialog)
    C.try(M.combat)
end

return M
