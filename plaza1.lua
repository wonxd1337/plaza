print("[DEBUG 1] 🚀 Skrip utama bot booth berhasil di-inject dan mulai dieksekusi!")

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local WEB_URL = "http://ez.mn/tmpl/feeds/feed/plaza/index.php" -- Sesuaikan URL server PHP kamu
local LocalPlayer = Players.LocalPlayer
local username = LocalPlayer.Name
local PlaceId = game.PlaceId

print("[DEBUG 2] Memuat modul-modul inti game...")
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
    warn("[DEBUG ERROR] ❌ Gagal memuat salah satu modul inti (Replion/ItemUtility/TradeData)!")
    return
end
print("[DEBUG 3] ✅ Semua modul inti berhasil dimuat.")

-- Konfigurasi Timer & Status (10 Menit = 600 Detik)
local TIMER_DURATION = 600 
local currentTimer = TIMER_DURATION
local hasActiveStock = true
local isBoothClaimed = false

-- Fungsi Pindah Server (Server Hop)
local function serverHop()
    print("[ServerHop] Mencari server baru yang memiliki slot kosong...")
    pcall(function()
        local servers = HttpService:JSONDecode(game:HttpGet("https://games.roblox.com/v1/games/" .. PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"))
        for _, s in ipairs(servers.data) do
            if s.playing < s.maxPlayers and s.id ~= game.JobId then
                print("[ServerHop] Berpindah ke Server ID: " .. s.id)
                TeleportService:TeleportToPlaceInstance(PlaceId, s.id, LocalPlayer)
                return
            end
        end
    end)
    TeleportService:Teleport(PlaceId, LocalPlayer)
end

-- Fungsi Reset Timer (Keadaan 3)
local function resetInactivityTimer()
    currentTimer = TIMER_DURATION
    print("[Timer] ⏱️ Timer inaktif di-reset kembali ke " .. (TIMER_DURATION / 60) .. " menit.")
end

-- Fungsi Auto Claim Booth Terdekat (Skenario 1 & Keadaan 1)
local function claimNearestBooth()
    print("[Booth] Memindai booth kosong terdekat...")
    local targetBooth = nil
    local shortestDistance = math.huge
    local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local rootPart = character:WaitForChild("HumanoidRootPart", 5)
    
    if not rootPart then 
        warn("[Booth] HumanoidRootPart tidak ditemukan!")
        return false 
    end

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
            print("[Booth] Berhasil mengklaim booth terdekat!")
            return true
        end
    end

    warn("[DEBUG] Tidak ada booth kosong yang ditemukan atau prompt gagal diakses.")
    return false
end

-- Fungsi Mengambil Item Aktif yang Sedang Dijual di Booth
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

-- Fungsi Sinkronisasi Inventaris & Booth ke Website
local function syncInventoryToWeb()
    print("[WebSync] Memulai sinkronisasi data ke web...")
    local playerData = Replion.Client:WaitReplion("Data")
    if not playerData then 
        warn("[WebSync] Gagal mendapatkan Data Replion!")
        return 
    end
    
    local inventory = playerData:Get("Inventory")
    if not inventory then 
        warn("[WebSync] Data Inventaris kosong!")
        return 
    end

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
        print("[Stok] 📦 Stok habis total! Bot standby menunggu perintah dari web.")
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
    print(string.format("[WebSync] ✅ Berhasil sinkron: %d item di tas, %d item di booth.", #payloadItems, #boothItemsPayload))
end

-- Eksekusi Utama Saat Bot Masuk Game
task.spawn(function()
    print("[DEBUG 4] Menunggu environment game siap (5 detik)...")
    task.wait(5)
    
    print("[DEBUG 5] Mencoba klaim booth terdekat...")
    isBoothClaimed = claimNearestBooth()
    
    if not isBoothClaimed then
        print("[ServerHop] Keadaan 1 Aktif: Booth di server ini penuh! Langsung pindah server...")
        task.wait(2)
        serverHop()
        return
    end

    print("[DEBUG 6] Booth berhasil diklaim, menjalankan sinkronisasi pertama...")
    syncInventoryToWeb()
end)

-- Background Watcher: Deteksi Perubahan Inventaris (Item Terjual / Berubah) -> Reset Timer (Keadaan 3)
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
                        print("[Inventory] 🔄 Perubahan inventaris terdeteksi (ada item terbeli/berubah)!")
                        resetInactivityTimer()
                        lastInventoryHash = currentState
                        syncInventoryToWeb()
                    end
                end
            end
        end)
    end
end)

-- Main Timer Loop (Skenario 2)
task.spawn(function()
    while true do
        task.wait(1)
        if isBoothClaimed then
            currentTimer = currentTimer - 1
            if currentTimer <= 0 then
                if hasActiveStock then
                    print("[ServerHop] Skenario 2 Aktif: Timer habis tanpa penjualan & stok masih ada. Pindah server...")
                    serverHop()
                    break
                else
                    print("[Timer] Timer habis, tetapi Keadaan 2 aktif (Stok Habis). Bot tetap standby.")
                    currentTimer = 60
                end
            end
        end
    end
end)

-- Polling Perintah dari Dashboard Web (Setup Harga & Jual Otomatis)
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
                        print(string.format("[Dashboard] Eksekusi jual item UUID [%s] dengan harga [%s]", cmd.item_uuid, tostring(cmd.price)))
                        
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
                                print("[Dashboard] Sukses memasang item baru ke booth!")
                                resetInactivityTimer()
                                task.spawn(syncInventoryToWeb)
                            else
                                warn("[Dashboard] Gagal memasang item ke booth: " . tostring(err))
                            end
                        end
                    end
                end
            end
        end)
        task.wait(3)
    end
end)
