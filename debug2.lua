local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local username = LocalPlayer.Name

print("========================================")
print("[DIAGNOSTIC] Tes Gerakan Aman (Tanpa Pathfinding) Dimulai...")
print("========================================")

-- Fitur Anti-AFK dasar
LocalPlayer.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
        print("[LOG ANTI-AFK] Aktivitas dikirim untuk mencegah idle.")
    end)
end)

-- Memuat Modul Inti Game
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
    warn("[DIAGNOSTIC ERROR] Gagal memuat modul inti game!")
    return
end

local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

-- ==========================================
-- TAHAP 1: GERAKAN AMAN (MENGAKALI PATHFINDING)
-- Menggunakan Humanoid:MoveTo langsung dengan jeda alami
-- ==========================================
local function testSafeMovement()
    print("[DIAGNOSTIC] -> TAHAP 1: Menjalankan Gerakan Aman (Direct MoveTo)...")
    
    -- Tentukan titik tujuan di sekitar (misalnya maju 10 stud)
    local targetPos = rootPart.Position + (rootPart.CFrame.LookVector * 10)
    
    humanoid:MoveTo(targetPos)
    
    -- Tunggu sampai karakter mendekati tujuan atau timeout maksimal 5 detik
    local startTime = tick()
    repeat
        task.wait(0.1)
    until (rootPart.Position - targetPos).Magnitude < 3 or (tick() - startTime) > 5
    
    print("[LOG TAHAP 1] Gerakan aman selesai.")
end

-- ==========================================
-- TAHAP 2: AUTO CLAIM BOOTH (Gerakan Langsung + Prompt Natural)
-- ==========================================
local function testAutoClaim()
    print("[DIAGNOSTIC] -> TAHAP 2: Menjalankan Auto Claim Booth (Safe Mode)...")
    local targetBooth = nil
    for _, booth in ipairs(CollectionService:GetTagged("Booth")) do
        local owner = booth:GetAttribute("Owner")
        if not owner or owner == 0 or owner == "" then
            targetBooth = booth
            break
        end
    end

    if targetBooth then
        local prompt = targetBooth:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then
            local targetPart = prompt.Parent
            local targetPos = (targetPart and targetPart:IsA("BasePart")) and (targetPart.Position + (targetPart.CFrame.LookVector * 3)) or (targetBooth:GetPivot().Position + Vector3.new(0, 0, 3))
            
            -- Gerak langsung ke booth tanpa pathfinding rumit
            humanoid:MoveTo(targetPos)
            
            local startTime = tick()
            repeat
                task.wait(0.1)
            until (rootPart.Position - targetPos).Magnitude < 4 or (tick() - startTime) > 6
            
            task.wait(0.5)

            local holdDur = prompt.HoldDuration or 0.5
            print("[LOG TAHAP 2] Menahan ProximityPrompt secara natural selama:", holdDur, "detik")
            task.wait(holdDur + 0.1)

            fireproximityprompt(prompt)
            print("[LOG TAHAP 2] ProximityPrompt berhasil dipicu.")
        else
            print("[LOG TAHAP 2] ProximityPrompt tidak ditemukan.")
        end
    else
        print("[LOG TAHAP 2] Tidak ada booth kosong di sekitar.")
    end
end

-- ==========================================
-- TAHAP 3: LIST SALAH SATU FISH KE BOOTH
-- ==========================================
local listedUuid = nil
local function testListFish()
    print("[DIAGNOSTIC] -> TAHAP 3: Menjalankan List Fish ke Booth...")
    local playerData = Replion.Client:WaitReplion("Data")
    if not playerData then return end
    local inventory = playerData:Get("Inventory")
    if not inventory then return end

    local foundItemUuid = nil
    local foundItemType = nil

    for catName, items in pairs(inventory) do
        if type(items) == "table" then
            for _, itm in ipairs(items) do
                if itm and itm.Id and itm.UUID then
                    local sInfo, info = pcall(function() return ItemUtility.GetItemDataFromItemType(catName, itm.Id) end)
                    if sInfo and info and info.Data then
                        local canTrade = false
                        pcall(function()
                            canTrade = TradeData.FollowTradeRules(info, { Metadata = itm.Metadata })
                        end)
                        if canTrade then
                            foundItemUuid = itm.UUID
                            foundItemType = info.Data.Type or catName
                            break
                        end
                    end
                end
            end
        end
        if foundItemUuid then break end
    end

    if foundItemUuid and foundItemType then
        print("[LOG TAHAP 3] Item tradeable ditemukan. Mengirim Remote CreateSaleListing...")
        local success, err = pcall(function()
            return TradeData.Remotes.CreateSaleListing:InvokeServer("Booth", foundItemType, foundItemUuid, 100)
        end)
        if success then
            listedUuid = foundItemUuid
            print("[LOG TAHAP 3] Berhasil melisting item UUID:", foundItemUuid)
        else
            print("[LOG TAHAP 3] Gagal melisting item:", err)
        end
    else
        print("[LOG TAHAP 3] Tidak ada item tradeable di inventaris.")
    end
end

-- ==========================================
-- TAHAP 4: UNLIST FISH DARI BOOTH
-- ==========================================
local function testUnlistFish()
    print("[DIAGNOSTIC] -> TAHAP 4: Menjalankan Unlist Fish...")
    if not listedUuid then
        print("[LOG TAHAP 4] Tidak ada item yang sebelumnya berhasil dilisting.")
        return
    end

    local saleListingsReplion = Replion.Client:WaitReplion("SaleListings")
    if not saleListingsReplion then return end
    local userIdStr = tostring(LocalPlayer.UserId)
    local listings = saleListingsReplion:Get({"Players", userIdStr, "Booth"})
    local targetListingId = nil

    if listings and type(listings) == "table" then
        for listingId, listingData in pairs(listings) do
            if listingData and listingData.Item and listingData.Item.UUID == listedUuid then
                targetListingId = listingId
                break
            end
        end
    end

    if targetListingId then
        print("[LOG TAHAP 4] Menemukan listingId, mengirim DeleteSaleListing...")
        local success, err = pcall(function()
            return TradeData.Remotes.DeleteSaleListing:InvokeServer("Booth", targetListingId)
        end)
        if success then
            print("[LOG TAHAP 4] Berhasil unlist item!")
        else
            print("[LOG TAHAP 4] Gagal unlist item:", err)
        end
    else
        print("[LOG TAHAP 4] ListingId tidak ditemukan.")
    end
end

-- ==========================================
-- EKSEKUSI BERURUTAN DENGAN JEDA 2 MENIT (120 DETIK)
-- ==========================================
task.spawn(function()
    task.wait(5)

    -- Aksi 1: Gerakan Aman (Mengakali Pathfinding)
    testSafeMovement()
    print("[DIAGNOSTIC] Selesai Tahap 1. Menunggu jeda 2 menit...")
    task.wait(120)

    -- Aksi 2: Auto Claim Booth
    testAutoClaim()
    print("[DIAGNOSTIC] Selesai Tahap 2. Menunggu jeda 2 menit...")
    task.wait(120)

    -- Aksi 3: List Fish
    testListFish()
    print("[DIAGNOSTIC] Selesai Tahap 3. Menunggu jeda 2 menit...")
    task.wait(120)

    -- Aksi 4: Unlist Fish
    testUnlistFish()
    print("[DIAGNOSTIC] Selesai Tahap 4. Seluruh rangkaian tes selesai!")
end)
