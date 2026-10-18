-- Discord: emtrazaltaccount | Roblox: emtraz
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local projectileFolder = workspace:WaitForChild("Projectiles")
local turretFolder = workspace:WaitForChild("Turrets")

local TAG = "Turret"

local SCAN_INTERVAL = 0.2 -- 5 scans a second is plenty and much cheaper

local AIM_TOLERANCE = math.cos(math.rad(4)) -- Stored as a cosine so the check is one dot product

local SWEEP_SPEED = 0.6
local SWEEP_ANGLE = math.rad(50)

local RECOIL_DISTANCE = 0.6
local RECOIL_RECOVERY = 12

local PREDICTION_PASSES = 3

local IDLE_COLOR = Color3.fromRGB(60, 230, 120)
local ALERT_COLOR = Color3.fromRGB(255, 45, 45)

local FLASH_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FIRE_SOUND_ID = "rbxassetid://138522511977686"
local IMPACT_SOUND_ID = "rbxassetid://9113634061"

local FLAT = Vector3.new(1, 0, 1) -- Ignore jumping when predicting

local DEFAULT_CONFIG = {
	Range = 70,
	FireRate = 1.5,
	Damage = 20,
	BulletSpeed = 140,
	TurnSpeed = 6,
}

local GRAVITY = Vector3.new(0, -workspace.Gravity * 0.15, 0) -- Reduced so bullet drop stays readable
local BULLET_LIFETIME = 3
local MAX_POOL = 64
local IMPACT_LIFETIME = 1.5
local DEFAULT_BULLET_COLOR = Color3.fromRGB(255, 170, 60)

local KINDS = {
	Default = {
		bulletColor = DEFAULT_BULLET_COLOR,
		soundPitch = 1,
	},
	Sniper = {
		bulletColor = Color3.fromRGB(60, 230, 255),
		soundPitch = 0.7,
		chargeLaser = true,
	},
	Minigun = {
		bulletColor = Color3.fromRGB(255, 70, 50),
		soundPitch = 1.35,
		spinPartNames = { Barrel = true, Spindle = true, BarrelClamp = true }, -- Parts that spin together
	},
}

local SPIN_MAX = 30
local SPIN_RESPONSE = 3
local SPIN_FIRE_THRESHOLD = 0.6 -- Minigun has to spin up before it fires

local LASER_MIN_WIDTH = 0.05
local LASER_MAX_WIDTH = 0.35
local LASER_DEFAULT_WIDTH = 0.08

local bulletParams = RaycastParams.new()
bulletParams.FilterType = Enum.RaycastFilterType.Exclude
bulletParams.FilterDescendantsInstances = { projectileFolder, turretFolder }
bulletParams.IgnoreWater = true

local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.FilterDescendantsInstances = { projectileFolder, turretFolder }
sightParams.IgnoreWater = true

local pool = {} -- Reused bullet parts, the Minigun fires a lot
local activeBullets = {}

local function createBulletPart()
	local part = Instance.new("Part")
	part.Name = "Bullet"
	part.Size = Vector3.new(0.25, 0.25, 1.8)
	part.Material = Enum.Material.Neon
	part.Anchored = true -- Moved by raycasts, not physics
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false

	local back = Instance.new("Attachment")
	back.Name = "Back"
	back.Position = Vector3.new(0, 0, 0.9)
	back.Parent = part
	local front = Instance.new("Attachment")
	front.Name = "Front"
	front.Position = Vector3.new(0, 0, -0.9)
	front.Parent = part

	local trail = Instance.new("Trail")
	trail.Attachment0 = back
	trail.Attachment1 = front
	trail.LightEmission = 1
	trail.Lifetime = 0.12
	trail.Transparency = NumberSequence.new(0.4, 1)
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.FaceCamera = true
	trail.Enabled = false
	trail.Parent = part
	return part
end

local function acquireBullet()
	return table.remove(pool) or createBulletPart() -- Reuse a spare part if there is one
end

local function releaseBullet(part)
	part.Trail.Enabled = false
	part.Parent = nil
	if #pool < MAX_POOL then
		table.insert(pool, part)
	else
		part:Destroy()
	end
end

