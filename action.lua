local component = require('component')
local robot = require('robot')
local sides = require('sides')
local computer = require('computer')
local os = require('os')
local database = require('database')
local gps = require('gps')
local config = require('config')
local scanner = require('scanner')
local events = require('events')
local inventory_controller = component.inventory_controller
local redstone = component.redstone
local restockAll, cleanUp, dumpInventory  -- Forward declaration
-- Runtime trash position; becomes nil if no separate trash chest exists at startup. config is never modified.
local runtimeTrashPos = config.trashPos

local function needCharge()
    return computer.energy() / computer.maxEnergy() < config.needChargeLevel
end


local function fullyCharged()
    return computer.energy() / computer.maxEnergy() > 0.99
end


local function fullInventory()
    for i=1, robot.inventorySize() do
        if robot.count(i) == 0 then
            return false
        end
    end
    return true
end


local function withSelectedSlot(fn, configTool, checkFullInventory)
    local selectedSlot = robot.select()
    if checkFullInventory == true then
        if fullInventory() then
            gps.save()
            dumpInventory()
            gps.resume()
        end
    end
    if configTool ~= nil then
        robot.select(robot.inventorySize() + configTool)
    end
    fn()
    robot.select(selectedSlot)
end


local function restockStick()
    withSelectedSlot(function()
        gps.go(config.stickContainerPos)
        -- Wait for a full stack of crop sticks; retry every 10 seconds if the chest is short
        while robot.count() < 64 do
            for i=1, inventory_controller.getInventorySize(sides.down) do
                os.sleep(0)
                inventory_controller.suckFromSlot(sides.down, i, 64-robot.count())
                if robot.count() == 64 then
                    break
                end
            end
            if robot.count() < 64 then
                if events.needExit() then
                    break
                end
                os.sleep(10)
            end
        end
    end, config.stickSlot)
end


local function isCropStick(slot)
    local item = robot.getItem(slot)
    if item == nil then
        return false
    end
    local stickItem = robot.getItem(robot.inventorySize() + config.stickSlot)
    if stickItem == nil then
        return item.name == 'IC2:crop'
    end
    return item.name == stickItem.name
end


local function dropDownToFirstEmpty()
    for e=1, inventory_controller.getInventorySize(sides.down) do
        if inventory_controller.getStackInSlot(sides.down, e) == nil then
            inventory_controller.dropIntoSlot(sides.down, e)
            break
        end
    end
end


