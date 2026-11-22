import("ess")
local KEYVAL = "f3"
Ess.DEBUG = true
local Ess = _G.Ess
if not (Ess and Ess.Math and Ess.Player and Ess.Object) then
    if Loader and Loader.Printf then Loader.Printf("[VSSmod] Install the 'Mercenaries 2 Lua Essentials' shipment to use this script.") end
    return
end

-- If this file is run a second time in the same world, tear the previous run down first so markers and
-- loops do not double up.
if _G.VehicleStockpiler and _G.VehicleStockpiler.stop then
    pcall(_G.VehicleStockpiler.stop)
end

pcall(import, "MrxPmc")
pcall(import, "MrxSupportData")

-- ---------------------------------------------------------------------------------------------------------
-- HOW IT WORKS -- two listeners
--   WATCH (always running): is a player in a vehicle? (Ess.Player.inVehicle(i) not nil / false / 0)
--       in a vehicle -> the three delivery-point markers are shown and the SCAN listener is switched on
--       on foot      -> the markers are removed and the SCAN listener is switched off
--   SCAN (only while a player is in a vehicle): has a player-driven vehicle entered a delivery point?
--       Garage / helipad: on entry the delivery array is built  { { vTemplate = <template>, nQty = 1, ... } }
--           and the player stays in control. When the player is no longer in that vehicle it is deleted,
--           added to the stockpile, and the "stockpile" fanfare banner is shown (no music). Driving out of
--           the point first cancels it; driving back in re-arms it.
--       Boat dock (autoDeliver): the moment a boat enters the point the driver is ejected and moved to the
--           dock exit, then the boat is deleted, stockpiled and the fanfare is shown.
-- ---------------------------------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------------------------------------
-- CONFIG
-- ---------------------------------------------------------------------------------------------------------
local CFG = {
    watchId      = "VehicleStockpiler.watch",
    scanId       = "VehicleStockpiler.scan",
    interval     = 0.5,      -- seconds between checks (both listeners)
    settleDelay  = 0.25,     -- seconds between the player getting out and the vehicle being deleted
    fadeTime     = 0.25,     -- vehicle fade-out (then destroyed), same idea as the game's own 0.2
    leaveMargin  = 3,        -- a pending delivery is cancelled once the vehicle is this far outside the radius
    scanRange    = 60,       -- only query a point for vehicles when a player is this close
    rgb          = { 60, 184, 120 },
    discAlpha    = 0.25,

    -- A zone resolves its position from the named dropoff object, unless it has a fixed `pos` = { x, y, z }.
    zones = {
        { id = "garage",  label = "Garage",  dropoff = "PMC Garage Dropoff",  radius = 5,
          pos = { 2654.3125, -13.828918457031, -928.89282226563 },
          physics = { car = true, tank = true } },
        { id = "helipad", label = "Helipad", dropoff = "PMC Helipad Dropoff", radius = 15,
          pos = { 2632.8032226563, 8.0310926437378, -885.96362304688 },
          physics = { helicopter = true }, mustBeGrounded = true },
        -- The dock delivers the moment a boat enters the marker: the driver is ejected and moved to the
        -- first exit point, then the boat is deleted and stockpiled (autoDeliver). If that exit object can't
        -- be found, the player is moved to the marker position instead.
        { id = "dock",    label = "Boat Dock", dropoff = "PMC Dock Dropoff",  radius = 10,
          pos = { 2546.6, -36.1, -789.4 },
          autoDeliver = true, exits = { "PMC Dock Exit 1", "PMC Dock Exit 2" },
          physics = { boat = true } },
    },
}

-- The support-types the game's garage-inventory treats as vehicles (wifpmcgarage.lua, OpenVehicleInventory).
local VEHICLE_SUPPORT_TYPES = { Civilian = true, Heavy = true, Light = true, Heli = true, Boat = true }

local busy      = {}   -- [vehicleKey] = true while a delivery is armed or being completed
local pending   = {}   -- [vehicleKey] = { veh, zone, pi, tDelivery }  armed, waiting for the player to get out
local notified  = {}   -- [flagKey] = true while a "can't deliver" hint has been shown for a vehicle
local supportOf = {}   -- [vehicleKey] = { id, name } | false   (cache; the name-hash scan is not free)
local tickCount = 0

local function log(msg) Ess.Log("[VehicleStockpiler] " .. tostring(msg)) end

-- Guids are userdata, so they are not safe table keys. Key by the string form instead (Ess.Name).
local function keyOf(u) return Ess.Name(u) or tostring(u) end

local function hint(sText)
    if Ess.Hud and Ess.Hud.message then Ess.Hud.message(sText) end
end