local function spawnImpact(position, normal, material, color)
	local anchor = Instance.new("Attachment")
	anchor.CFrame = CFrame.lookAt(position + normal * 0.05, position + normal * 2)
	anchor.Parent = workspace.Terrain

	local burst = Instance.new("ParticleEmitter")
	burst.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	burst.Color = ColorSequence.new(color)
	burst.LightEmission = 1
	burst.Size = NumberSequence.new(0.25, 0)
	burst.Lifetime = NumberRange.new(0.15, 0.35)
	burst.Speed = NumberRange.new(8, 18)
	burst.SpreadAngle = Vector2.new(60, 60)
	burst.Acceleration = Vector3.new(0, -workspace.Gravity * 0.5, 0)
	burst.EmissionDirection = Enum.NormalId.Front
	burst.Rate = 0 -- One burst instead of a stream
	burst.Parent = anchor

	local dust = Instance.new("ParticleEmitter")
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	dust.Color = ColorSequence.new(material == Enum.Material.Neon and color or Color3.fromRGB(150, 145, 140))
	dust.Transparency = NumberSequence.new(0.5, 1)
	dust.Size = NumberSequence.new(0.4, 1.6)
	dust.Lifetime = NumberRange.new(0.3, 0.5)
	dust.Speed = NumberRange.new(2, 4)
	dust.SpreadAngle = Vector2.new(30, 30)
	dust.EmissionDirection = Enum.NormalId.Front
	dust.Rate = 0
	dust.Parent = anchor

	local sound = Instance.new("Sound")
	sound.SoundId = IMPACT_SOUND_ID
	sound.Volume = 0.35
	sound.PlaybackSpeed = 0.9 + math.random() * 0.3
	sound.RollOffMaxDistance = 80
	sound.Parent = anchor

	burst:Emit(10)
	dust:Emit(3)
	sound:Play()
	Debris:AddItem(anchor, IMPACT_LIFETIME) -- One cleanup for every effect
end

local function fireBullet(origin, velocity, damage, color)
	local part = acquireBullet()
	part.Color = color
	part.Trail.Color = ColorSequence.new(color)
	part.CFrame = CFrame.lookAt(origin, origin + velocity)
	part.Parent = projectileFolder
	part.Trail:Clear()
	part.Trail.Enabled = true

	table.insert(activeBullets, {
		position = origin,
		velocity = velocity,
		damage = damage,
		color = color,
		age = 0,
		part = part,
	})
end

local function onBulletHit(bullet, result)
	local character = result.Instance:FindFirstAncestorOfClass("Model")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid:TakeDamage(bullet.damage) -- Respects ForceFields
	end
	spawnImpact(result.Position, result.Normal, result.Material, bullet.color)
	releaseBullet(bullet.part)
end

local function stepBullet(bullet, dt)
	local nextVelocity = bullet.velocity + GRAVITY * dt
	local displacement = (bullet.velocity + nextVelocity) * 0.5 * dt

	local result = workspace:Raycast(bullet.position, displacement, bulletParams) -- Stops fast bullets passing through walls
	if result then
		onBulletHit(bullet, result)
		return false
	end

	bullet.position += displacement
	bullet.velocity = nextVelocity
	bullet.age += dt
	if bullet.age >= BULLET_LIFETIME then
		releaseBullet(bullet.part)
		return false
	end

	bullet.part.CFrame = CFrame.lookAt(bullet.position, bullet.position + bullet.velocity)
	return true
end

