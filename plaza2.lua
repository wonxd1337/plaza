print("DEBUG 1: Skrip utama bot booth mulai dieksekusi")

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local WEB_URL = "http://ez.mn/tmpl/feeds/feed/rob/index.php"
local LocalPlayer = Players.LocalPlayer
local username = LocalPlayer.Name
local PlaceId = game.PlaceId

print("DEBUG 2: Memuat modul-modul inti game...")
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
print("DEBUG 3: Semua modul inti berhasil dimuat.")

local TIMER_DURATION = 600 
local currentTimer = TIMER_DURATION
local hasActiveStock = true
local isBoothClaimed = false

local function serverHop()
    print("ServerHop: Mencari server baru...")
    pcall(function()
        local servers = HttpService:JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/" .. PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"))
        for _, s in ipairs(servers.data) do
            if s.playing < s.maxPlayers and s.id ~= game.JobId then
                print("ServerHop: Berpindah ke Server ID: " .. s.id)
                TeleportService:TeleportToPlaceInstance(PlaceId, s.id, LocalPlayer)
                return
            end
        end
    end)
    TeleportService:Teleport(PlaceId, LocalPlayer)
end

local function resetInactivityTimer()
    currentTimer = TIMER_DURATION
    print("Timer: Timer di-reset kembali.")
end

local function claimNearestBooth()
    print("Booth: Memindai booth kosong terdekat...")
    local targetBooth = nil
    local shortestDistance = math.huge
    local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local rootPart = character:WaitForChild("HumanoidRootPart", 5)
    
    if not rootPart then return false end

    pcall(function()
        local boothsFolder = Workspace:FindFirstChild("Booths") or Workspace:FindFirstChild("Booth")
        if boothsFolder then
            for _, booth in ipairs(boothsFolder:GetChildren()) do
                local ownerVal = booth:FindFirstChild("Owner")
                if ownerVal and (ownerVal.Value == nil or ownerVal.Value == 0 or ownerVal.Value == "") then
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
        end
    end)

    if targetBooth then
        local prompt = targetBooth:FindFirstChildWhichIsA("ProximityPrompt", true) or targetBooth:FindFirstChild("Interact", true)
        if prompt and prompt:IsA("ProximityPrompt") then
            fireproximityprompt(prompt)
            print("Booth: Berhasil mengklaim booth!")
            return true
        end
    end
    return false
end

local function getActiveBoothItems(playerData)
    local boothItemsPayload = {}
    pcall(function()
        local boothData = playerData:Get("Booth") or playerData:Get("Booths")
        if boothData and boothData.Listings then
            for _, listing in pairs(boothData.Listings) do
                local itemUUID = listing.UUID or listing.ItemUUID
                local price = listing.Price or 0
                local categoryName = listing.ItemType or "Items"
                local itemId = listing.Id or listing.ItemId

                if itemId and itemUUID then
                    local sInfo, itemInfo = pcall(function() 
                        return ItemUtility.GetItemDataFromItemType(categoryName, itemId) 
                    end)

                    if sInfo and itemInfo and itemInfo.Data then
                        local realData = itemInfo.Data
                        local metadata = listing.Metadata or {}
                        
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
    end)
    return boothItemsPayload
end

local function syncInventoryToWeb()
    print("WebSync: Memulai sinkronisasi data...")
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

    local boothItemsPayload = getActiveBoothItems(playerData)

    if totalTradeable == 0 and #boothItemsPayload == 0 then
        hasActiveStock = false
        print("Stok: Stok habis total! Standby.")
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
    print("WebSync: Berhasil sinkronisasi.")
end

task.spawn(function()
    print("DEBUG 4: Menunggu environment game siap...")
    task.wait(5)
    
    print("DEBUG 5: Klaim booth...")
    isBoothClaimed = claimNearestBooth()
    
    if not isBoothClaimed then
        print("ServerHop: Booth penuh, pindah server...")
        task.wait(2)
        serverHop()
        return
    end

    print("DEBUG 6: Sinkronisasi awal...")
    syncInventoryToWeb()
end)

task.spawn(function()
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
                        print("Inventory: Perubahan terdeteksi!")
                        resetInactivityTimer()
                        lastInventoryHash = currentState
                        syncInventoryToWeb()
                    end
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
                    print("ServerHop: Timer habis, pindah server...")
                    serverHop()
                    break
                else
                    print("Timer habis, stok kosong. Bot standby.")
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
                Url = WEB_URL .. "?action=poll_commands&username=" .. HttpService:UrlEncode(username),
                Method = "GET"
            })
            
            if response.StatusCode == 200 then
                local resData = HttpService:JSONDecode(response.Body)
                if resData.status == 'ok' and resData.command then
                    local cmd = resData.command
                    
                    if cmd.action_type == 'sell_item' then
                        print("Dashboard: Eksekusi jual item...")
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
                                print("Dashboard: Sukses pasang item ke booth!")
                                resetInactivityTimer()
                                task.spawn(syncInventoryToWeb)
                            else
                                warn("Dashboard: Gagal pasang item: " .. tostring(err))
                            end
                        end
                    end
                end
            end
        end)
        task.wait(3)
    end
end)
