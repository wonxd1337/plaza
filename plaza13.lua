print("DEBUG 1: Skrip utama bot booth mulai dieksekusi")

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
-- VirtualUser dihapus total karena memicu anti-cheat BAC-6229

local WEB_URL = "http://ez.mn/tmpl/feeds/feed/plaza/index.php"
local LocalPlayer = Players.LocalPlayer
local username = LocalPlayer.Name
local PlaceId = game.PlaceId
local maxPlayers = Players.MaxPlayers
local Camera = Workspace.CurrentCamera

-- ==========================================
-- FITUR MICRO-MOVEMENT ANTI-AFK (Aman dari BAC)
-- Menggeser sudut kamera sangat tipis secara berkala untuk mereset timer AFK Roblox
-- ==========================================
task.spawn(function()
    while true do
        task.wait(300) -- Setiap 5 menit
        pcall(function()
            local currentCFrame = Camera.CFrame
            Camera.CFrame = currentCFrame * CFrame.Angles(0, math.rad(0.05), 0)
            task.wait(0.1)
            Camera.CFrame = currentCFrame
            print("[LOG ANTI-AFK] Micro-movement kamera berhasil dieksekusi.")
        end)
    end
end)

local successReplion, Replion = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Replion")) 
end)
local successItemUtil, ItemUtility = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemUtility")) 
end)
local successTrade, TradeData = pcall(function()
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Trading"):WaitForChild("TradeData"))
end)

if not successReplion or not successItemUtil or not successTrade then
    warn("DEBUG ERROR: Gagal memuat modul inti!")
    return
end

local serverBrowserReplion = Replion.Client:WaitReplion("ServerBrowser")

TeleportService.TeleportInitFailed:Connect(function(player, teleportResult, errorMessage)
    if player == LocalPlayer then
        pcall(function() GuiService:ClearError() end)
    end
end)

local TIMER_DURATION = 900 
local currentTimer = TIMER_DURATION
local hasActiveStock = true
local isBoothClaimed = false

local function serverHopHighestRAP()
    local servers = serverBrowserReplion and serverBrowserReplion.Data and serverBrowserReplion.Data.Servers
    if not servers then
        TeleportService:Teleport(PlaceId, LocalPlayer)
        return
    end

    local bestJobId = nil
    local highestRAP = -1

    for jobId, serverData in pairs(servers) do
        if jobId ~= game.JobId and serverData then
            local playerCount = serverData.Players or serverData.PlayerCount or 0
            if playerCount < (maxPlayers - 1) then
                local serverRAP = serverData.RAP or serverData.TotalRAP or serverData.Value or 0
                if serverRAP > highestRAP then
                    highestRAP = serverRAP
                    bestJobId = jobId
                end
            end
        end
    end

    if bestJobId then
        pcall(function()
            TeleportService:TeleportToPlaceInstance(PlaceId, bestJobId, LocalPlayer)
        end)
    else
        TeleportService:Teleport(PlaceId, LocalPlayer)
    end
end

local function resetInactivityTimer()
    currentTimer = TIMER_DURATION
end

local function moveToTarget(humanoid, rootPart, targetPos)
    local path = PathfindingService:CreatePath({
        AgentRadius = 2,
        AgentHeight = 5,
        AgentCanJump = true
    })
    
    local success = pcall(function()
        path:ComputeAsync(rootPart.Position, targetPos)
    end)
    
    if success and path.Status == Enum.PathStatus.Success then
        local waypoints = path:GetWaypoints()
        for _, waypoint in ipairs(waypoints) do
            humanoid:MoveTo(waypoint.Position)
            if waypoint.Action == Enum.PathWaypointAction.Jump then
                humanoid.Jump = true
            end
            
            local reached = false
            local connection
            connection = humanoid.MoveToFinished:Connect(function(isReached)
                reached = true
                connection:Disconnect()
            end)
            
            local startTime = tick()
            while not reached and (rootPart.Position - waypoint.Position).Magnitude > 3 and (tick() - startTime) < 5 do
                task.wait()
            end
            
            if connection then
                connection:Disconnect()
            end
        end
    else
        humanoid:MoveTo(targetPos)
        local startTime = tick()
        repeat
            task.wait(0.1)
        until (rootPart.Position - targetPos).Magnitude < 4 or (tick() - startTime) > 6
    end
end