function dumpInventory()
    withSelectedSlot(function()
        -- Identify crop sticks before any trash/storage classification
        local stickSlots = {}
        local otherSlots = {}
        for i=1, robot.inventorySize() + config.storageStopSlot do
            if isCropStick(i) then
                stickSlots[#stickSlots+1] = i
            elseif robot.count(i) > 0 then
                otherSlots[#otherSlots+1] = i
            end
        end

        -- Dump normal items to the trash chest (new layout) or the combined storage/trash chest (legacy)
        gps.go(runtimeTrashPos ~= nil and config.trashPos or config.storagePos)
        for _, i in ipairs(otherSlots) do
            os.sleep(0)
            robot.select(i)
            dropDownToFirstEmpty()
        end

        -- Return crop sticks to the crop stick chest
        if #stickSlots > 0 then
            gps.go(config.stickContainerPos)
            for _, i in ipairs(stickSlots) do
                os.sleep(0)
                robot.select(i)
                dropDownToFirstEmpty()
            end
        end
    end)
end


local function placeCropStick(count)
    withSelectedSlot(function()

        if count == nil then
            count = 1
        end

        if robot.count(robot.inventorySize() + config.stickSlot) < count + 1 then
            gps.save()
            restockStick()
            gps.resume()
        end

        robot.select(robot.inventorySize() + config.stickSlot)
        inventory_controller.equip()

        for _=1, count do
            robot.useDown()
        end

        inventory_controller.equip()
    end)
end


local function pulseDown()
    redstone.setOutput(sides.down, 15)
    os.sleep(0.1)
    redstone.setOutput(sides.down, 0)
end


local function deweed()
    withSelectedSlot(function()
        robot.select(robot.inventorySize() + config.spadeSlot)
        inventory_controller.equip()
        robot.useDown()
        robot.suckDown()

        inventory_controller.equip()
    end, config.spadeSlot, true)
end


local function harvest()
    withSelectedSlot(function()
        robot.swingDown()
        robot.suckDown()
    end, nil, true)
end


local function harvestViable()
    withSelectedSlot(function()
        -- Record the inventory before the harvest to identify the newly collected seed bags
        local before = {}
        for i=1, robot.inventorySize() do
            before[i] = robot.count(i)
        end

        robot.swingDown()
        robot.suckDown()

        -- Route the newly collected seed bags to the storage chest (new layout only)
        if runtimeTrashPos ~= nil then
            local newSlots = {}
            for i=1, robot.inventorySize() + config.storageStopSlot do
                local item = robot.getItem(i)
                if item ~= nil and not isCropStick(i) and before[i] < item.count then
                    newSlots[#newSlots+1] = i
                end
            end
            if #newSlots > 0 then
                gps.save()
                gps.go(config.storagePos)
                for _, i in ipairs(newSlots) do
                    robot.select(i)
                    dropDownToFirstEmpty()
                end
                gps.resume()
            end
        end
    end, nil, true)
end


local function transplant(src, dest)
    withSelectedSlot(function()
        gps.save()
        inventory_controller.equip()

        -- Transfer to relay location
        gps.go(src)
        robot.useDown(sides.down, true)
        gps.go(config.dislocatorPos)
        pulseDown()

        -- Transfer crop to destination
        robot.useDown(sides.down, true)
        gps.go(dest)

        local crop = scanner.scan()
        if crop.name == 'air' then
            placeCropStick()

        elseif crop.isCrop == false then
            database.addToStorage(crop)
            gps.go(gps.storageSlotToPos(database.nextStorageSlot()))
            placeCropStick()
        end

        robot.useDown(sides.down, true)
        gps.go(config.dislocatorPos)
        pulseDown()

        -- Reprime binder
        robot.useDown(sides.down, true)

        -- Destroy original crop
        inventory_controller.equip()
        gps.go(config.relayFarmlandPos)
        robot.swingDown()
        robot.suckDown()

        gps.resume()
    end, config.binderSlot)
end


function cleanUp()
    for slot=1, config.workingFarmArea, 1 do
        -- Scan
        gps.go(gps.workingSlotToPos(slot))
        local crop = scanner.scan()

        -- Remove all children and empty parents
        if slot % 2 == 0 or crop.name == 'emptyCrop' then
            robot.swingDown()

        -- Remove bad parents
        elseif crop.isCrop and crop.name ~= 'air' then
            if scanner.isWeed(crop, 'working') then
                robot.swingDown()
            end
        end

        -- Pickup
        robot.suckDown()
    end
    events.setNeedCleanup(false)
    restockAll()
end


local function primeBinder()
    withSelectedSlot(function()
        inventory_controller.equip()

        -- Use binder at start to reset it, if already primed
        robot.useDown(sides.down, true)

        gps.go(config.dislocatorPos)
        robot.useDown(sides.down)

        inventory_controller.equip()
    end, config.binderSlot)
end


local function charge()
    gps.go(config.chargerPos)
    gps.turnTo(1)
    repeat
        os.sleep(0.5)
        if events.needExit() then
            if events.needCleanup() and config.cleanUp then
                events.setNeedCleanup(false)
                cleanUp()
            end
            os.exit() -- Exit here to leave robot in starting position
        end
    until fullyCharged()
end


local function clearDown()
    withSelectedSlot(function()
        inventory_controller.equip()
        robot.useDown()
        robot.swingDown()
        robot.suckDown()
        inventory_controller.equip()
    end, config.spadeSlot, true)
end


function restockAll()
    dumpInventory()
    restockStick()
    charge()
end


local function hasInventoryBelow()
    -- getInventorySize yields nil (newer OC) or throws (older OC) when no inventory is present
    local ok, size = pcall(inventory_controller.getInventorySize, sides.down)
    return ok and size ~= nil
end


local function detectLayout()
    gps.go(config.trashPos)
    local hasTrash = hasInventoryBelow()

    gps.go(config.storagePos)
    local hasStorage = hasInventoryBelow()

    if hasTrash and hasStorage then
        runtimeTrashPos = config.trashPos
        print('CropBot: Separate trash and storage chests detected')
    elseif hasStorage then
        runtimeTrashPos = nil
        print('CropBot: Combined storage/trash chest detected')
    else
        gps.go(config.chargerPos)
        print('===== ERROR: Invalid chest layout =====')
        if hasTrash then
            print(string.format('A chest was found at the trash position (%d, %d) but not at the storage position (%d, %d).', config.trashPos[1], config.trashPos[2], config.storagePos[1], config.storagePos[2]))
            print('Cannot determine which chest is which. Please add a chest at the storage position.')
        else
            print(string.format('No chest was found at the storage position (%d, %d).', config.storagePos[1], config.storagePos[2]))
            print('Please place a storage chest (or a combined storage/trash chest) at the storage position.')
        end
        os.exit()
    end
end


local function initWork()
    events.initEvents()
    events.hookEvents()
    detectLayout()
    charge()
    database.resetStorage()
    primeBinder()
    restockAll()
end


local function analyzeStorage(existingTarget)
    if config.checkStorageBefore then
        local targetCropName = database.getFarm()[1].name
        for slot=1, config.storageFarmArea, 1 do
            gps.go(gps.storageSlotToPos(slot))
            local crop = scanner.scan()
            if crop.name ~= 'air' then
                if (existingTarget == true and crop.name ~= targetCropName) then
                    clearDown()
                elseif scanner.isWeed(crop, 'storage') then
                    clearDown()
                else
                    database.updateStorage(slot, crop)
                end
            end
        end
    end
end


return {
    needCharge = needCharge,
    charge = charge,
    restockStick = restockStick,
    dumpInventory = dumpInventory,
    restockAll = restockAll,
    placeCropStick = placeCropStick,
    pulseDown = pulseDown,
    deweed = deweed,
    harvest = harvest,
    harvestViable = harvestViable,
    transplant = transplant,
    cleanUp = cleanUp,
    initWork = initWork,
    clearDown = clearDown,
    analyzeStorage = analyzeStorage
}