-- ---------------------------------------------------------------------------------------------------------
-- Delivery points: resolve, mark
-- ---------------------------------------------------------------------------------------------------------
-- Resolve the point's position once and cache it; the point is static, so after this only the cached
-- coordinates are used.
local function resolveZone(zone)
    if zone.x then return true end
    if zone.pos then
        zone.x, zone.y, zone.z = zone.pos[1], zone.pos[2], zone.pos[3]
        log(zone.id .. " delivery point fixed at " .. zone.x .. ", " .. zone.y .. ", " .. zone.z)
        return true
    end
    local u = Ess.Guid(zone.dropoff)
    if not u then return false end
    local x, y, z = Ess.Object.pos(u)
    if not x then return false end
    zone.x, zone.y, zone.z = x, y, z
    log(zone.id .. " delivery point resolved at " .. x .. ", " .. y .. ", " .. z)
    return true
end

-- The graphical marker: a ground ring the same radius as the real bounds, a floating "deliverable" icon, and
-- a radar + PDA blip. Ess.Mark.zone owns a TinyGeometry anchor; Ess.Mark.clear removes everything.
local function dropMarker(zone)
    if zone.marker then Ess.Mark.clear(zone.marker) end
    zone.marker = nil
    zone.nextTry, zone.markerCheck = nil, nil
end

local function showMarker(zone)
    if not zone.marker then
        if zone.nextTry and tickCount < zone.nextTry then return end
        zone.marker = Ess.Mark.zone(zone.x, zone.y, zone.z, zone.radius, {
            kind = "deliverable", icon = true, rgb = CFG.rgb, discAlpha = CFG.discAlpha,
            label = "Stockpile Delivery: " .. zone.label,
        })
        zone.markerCheck = 0
        if not zone.marker then zone.nextTry = tickCount + 20 end   -- spawn failed; retry in ~10 s
    else
        zone.markerCheck = (zone.markerCheck or 0) + 1
        if zone.markerCheck >= 10 then           -- every ~5 s make sure the anchor survived streaming
            zone.markerCheck = 0
            if not Ess.Object.valid(zone.marker.anchor) then dropMarker(zone) end
        end
    end
end

local function showMarkers()
    for _, zone in ipairs(CFG.zones) do
        if resolveZone(zone) then showMarker(zone) end
    end
end

local function hideMarkers()
    for _, zone in ipairs(CFG.zones) do dropMarker(zone) end
end

-- ---------------------------------------------------------------------------------------------------------
-- Vehicle checks
-- ---------------------------------------------------------------------------------------------------------
-- Match a vehicle to its stockpile entry the way the game's _FindVehicleInSupport does: the vehicle's
-- localized-name hash against String.GetHash of each support entry's sName.
local function findSupport(veh)
    local ok, hash = Ess.Safe.quiet(Object.GetLocalizedName, veh, true)
    if not ok or hash == nil then return nil end
    local data = MrxSupportData and MrxSupportData.tSupportData
    if type(data) ~= "table" then return nil end
    for sId, t in pairs(data) do
        if VEHICLE_SUPPORT_TYPES[t.sType] and t.sName then
            local ok2, h2 = Ess.Safe.quiet(String.GetHash, t.sName, true)
            if ok2 and h2 == hash then return sId, t.sName end
        end
    end
    return nil
end

local function supportFor(veh, key)
    local c = supportOf[key]
    if c == nil then
        local sId, sName = findSupport(veh)
        c = sId and { id = sId, name = sName } or false
        supportOf[key] = c
    end
    if c then return c.id, c.name end
    return nil
end

-- The driver, if (and only if) a player is driving.
local function playerDriver(veh)
    local d = Ess.Vehicle.driver(veh)
    if d and Ess.Object.playerControlled(d) then return d end
    return nil
end

-- Does this vehicle belong at this point? Second return is a reason worth telling the player about.
local function eligible(zone, veh)
    local pt = Ess.Object.physicsType(veh)
    if not pt or not zone.physics[pt] then return false, nil end   -- wrong kind for this point: say nothing
    if zone.mustBeGrounded and Ess.Vehicle.isFlying(veh) then return false, "fly" end
    return true
end

-- Key of the vehicle player i is in, or nil when that player is on foot. Ess.Player.inVehicle(i) gives a
-- vehicle guid or nil; false and 0 are treated as "not in a vehicle" too.
local function inVehicleKey(i)
    local v = Ess.Player.inVehicle(i)
    if not v or v == 0 then return nil end
    return keyOf(v)
end

local function anyPlayerInVehicle()
    for i = 0, 1 do
        if inVehicleKey(i) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------------------