local function updateBullets(dt)
	for i = #activeBullets, 1, -1 do
		if not stepBullet(activeBullets[i], dt) then
			activeBullets[i] = activeBullets[#activeBullets] -- Swap-remove, no shifting
			activeBullets[#activeBullets] = nil
		end
	end
end

local Turret = {}
Turret.__index = Turret

function Turret.new(model)
	local head = model:FindFirstChild("Head")
	local swivel = head and head.PrimaryPart
	local muzzle = swivel and swivel:FindFirstChild("Muzzle")
	if not muzzle then
		warn("[TurretSystem] " .. model:GetFullName() .. " is missing Head/Swivel/Muzzle")
		return nil
	end

	local self = setmetatable({}, Turret)
	self.model = model
	self.head = head
	self.swivel = swivel
	self.muzzle = muzzle
	self.flash = swivel:FindFirstChild("MuzzleFlash")
	self.eye = head:FindFirstChild("Eye")

	self.restCFrame = head:GetPivot()
	self.aimCFrame = self.restCFrame
	self.origin = self.restCFrame.Position
	self.recoil = 0
	self.lastShot = 0
	self.sweepTime = math.random() * math.pi * 2
	self.scanTimer = math.random() * SCAN_INTERVAL -- Spreads scans across frames

	self:buildEffects()
	self:readConfig()
	self:setupSpin()
	self:setTarget(nil)

	self.configConnection = model.AttributeChanged:Connect(function(name)
		if DEFAULT_CONFIG[name] ~= nil or name == "Kind" then
			self:readConfig()
		end
	end)

	return self
end

function Turret:buildEffects()
	self.laserEnd = Instance.new("Attachment")
	self.laserEnd.Name = self.model.Name .. "LaserEnd"
	self.laserEnd.Parent = workspace.Terrain -- Terrain never moves

	self.laser = Instance.new("Beam")
	self.laser.Attachment0 = self.muzzle
	self.laser.Attachment1 = self.laserEnd
	self.laser.Color = ColorSequence.new(ALERT_COLOR)
	self.laser.Width0 = LASER_DEFAULT_WIDTH
	self.laser.Width1 = LASER_DEFAULT_WIDTH
	self.laser.LightEmission = 1
	self.laser.Transparency = NumberSequence.new(0.35)
	self.laser.FaceCamera = true
	self.laser.Segments = 1
	self.laser.Enabled = false
	self.laser.Parent = self.swivel

	self.fireSound = Instance.new("Sound")
	self.fireSound.SoundId = FIRE_SOUND_ID
	self.fireSound.Volume = 0.6
	self.fireSound.RollOffMaxDistance = 160
	self.fireSound.Parent = self.swivel

	self.sparks = Instance.new("ParticleEmitter")
	self.sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	self.sparks.Color = ColorSequence.new(Color3.fromRGB(255, 200, 110), Color3.fromRGB(255, 110, 40))
	self.sparks.LightEmission = 1
	self.sparks.Size = NumberSequence.new(0.35, 0)
	self.sparks.Lifetime = NumberRange.new(0.08, 0.18)
	self.sparks.Speed = NumberRange.new(14, 24)
	self.sparks.SpreadAngle = Vector2.new(18, 18)
	self.sparks.EmissionDirection = Enum.NormalId.Front
	self.sparks.Rate = 0
	self.sparks.Parent = self.muzzle
end

function Turret:readConfig()
	local model = self.model
	local function get(name)
		local value = model:GetAttribute(name)
		if value == nil then
			return DEFAULT_CONFIG[name]
		end
		return value
	end
	self.range = get("Range")
	self.fireInterval = 1 / math.max(get("FireRate"), 0.01)
	self.damage = get("Damage")
	self.bulletSpeed = get("BulletSpeed")
	self.turnSpeed = get("TurnSpeed")
	self.style = KINDS[model:GetAttribute("Kind")] or KINDS.Default -- Unknown kinds fall back to Default
	self.fireSound.PlaybackSpeed = self.style.soundPitch
end

function Turret:setupSpin()
	self.spinParts = nil
	self.spinSpeed = 0
	self.spinAngle = 0
	local names = self.style.spinPartNames
	if not names then
		return
	end
	self.spinParts = {}
	local swivelCFrame = self.swivel.CFrame
	for _, part in self.head:GetChildren() do
		if part:IsA("BasePart") and names[part.Name] then
			self.spinParts[part] = swivelCFrame:ToObjectSpace(part.CFrame) -- Offset from the swivel, rebuilt every frame
		end
	end
	local muzzlePosition = self.muzzle.Position
	self.spinAxis = CFrame.new(muzzlePosition.X, muzzlePosition.Y, 0)
end

function Turret:hasLineOfSight(character, offset)
	local result = workspace:Raycast(self.origin, offset, sightParams)
	return result == nil or result.Instance:IsDescendantOf(character)
end

function Turret:findTarget()
	local bestRoot, bestHumanoid, bestPlayer
	local bestDistance = self.range
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and humanoid.Health > 0 then
			local offset = root.Position - self.origin
			local distance = offset.Magnitude
			if distance < bestDistance and self:hasLineOfSight(character, offset) then
				bestRoot, bestHumanoid, bestPlayer, bestDistance = root, humanoid, player, distance
			end
		end
	end
	return bestRoot, bestHumanoid, bestPlayer
end

function Turret:setTarget(root, humanoid, player)
	if root == self.target and root ~= nil then
		return
	end
	self.target, self.targetHumanoid, self.targetPlayer = root, humanoid, player
	self.model:SetAttribute("TargetId", player and player.UserId or 0) -- The HUD reads this

	local color = root and ALERT_COLOR or IDLE_COLOR
	self.laser.Enabled = root ~= nil
	if self.eye then
		self.eye.Color = color
		local glow = self.eye:FindFirstChildOfClass("PointLight")
		if glow then
			glow.Color = color
		end
	end
end

function Turret:predictAimPoint(root)
	local origin = self.muzzle.WorldPosition
	local velocity = root.AssemblyLinearVelocity * FLAT
	local point = root.Position
	local travelTime = 0
	for _ = 1, PREDICTION_PASSES do
		travelTime = (point - origin).Magnitude / self.bulletSpeed
		point = root.Position + velocity * travelTime
	end
	return point - GRAVITY * 0.5 * travelTime * travelTime -- Aim up to cancel bullet drop
end

function Turret:isReadyToFire(now)
	if now - self.lastShot < self.fireInterval then
		return false
	end
	if self.spinParts and self.spinSpeed < SPIN_MAX * SPIN_FIRE_THRESHOLD then
		return false
	end
	return true
end

function Turret:fire(aimPoint, now)
	self.lastShot = now
	local origin = self.muzzle.WorldPosition
	fireBullet(origin, (aimPoint - origin).Unit * self.bulletSpeed, self.damage, self.style.bulletColor)
	self.recoil = RECOIL_DISTANCE
	self.fireSound:Play()
	self.sparks:Emit(8)
	if self.flash then
		self.flash.Brightness = 6
		TweenService:Create(self.flash, FLASH_TWEEN, { Brightness = 0 }):Play()
	end
end

function Turret:updateSpin(dt)
	if not self.spinParts then
		return
	end
	local goal = self.target and SPIN_MAX or 0
	self.spinSpeed += (goal - self.spinSpeed) * (1 - math.exp(-SPIN_RESPONSE * dt))
	self.spinAngle = (self.spinAngle + self.spinSpeed * dt) % (math.pi * 2)

	local spin = self.spinAxis * CFrame.Angles(0, 0, self.spinAngle) * self.spinAxis:Inverse() -- Rotate around the barrel axis
	local swivelCFrame = self.swivel.CFrame
	for part, offset in self.spinParts do
		part.CFrame = swivelCFrame * spin * offset
	end
end

function Turret:updateLaser(now)
	if not self.style.chargeLaser then
		return
	end
	local charge = math.clamp((now - self.lastShot) / self.fireInterval, 0, 1)
	local width = LASER_MIN_WIDTH + (LASER_MAX_WIDTH - LASER_MIN_WIDTH) * charge
	self.laser.Width0 = width
	self.laser.Width1 = width
end

function Turret:update(dt, now)
	self.scanTimer -= dt
	if self.scanTimer <= 0 then
		self.scanTimer = SCAN_INTERVAL
		self:setTarget(self:findTarget())
	end

	local desired
	local target = self.target
	if target and target.Parent and self.targetHumanoid.Health > 0 then
		local aimPoint = self:predictAimPoint(target)
		desired = CFrame.lookAt(self.origin, aimPoint)
		self.laserEnd.WorldPosition = target.Position
		local aligned = self.aimCFrame.LookVector:Dot(desired.LookVector) >= AIM_TOLERANCE
		if aligned and self:isReadyToFire(now) then
			self:fire(aimPoint, now)
		end
		self:updateLaser(now)
	else
		if target then
			self:setTarget(nil)
		end
		self.sweepTime += dt
		desired = self.restCFrame * CFrame.Angles(0, math.sin(self.sweepTime * SWEEP_SPEED) * SWEEP_ANGLE, 0)
	end

	self.aimCFrame = self.aimCFrame:Lerp(desired, 1 - math.exp(-self.turnSpeed * dt)) -- Smooth turning at any frame rate
	self.recoil *= math.exp(-RECOIL_RECOVERY * dt)
	self.head:PivotTo(self.aimCFrame * CFrame.new(0, 0, self.recoil))
	self:updateSpin(dt)
end

function Turret:destroy()
	self:setTarget(nil)
	self.configConnection:Disconnect()
	if self.spinParts then
		local swivelCFrame = self.swivel.CFrame
		for part, offset in self.spinParts do
			part.CFrame = swivelCFrame * offset
		end
	end
	self.laser:Destroy()
	self.fireSound:Destroy()
	self.sparks:Destroy()
	self.laserEnd:Destroy()
end

local turrets = {}

local function register(model)
	if turrets[model] or not model:IsDescendantOf(workspace) then
		return
	end
	turrets[model] = Turret.new(model)
end

local function unregister(model)
	local turret = turrets[model]
	if turret then
		turret:destroy()
		turrets[model] = nil
	end
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(register)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(unregister)
for _, model in CollectionService:GetTagged(TAG) do
	register(model)
end

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	for _, turret in turrets do
		turret:update(dt, now)
	end
	updateBullets(dt) -- After turrets fire, so new bullets move this frame
end)
