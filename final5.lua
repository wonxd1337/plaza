local PLAZA_PLACE_ID = 79378095465365

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")

local WEB_URL = "http://ez.mn/tmpl/feeds/feed/plaza/api.php"
local LocalPlayer = Players.LocalPlayer
local username = LocalPlayer.Name
local maxPlayers = Players.MaxPlayers

local MAX_BOOTH_SLOTS = 10 

-- Logika Cek Place ID Sederhana & Bersih
if game.PlaceId ~= PLAZA_PLACE_ID then
    pcall(function()
        TeleportService:Teleport(PLAZA_PLACE_ID, LocalPlayer)
    end)
    return
end

-- Anti-AFK Metode Bersih (Mematikan sinyal idle dari akarnya via getconnections)
task.spawn(function()
    pcall(function()
        for _, connection in ipairs(getconnections(LocalPlayer.Idled)) do
            connection:Disable()
        end
    end)
end)

local function moveToTarget(humanoid, rootPart, targetPos)
    local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
    local success = pcall(function() path:ComputeAsync(rootPart.Position, targetPos) end)
    
    if success and path.Status == Enum.PathStatus.Success then
        for _, waypoint in ipairs(path:GetWaypoints()) do
            humanoid:MoveTo(waypoint.Position)
            if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
            local reached = false
            local conn = humanoid.MoveToFinished:Connect(function() reached = true; conn:Disconnect() end)
            local startT = tick()
            while not reached and (rootPart.Position - waypoint.Position).Magnitude > 3 and (tick() - startT) < 5 do
                task.wait()
            end
            if conn then conn:Disconnect() end
        end
    else
        humanoid:MoveTo(targetPos)
        local startT = tick()
        repeat task.wait(0.1) until (rootPart.Position - targetPos).Magnitude < 4 or (tick() - startT) < 6
    end
end

local successReplion, Replion = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Replion")) 
end)
local successItemUtil, ItemUtility = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemUtility")) 
end)
local successTrade, TradeData = pcall(function()
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Trading"):WaitForChild("TradeData"))
end)

local allVariants = {}
if successItemUtil and ItemUtility then
    pcall(function()
        local successVar, vars = pcall(ItemUtility.GetVariants)
        if successVar and vars then allVariants = vars end
    end)
end

local successInternal, InternalUtility = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ToolTip"):WaitForChild("Internal"):WaitForChild("Utility")) 
end)

if not successReplion or not successItemUtil or not successTrade then
    return
end

local serverBrowserReplion = Replion.Client:WaitReplion("ServerBrowser")

local TIMER_DURATION = 900 
local currentTimer = TIMER_DURATION
local hasActiveStock = true
local isBoothClaimed = false

local function getBotTokens()
    local tokens = 0
    pcall(function()
        local playerData = Replion.Client:WaitReplion("Data")
        if playerData then
            tokens = playerData:Get("Tokens") or 0
        end
    end)
    return tokens
end

local function getItemRAP(itemType, itemId)
    local rapVal = 0
    pcall(function()
        local rapReplion = Replion.Client:GetReplion("RAP")
        if not rapReplion then
            rapReplion = Replion.Client:WaitReplion("RAP")
        end
        
        if rapReplion and itemId then
            local itemData = ItemUtility.GetItemDataFromItemType(itemType, itemId)
            if itemData then
                local tId = TradeData.GetItemId(itemType, itemData)
                local val = rapReplion:Get({ "RAPs", itemType, tId })
                if val and val ~= -1 then
                    rapVal = tonumber(val) or 0
                end
            end
        end
    end)
    return rapVal
end

local function formatItemName(realName, weight, sizeCategory)
    if sizeCategory == "Max" then
        return "Big " .. realName .. " [MAX] [" .. weight .. "kg]"
    elseif sizeCategory == "Big" then
        return "Big " .. realName .. " [" .. weight .. "kg]"
    else
        return realName .. " [" .. weight .. "kg]"
    end
end

local function extractItemMetadata(itemInfo, itemData, categoryName)
    local metadata = itemData.Metadata or {}
    local rawMutation = metadata.VariantId
    local isShiny = metadata.Shiny == true
    
    local finalMutation = ""
    if rawMutation and isShiny then finalMutation = tostring(rawMutation) .. " Shiny"
    elseif rawMutation then finalMutation = tostring(rawMutation)
    elseif isShiny then finalMutation = "Shiny" end

    local mutationColorStr = ""
    if rawMutation then
        local currentVariants = allVariants
        if not currentVariants or not next(currentVariants) then
            pcall(function()
                local s, v = pcall(ItemUtility.GetVariants)
                if s and v then currentVariants = v end
            end)
        end

        for k, v in pairs(currentVariants) do
            local mutName = v._moduleScript or tostring(k)
            if tostring(mutName) == tostring(rawMutation) then
                local tierColor = (v.Data and v.Data.TierColor)
                if tierColor then
                    mutationColorStr = tostring(tierColor)
                end
                break
            end
        end
    end

    local rarityName = "Common"
    if successInternal and InternalUtility and InternalUtility.getTierData then
        local succTier, tierData = pcall(function() return InternalUtility.getTierData(itemInfo) end)
        if succTier and tierData and tierData.Name then rarityName = tostring(tierData.Name) end
    end

    local rawChance = 0
    if itemInfo.Probability and type(itemInfo.Probability) == "table" then
        rawChance = tonumber(itemInfo.Probability.Chance) or 0
    end

    return finalMutation, mutationColorStr, isShiny, rarityName, rawChance
