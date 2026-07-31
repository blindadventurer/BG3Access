-- The server half of the layer.
--
-- Walking to a thing is Osiris work (CharacterMoveTo), and Osiris lives only on the server,
-- so the client asks over the A11yNav channel and this side moves the character. There is no
-- reader here and nothing to speak: it listens, and that is all.
--
-- Loose copy wins over the packed one, same as on the client - see BootstrapClient.lua.

local DEV = "A11y/"
local NAME = "a11y-nav-server"

local ENV = _ENV

local function soft(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local G = rawget(ENV, "_G") or ENV
rawset(ENV, "_G", G)

local function fromLoose()
    local src = soft(Ext.IO.LoadFile, DEV .. NAME .. ".lua")
    if type(src) ~= "string" or #src == 0 then return nil end
    -- Second argument is the environment table, not a chunk name - see BootstrapClient.lua.
    local ok, chunk, err = pcall(load, src, ENV)
    if not ok or chunk == nil then
        Ext.Utils.PrintWarning("[a11y] loose " .. NAME .. " will not compile (" ..
            tostring(err or chunk) .. ") - falling back to the packed copy")
        return nil
    end
    local ran, mod = pcall(chunk)
    if not ran then
        Ext.Utils.PrintWarning("[a11y] loose " .. NAME .. " failed while loading (" ..
            tostring(mod) .. ") - falling back to the packed copy")
        return nil
    end
    return mod
end

local mod, where = fromLoose(), "loose"
if mod == nil then
    local ok, packed = pcall(Ext.Require, "A11y/" .. NAME .. ".lua")
    mod, where = ok and packed or nil, "packed"
end

if mod == nil then
    Ext.Utils.PrintError("[a11y] " .. NAME .. " did not load - walking to objects is off")
    return
end

G.NavSrv = mod
local ok, err = pcall(mod.listen)
Ext.Utils.Print("[a11y] nav server " .. where .. ", listening: " .. tostring(ok and true or err))
