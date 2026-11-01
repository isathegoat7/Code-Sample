--Roblox: Z0MBBI3E, Discord: deadstarisa
--!strict
--@author: isa
--@date: 10/11/26
--[[@description
	server side of the bow system. checks every shot a client asks for,
	flies the arrow on the server and deals the damage when it lands
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
local Modules = ReplicatedStorage.Shared.Modules
local Network = require(Modules.Core.Network)
local Config = require(Modules.Platform.Bow)
local ArrowFlight = require(Modules.Game.Bow.ArrowFlight)
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
-- CONSTANTS --
--------------------------------
-- //Length of the arrow model, used to sink the tip into whatever it hits
local ArrowTemplate = ReplicatedStorage.Assets.Bow:FindFirstChild("Arrow") :: BasePart
local ARROW_LENGTH = (ArrowTemplate:GetAttribute("Length") :: number?) or ArrowTemplate.Size.Z

-- //How long a kill still counts for the shooter after their arrow hits
local CREATOR_TAG_LIFETIME = 2

-- //Shortest direction the client can send before the shot is thrown out
local MIN_DIRECTION_LENGTH = 0.5
--------------------------------
-- VARIABLES --
--------------------------------
local BowEvent = Network.Bow
local BowService = {}
local Actions: { [string]: (Player, ...any) -> () } = {}

-- //Draw and reload timing for every player in the server
local Shooters: { [Player]: Shooter } = {}

-- //Every arrow that is still flying
local LiveArrows: { LiveArrow } = {}
--------------------------------
-- PRIVATE FUNCTIONS --
--------------------------------
-- //Gives back the character if the player is alive and holding the bow
local function GetBowHolder(Player: Player): Model?
	local Character = Player.Character
	if not Character then
		return nil
	end

	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	if not Humanoid or Humanoid.Health <= 0 then
		return nil
	end

	local Tool = Character:FindFirstChild("Bow")
	if not Tool or not Tool:IsA("Tool") then
		return nil
	end

	return Character
end

-- //Walks up from the part that was hit until it finds a model with a humanoid
local function FindHumanoid(Part: Instance): (Humanoid?, Model?)
	local Model = Part:FindFirstAncestorOfClass("Model")

	while Model do
		local Humanoid = Model:FindFirstChildOfClass("Humanoid")
		if Humanoid then
			return Humanoid, Model
		end

		Model = Model:FindFirstAncestorOfClass("Model")
	end

	return nil, nil
end

-- //The head, or a hat welded to the head, counts as a headshot
local function IsHeadshot(Part: BasePart): boolean
	if Part.Name == "Head" then
		return true
	end

	if not Part:FindFirstAncestorOfClass("Accessory") then
		return false
	end

	local Weld = Part:FindFirstChild("AccessoryWeld")
	if not Weld or not Weld:IsA("Weld") then
		return false
	end

	return Weld.Part1 ~= nil and Weld.Part1.Name == "Head"
end

-- //Damage grows with how far the bow was drawn and is multiplied on a headshot
local function GetDamage(Charge: number, Headshot: boolean): number
	local Damage = Config.MinDamage + (Config.MaxDamage - Config.MinDamage) * Charge

	if Headshot then
		Damage *= Config.HeadshotMultiplier
	end

	return math.round(Damage)
end

-- //Marks who hit the humanoid last so the kill can be credited to them
local function TagKiller(Humanoid: Humanoid, Player: Player)
	local OldTag = Humanoid:FindFirstChild("creator")
	if OldTag then
		OldTag:Destroy()
	end

	local Tag = Instance.new("ObjectValue")
	Tag.Name = "creator"
	Tag.Value = Player
	Tag.Parent = Humanoid
	Debris:AddItem(Tag, CREATOR_TAG_LIFETIME)
end

-- //The target has to be alive, not the shooter, not protected, and allowed to be hurt
local function CanDamage(Arrow: LiveArrow, Humanoid: Humanoid, Model: Model): boolean
	if Humanoid.Health <= 0 then
		return false
	end

	if Model == Arrow.Player.Character then
		return false
	end

	if Model:FindFirstChildOfClass("ForceField") then
		return false
	end

	if Players:GetPlayerFromCharacter(Model) and not Config.DamagePlayers then
		return false
	end

	return true
end

-- //Deals the damage, then tells the shooter so they get a hitmarker
local function DamageTarget(Arrow: LiveArrow, Humanoid: Humanoid, Part: BasePart, Position: Vector3)
	local Headshot = IsHeadshot(Part)
	local Damage = GetDamage(Arrow.Charge, Headshot)

	TagKiller(Humanoid, Arrow.Player)
	Humanoid:TakeDamage(Damage)

	-- //The shooter may have left while the arrow was flying
	if not Arrow.Player.Parent then
		return
	end

	BowEvent:FireClient(Arrow.Player, "Hit", Position, Damage, Headshot, Humanoid.Health <= 0)
end

-- //Sticks the arrow where it hit for everyone, then damages whatever it hit
local function LandArrow(Arrow: LiveArrow, Hit: RaycastResult)
	local Part = Hit.Instance
	local RestingCFrame = ArrowFlight.restingCFrame(Hit.Position, Arrow.Flight.Direction, ARROW_LENGTH, Arrow.Charge)

	BowEvent:FireAllClients("Land", Arrow.Player, Arrow.ShotId, Part, Part.CFrame:ToObjectSpace(RestingCFrame))

	local Humanoid, Model = FindHumanoid(Part)
	if not Humanoid or not Model then
		return
	end

	if not CanDamage(Arrow, Humanoid, Model) then
		return
	end

	DamageTarget(Arrow, Humanoid, Part, Hit.Position)
end

-- //Takes an arrow out of the list by moving the last one into its slot
local function RemoveArrow(Index: number)
	LiveArrows[Index] = LiveArrows[#LiveArrows]
	LiveArrows[#LiveArrows] = nil
end

-- //Moves every flying arrow forward and lands the ones that hit something
local function StepArrows(DeltaTime: number)
	for Index = #LiveArrows, 1, -1 do
		local Arrow = LiveArrows[Index]
		local Hit, Expired = ArrowFlight.step(Arrow.Flight, DeltaTime)

		if not Hit and not Expired then
			continue
		end

		RemoveArrow(Index)

		if Hit then
			LandArrow(Arrow, Hit)
		end
	end
end

-- //Stops any draw in progress and refills the player's arrows
local function ResetShooter(Player: Player)
	local Shooter = Shooters[Player]
	if Shooter then
		Shooter.DrawStartedAt = nil
	end

	Player:SetAttribute("Arrows", Config.StartingArrows)
end

-- //Gives a joining player their shooter data and resets them on every respawn
local function SetupPlayer(Player: Player)
	Shooters[Player] = { DrawStartedAt = nil, LastShotAt = 0 }
	ResetShooter(Player)

	Player.CharacterAdded:Connect(function()
		ResetShooter(Player)
	end)
end

-- //Clears the player's shooter data when they leave
local function RemovePlayer(Player: Player)
	Shooters[Player] = nil
end

-- //Everything the client sent has to be the right type and not NaN
local function IsValidShot(Origin: any, Direction: any, Charge: any, ShotId: any): boolean
	if typeof(Origin) ~= "Vector3" or typeof(Direction) ~= "Vector3" then
		return false
	end

	if typeof(Charge) ~= "number" or typeof(ShotId) ~= "number" then
		return false
	end

	-- //NaN is the only value that isn't equal to itself
	if Origin ~= Origin or Direction ~= Direction or Charge ~= Charge then
		return false
	end

	return true
end

-- //The bow has to finish reloading before it can fire again
local function IsReloaded(Shooter: Shooter, Now: number): boolean
	return Now - Shooter.LastShotAt >= Config.ReloadTime * Config.Validation.ReloadLeniency
end

-- //How many arrows the player has left
local function GetArrows(Player: Player): number
	local Arrows = Player:GetAttribute("Arrows")
	if typeof(Arrows) ~= "number" then
		return 0
	end

	return Arrows
end

-- //The arrow has to start near the shooter's head and point somewhere
local function IsValidOrigin(Character: Model, Origin: Vector3, Direction: Vector3): boolean
	local Head = Character:FindFirstChild("Head")
	if not Head or not Head:IsA("BasePart") then
		return false
	end

	if (Origin - Head.Position).Magnitude > Config.Validation.MaxOriginDistance then
		return false
	end

	return Direction.Magnitude >= MIN_DIRECTION_LENGTH
end

-- //Caps the charge to how long the bow was really held, nil if it's too weak to fire
local function GetPower(DrawStartedAt: number, Now: number, Charge: number): number?
	local MaxCharge = math.min(1, (Now - DrawStartedAt + Config.Validation.ChargeLeniency) / Config.DrawTime)
	if MaxCharge < Config.MinCharge then
		return nil
	end

	return math.clamp(Charge, Config.MinCharge, MaxCharge)
end

-- //Raycast params that ignore the shooter's own character
local function GetRaycastParams(Character: Model): RaycastParams
	local Params = RaycastParams.new()
	Params.FilterType = Enum.RaycastFilterType.Exclude
	Params.FilterDescendantsInstances = { Character }
	Params.IgnoreWater = true

	return Params
end

-- //Starts the arrow flying on the server and shows it to everyone except the shooter
local function LaunchArrow(Player: Player, Character: Model, Origin: Vector3, Direction: Vector3, Power: number, ShotId: number)
	local Velocity = Direction.Unit * ArrowFlight.speedFor(Power)

	table.insert(LiveArrows, {
		Player = Player,
		ShotId = ShotId,
		Charge = Power,
		Flight = ArrowFlight.new(Origin, Velocity, GetRaycastParams(Character)),
	})

	for _, Other in Players:GetPlayers() do
		if Other == Player then
			continue
		end

		BowEvent:FireClient(Other, "Arrow", Player, Origin, Velocity, ShotId)
	end
end

-- //Sends each client request to its action and ignores anything else
local function OnBowEvent(Player: Player, Action: any, ...: any)
	if typeof(Action) ~= "string" then
		return
	end

	local Handler = Actions[Action]
	if not Handler then
		return
	end

	Handler(Player, ...)
end
--------------------------------
-- ACTIONS --
--------------------------------
-- //The player started drawing the bow
function Actions.Draw(Player: Player)
	local Shooter = Shooters[Player]
	if not Shooter or not GetBowHolder(Player) then
		return
	end

	Shooter.DrawStartedAt = os.clock()
end

-- //The player let go of the draw without firing
function Actions.Cancel(Player: Player)
	local Shooter = Shooters[Player]
	if not Shooter then
		return
	end

	Shooter.DrawStartedAt = nil
end

-- //The player released the bow, check the shot and fire the arrow
function Actions.Fire(Player: Player, Origin: any, Direction: any, Charge: any, ShotId: any)
	if not IsValidShot(Origin, Direction, Charge, ShotId) then
		return
	end

	local Shooter = Shooters[Player]
	local Character = GetBowHolder(Player)
	if not Shooter or not Character then
		return
	end

	-- //Every release ends the draw, even one that gets rejected
	local DrawStartedAt = Shooter.DrawStartedAt
	Shooter.DrawStartedAt = nil

	local Now = os.clock()
	if not DrawStartedAt or not IsReloaded(Shooter, Now) then
		return
	end

	local Arrows = GetArrows(Player)
	if Arrows <= 0 then
		return
	end

	if not IsValidOrigin(Character, Origin, Direction) then
		return
	end

	local Power = GetPower(DrawStartedAt, Now, Charge)
	if not Power then
		return
	end

	-- //The shot is good, so start the reload and use up an arrow
	Shooter.LastShotAt = Now
	Player:SetAttribute("Arrows", Arrows - 1)

	-- //Fire the arrow
	LaunchArrow(Player, Character, Origin, Direction, Power, ShotId)
end
--------------------------------
-- PUBLIC FUNCTIONS --
--------------------------------
function BowService.Start()
	-- //Listen for draw, cancel and fire requests from clients
	BowEvent.OnServerEvent:Connect(OnBowEvent)

	-- //Set up players as they join, plus anyone already in the server
	Players.PlayerAdded:Connect(SetupPlayer)
	Players.PlayerRemoving:Connect(RemovePlayer)

	for _, Player in Players:GetPlayers() do
		SetupPlayer(Player)
	end

	-- //Move every flying arrow each frame
	RunService.Heartbeat:Connect(StepArrows)
end

return BowService
