print("DEBUG 1: Skrip utama bot booth mulai dieksekusi")

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")

local WEB_URL = "http://ez.mn/tmpl/feeds/feed/plaza/index.php" -- Sesuaikan dengan URL server PHP kamu
local LocalPlayer = Players.LocalPlayer
local username = LocalPlayer.Name
local PlaceId = game.PlaceId
local maxPlayers = Players.MaxPlayers

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

-- Ambil ServerBrowser Replion bawaan game
local serverBrowserReplion = Replion.Client:WaitReplion("ServerBrowser")
print("DEBUG 3: Semua modul inti & ServerBrowser berhasil dimuat.")

-- Anti-Nyangkut Teleport Error
TeleportService.TeleportInitFailed:Connect(function(player, teleportResult, errorMessage)
    if player == LocalPlayer then
        pcall(function() GuiService:ClearError() end)
    end
end)

-- Konfigurasi Timer & Status (10 Menit = 600 Detik)
local TIMER_DURATION = 600 
local currentTimer = TIMER_DURATION
local hasActiveStock = true
local isBoothClaimed = false

-- ==========================================
-- FUNGSI: Server Hop Berdasarkan RAP Tertinggi via ServerBrowser
-- ==========================================
local function serverHopHighestRAP()
    print("ServerHop: Memindai ServerBrowser internal game untuk mencari RAP tertinggi...")
    
    local servers = serverBrowserReplion and serverBrowserReplion.Data and serverBrowserReplion.Data.Servers
    if not servers then
        print("ServerHop: Data ServerBrowser kosong, melakukan fallback teleport biasa...")
        TeleportService:Teleport(PlaceId, LocalPlayer)
        return
    end

    print("--- SCANNING SERVERS ---")
    local bestJobId = nil
    local highestRAP = -1

    for jobId, serverData in pairs(servers) do
        if jobId ~= game.JobId and serverData then
            local playerCount = serverData.Players or serverData.PlayerCount or 0
            
            if playerCount < (maxPlayers - 1) then
                local serverRAP = serverData.RAP or serverData.TotalRAP or serverData.Value or 0
                
                print(string.format("Server ID: %s | Players: %d | RAP: %s", jobId, playerCount, tostring(serverRAP)))
                
                if serverRAP > highestRAP then
                    highestRAP = serverRAP
                    bestJobId = jobId
                end
            end
        end
    end
    print("------------------------")

    if bestJobId then
        print(string.format("ServerHop: Menemukan server target dengan RAP tertinggi! JobId: %s (RAP: %s)", bestJobId, tostring(highestRAP)))
        pcall(function()
            TeleportService:TeleportToPlaceInstance(PlaceId, bestJobId, LocalPlayer)
        end)
    else
        print("ServerHop: Tidak ada server kriteria ditemukan di ServerBrowser, melakukan fallback...")
        TeleportService:Teleport(PlaceId, LocalPlayer)
    end
end

-- Fungsi Reset Timer (Keadaan 3)
local function resetInactivityTimer()
    currentTimer = TIMER_DURATION
    print("Timer: Timer inaktif di-reset kembali.")
end

-- ==========================================
-- FUNGSI PERBAIKAN: Auto Claim Booth Terdekat (Menggunakan CollectionService & Attribute)
-- ==========================================
local function claimNearestBooth()
    print("Booth: Memindai booth kosong terdekat via CollectionService...")
    local targetBooth = nil
    local shortestDistance = math.huge
    local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local rootPart = character:WaitForChild("HumanoidRootPart", 5)
    
    if not rootPart then return false end

    pcall(function()
        -- Mengambil seluruh objek yang bertag "Booth" dari game
        for _, booth in ipairs(CollectionService:GetTagged("Booth")) do
            local owner = booth:GetAttribute("Owner")
            
            -- Jika Owner bernilai nil, 0, atau kosong, berarti booth tersebut kosong
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
        local prompt = targetBooth:FindFirstChildWhichIsA("ProximityPrompt", true) or targetBooth:FindFirstChild("Interact", true)
        if prompt and prompt:IsA("ProximityPrompt") then
            fireproximityprompt(prompt)
            print("Booth: Berhasil mengklaim booth terdekat!")
            return true
        end
    end
    
    print("Booth: Tidak ada booth kosong ditemukan di server ini.")
    return false
end

-- ==========================================
-- FUNGSI: Ambil Data Item Aktif di Booth
-- ==========================================
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

-- ==========================================
-- FUNGSI: Sinkronisasi Inventaris & Booth ke Web
-- ==========================================
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
        print("Stok: Stok habis total! Bot standby menunggu perintah.")
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

-- ==========================================
-- EKSEKUSI UTAMA: Masuk Game & Klaim Booth (Skenario 1 & Keadaan 1)
-- ==========================================
task.spawn(function()
    print("DEBUG 4: Menunggu environment game siap...")
    task.wait(5)
    
    print("DEBUG 5: Mencari booth terdekat...")
    isBoothClaimed = claimNearestBooth()
    
    -- Jika booth penuh, baru jalankan hop server RAP tertinggi
    if not isBoothClaimed then
        print("ServerHop: Keadaan 1 Aktif - Booth penuh, mencari server RAP tertinggi...")
        task.wait(2)
        serverHopHighestRAP()
        return
    end

    print("DEBUG 6: Booth berhasil diklaim, menjalankan sinkronisasi awal...")
    syncInventoryToWeb()
end)

-- ==========================================
-- BACKGROUND WATCHER: Deteksi Item Terjual -> Reset Timer (Keadaan 3)
-- ==========================================
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
                        print("Inventory: Perubahan terdeteksi (item terjual)!")
                        resetInactivityTimer() 
                        lastInventoryHash = currentState
                        syncInventoryToWeb()
                    end
                end
            end
        end)
    end
end)

-- ==========================================
-- MAIN TIMER LOOP: Skenario 2 (Inaktif 10 Menit)
-- ==========================================
task.spawn(function()
    while true do
        task.wait(1)
        if isBoothClaimed then
            currentTimer = currentTimer - 1
            if currentTimer <= 0 then
                if hasActiveStock then
                    print("ServerHop: Skenario 2 Aktif - Timer habis & stok masih ada. Pindah ke server RAP tertinggi...")
                    serverHopHighestRAP()
                    break
                else
                    print("Timer habis, tapi Keadaan 2 aktif (Stok Habis). Bot tetap standby.")
                    currentTimer = 60 
                end
            end
        end
    end
end)

-- ==========================================
-- POLLING PERINTAH DARI WEB DASHBOARD
-- ==========================================
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
