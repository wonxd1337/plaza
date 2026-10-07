-- Ada 2 PlaceId plaza; keduanya dianggap "sudah di dalam plaza" (tidak ada false hop)
local PLAZA_PLACE_IDS = {
    [79378095465365] = true,
    [82602826017494] = true,
}
local function isPlazaPlace(placeId)
    return PLAZA_PLACE_IDS[placeId] == true
end

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local GuiService = game:GetService("GuiService")

local WEB_URL = "http://ez.mn/tmpl/feeds/feed/plaza/api.php"
local LocalPlayer = Players.LocalPlayer
local username = LocalPlayer.Name
local maxPlayers = Players.MaxPlayers

local MAX_BOOTH_SLOTS = 10 

-- ==========================================
-- ANTI-NYANGKUT: Penanganan Eror Teleport (Error 772 / Server Full)
-- ==========================================
local lastHopFailed = false      -- true kalau teleport ditolak game (Error 772 / server full / dll)
local pendingHopJobId = nil     -- JobId yang sedang dituju
local failedJobIds = {}         -- JobId gagal -> waktu gagal (diblacklist sementara)

TeleportService.TeleportInitFailed:Connect(function(player, teleportResult, errorMessage)
    if player == LocalPlayer then
        if pendingHopJobId then failedJobIds[pendingHopJobId] = os.time() end
        lastHopFailed = true
        pcall(function()
            GuiService:ClearError()
        end)
    end
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

-- Belum di plaza: panggil langsung remote RE/TradePlazaTeleport (tanpa cari portal / jalan kaki)
if not isPlazaPlace(game.PlaceId) then
    task.spawn(function()
        local function getPlazaRemote()
            local pkg = ReplicatedStorage:WaitForChild("Packages", 15)
            local idx = pkg and pkg:WaitForChild("_Index", 15)
            local netPkg = idx and idx:WaitForChild("sleitnick_net@0.2.0", 15)
            local net = netPkg and netPkg:WaitForChild("net", 15)
            return net and net:WaitForChild("RE/TradePlazaTeleport", 15)
        end

        local remote = nil
        while not isPlazaPlace(game.PlaceId) do
            pcall(function()
                if not remote then remote = getPlazaRemote() end
                if remote then
                    if remote:IsA("RemoteFunction") then
                        remote:InvokeServer()
                    else
                        remote:FireServer()
                    end
                end
            end)
            task.wait(8)   -- beri waktu proses teleport sebelum mencoba lagi
        end
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
local hopDeadline = os.time() + TIMER_DURATION   -- waktu absolut kapan harus hop (anti-drift)
local hasActiveStock = true
local isBoothClaimed = false
local isHopping = false
local HOP_RETRY_DELAY = 10     -- jeda coba lagi kalau hop gagal
local NO_STOCK_RECHECK = 60    -- booth kosong: cek ulang tiap 60 dtk (tidak hop)

local function getTimeLeft()
    return math.max(0, hopDeadline - os.time())
end

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

-- ==========================================
-- SERVER HOP: pilih server RAP tertinggi, deteksi gagal teleport, blacklist, retry
-- return true  = teleport sedang berjalan (tidak ada sinyal gagal)
-- return false = semua percobaan gagal
-- ==========================================
local function serverHopHighestRAP()
    if isHopping then return false end
    isHopping = true

    task.spawn(function()
        pcall(function()
            request({
                Url = WEB_URL .. "?action=bot_status&username=" .. HttpService:UrlEncode(username) .. "&state=hopping",
                Method = "GET"
            })
        end)
    end)

    local function waitTeleportResult()
        local t0 = tick()
        while tick() - t0 < 15 and not lastHopFailed do task.wait(0.5) end
        return not lastHopFailed
    end

    local maxAttempts = 5
    for attempt = 1, maxAttempts do
        local bestJobId, highestRAP = nil, -1

        pcall(function()
            local servers = serverBrowserReplion and serverBrowserReplion.Data and serverBrowserReplion.Data.Servers
            if type(servers) ~= "table" then return end
            local now = os.time()
            for jobId, serverData in pairs(servers) do
                local failedAt = failedJobIds[jobId]
                local blacklisted = failedAt and (now - failedAt) < 120
                if jobId ~= game.JobId and type(serverData) == "table" and not blacklisted then
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
        end)

        if bestJobId then
            lastHopFailed = false
            pendingHopJobId = bestJobId
            local ok = pcall(function()
                TeleportService:TeleportToPlaceInstance(game.PlaceId, bestJobId, LocalPlayer)
            end)
            if ok then
                if waitTeleportResult() then
                    isHopping = false
                    return true
                end
            else
                failedJobIds[bestJobId] = os.time()
            end
            pendingHopJobId = nil
        end
        task.wait(2)
    end

    -- Fallback terakhir: teleport ke server acak (aman dari error, tidak membunuh thread)
    lastHopFailed = false
    pendingHopJobId = nil
    local okFallback = pcall(function()
        TeleportService:Teleport(game.PlaceId, LocalPlayer)
    end)
    local result = okFallback and waitTeleportResult()
    isHopping = false
    return result
end

local function resetInactivityTimer()
    hopDeadline = os.time() + TIMER_DURATION
end

-- Item BARU dipajang: timer cuma +3 menit (tidak lebih dari batas TIMER_DURATION)
local TIMER_ADD_NEW_ITEM = 180
local function extendInactivityTimer(sec)
    hopDeadline = math.min(hopDeadline + sec, os.time() + TIMER_DURATION)
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
            task.wait((prompt.HoldDuration or 0.5) + 0.1)
            fireproximityprompt(prompt)
            return true
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
                            Category = tostring(catName),
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
                            Category = tostring(catName),
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
                        -- timer +3 mnt ditangani watcher booth (item baru terdeteksi)
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

            -- detail item untuk riwayat penjualan + notifikasi Discord
            local infoTbl = (sInfo and type(itemInfo) == "table") and itemInfo or nil
            local saleMutation, saleMutColor, saleShiny, saleRarity = "", "", false, "Common"
            if infoTbl then
                local okM, m1, m2, m3, m4 = pcall(extractItemMetadata, infoTbl, itemData, itemType)
                if okM then saleMutation, saleMutColor, saleShiny, saleRarity = m1, m2, m3, m4 end
            end
            local saleIcon = ""
            if realData then
                saleIcon = tostring(realData.Icon or realData.Image or (infoTbl and (infoTbl.Icon or infoTbl.Image)) or "")
            end
            local saleRAP = 0
            pcall(function() saleRAP = getItemRAP((realData and realData.Type) or itemType, itemData.Id) end)
            
            pcall(function()
                request({
                    Url = WEB_URL .."?action=record_sale",
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = HttpService:JSONEncode({
                        username = username,
                        item_name = itemName,
                        price = tonumber(price) or 0,
                        buyer_name = buyerName,
                        item_uuid = (itemData and itemData.UUID) and tostring(itemData.UUID) or nil,
                        base_name = realData and realData.Name or nil,
                        icon = saleIcon,
                        mutation = saleMutation,
                        mutation_color = saleMutColor,
                        shiny = saleShiny == true,
                        weight = weight,
                        size_category = sizeCategory,
                        rarity = saleRarity,
                        category = tostring(itemType),
                        rap = saleRAP
                    })
                })
            end)
            resetInactivityTimer()   -- terjual: reset penuh
            syncBoothOnly()
            task.spawn(processQueue)
            task.spawn(function() task.wait(2); pcall(syncInventoryToWeb) end) -- inventaris dashboard ikut diperbarui
        end)
    end)
