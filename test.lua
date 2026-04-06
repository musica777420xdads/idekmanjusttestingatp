repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Stats = game:GetService("Stats")
local UIS = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local SoundService = game:GetService("SoundService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local ServerBrowserRemote = ReplicatedStorage:WaitForChild("__ServerBrowser")

local lp = Players.LocalPlayer or Players:GetPropertyChangedSignal("LocalPlayer"):Wait() and Players.LocalPlayer

getgenv().ShuttingDown = false
getgenv().IsServerHopping = false

local CurrentJobId = game.JobId
local CurrentPlaceId = game.PlaceId

local function joinpirates()
    game:GetService("ReplicatedStorage"):WaitForChild("Remotes"):WaitForChild("CommF_"):InvokeServer("SetTeam", Config.SELECTED_TEAM)
    task.wait(0.1)
end

while not lp.Character or not lp.Character:FindFirstChild("HumanoidRootPart") do
    joinpirates()
    task.wait(0.1)
end

local MIN_PLAYER_LEVEL = 2300
local PREDICTION_TIME = 0.25
local YOffset = 6
local FruitAttackRange = 100
local ATTACK_DURATION = 30
local LOW_HEALTH_THRESHOLD = 5000
local SAFE_HEALTH_THRESHOLD = 9000
local ESCAPE_HEIGHT = 273861
local InstaTpConnection = nil
local SelectedPlayer = nil
local CurrentTargetPlayer = nil
local FruitAttackEnabled = false
local FruitAttackConnection = nil
local PREDICTION_SAMPLES = 3
local PREDICTION_SAMPLE_INTERVAL = 0.05
local PREDICTION_TIME = 0.25
local PlayerPositionHistory = {}

local SessionStartTime = tick()
local InitialBounty = 0
local TotalKills = 0
local EliminatedPlayers = {}
local TargetedPlayers = {}

local V_KEY_DELAY = 1 -- dragon shi

local StartInstaTeleport
local StartFruitAttack
local StopFruitAttack

local function PerformHealthEscape()
    if InstaTpConnection then
        InstaTpConnection:Disconnect()
        InstaTpConnection = nil
    end

    local wasAttacking = FruitAttackEnabled
    local previousTarget = CurrentTargetPlayer
    StopFruitAttack()

    local escapeActive = true

    local escapeThread = task.spawn(function()
        while escapeActive do
            pcall(function()
                local char = lp.Character
                if char then
                    local hrp = char:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        local pos = hrp.Position
                        hrp.CFrame = CFrame.new(pos.X, pos.Y + ESCAPE_HEIGHT, pos.Z)
                    end
                end
            end)
            task.wait(0.05)
        end
    end)
    
    while true do
        task.wait(0.5)
        
        local char = lp.Character
        if char then
            local humanoid = char:FindFirstChild("Humanoid")
            if humanoid and humanoid.Health >= SAFE_HEALTH_THRESHOLD then
                break
            else
                if humanoid then
                end
            end
        end
    end

    escapeActive = false
    task.wait(0.2)
    
    StartInstaTeleport()

    if wasAttacking and previousTarget and previousTarget.Parent then
        CurrentTargetPlayer = previousTarget
        SelectedPlayer = previousTarget.Name
        FruitAttackEnabled = true
        StartFruitAttack(previousTarget)
    end
end

local function IsHealthLow()
    local char = lp.Character
    if not char then return false end
    
    local humanoid = char:FindFirstChild("Humanoid")
    if not humanoid then return false end
    
    return humanoid.Health <= LOW_HEALTH_THRESHOLD
end

local function GetPlayerLevel(player)
    local data = player:FindFirstChild("Data")
    if data then
        local level = data:FindFirstChild("Level")
        if level and level.Value then
            return tonumber(level.Value)
        end
    end
    return 0
end

local function IsPlayerInSafeZone(player)
    if not player.Character then return false end
    
    local hrp = player.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    
    local inCombat = player.Character:GetAttribute("InCombat")
    if inCombat == "0" or inCombat == "1" then
        return false
    end
    
    local SafeZonesFolder = workspace._WorldOrigin:FindFirstChild("SafeZones")
    if not SafeZonesFolder then
        return false
    end
    
    local function getSafeZoneRadius(zone)
        local mesh = zone:FindFirstChild("Mesh")
        if mesh and mesh:IsA("SpecialMesh") then
            local realDiameter = zone.Size.X * mesh.Scale.X
            return realDiameter / 2
        end
        return nil
    end
    
    for _, zone in pairs(SafeZonesFolder:GetChildren()) do
        local radius = getSafeZoneRadius(zone)
        if radius then
            local dist = (zone.Position - hrp.Position).Magnitude
            if dist <= radius then
                return true
            end
        end
    end
    
    return false
end

local function PvpEnable()
    pcall(function()
        local args = {"EnablePvp"}
        game:GetService("ReplicatedStorage"):WaitForChild("Remotes"):WaitForChild("CommF_"):InvokeServer(unpack(args))
    end)
end

local function IsPlayerValid(player)
    if player == lp then return false end
    
    if lp.Team and lp.Team.Name == "Marines" and player.Team and player.Team == lp.Team then 
        return false 
    end
    
    local pvpDisabled = player:GetAttribute("PvpDisabled")
    if pvpDisabled == true then return false end

    local raiding = player:GetAttribute("IslandRaiding")
    if raiding == true then return false end

    local level = GetPlayerLevel(player)
    if level < MIN_PLAYER_LEVEL then return false end
    
    if IsPlayerInSafeZone(player) then return false end
    
    if player.Character.Humanoid.Health == 0 then return false end

    return true
end

function GetCurrentBounty()
    local leaderstats = lp:FindFirstChild("leaderstats")
    if leaderstats then
        local bounty = leaderstats:FindFirstChild("Bounty/Honor")
        if bounty then
            return tonumber(bounty.Value) or 0
        end
    end
    return 0
end

local function IsInCombat()
    local playerGui = lp:FindFirstChild("PlayerGui")
    if not playerGui then return false end

    local mainGui = playerGui:FindFirstChild("Main")
    if not mainGui then return false end

    local bottomHUD = mainGui:FindFirstChild("BottomHUDList")
    if not bottomHUD then return false end

    local inCombatUI = bottomHUD:FindFirstChild("InCombat")
    if not inCombatUI then return false end

    if not inCombatUI.Visible then return false end
    
    if inCombatUI:IsA("TextLabel") and inCombatUI.Text and string.find(inCombatUI.Text, "risk") or string.find(inCombatUI.Text, "Risk") then
        return true
    end
    
    return false
end

local function FakeIsInCombat()
    local playerGui = lp:FindFirstChild("PlayerGui")
    if not playerGui then return false end

    local mainGui = playerGui:FindFirstChild("Main")
    if not mainGui then return false end

    local bottomHUD = mainGui:FindFirstChild("BottomHUDList")
    if not bottomHUD then return false end

    local inCombatUI = bottomHUD:FindFirstChild("InCombat")
    if not inCombatUI then return false end

    return inCombatUI.Visible == true
end

local function WaitForCombatEnd(timeout)
    timeout = timeout or 30
    local startTime = tick()
    
    while IsInCombat() and (tick() - startTime) < timeout do
        task.wait(1)
    end
    
    if IsInCombat() then
        return false
    end
    
    return true
end

local function BusoKen()
    pcall(function()
        local args = {"Ken", true}
        ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CommE"):FireServer(unpack(args))
        
        local char = lp.Character
        if char then
            local hasBuso = char:FindFirstChild("HasBuso")
            if not hasBuso then
                local args2 = {"Buso"}
                ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CommF_"):InvokeServer(unpack(args2))
            end
        end
    end)
end

task.spawn(function()
    while not getgenv().ShuttingDown do
        pcall(function()
            BusoKen()
        end)
        task.wait(5)
    end
end)

local function ServerHop()

    getgenv().IsServerHopping = true
    getgenv().ShuttingDown = true

    if InstaTpConnection then
        InstaTpConnection:Disconnect()
        InstaTpConnection = nil
    end

    if FakeIsInCombat() then
        
        local flag = Instance.new("BoolValue")
        flag.Name = "CombatEscape"
        flag.Parent = workspace
        
        task.spawn(function()
            while flag.Parent do
                local char = lp.Character
                if char then
                    local hrp = char:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        local pos = hrp.Position
                        hrp.CFrame = CFrame.new(pos.X, pos.Y + 273861, pos.Z)
                    end
                end
                task.wait(0.05)
            end
        end)
        
        WaitForCombatEnd(30)
        
        flag:Destroy()
    end

    task.wait(1)

    local PlayerGui = lp.PlayerGui

    if not PlayerGui:FindFirstChild("ServerBrowser") then
        getgenv().IsServerHopping = false
        return
    end

    PlayerGui.ServerBrowser.Enabled = true
    task.wait(0.1)

    local Filters = PlayerGui.ServerBrowser.Frame:FindFirstChild("Filters")
    local SearchRegion = Filters and Filters:FindFirstChild("SearchRegion")
    local TextBox = SearchRegion and SearchRegion:FindFirstChild("TextBox")

    if not TextBox then
        getgenv().IsServerHopping = false
        return
    end

    TextBox.Text = Config.Selected_Region
    task.wait(3)

    local ScrollingFrame = PlayerGui.ServerBrowser.Frame.ScrollingFrame
    local FakeScroll = PlayerGui.ServerBrowser.Frame.FakeScroll
    local Inside = FakeScroll.Inside
    
    ScrollingFrame.CanvasPosition = Vector2.new(0, math.random(100, 7000))
    task.wait(0.1)

    local currentJobId = game.JobId

    while true do
        task.wait(0.5)

        for _, template in ipairs(Inside:GetChildren()) do
            if template.Name == "Template" then
                local joinButton = template:FindFirstChild("Join")
                if joinButton then
                    local job = joinButton:GetAttribute("Job")
                    if job and tostring(job):find("-", 1, true) then
                        job = tostring(job)
                        
                        if job == currentJobId then
                        else
                            local success, err = pcall(function()
                                ServerBrowserRemote:InvokeServer("teleport", job)
                            end)
                            if not success then
                                local success2, err2 = pcall(function()
                                    ServerBrowserRemote:InvokeServer("teleport", job)
                                end)
                                if not success2 then
                                end
                            end
                            task.wait(1)
                        end
                    end
                end
            end
        end
    end
end

local FruitConfigs = {
    ["Dragon"] = {
        ToolName = "Dragon-Dragon",
        RemoteName = "LeftClickRemote",
        Args = function(direction)
            return {
                Vector3.new(direction.X, direction.Y, direction.Z),
                1
            }
        end
    },
    ["T-Rex"] = {
        ToolName = "T-Rex-T-Rex",
        RemoteName = "LeftClickRemote",
        Args = function(direction)
            return {
                Vector3.new(direction.X, direction.Y, direction.Z),
                3
            }
        end
    },
    ["Empyrean"] = {
        ToolName = "Empyrean (Kitsune)-Empyrean (Kitsune)",
        RemoteName = "LeftClickRemote",
        Args = function(direction)
            return {
                Vector3.new(direction.X, direction.Y, direction.Z),
                1
            }
        end
    },
    ["Kitsune"] = {
        ToolName = "Kitsune-Kitsune",
        RemoteName = "LeftClickRemote",
        Args = function(direction)
            return {
                Vector3.new(direction.X, direction.Y, direction.Z),
                1
            }
        end
    },
    ["Pain"] = {
        ToolName = "Pain-Pain",
        RemoteName = "LeftClickRemote",
        Args = function(direction)
            return {
                Vector3.new(direction.X, direction.Y, direction.Z),
                1
            }
        end
    },
    ["Gas"] = {
        ToolName = "Gas-Gas",
        RemoteName = "LeftClickRemote",
        Args = function(direction)
            return {
                Vector3.new(direction.X, direction.Y, direction.Z),
                1
            }
        end
    },
    ["Control"] = {
        ToolName = "Control-Control",
        RemoteName = "LeftClickRemote",
        Args = function(direction)
            return {
                Vector3.new(direction.X, direction.Y, direction.Z),
                1
            }
        end
    }
}

local function GetPlayerFruit()
    local backpack = lp.Backpack
    for _, item in ipairs(backpack:GetChildren()) do
        if item:GetAttribute("WeaponType") == "Demon Fruit" then return item end
    end
    for _, item in ipairs(lp.Character:GetChildren()) do
        if item:GetAttribute("WeaponType") == "Demon Fruit" then return item end
    end
    return nil
end

local function EquipFruit()
    local config = FruitConfigs[Config.SELECTED_FRUIT]
    if not config then 
        return false
    end
    
    local character = lp.Character
    local backpack = lp.Backpack
    
    if not character then return false end
    
    local equippedTool = character:FindFirstChild(config.ToolName)
    if equippedTool then 
        return true 
    end
    
    local tool = backpack:FindFirstChild(config.ToolName)
    if tool then
        character.Humanoid:EquipTool(tool)
        task.wait(0.1)
        return true
    end
    
    return false
end

local function FruitAttackPlayer(targetPlayer)
    if not targetPlayer or not targetPlayer.Character then return end
    
    local config = FruitConfigs[Config.SELECTED_FRUIT]
    if not config then return end
    
    local myChar = lp.Character
    if not myChar then return end
    
    local myHRP = myChar:FindFirstChild("HumanoidRootPart")
    local targetHRP = targetPlayer.Character:FindFirstChild("HumanoidRootPart")
    
    if not myHRP or not targetHRP then return end
    
    local distance = (targetHRP.Position - myHRP.Position).Magnitude
    if distance > FruitAttackRange then return end
    
    local direction = (targetHRP.Position - myHRP.Position).Unit
    
    local tool = myChar:FindFirstChild(config.ToolName)
    if not tool then
        EquipFruit()
        task.wait(0.1)
        tool = myChar:FindFirstChild(config.ToolName)
        if not tool then return end
    end
    
    local remote = tool:FindFirstChild(config.RemoteName)
    if not remote then 
        return 
    end
    
    pcall(function()
        local args = config.Args(direction)
        remote:FireServer(unpack(args))
    end)
end

function StartFruitAttack(targetPlayer)
    if FruitAttackConnection then
        task.cancel(FruitAttackConnection)
    end
    
    FruitAttackConnection = task.spawn(function()
        while FruitAttackEnabled and targetPlayer do
            task.wait(0.01)
            
            local myChar = lp.Character
            local myHRP = myChar and myChar:FindFirstChild("HumanoidRootPart")
            
            if not myHRP then continue end
            
            if not targetPlayer.Parent or not targetPlayer.Character then
                break
            end
            
            local targetHRP = targetPlayer.Character:FindFirstChild("HumanoidRootPart")
            local targetHumanoid = targetPlayer.Character:FindFirstChild("Humanoid")
            
            if targetHRP and targetHumanoid and targetHumanoid.Health > 0 then
                FruitAttackPlayer(targetPlayer)
            end
        end
    end)
end

function StopFruitAttack()
    FruitAttackEnabled = false
    if FruitAttackConnection then
        task.cancel(FruitAttackConnection)
        FruitAttackConnection = nil
    end
end

local function GetAllValidPlayers()
    local validPlayers = {}
    
    for _, player in pairs(Players:GetPlayers()) do
        if IsPlayerValid(player) then
            table.insert(validPlayers, player)
        end
    end
    
    return validPlayers
end

function StartInstaTeleport()
    if InstaTpConnection then
        InstaTpConnection:Disconnect()
    end
    
    InstaTpConnection = RunService.Stepped:Connect(function()
        if not SelectedPlayer then return end
        
        pcall(function()
            local char = lp.Character
            local target = Players:FindFirstChild(SelectedPlayer)
            
            if char and target and target.Character then
                local hrp = char:FindFirstChild("HumanoidRootPart")
                local targetHRP = target.Character:FindFirstChild("HumanoidRootPart")
                
                if hrp and targetHRP then
                    if not PlayerPositionHistory[SelectedPlayer] then
                        PlayerPositionHistory[SelectedPlayer] = {
                            positions = {},
                            timestamps = {},
                            lastUpdate = tick()
                        }
                    end
                    
                    local history = PlayerPositionHistory[SelectedPlayer]
                    local currentTime = tick()
                    local currentPos = targetHRP.Position
                    
                    table.insert(history.positions, currentPos)
                    table.insert(history.timestamps, currentTime)
                    
                    while #history.positions > PREDICTION_SAMPLES do
                        table.remove(history.positions, 1)
                        table.remove(history.timestamps, 1)
                    end
                    
                    local predictedPos = currentPos
                    
                    if #history.positions >= 2 then
                        local totalDisplacement = Vector3.new(0, 0, 0)
                        local totalTime = 0
                        
                        for i = 2, #history.positions do
                            local displacement = history.positions[i] - history.positions[i-1]
                            local deltaTime = history.timestamps[i] - history.timestamps[i-1]
                            
                            if deltaTime > 0 then
                                totalDisplacement = totalDisplacement + displacement
                                totalTime = totalTime + deltaTime
                            end
                        end
                        
                        if totalTime > 0 then
                            local calculatedVelocity = totalDisplacement / totalTime
                            
                            predictedPos = currentPos + (calculatedVelocity * PREDICTION_TIME)
                        end
                    end
                    
                    hrp.CFrame = CFrame.new(predictedPos) * CFrame.new(0, YOffset, 0)
                end
            else
                if PlayerPositionHistory[SelectedPlayer] then
                    PlayerPositionHistory[SelectedPlayer] = nil
                end
            end
        end)
    end)
end

local function OnCharacterDeath()
    getgenv().ShuttingDown = true
    
    if InstaTpConnection then
        InstaTpConnection:Disconnect()
        InstaTpConnection = nil
    end
    
    StopFruitAttack()
    SelectedPlayer = nil
    CurrentTargetPlayer = nil
    FruitAttackEnabled = false
    PlayerPositionHistory = {}
    local newChar = lp.Character or lp.CharacterAdded:Wait()
    local newHRP = newChar:WaitForChild("HumanoidRootPart", 10)
    local newHumanoid = newChar:WaitForChild("Humanoid", 10)
    
    if newHRP and newHumanoid then
        task.wait(1)
        getgenv().ShuttingDown = false
        StartAntiSeat()
        StartInstaTeleport()
        newHumanoid.Died:Connect(function()
            OnCharacterDeath()
        end)
    else
    end
end

lp.CharacterAdded:Connect(function(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    if humanoid then
        humanoid.Died:Connect(function()
            OnCharacterDeath()
        end)
    else
    end
end)

if lp.Character then
    local humanoid = lp.Character:FindFirstChild("Humanoid")
    if humanoid then
        humanoid.Died:Connect(function()
            OnCharacterDeath()
        end)
    end
end

StartInstaTeleport()

if InitialBounty == 0 then
    InitialBounty = GetCurrentBounty()
end

task.spawn(function()
    while task.wait(1) do
        if FruitAttackEnabled then
            EquipFruit()
        end
    end
end)

task.spawn(function()
    while true do
        task.wait(0.01)
        GetPlayerFruit():WaitForChild("LeftClickRemote"):FireServer(vector.create(0.12, -0.5, -0.1), 1, true)
    end
end)

task.spawn(function()
    task.wait(3)
    
    local currentIndex = 1
    
    while true do
        -- Health escape check
        if IsHealthLow() then
            PerformHealthEscape()
            task.wait(1)
        end
        
        -- Get all valid players
        local validPlayers = GetAllValidPlayers()
        
        if #validPlayers > 0 then
            -- Reset index if it exceeds list length or is 0
            if currentIndex > #validPlayers or currentIndex < 1 then
                currentIndex = 1
            end
            
            local targetPlayer = validPlayers[currentIndex]
            
            if targetPlayer and targetPlayer.Parent and targetPlayer.Character then
                -- Check if player died
                local humanoid = targetPlayer.Character:FindFirstChild("Humanoid")
                if humanoid and humanoid.Health <= 0 then
                    if not table.find(EliminatedPlayers, targetPlayer.Name) then
                        table.insert(EliminatedPlayers, targetPlayer.Name)
                        TotalKills = TotalKills + 1
                    end
                end
                
                -- Update target for InstaTp
                SelectedPlayer = targetPlayer.Name
                CurrentTargetPlayer = targetPlayer
            end
            
            -- Move to next player BEFORE waiting
            currentIndex = currentIndex + 1
            
        else
            -- No valid players, server hop
            currentIndex = 1
            ServerHop()
        end
        
        -- Wait 0.1 seconds before cycling to next player
        task.wait(0.15)
    end
end)

local function v4()
    local args = {
        true
    }
    game:GetService("Players").LocalPlayer:WaitForChild("Backpack"):WaitForChild("Awakening"):WaitForChild("RemoteFunction"):InvokeServer(unpack(args))
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.T, false, game)
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.T, false, game)
end

while wait(1) do
    PvpEnable()
    v4()
end

task.spawn(function()
    task.wait(40)
    ServerHop()
end)