-- Fanfare
-- ---------------------------------------------------------------------------------------------------------
-- Only the native banner: Hud.EventFanfare:Commence. The music sting is a separate call (MrxMusic.PlayFanfare,
-- which Ess.Easy.Fun.fanfare wraps), and it is deliberately not made here. sType "stockpile" is one of the
-- shipped EventFanfare styles (an unknown sType crashes Commence), and the text format matches the game's own
-- stockpile fanfare: "<support name> (x <qty>)". sName is a localization key like "[vehicle.coandaattack]";
-- the HUD resolves it, exactly as it does for the game's fanfare.
local function fanfare(tDelivery)
    for _, item in ipairs(tDelivery) do
        local sText = tostring(item.sName) .. " (x " .. tostring(item.nQty) .. ")"
        Ess.Safe.named("VehicleStockpiler.fanfare", function()
            Hud.EventFanfare:Commence({ sType = "stockpile", vText = sText })
        end)
    end
end

-- ---------------------------------------------------------------------------------------------------------
-- Delivery
-- ---------------------------------------------------------------------------------------------------------
local function qtyOf(sSupport)
    if not (MrxPmc and MrxPmc.GetSupportQty) then return 0 end
    local ok, n = Ess.Safe.quiet(MrxPmc.GetSupportQty, sSupport)
    return (ok and tonumber(n)) or 0
end

-- Step 1, on entering the point: build the array holding the vehicle template and the quantity to add.
-- Object.GetParent on a spawned vehicle is its template, the same lookup the game's garage uses for storage
-- (wifpmcgarage.lua, _AddVehicle). nBefore is the stock at this moment, so that if the game's own garage
-- script counts the vehicle when the player gets out inside the HQ regions it is not added twice.
local function newDelivery(veh, zone, key, sSupport, sName)
    return {
        veh = veh, zone = zone, key = key,
        tDelivery = {
            { vTemplate = Ess.Object.parent(veh), nQty = 1, sSupport = sSupport, sName = sName,
              nBefore = qtyOf(sSupport) },
        },
    }
end

local function arm(veh, zone, key, sSupport, sName)
    local pi
    for i = 0, 1 do
        if inVehicleKey(i) == key then pi = i; break end
    end
    if not pi then return end   -- nobody readable in the seat yet; try again next tick

    busy[key] = true
    local p = newDelivery(veh, zone, key, sSupport, sName)
    p.pi = pi
    pending[key] = p
    hint("Step out of the vehicle to add it to the stockpile.")
end

local function cancel(key, why)
    pending[key] = nil
    busy[key] = nil
    log("delivery cancelled (" .. why .. ")")
end

