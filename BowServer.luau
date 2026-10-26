--!strict
--Roblox: Z0MBBI3E, Discord: deadstarisa
--@author: isa
--@date: 10/11/26
--[[@description
	server side of bow system
]]
--------------------------------
-- SERVICES --
--------------------------------
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
--------------------------------
-- DEPENDENCIES
--------------------------------
local ClientModules = ReplicatedStorage.Shared.Modules
local Network = require(ClientModules.Core.Network)
local Config = require(ClientModules.Platform.Bow)
local ArrowFlight = require(ClientModules.Game.Bow.ArrowFlight)
--------------------------------
-- TYPES --
--------------------------------
type Shooter = {
	DrawStartedAt: number?,
	LastShotAt: number,
}

type LiveArrow = {
	Player: Player,
	ShotId: number,
	Charge: number,
	Flight: ArrowFlight.Flight,
}
--------------------------------
-- VARIABLES --
--------------------------------
local Module = {}
local Actions: { [string]: (Player, ...any) -> () } = {}

local arrowTemplate = ReplicatedStorage.Assets.Bow:FindFirstChild("Arrow") :: BasePart
local ARROW_LENGTH = (arrowTemplate:GetAttribute("Length") :: number?) or arrowTemplate.Size.Z

local shooters: { [Player]: Shooter } = {}
local liveArrows: { LiveArrow } = {}
--------------------------------
-- PRIVATE FUNCTIONS --
--------------------------------
local function bowHolder(player: Player): Model?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local tool = character:FindFirstChild("Bow")
	if not tool or not tool:IsA("Tool") then
		return nil
	end
	return character
end

local function findHumanoid(part: Instance): (Humanoid?, Model?)
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid, model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

local function isHeadshot(part: BasePart): boolean
	if part.Name == "Head" then
		return true
	end
	if part:FindFirstAncestorOfClass("Accessory") then
		local weld = part:FindFirstChild("AccessoryWeld")
		return weld ~= nil and weld:IsA("Weld") and weld.Part1 ~= nil and weld.Part1.Name == "Head"
	end
	return false
end

local function damageFor(charge: number, headshot: boolean): number
	local damage = Config.MinDamage + (Config.MaxDamage - Config.MinDamage) * charge
	if headshot then
		damage *= Config.HeadshotMultiplier
	end
	return math.round(damage)
end

local function tagKiller(humanoid: Humanoid, player: Player)
	local old = humanoid:FindFirstChild("creator")
	if old then
		old:Destroy()
	end
	local tag = Instance.new("ObjectValue")
	tag.Name = "creator"
	tag.Value = player
	tag.Parent = humanoid
	Debris:AddItem(tag, 2)
end

local function landArrow(arrow: LiveArrow, hit: RaycastResult)
	local part = hit.Instance
	local resting = ArrowFlight.restingCFrame(hit.Position, arrow.Flight.Direction, ARROW_LENGTH, arrow.Charge)
	Network.Bow:FireAllClients("Land", arrow.Player, arrow.ShotId, part, part.CFrame:ToObjectSpace(resting))

	local humanoid, model = findHumanoid(part)
	if not humanoid or not model or humanoid.Health <= 0 then
		return
	end
	if model == arrow.Player.Character or model:FindFirstChildOfClass("ForceField") then
		return
	end
	if Players:GetPlayerFromCharacter(model) and not Config.DamagePlayers then
		return
	end

	local headshot = isHeadshot(part)
	local damage = damageFor(arrow.Charge, headshot)
	tagKiller(humanoid, arrow.Player)
	humanoid:TakeDamage(damage)

	if arrow.Player.Parent then
		Network.Bow:FireClient(arrow.Player, "Hit", hit.Position, damage, headshot, humanoid.Health <= 0)
	end
end

local function stepArrows(dt: number)
	for index = #liveArrows, 1, -1 do
		local arrow = liveArrows[index]
		local hit, expired = ArrowFlight.step(arrow.Flight, dt)
		if hit or expired then
			liveArrows[index] = liveArrows[#liveArrows]
			liveArrows[#liveArrows] = nil
		end
		if hit then
			landArrow(arrow, hit)
		end
	end
end

local function setupPlayer(player: Player)
	shooters[player] = { DrawStartedAt = nil, LastShotAt = 0 }
	player:SetAttribute("Arrows", Config.StartingArrows)
	player.CharacterAdded:Connect(function()
		local shooter = shooters[player]
		if shooter then
			shooter.DrawStartedAt = nil
		end
		player:SetAttribute("Arrows", Config.StartingArrows)
	end)
end

function Actions.Draw(player: Player)
	local shooter = shooters[player]
	if shooter and bowHolder(player) then
		shooter.DrawStartedAt = os.clock()
	end
end

function Actions.Cancel(player: Player)
	local shooter = shooters[player]
	if shooter then
		shooter.DrawStartedAt = nil
	end
end

function Actions.Fire(player: Player, origin: any, direction: any, charge: any, shotId: any)
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
		return
	end
	if typeof(charge) ~= "number" or typeof(shotId) ~= "number" then
		return
	end
	if origin ~= origin or direction ~= direction or charge ~= charge then
		return
	end

	local shooter = shooters[player]
	local character = bowHolder(player)
	if not shooter or not character then
		return
	end

	local drawStartedAt = shooter.DrawStartedAt
	shooter.DrawStartedAt = nil
	local now = os.clock()
	if not drawStartedAt or now - shooter.LastShotAt < Config.ReloadTime * Config.Validation.ReloadLeniency then
		return
	end

	local arrows = player:GetAttribute("Arrows")
	if typeof(arrows) ~= "number" or arrows <= 0 then
		return
	end

	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	if (origin - head.Position).Magnitude > Config.Validation.MaxOriginDistance or direction.Magnitude < 0.5 then
		return
	end

	local maxCharge = math.min(1, (now - drawStartedAt + Config.Validation.ChargeLeniency) / Config.DrawTime)
	if maxCharge < Config.MinCharge then
		return
	end
	local power = math.clamp(charge, Config.MinCharge, maxCharge)

	shooter.LastShotAt = now
	player:SetAttribute("Arrows", arrows - 1)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true

	local velocity = direction.Unit * ArrowFlight.speedFor(power)
	table.insert(liveArrows, {
		Player = player,
		ShotId = shotId,
		Charge = power,
		Flight = ArrowFlight.new(origin, velocity, params),
	})

	for _, other in Players:GetPlayers() do
		if other ~= player then
			Network.Bow:FireClient(other, "Arrow", player, origin, velocity, shotId)
		end
	end
end
--------------------------------
-- PUBLIC FUNCTIONS --
--------------------------------
function Module.Start()
	Network.Bow.OnServerEvent:Connect(function(player: Player, action: any, ...: any)
		if typeof(action) ~= "string" then
			return
		end
		local handler = Actions[action]
		if handler then
			handler(player, ...)
		end
	end)

	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(function(player)
		shooters[player] = nil
	end)
	for _, player : Player in ipairs(Players:GetChildren()) do
		if not shooters[player] then
			setupPlayer(player)
		end
	end

	RunService.Heartbeat:Connect(stepArrows)
end

function Module.Init()

end

return Module