end

local function serverHopHighestRAP()
    local servers = serverBrowserReplion and serverBrowserReplion.Data and serverBrowserReplion.Data.Servers
    if not servers then
        TeleportService:Teleport(PLAZA_PLACE_ID, LocalPlayer)
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
            TeleportService:TeleportToPlaceInstance(PLAZA_PLACE_ID, bestJobId, LocalPlayer)
        end)
    else
        TeleportService:Teleport(PLAZA_PLACE_ID, LocalPlayer)
    end
end

local function resetInactivityTimer()
    currentTimer = TIMER_DURATION
end

local function autoClaimBooth()
    local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local humanoid = character:WaitForChild("Humanoid")
    local rootPart = character:WaitForChild("HumanoidRootPart")
    local targetBooth = nil
    local shortestDist = math.huge

    pcall(function()
        for _, booth in ipairs(CollectionService:GetTagged("Booth")) do
            local owner = booth:GetAttribute("Owner")
            if not owner or owner == 0 or owner == "" then
                local bPart = booth.PrimaryPart or booth:FindFirstChildWhichIsA("BasePart")
                if bPart then
                    local dist = (rootPart.Position - bPart.Position).Magnitude
                    if dist < shortestDist then shortestDist = dist; targetBooth = booth end
                end
            end
        end
    end)

    if targetBooth then
        local prompt = targetBooth:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then
            local targetPos = prompt.Parent and prompt.Parent:IsA("BasePart") and (prompt.Parent.Position + (prompt.Parent.CFrame.LookVector * 3)) or (targetBooth:GetPivot().Position + Vector3.new(0, 0, 3))
            moveToTarget(humanoid, rootPart, targetPos)
            task.wait(0.5)
            
            local currentOwner = targetBooth:GetAttribute("Owner")
            if currentOwner and currentOwner ~= 0 and currentOwner ~= "" then
                return false
            end

            task.wait((prompt.HoldDuration or 0.5) + 0.1)
            fireproximityprompt(prompt)
            task.wait(0.6)

            local verifiedOwner = targetBooth:GetAttribute("Owner")
            if tostring(verifiedOwner) == tostring(LocalPlayer.UserId) then
                return true
            end
        end
    end
    return false
end

local function getActiveBoothItems()
    local boothItemsPayload = {}
    pcall(function()
        local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
        if not saleListingsReplion then return end
        local listings = saleListingsReplion:Get({"Players", tostring(LocalPlayer.UserId), "Booth"})
        
        if listings and type(listings) == "table" then
            for listingId, listingData in pairs(listings) do
                if listingData and listingData.Item then
                    local item = listingData.Item
                    local catName = listingData.ItemType or "Items"
                    local price = listingData.Price or 0
                    local sInfo, itemInfo = pcall(function() return ItemUtility.GetItemDataFromItemType(catName, item.Id) end)
                    
                    if sInfo and itemInfo and itemInfo.Data then
                        local realData = itemInfo.Data
                        local metadata = item.Metadata or {}
                        local weight = tonumber(metadata.Weight) or 0
                        
                        local bigMin = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Min) or 0
                        local bigMax = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Max) or 0

                        local sizeCategory = "Biasa"
                        if itemInfo.Weight and itemInfo.Weight.Big then
                            if weight >= bigMax then
                                sizeCategory = "Max"
                            elseif weight >= bigMin then
                                sizeCategory = "Big"
                            end
                        end

                        local finalName = formatItemName(realData.Name, weight, sizeCategory)
                        local finalMutation, mutationColorStr, isShiny, rarityName, rawChance = extractItemMetadata(itemInfo, item, catName)
                        local itemRAP = getItemRAP(realData.Type or catName, item.Id)

                        table.insert(boothItemsPayload, {
                            UUID = tostring(item.UUID),
                            Name = finalName,
                            Type = tostring(realData.Type or catName),
                            Icon = tostring(realData.Icon or realData.Image or itemInfo.Icon or itemInfo.Image or ""),
                            Weight = weight,
                            SizeCategory = sizeCategory,
                            BigMin = bigMin,
                            BigMax = bigMax,
                            Mutation = finalMutation,
                            MutationColor = mutationColorStr,
                            Shiny = isShiny,
                            RAP = itemRAP,
                            Price = tonumber(price) or 0,
                            Rarity = rarityName,
                            Chance = rawChance
                        })
                    end
                end
            end
        end
    end)
    return boothItemsPayload
