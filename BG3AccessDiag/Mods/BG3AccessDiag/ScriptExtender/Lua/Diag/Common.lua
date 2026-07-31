--- Shared helpers for the host-viability probes.
--- Everything here is defensive: a probe that explodes must not take the others with it.

local M = {}

M.DIR = "A11yDiag/"

local side = Ext.IsServer() and "server" or "client"
M.SIDE = side

function M.log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    Ext.Utils.Print("[a11y/" .. side .. "] " .. (ok and msg or tostring(fmt)))
end

--- pcall wrapper that returns a table describing the outcome instead of throwing.
function M.try(fn, ...)
    local res = table.pack(pcall(fn, ...))
    if res[1] then
        return { ok = true, value = res[2], n = res.n - 1 }
    end
    return { ok = false, error = tostring(res[2]) }
end

--- Value of a call, or nil. Never throws.
function M.soft(fn, ...)
    local r = M.try(fn, ...)
    if r.ok then return r.value end
    return nil
end

--- Render anything into something Ext.Json.Stringify can eat.
function M.plain(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "nil" or t == "boolean" or t == "number" then return v end
    if t == "string" then return v end
    if depth > 4 then return "<depth>" end
    if t == "table" then
        local out = {}
        local n = 0
        for k, vv in pairs(v) do
            n = n + 1
            if n > 200 then out["..."] = "truncated"; break end
            out[tostring(k)] = M.plain(vv, depth + 1)
        end
        return out
    end
    if t == "userdata" then
        local ty = M.soft(Ext.Types.GetObjectType, v)
        local str = M.soft(function() return tostring(v) end)
        return { __type = ty or "userdata", __str = str }
    end
    return tostring(v)
end

local pending = {}

--- Merge a section into the report and flush it to disk immediately, so partial
--- results survive a crash mid-probe.
function M.report(name, data)
    pending[name] = M.plain(data)
    local body = M.soft(Ext.Json.Stringify, pending, { Beautify = true, MaxDepth = 24 })
    if body == nil then
        body = "{\"error\":\"stringify failed for section " .. tostring(name) .. "\"}"
    end
    local path = M.DIR .. side .. ".json"
    local ok = M.soft(Ext.IO.SaveFile, path, body)
    M.log("section %s written (%s) -> %s", tostring(name), tostring(ok), path)
end

--- Free-standing file, for big dumps that should not bloat the main report.
function M.dump(fileName, data)
    local body = M.soft(Ext.Json.Stringify, M.plain(data), { Beautify = true, MaxDepth = 24 })
    if body == nil then return false end
    return M.soft(Ext.IO.SaveFile, M.DIR .. fileName, body)
end

function M.now()
    return M.soft(Ext.Timer.MicrosecTime) or 0
end

function M.env()
    return {
        side = side,
        extenderVersion = M.soft(Ext.Utils.Version),
        gameVersion = M.soft(Ext.Utils.GameVersion),
        gameState = tostring(M.soft(Ext.Utils.GetGameState)),
        clock = M.soft(Ext.Timer.ClockTime),
        developerMode = M.soft(Ext.Debug.IsDeveloperMode),
        loadOrder = M.soft(Ext.Mod.GetLoadOrder),
    }
end

return M
