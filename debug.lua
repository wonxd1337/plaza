print("==================================================")
print("[DIAGNOSTIC] Skrip Debugging Bot Dimulai...")
print("==================================================")

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local username = LocalPlayer.Name
local WEB_URL = "http://ez.mn/tmpl/feeds/feed/plaza/index.php"

-- ==========================================
-- TAHAP 1: FITUR ANTI-AFK
-- ==========================================
print("[DIAGNOSTIC - TAHAP 1] Mengaktifkan Anti-AFK...")
LocalPlayer.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
        print("[LOG TAHAP 1] Event Idled terpanggil, Anti-AFK merespons.")
    end)
end)

print("[DIAGNOSTIC] -> Menunggu 2 menit di TAHAP 1 (Anti-AFK saja)...")
print("[DIAGNOSTIC] -> Perhatikan apakah kena kick selama 2 menit ini.")
task.wait(120)
print("[DIAGNOSTIC] -> TAHAP 1 SELESAI. Aman? Lanjut ke tahap berikutnya...")

-- ==========================================
-- TAHAP 2: MEMUAT MODUL INTI GAME
-- ==========================================
print("[DIAGNOSTIC - TAHAP 2] Memuat Modul Inti (Replion, ItemUtility, TradeData)...")

local successReplion, Replion = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Replion")) 
end)
local successItemUtil, ItemUtility = pcall(function() 
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemUtility")) 
end)
local successTrade, TradeData = pcall(function()
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Trading"):WaitForChild("TradeData"))
end)

if successReplion and successItemUtil and successTrade then
    print("[LOG TAHAP 2] Semua modul inti berhasil dimuat tanpa error.")
else
    warn("[LOG TAHAP 2 WARNING] Ada modul yang gagal dimuat!")
end

print("[DIAGNOSTIC] -> Menunggu 2 menit di TAHAP 2 (Modul Inti dimuat)...")
task.wait(120)
print("[DIAGNOSTIC] -> TAHAP 2 SELESAI. Lanjut ke tahap berikutnya...")

-- ==========================================
-- TAHAP 3: SINKRONISASI WEB AWAL
-- ==========================================
print("[DIAGNOSTIC - TAHAP 3] Melakukan tes Sinkronisasi Data ke Web Dashboard...")
pcall(function()
    local response = request({
        Url = WEB_URL .. "?action=sync_inventory",
        Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = HttpService:JSONEncode({ 
            username = username, 
            items = {},
            booth_items = {}
        })
    })
    if response then
        print("[LOG TAHAP 3] Berhasil menghubungi server web. Status Code:", response.StatusCode)
    end
end)

print("[DIAGNOSTIC] -> Menunggu 2 menit di TAHAP 3 (Setelah Web Sync)...")
task.wait(120)
print("[DIAGNOSTIC] -> TAHAP 3 SELESAI. Lanjut ke tahap berikutnya...")

-- ==========================================
-- TAHAP 4: POLLING COMMANDS LOOP
-- ==========================================
print("[DIAGNOSTIC - TAHAP 4] Menjalankan Loop Polling Commands (Cek Perintah Web)...")
task.spawn(function()
    while true do
        print("[LOG TAHAP 4] Mengirim request polling command ke web...")
        pcall(function()
            local response = request({
                Url = WEB_URL .. "?action=poll_commands&username=" .. HttpService:UrlEnum and HttpService:UrlEncode(username) or HttpService:UrlEncode(username),
                Method = "GET"
            })
            if response and response.StatusCode == 200 then
                print("[LOG TAHAP 4] Polling sukses diterima server web.")
            end
        end)
        task.wait(10) -- Cek setiap 10 detik
    end
end)

print("[DIAGNOSTIC] -> Menunggu 2 menit di TAHAP 4 (Polling Berjalan)...")
task.wait(120)
print("==================================================")
print("[DIAGNOSTIC] SEMUA TAHAP DASAR (1-4) TELAH DLEWATI!")
print("[DIAGNOSTIC] Jika sampai sini TIDAK KENA KICK, berarti biang kerok mutlak ada di bagian:")
print("[DIAGNOSTIC] 1. Auto Claim Booth (Pathfinding / ProximityPrompt)")
print("[DIAGNOSTIC] 2. Pemanggilan RemoteFunction TradeData (CreateSaleListing / DeleteSaleListing)")
print("==================================================")