end

local function syncBoothOnly()
    local boothItemsPayload = getActiveBoothItems()
    local tokens = getBotTokens()
    hasActiveStock = (#boothItemsPayload > 0)

    pcall(function()
        request({
            Url = WEB_URL .."?action=sync_booth",
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({ 
                username = username, 
                tokens = tokens,
                booth_items = boothItemsPayload
            })
        })
    end)
end

local function syncInventoryToWeb()
    local playerData = Replion.Client:WaitReplion("Data")
    if not playerData then return end
    local inventory = playerData:Get("Inventory")
    if not inventory then return end

    local payloadItems = {}
    for catName, items in pairs(inventory) do
        if type(items) == "table" then
            for _, itemData in ipairs(items) do
                if itemData and itemData.Id and itemData.UUID then
                    local sItem, itemInfo = pcall(function() return ItemUtility.GetItemDataFromItemType(catName, itemData.Id) end)
                    if sItem and itemInfo and itemInfo.Data then
                        local canTrade = false
                        pcall(function() canTrade = TradeData.FollowTradeRules(itemInfo, { Metadata = itemData.Metadata }) end)
                        if canTrade then
                            local realData = itemInfo.Data
                            local metadata = itemData.Metadata or {}
                            local weight = tonumber(metadata.Weight) or 0
                            
                            local bigMin = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Min) or 0
                            local bigMax = (itemInfo.Weight and itemInfo.Weight.Big and itemInfo.Weight.Big.Max) or 0

                            local sizeCategory = "Biasa"
                            if itemInfo.Weight and itemInfo.Weight.Big then
                                if weight >= bigMax then
                                    sizeCategory = "Max"
                                elseif weight >= bigMin then
                                    sizeCategory = "Big"
                                end
                            end

                            local finalName = formatItemName(realData.Name, weight, sizeCategory)
                            local finalMutation, mutationColorStr, isShiny, rarityName, rawChance = extractItemMetadata(itemInfo, itemData, catName)
                            local itemRAP = getItemRAP(realData.Type or catName, itemData.Id)

                            table.insert(payloadItems, {
                                UUID = tostring(itemData.UUID),
                                Name = finalName,
                                Type = tostring(realData.Type or catName),
                                Icon = tostring(realData.Icon or realData.Image or itemInfo.Icon or itemInfo.Image or ""),
                                Weight = weight,
                                SizeCategory = sizeCategory,
                                BigMin = bigMin,
                                BigMax = bigMax,
                                Mutation = finalMutation,
                                MutationColor = mutationColorStr,
                                Shiny = isShiny,
                                RAP = itemRAP,
                                Rarity = rarityName,
                                Chance = rawChance
                            })
                        end
                    end
                end
            end
        end
    end

    local boothItemsPayload = getActiveBoothItems()
    local tokens = getBotTokens()

    pcall(function()
        request({
            Url = WEB_URL .."?action=sync_inventory",
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({ 
                username = username, 
                tokens = tokens,
                items = payloadItems,
                booth_items = boothItemsPayload
            })
        })
    end)
end

local function processQueue()
    pcall(function()
        local boothItems = getActiveBoothItems()
        if #boothItems >= MAX_BOOTH_SLOTS then
            return 
        end

        local response = request({
            Url = WEB_URL .."?action=get_next_queue&username=" .. HttpService:UrlEncode(username),
            Method = "GET"
        })

        if response.StatusCode == 200 then
            local resData = HttpService:JSONDecode(response.Body)
            if resData.status == 'ok' and resData.queue then
                local q = resData.queue
                local targetUuid = q.uuid
                local targetPrice = tonumber(q.price)

                local playerData = Replion.Client:WaitReplion("Data")
                local inventory = playerData and playerData:Get("Inventory")
                local targetType = nil

                if inventory then
                    for catName, items in pairs(inventory) do
                        for _, itm in ipairs(items) do
                            if itm.UUID == targetUuid then
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

                if targetType and targetPrice then
                    local success = pcall(function()
                        return TradeData.Remotes.CreateSaleListing:InvokeServer("Booth", targetType, targetUuid, targetPrice)
                    end)

                    if success then
                        resetInactivityTimer()
                        task.spawn(function() task.wait(1.5); syncBoothOnly() end)
                    end
                end
            end
        end
    end)
end