end)

task.spawn(function()
    task.wait(5)
    isBoothClaimed = autoClaimBooth()
    if not isBoothClaimed then
        task.wait(2)
        while true do
            local ok, hopped = pcall(serverHopHighestRAP)
            task.wait((ok and hopped) and 20 or HOP_RETRY_DELAY)
        end
    end
    syncBoothOnly()
    processQueue()
    pcall(syncInventoryToWeb) -- inventaris selalu segar tiap bot masuk server baru
end)

task.spawn(function()
    local lastBoothHash = ""
    local lastIds = {}
    local function collectIds(listings)
        local ids = {}
        if type(listings) == "table" then
            for _, data in pairs(listings) do
                local uuid = data and data.Item and data.Item.UUID
                if uuid then ids[tostring(uuid)] = true end
            end
        end
        return ids
    end
    while true do
        task.wait(3)
        pcall(function()
            local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
            if saleListingsReplion then
                local listings = saleListingsReplion:Get({"Players", tostring(LocalPlayer.UserId), "Booth"})
                local currentState = HttpService:JSONEncode(listings or {})
                if lastBoothHash == "" then
                    lastBoothHash = currentState
                    lastIds = collectIds(listings)
                elseif lastBoothHash ~= currentState then
                    local ids = collectIds(listings)
                    local added, removed = false, false
                    for id in pairs(ids) do
                        if not lastIds[id] then added = true; break end
                    end
                    for id in pairs(lastIds) do
                        if not ids[id] then removed = true; break end
                    end
                    lastIds = ids
                    if removed then
                        resetInactivityTimer()                         -- item terjual/di-unlist: reset penuh
                    elseif added then
                        extendInactivityTimer(TIMER_ADD_NEW_ITEM)      -- item baru: +3 menit saja
                    end
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
        if isBoothClaimed and not isHopping and getTimeLeft() <= 0 then
            -- cek stok LANGSUNG dari booth (bukan flag yang bisa basi)
            local okItems, items = pcall(getActiveBoothItems)
            hasActiveStock = okItems and type(items) == "table" and #items > 0

            if hasActiveStock then
                local okHop, hopped = pcall(serverHopHighestRAP)
                -- JANGAN break: kalau hop gagal, loop tetap hidup dan coba lagi
                hopDeadline = os.time() + ((okHop and hopped) and 20 or HOP_RETRY_DELAY)
            else
                hopDeadline = os.time() + NO_STOCK_RECHECK   -- booth kosong: tidak hop
            end
        end
    end
end)

task.spawn(function()
    while true do
        pcall(function()
            local response = request({
                Url = WEB_URL .."?action=poll_commands&username=" .. HttpService:UrlEncode(username)
                    .. "&timer=" .. getTimeLeft() .. "&stock=" .. (hasActiveStock and 1 or 0),
                Method = "GET"
            })
            if response.StatusCode == 200 then
                local resData = HttpService:JSONDecode(response.Body)
                if resData.timer_duration then
                    local newDur = tonumber(resData.timer_duration)
                    if newDur and newDur > 0 and newDur ~= TIMER_DURATION then
                        TIMER_DURATION = newDur
                        if getTimeLeft() > TIMER_DURATION then hopDeadline = os.time() + TIMER_DURATION end
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
                            local success, res = pcall(function()
                                return TradeData.Remotes.CreateSaleListing:InvokeServer("Booth", targetType, cmd.item_uuid, tonumber(cmd.price))
                            end)
                            if success and res ~= false then
                                -- timer +3 mnt ditangani watcher booth (item baru terdeteksi)
                                task.spawn(function() task.wait(1.5); syncBoothOnly() end)
                            else
                                warn("[CMD] Listing ditolak game:", res)
                                task.spawn(syncInventoryToWeb) -- data dashboard kemungkinan basi
                            end
                        else
                            warn("[CMD] Item tidak ada di inventaris bot (UUID basi), sinkron ulang inventaris:", cmd.item_uuid)
                            task.spawn(syncInventoryToWeb) -- item hilang dari dashboard otomatis
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