-- Steps 2-4, once the player is out: delete the vehicle, add every array entry to the stockpile, fanfare.
local function complete(p)
    local removed = false
    if Ess.Object.valid(p.veh) then
        Ess.Vehicle.evictAll(p.veh)                    -- passengers / AI aboard get out; the player already is
        Ess.Object.fadeOut(p.veh, CFG.fadeTime, true)  -- fade, then destroyed
        removed = true
    end

    local added = {}
    for _, item in ipairs(p.tDelivery) do
        local nNow = qtyOf(item.sSupport)
        if nNow - item.nBefore >= item.nQty then
            -- The game's own garage script already stockpiled it when the player got out.
            log(item.sSupport .. " already counted by the garage script; not adding twice")
            added[#added + 1] = item
        elseif removed and MrxPmc and MrxPmc.AddSupportQty then
            -- bDspFanfare = false: the fanfare below is shown once, by this script.
            local ok = Ess.Safe.quiet(MrxPmc.AddSupportQty, item.sSupport, item.nQty, false)
            if ok then added[#added + 1] = item end
        else
            log("vehicle vanished before delivery completed; nothing stockpiled")
        end
    end

    if #added > 0 then fanfare(added) end
end

-- Put the player on the zone's exit point (the same call the game's garage uses). If the exit object can't be
-- found, fall back to the marker position.
local function movePlayer(char, zone)
    if not (char and Ess.Object.valid(char)) then return end
    local sExit = zone.exits and zone.exits[1]
    if sExit and Ess.Guid(sExit) then
        Ess.Safe.quiet(Object.SetTransformToObject, char, sExit)
    else
        Ess.Player.teleport(zone.x, zone.y, zone.z, 0)
    end
end

-- autoDeliver zones (the boat dock): no waiting for the player. Build the array, eject the driver, move them
-- to the exit point, then delete the vehicle, stockpile it and show the fanfare.
local function deliverNow(veh, driver, zone, key, sSupport, sName)
    busy[key] = true
    local p = newDelivery(veh, zone, key, sSupport, sName)
    Ess.Vehicle.exit(veh, driver)
    Ess.Event.on(Event.TimerRelative, { CFG.settleDelay }, function()
        movePlayer(driver, zone)
        complete(p)
    end)
end

-- Armed deliveries (garage / helipad). Runs on the WATCH listener, so it keeps going after the player gets
-- out of the vehicle -- which is exactly the moment it is waiting for.
local function checkPending()
    for key, p in pairs(pending) do
        if not Ess.Object.valid(p.veh) then
            cancel(key, "vehicle gone")
        else
            local d = Ess.Object.distance(p.veh, p.zone.x, p.zone.y, p.zone.z)
            if d and d > p.zone.radius + CFG.leaveMargin then
                cancel(key, "left the delivery point")
            elseif inVehicleKey(p.pi) == key then
                -- still inside the vehicle: keep waiting
            elseif p.zone.mustBeGrounded and Ess.Vehicle.isFlying(p.veh) then
                cancel(key, "left a flying aircraft")
            else
                -- The player is out of the vehicle. Let it settle (and the game's own garage hooks run),
                -- then complete. busy[key] stays set so it can't be re-armed meanwhile.
                pending[key] = nil
                Ess.Event.on(Event.TimerRelative, { CFG.settleDelay }, function() complete(p) end)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------
-- SCAN listener: has a player-driven vehicle entered a delivery point?
-- ---------------------------------------------------------------------------------------------------------
local function once(seen, flagKey, sText)
    seen[flagKey] = true
    if not notified[flagKey] then
        notified[flagKey] = true
        hint(sText)
    end
end

local function scanZone(zone, seen)
    local vehicles = Ess.Probe.inArea(zone.x, zone.y, zone.z, zone.radius, "Vehicle")
    for _, veh in ipairs(vehicles) do
        local key = keyOf(veh)
        if not busy[key] then
            local driver = playerDriver(veh)
            if driver then
                local ok, why = eligible(zone, veh)
                if ok then
                    local sId, sName = supportFor(veh, key)
                    if sId then
                        if zone.autoDeliver then
                            deliverNow(veh, driver, zone, key, sId, sName)
                        else
                            arm(veh, zone, key, sId, sName)
                        end
                    else
                        once(seen, key .. "|nosupport", "This vehicle can't be added to the stockpile.")
                    end
                elseif why == "fly" then
                    once(seen, key .. "|fly", "Land the helicopter on the pad to stockpile it.")
                end
            end
        end
    end
end

-- Closest distance from any player character to a point (co-op aware), or nil if no character is readable.
local function playerDistance(x, y, z)
    local best
    for i = 0, 1 do
        local c = Ess.Player.character(i)
        if c then
            local d = Ess.Object.distance(c, x, y, z)
            if d and (not best or d < best) then best = d end
        end
    end
    return best
end

local function scanTick()
    local seen = {}
    for _, zone in ipairs(CFG.zones) do
        if resolveZone(zone) then
            local d = playerDistance(zone.x, zone.y, zone.z)
            if d and d <= CFG.scanRange then scanZone(zone, seen) end
        end
    end
    -- Forget a hint once its vehicle has left the point, so it can be shown again next visit.
    for k in pairs(notified) do
        if not seen[k] then notified[k] = nil end
    end
end

local function startScan()
    if Ess.Loop.isRunning(CFG.scanId) then return end
    Ess.Loop.start(CFG.scanId, CFG.interval, function()
        local ok, err = pcall(scanTick)
        if not ok then log("scan error: " .. tostring(err)) end
        return true   -- never let one bad tick end the listener
    end)
end

local function stopScan()
    if Ess.Loop.isRunning(CFG.scanId) then Ess.Loop.stop(CFG.scanId) end
    for k in pairs(notified) do notified[k] = nil end
end

-- ---------------------------------------------------------------------------------------------------------
-- WATCH listener: is a player in a vehicle?
-- ---------------------------------------------------------------------------------------------------------
local function watchTick()
    tickCount = tickCount + 1
    checkPending()
    if anyPlayerInVehicle() then
        showMarkers()
        startScan()
    else
        stopScan()
        hideMarkers()
    end
end

local function stop()
    Ess.Loop.stop(CFG.watchId)
    stopScan()
    hideMarkers()
    for k in pairs(pending) do pending[k] = nil end
    for k in pairs(busy)    do busy[k]    = nil end
end

_G.VehicleStockpiler = { CFG = CFG, stop = stop }

Ess.Loop.start(CFG.watchId, CFG.interval, function()
    local ok, err = pcall(watchTick)
    if not ok then log("watch error: " .. tostring(err)) end
    return true   -- never let one bad tick end the listener
end)
log("watching for a player in a vehicle")