task.spawn(function()
    pcall(function()
        TradeData.Remotes.SaleListingSold.OnClientEvent:Connect(function(buyer, _, _, itemType, itemData, price)
            local sInfo, itemInfo = pcall(function() return ItemUtility.GetItemDataFromItemType(itemType, itemData.Id) end)
            local realData = (sInfo and itemInfo and itemInfo.Data) and itemInfo.Data or nil
            local metadata = itemData.Metadata or {}
            local weight = tonumber(metadata.Weight) or 0
            local sizeCategory = "Biasa"
            if itemInfo and itemInfo.Weight and itemInfo.Weight.Big then
                local bigMin = itemInfo.Weight.Big.Min or 0
                local bigMax = itemInfo.Weight.Big.Max or 0
                if weight >= bigMax then sizeCategory = "Max" elseif weight >= bigMin then sizeCategory = "Big" end
            end
            local itemName = realData and formatItemName(realData.Name, weight, sizeCategory) or "Unknown Item"
            local buyerName = (buyer and buyer.DisplayName) and buyer.DisplayName or "Player"
            
            pcall(function()
                request({
                    Url = WEB_URL .."?action=record_sale",
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode({
                        username = username,
                        item_name = itemName,
                        price = tonumber(price) or 0,
                        buyer_name = buyerName
                    })
                })
            end)
            syncBoothOnly()
            task.spawn(processQueue)
        end)
    end)
end)

task.spawn(function()
    task.wait(5)
    local maxRetries = 5
    local attempts = 0
    
    repeat
        isBoothClaimed = autoClaimBooth()
        if not isBoothClaimed then
            attempts += 1
            task.wait(2)
        end
    until isBoothClaimed or attempts >= maxRetries

    if not isBoothClaimed then
        serverHopHighestRAP()
        return
    end
    syncBoothOnly()
    processQueue()
end)

task.spawn(function()
    local lastBoothHash = ""
    while true do
        task.wait(3)
        pcall(function()
            local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
            if saleListingsReplion then
                local listings = saleListingsReplion:Get({"Players", tostring(LocalPlayer.UserId), "Booth"})
                local currentState = HttpService:JSONEncode(listings or {})
                if lastBoothHash == "" then
                    lastBoothHash = currentState
                elseif lastBoothHash ~= currentState then
                    resetInactivityTimer()
                    lastBoothHash = currentState
                    syncBoothOnly()
                    processQueue()
                end
            end
        end)
    end
end)

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

task.spawn(function()
    while true do
        pcall(function()
            local response = request({
                Url = WEB_URL .."?action=poll_commands&username=" .. HttpService:UrlEncode(username),
                Method = "GET"
            })
            if response.StatusCode == 200 then
                local resData = HttpService:JSONDecode(response.Body)
                if resData.timer_duration then
                    local newDur = tonumber(resData.timer_duration)
                    if newDur and newDur > 0 and newDur ~= TIMER_DURATION then
                        TIMER_DURATION = newDur
                        if currentTimer > TIMER_DURATION then currentTimer = TIMER_DURATION end
                    end
                end

                if resData.status == 'ok' and resData.command then
                    local cmd = resData.command
                    if cmd.action_type == 'refresh_inventory' then
                        task.spawn(syncInventoryToWeb)
                    elseif cmd.action_type == 'sell_item' then
                        local playerData = Replion.Client:WaitReplion("Data")
                        local inventory = playerData and playerData:Get("Inventory")
                        local targetType = nil
                        if inventory then
                            for catName, items in pairs(inventory) do
                                for _, itm in ipairs(items) do
                                    if itm.UUID == cmd.item_uuid then
                                        local sInfo, info = pcall(function() return ItemUtility.GetItemDataFromItemType(catName, itm.Id) end)
                                        if sInfo and info and info.Data then targetType = info.Data.Type or catName end
                                        break
                                    end
                                end
                                if targetType then break end
                            end
                        end
                        if targetType then
                            local success = pcall(function()
                                return TradeData.Remotes.CreateSaleListing:InvokeServer("Booth", targetType, cmd.item_uuid, tonumber(cmd.price))
                            end)
                            if success then
                                resetInactivityTimer()
                                task.spawn(function() task.wait(1.5); syncBoothOnly() end)
                            end
                        end
                    elseif cmd.action_type == 'unlist_item' then
                        pcall(function()
                            local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
                            if not saleListingsReplion then return end
                            local listings = saleListingsReplion:Get({"Players", tostring(LocalPlayer.UserId), "Booth"})
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
                                local success = pcall(function()
                                    return TradeData.Remotes.DeleteSaleListing:InvokeServer("Booth", targetListingId)
                                end)
                                if success then
                                    resetInactivityTimer()
                                    task.spawn(function() task.wait(1.5); syncBoothOnly(); processQueue(); end)
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