-- AMAN DARI ANTI-CHEAT: Menggunakan Smart Pathfinding & Prompt asli
local function autoClaimBooth()
    local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local humanoid = character:WaitForChild("Humanoid")
    local rootPart = character:WaitForChild("HumanoidRootPart")

    local targetBooth = nil
    local shortestDistance = math.huge

    pcall(function()
        for _, booth in ipairs(CollectionService:GetTagged("Booth")) do
            local owner = booth:GetAttribute("Owner")
            if not owner or owner == 0 or owner == "" then
                local boothPart = booth.PrimaryPart or booth:FindFirstChildWhichIsA("BasePart")
                if boothPart then
                    local distance = (rootPart.Position - boothPart.Position).Magnitude
                    if distance < shortestDistance then
                        shortestDistance = distance
                        targetBooth = booth
                    end
                end
            end
        end
    end)

    if targetBooth then
        local prompt = targetBooth:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then
            local targetPart = prompt.Parent
            local targetPosition
            if targetPart and targetPart:IsA("BasePart") then
                targetPosition = targetPart.Position + (targetPart.CFrame.LookVector * 3)
            else
                targetPosition = targetBooth:GetPivot().Position + Vector3.new(0, 0, 3)
            end
            
            moveToTarget(humanoid, rootPart, targetPosition)
            task.wait(0.5) -- Jeda stabilisasi setelah sampai
            
            local originalHoldDuration = prompt.HoldDuration or 0.5
            task.wait(originalHoldDuration + 0.1) 
            
            fireproximityprompt(prompt)
            print("[SUCCESS] Booth berhasil diklaim secara aman!")
            return true
        end
    end
    print("[INFO] Tidak ada booth kosong yang ditemukan.")
    return false
end

local function getActiveBoothItems()
    local boothItemsPayload = {}
    pcall(function()
        local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
        if not saleListingsReplion then return end
        
        local userIdStr = tostring(LocalPlayer.UserId)
        local listings = saleListingsReplion:Get({"Players", userIdStr, "Booth"})
        
        if listings and type(listings) == "table" then
            for listingId, listingData in pairs(listings) do
                if listingData and listingData.Item then
                    local item = listingData.Item
                    local categoryName = listingData.ItemType or "Items"
                    local price = listingData.Price or 0
                    local itemId = item.Id
                    local itemUUID = item.UUID

                    if itemId and itemUUID then
                        local sInfo, itemInfo = pcall(function() 
                            return ItemUtility.GetItemDataFromItemType(categoryName, itemId) 
                        end)

                        if sInfo and itemInfo and itemInfo.Data then
                            local realData = itemInfo.Data
                            local metadata = item.Metadata or {}
                            
                            local icon = realData.Icon or realData.Image or ""
                            local weight = tonumber(metadata.Weight) or 0
                            
                            local sizeCategory = "Biasa"
                            if itemInfo.Weight and itemInfo.Weight.Big then
                                local bigMin = itemInfo.Weight.Big.Min or 0
                                local bigMax = itemInfo.Weight.Big.Max or 0
                                if weight >= bigMax then
                                    sizeCategory = "Max"
                                elseif weight >= bigMin then
                                    sizeCategory = "Big"
                                end
                            end

                            local rawMutation = metadata.VariantId
                            local isShiny = metadata.Shiny == true
                            local finalMutation = "Normal"
                            if rawMutation and isShiny then
                                finalMutation = tostring(rawMutation) .. " Shiny"
                            elseif rawMutation then
                                finalMutation = tostring(rawMutation)
                            elseif isShiny then
                                finalMutation = "Shiny"
                            end

                            table.insert(boothItemsPayload, {
                                UUID = tostring(itemUUID),
                                Name = tostring(realData.Name),
                                Type = tostring(realData.Type or categoryName),
                                Icon = tostring(icon),
                                Weight = weight,
                                SizeCategory = sizeCategory,
                                Mutation = finalMutation,
                                Shiny = isShiny,
                                Price = tonumber(price) or 0
                            })
                        end
                    end
                end
            end
        end
    end)
    return boothItemsPayload
end

local function syncInventoryToWeb()
    local playerData = Replion.Client:WaitReplion("Data")
    if not playerData then return end
    
    local inventory = playerData:Get("Inventory")
    if not inventory then return end

    local payloadItems = {}
    local totalTradeable = 0

    for categoryName, items in pairs(inventory) do
        if type(items) == "table" then
            for _, itemData in ipairs(items) do
                if itemData and itemData.Id and itemData.UUID then
                    local successItem, itemInfo = pcall(function() 
                        return ItemUtility.GetItemDataFromItemType(categoryName, itemData.Id) 
                    end)
                    
                    if successItem and itemInfo and itemInfo.Data then
                        local canTrade = false
                        pcall(function()
                            canTrade = TradeData.FollowTradeRules(itemInfo, { Metadata = itemData.Metadata })
                        end)

                        if canTrade then
                            totalTradeable = totalTradeable + 1
                            local realData = itemInfo.Data
                            local metadata = itemData.Metadata or {}
                            
                            local icon = realData.Icon or realData.Image or ""
                            local weight = tonumber(metadata.Weight) or 0
                            
                            local sizeCategory = "Biasa"
                            if itemInfo.Weight and itemInfo.Weight.Big then
                                local bigMin = itemInfo.Weight.Big.Min or 0
                                local bigMax = itemInfo.Weight.Big.Max or 0
                                if weight >= bigMax then
                                    sizeCategory = "Max"
                                elseif weight >= bigMin then
                                    sizeCategory = "Big"
                                end
                            end

                            local rawMutation = metadata.VariantId
                            local isShiny = metadata.Shiny == true
                            local finalMutation = "Normal"
                            if rawMutation and isShiny then
                                finalMutation = tostring(rawMutation) .. " Shiny"
                            elseif rawMutation then
                                finalMutation = tostring(rawMutation)
                            elseif isShiny then
                                finalMutation = "Shiny"
                            end

                            table.insert(payloadItems, {
                                UUID = tostring(itemData.UUID),
                                Name = tostring(realData.Name),
                                Type = tostring(realData.Type or categoryName),
                                Icon = tostring(icon),
                                Weight = weight,
                                SizeCategory = sizeCategory,
                                Mutation = finalMutation,
                                Shiny = isShiny
                            })
                        end
                    end
                end
            end
        end
    end

    local boothItemsPayload = getActiveBoothItems()

    if totalTradeable == 0 and #boothItemsPayload == 0 then
        hasActiveStock = false
    else
        hasActiveStock = true
    end

    pcall(function()
        request({
            Url = WEB_URL .. "?action=sync_inventory",
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({ 
                username = username, 
                items = payloadItems,
                booth_items = boothItemsPayload
            })
        })
    end)
end

task.spawn(function()
    task.wait(5)
    isBoothClaimed = autoClaimBooth()
    
    if not isBoothClaimed then
        task.wait(2)
        serverHopHighestRAP()
        return
    end

    syncInventoryToWeb()
end)

task.spawn(function()
    local lastInventoryHash = ""
    while true do
        task.wait(5)
        pcall(function()
            local playerData = Replion.Client:WaitReplion("Data")
            if playerData then
                local inventory = playerData:Get("Inventory")
                if inventory then
                    local currentState = HttpService:JSONEncode(inventory)
                    if lastInventoryHash == "" then
                        lastInventoryHash = currentState
                    elseif lastInventoryHash ~= currentState then
                        resetInactivityTimer() 
                        lastInventoryHash = currentState
                        syncInventoryToWeb()
                    end
                end
            end
        end)
    end
end)

-- Loop Utama Timer Inaktivitas
task.spawn(function()
    while true do
        task.wait(1)
        if isBoothClaimed then
            currentTimer = currentTimer - 1
            if currentTimer <= 0 then
                if hasActiveStock then
                    serverHopHighestRAP()
                    break
                else
                    currentTimer = 60 
                end
            end
        end
    end
end)

-- Loop Polling Command (Sell, Unlist, & Timer Duration Sync)
task.spawn(function()
    while true do
        pcall(function()
            local response = request({
                Url = WEB_URL .. "?action=poll_commands&username=" .. HttpService:UrlEncode(username),
                Method = "GET"
            })
            
            if response.StatusCode == 200 then
                local resDataFixed = HttpService:JSONDecode(response.Body)
                
                if resDataFixed.timer_duration then
                    local newDuration = tonumber(resDataFixed.timer_duration)
                    if newDuration and newDuration > 0 and newDuration ~= TIMER_DURATION then
                        TIMER_DURATION = newDuration
                        if currentTimer > TIMER_DURATION then
                            currentTimer = TIMER_DURATION
                        end
                    end
                end

                if resDataFixed.status == 'ok' and resDataFixed.command then
                    local cmd = resDataFixed.command
                    
                    if cmd.action_type == 'sell_item' then
                        local playerData = Replion.Client:WaitReplion("Data")
                        local inventory = playerData and playerData:Get("Inventory")
                        local targetType = nil
                        
                        if inventory then
                            for catName, items in pairs(inventory) do
                                for _, itm in ipairs(items) do
                                    if itm.UUID == cmd.item_uuid then
                                        local sInfo, info = pcall(function() return ItemUtility.GetItemDataFromItemType(catName, itm.Id) end)
                                        if sInfo and info and info.Data then
                                            targetType = info.Data.Type or catName
                                        end
                                        break
                                    end
                                end
                                if targetType then break end
                            end
                        end

                        if targetType then
                            local success, err = pcall(function()
                                return TradeData.Remotes.CreateSaleListing:InvokeServer("Booth", targetType, cmd.item_uuid, tonumber(cmd.price))
                            end)
                            
                            if success then
                                resetInactivityTimer() 
                                task.spawn(syncInventoryToWeb)
                            end
                        end

                    elseif cmd.action_type == 'unlist_item' then
                        pcall(function()
                            local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
                            if not saleListingsReplion then return end
                            
                            local userIdStr = tostring(LocalPlayer.UserId)
                            local listings = saleListingsReplion:Get({"Players", userIdStr, "Booth"})
                            local targetListingId = nil
                            
                            if listings and type(listings) == "table" then
                                for listingId, listingData in pairs(listings) do
                                    if listingData and listingData.Item and listingData.Item.UUID == cmd.item_uuid then
                                        targetListingId = listingId
                                        break
                                    end
                                end
                            end
                            
                            if targetListingId then
                                local success, err = pcall(function()
                                    return TradeData.Remotes.DeleteSaleListing:InvokeServer("Booth", targetListingId)
                                end)
                                
                                if success then
                                    resetInactivityTimer()
                                    task.spawn(syncInventoryToWeb)
                                end
                            end
                        end)
                    end
                end
            end
        end)
        task.wait(3)
    end
end)
