-- init.lua

AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

DEFINE_BASECLASS("acf_explosive")

-------------------------------[[ Local Functions ]]-------------------------------

local WireTable = {
	gmod_wire_pod = function(Input)
		if Input.Pod then
			return Input.Pod:GetDriver()
		end
	end,
	gmod_wire_keyboard = function(Input)
		if Input.ply then
			return Input.ply
		end
	end,
	gmod_wire_expression2 = function(Input, This)
		if Input.Inputs.Fire then
			return This:GetUser(Input.Inputs.Fire.Src)
		elseif Input.Inputs.Shoot then
			return This:GetUser(Input.Inputs.Shoot.Src)
		elseif Input.Inputs then
			for _, V in pairs(Input.Inputs) do
				if not IsValid(V.Src) then
					return Input.Owner or Input:GetOwner()
				end

				if WireTable[V.Src:GetClass()] then
					return This:GetUser(V.Src)
				end
			end
		end
	end,
}

WireTable.gmod_wire_adv_pod = WireTable.gmod_wire_pod
WireTable.gmod_wire_joystick = WireTable.gmod_wire_pod
WireTable.gmod_wire_joystick_multi = WireTable.gmod_wire_pod

local Inputs = {
	Fire = function(Rack, Value)
		Rack.Firing = ACF.GunfireEnabled and Value ~= 0

		if Rack.Firing and Rack.NextFire >= 1 then
			Rack.User = Rack:GetUser(Rack.Inputs.Fire.Src)

			if not IsValid(Rack.User) then
				Rack.User = Rack.Owner
			end

			Rack:FireMissile()
		end
	end,
	["Fire Delay"] = function(Rack, Value)
		Rack.FireDelay = math.Clamp(Value, 0, 1)
	end,
	Reload = function(Rack, Value)
		if Value ~= 0 then
			Rack:Reload()
		end
	end,
	["Target Pos"] = function(Rack, Value)
		Wire_TriggerOutput(Rack, "Position", Value)
	end,
	["Target Ent"] = function(Rack, Value)
		Wire_TriggerOutput(Rack, "Target", Value)
	end,
}

local function CheckRackID(ID, MissileID)
	local Weapons = ACF.Weapons

	if not (ID and Weapons.Rack[ID]) then
		local GunClass = Weapons.Guns[MissileID]

		if not GunClass then
			error("Couldn't spawn the missile rack: can't find the gun-class '" .. tostring(MissileID) .. "'.")
		end

		if not GunClass.rack then
			error("Couldn't spawn the missile rack: '" .. tostring(MissileID) .. "' doesn't have a preferred missile rack.")
		end

		ID = GunClass.rack
	end

	return ID
end

local function GetNextCrate(Rack)
	if not next(Rack.Crates) then return end -- No crates linked to this gun

	local Select = next(Rack.Crates, Rack.CurrentCrate) or next(Rack.Crates) -- Next crate from Start or, if at last crate, first crate
	local Start = Select

	repeat
		if Select.Load and Select.Ammo > 0 then return Select end

		Select = next(Rack.Crates, Select) or next(Rack.Crates)
	until Select == Start -- If we've looped back around to the start then there's nothing to use

	return (Select.Load and Select.Ammo > 0) and Select
end

local function GetNextAttachName(Rack)
	if not next(Rack.AttachPoints) then return end

	local Name = next(Rack.AttachPoints)
	local Start = Name

	repeat
		if not Rack.Missiles[Name] then
			return Name
		end

		Name = next(Rack.AttachPoints, Name) or next(Rack.AttachPoints)
	until Name == Start
end

local function GetMissileAngPos(Rack, Missile, AttachName)
	local GunData = list.Get("ACFEnts").Guns[Missile.BulletData.Id]
	local RackData = ACF.Weapons.Rack[Rack.Id]
	local Position = Rack.AttachPoints[AttachName]

	if GunData and RackData then
		local Offset = (GunData.modeldiameter or GunData.caliber) / (2.54 * 2)
		local MountPoint = RackData.mountpoints[AttachName]

		Position = Position + MountPoint.offset + MountPoint.scaledir * Offset
	end

	return Position, Rack:GetAngles()
end

local function AddMissile(Rack, Crate)
	if not IsValid(Crate) then return end

	local Attach = GetNextAttachName(Rack)

	if not Attach then return end

	local BulletData = ACFM_CompactBulletData(Crate)
	local Missile = ents.Create("acf_missile")

	BulletData.IsShortForm = true
	BulletData.Owner = Rack.Owner

	Missile.Owner = Rack.Owner
	Missile.Launcher = Rack
	Missile.DisableDamage = Rack.ProtectMissile
	Missile.Attachment = Attach

	Missile:SetBulletData(BulletData)

	local Pos, Angles = GetMissileAngPos(Rack, Missile, Attach)
	local RackModel = ACF_GetRackValue(Rack.Id, "rackmdl") or ACF_GetGunValue(BulletData.Id, "rackmdl")

	if RackModel then
		Missile:SetModelEasy(RackModel)
		Missile.RackModelApplied = true
	end

	Missile:Spawn()
	Missile:SetParent(Rack)
	Missile:SetParentPhysNum(0)
	Missile:SetAngles(Angles)
	Missile:SetPos(Pos)
	Missile:SetOwner(Rack.Owner)

	if Rack.HideMissile then
		Missile:SetNoDraw(true)
	end

	Rack:EmitSound("acf_extra/tankfx/resupply_single.wav", 500, 100)
	Rack:UpdateAmmoCount(Attach, Missile)

	Rack.CurrentCrate = Crate

	Crate.Ammo = Crate.Ammo - 1
	--SetLoadedWeight(Rack)

	return Missile
end

local function CheckLegal(Rack)
	if not IsValid(Rack) then return end
	if Rack:GetNoDraw() then return end
	if not Rack:IsSolid() then return end
	if Rack.ClipData and next(Rack.ClipData) then return end
	if Rack:GetModel() ~= Rack.Model then return end

	local PhysObj = Rack:GetPhysicsObject()

	if not IsValid(PhysObj) then return end
	if PhysObj:GetMass() < Rack.LegalWeight then return end
	if not PhysObj:GetVolume() then return end

	-- Update the ancestor of the rack
	Rack.Physical = ACF_GetAncestor(Rack)

	return true
end

local function CheckCrateDistance(Rack, Crate)
	if not IsValid(Crate) then return end

	return Rack:GetPos():DistToSqr(Crate:GetPos()) >= 262144
end

local function TrimDistantCrates(Rack)
	if not next(Rack.Crates) then return end

	local Sound = "physics/metal/metal_box_impact_bullet%s.wav"

	for Crate in pairs(Rack.Crates) do
		if CheckCrateDistance(Rack, Crate) and Crate.Load then
			Rack:EmitSound(Sound:format(math.random(1, 3)), 500, 100)
			Rack:Unlink(Crate)
		end
	end
end

local function UpdateRefillBonus(Rack)
	local SelfPos = Rack:GetPos()
	local Efficiency = 0.11 * ACF.AmmoMod -- Copied from acf_ammo, beware of changes!
	local MinFullEfficiency = 50000 * Efficiency -- The minimum crate volume to provide full efficiency bonus all by itself.
	local MaxDist = ACF.RefillDistance
	local TotalBonus = 0

	for Crate in pairs(ACF.AmmoCrates) do
		if Crate.RoundType == "Refill" and Crate.Ammo > 0 and Crate.Load then
			local CrateDist = SelfPos:Distance(Crate:GetPos())

			if CrateDist <= MaxDist then
				CrateDist = math.max(0, CrateDist * 2 - MaxDist)

				local Bonus = (Crate.Volume / MinFullEfficiency) * (MaxDist - CrateDist) / MaxDist

				TotalBonus = TotalBonus + Bonus
			end
		end
	end

	Rack.ReloadMultiplierBonus = math.min(TotalBonus, 1)
	Rack:SetNWFloat("ReloadBonus", Rack.ReloadMultiplierBonus)

	return Rack.ReloadMultiplierBonus
end

local function SetStatusString(Rack)
	local PhysObj = Rack:GetPhysicsObject()

	if not IsValid(PhysObj) then
		Rack:SetNWString("Status", "Something truly horrifying happened to this rack - it has no physics object.")

		return
	end

	if PhysObj:GetMass() < Rack.LegalWeight then
		Rack:SetNWString("Status", "Underweight! (should be " .. Rack.LegalWeight .. " kg)")

		return
	end

	if not IsValid(Rack.CurrentCrate) then
		Rack:SetNWString("Status", "Can't find ammo!")

		return
	end

	Rack:SetNWString("Status", "")
end

-------------------------------[[ Global Functions ]]-------------------------------

function MakeACF_Rack(Owner, Pos, Angle, Id, MissileId)
	if not Owner:CheckLimit("_acf_gun") then return end

	local Rack = ents.Create("acf_rack")

	if not IsValid(Rack) then return end

	Id = CheckRackID(Id, MissileId)

	local List = ACF.Weapons.Rack
	local Classes = ACF.Classes.Rack
	local GunData = List[Id] or error("Couldn't find the " .. tostring(Id) .. " gun-definition!")
	local GunClass = Classes[GunData.gunclass] or error("Couldn't find the " .. tostring(GunData.gunclass) .. " gun-class!")

	Rack:SetModel(GunData.model)
	Rack:SetAngles(Angle)
	Rack:SetPos(Pos)
	Rack:Spawn()

	Rack:PhysicsInit(SOLID_VPHYSICS)
	Rack:SetMoveType(MOVETYPE_VPHYSICS)

	Rack.Id					= Id
	Rack.MissileId			= MissileId
	Rack.MinCaliber			= GunData.mincaliber
	Rack.MaxCaliber			= GunData.maxcaliber
	Rack.Caliber			= GunData.caliber
	Rack.Model				= GunData.model
	Rack.Mass				= GunData.weight
	Rack.LegalWeight		= Rack.Mass
	Rack.Class				= GunData.gunclass
	Rack.Owner				= Owner

	-- Custom BS for karbine: Per Rack ROF, Magazine Size, Mag reload Time
	Rack.PGRoFmod			= GunData.rofmod and math.max(0, GunData.rofmod) or 1
	Rack.MagSize			= GunData.magsize and math.max(1, GunData.magsize) or 1
	Rack.MagReload 			= GunData.magreload and math.max(Rack.MagReload, GunData.magreload) or  0

	Rack.Muzzleflash		= GunData.muzzleflash or GunClass.muzzleflash or ""
	Rack.RoFmod				= GunClass.rofmod
	Rack.Sound				= GunData.sound or GunClass.sound
	Rack.Inaccuracy			= GunClass.spread

	Rack.HideMissile		= GunData.hidemissile
	Rack.ProtectMissile		= GunData.protectmissile
	Rack.CustomArmour		= GunData.armour or GunClass.armour

	Rack.ReloadMultiplier   = ACF_GetRackValue(Id, "reloadmul")
	Rack.WhitelistOnly      = ACF_GetRackValue(Id, "whitelistonly")

	Rack.SpecialHealth		= true	--If true needs a special ACF_Activate function
	Rack.SpecialDamage		= true	--If true needs a special ACF_OnDamage function
	Rack.ReloadTime			= 1
	Rack.Ready				= true
	Rack.NextFire			= 1
	Rack.PostReloadWait		= CurTime()
	Rack.WaitFunction		= Rack.GetFireDelay
	Rack.LastSend			= 0
	Rack.Inaccuracy			= 1

	Rack.IsMaster			= true
	Rack.AmmoCount			= 0
	Rack.LastThink			= CurTime()

	Rack.Missiles			= {}
	Rack.Crates				= {}
	Rack.AttachPoints		= {}

	Rack.Inputs = WireLib.CreateInputs(Rack, { "Fire", "Reload", "Target Pos [VECTOR]", "Target Ent [ENTITY]" })
	Rack.Outputs = WireLib.CreateOutputs(Rack, { "Ready", "Entity [ENTITY]", "Shots Left", "Position [VECTOR]", "Target [ENTITY]" })

	Rack.BulletData	= {
		Type = "Empty",
		PropMass = 0,
		ProjMass = 0,
	}

	Rack:SetNWString("Class", Rack.Class)
	Rack:SetNWString("ID", Rack.Id)
	Rack:SetNWString("GunType", Rack.MissileId or Rack.Id)
	Rack:SetNWString("Sound", Rack.Sound)

	Wire_TriggerOutput(Rack, "Entity", Rack)
	Wire_TriggerOutput(Rack, "Ready", 1)

	local PhysObj = Rack:GetPhysicsObject()

	if IsValid(PhysObj) then
		PhysObj:SetMass(Rack.Mass)
	end

	local MountPoints = ACF.Weapons.Rack[Rack.Id].mountpoints

	for _, Data in pairs(Rack:GetAttachments()) do
		local Attachment = Rack:GetAttachment(Data.id)

		if MountPoints[Data.name] then
			Rack.AttachPoints[Data.name] = Rack:WorldToLocal(Attachment.Pos)
		end
	end

	Owner:AddCount("_acf_gun", Rack)
	Owner:AddCleanup("acfmenu", Rack)

	return Rack
end

list.Set("ACFCvars", "acf_rack" , {"data9", "id"})
duplicator.RegisterEntityClass("acf_rack", MakeACF_Rack, "Pos", "Angle", "Id", "MissileId")

function ENT:GetReloadTime(Missile)
	local ReloadMult = self.ReloadMultiplier
	local ReloadBonus = self.ReloadMultiplierBonus or 0
	local MagSize = self.MagSize ^ 1.1
	local DelayMult = (ReloadMult - (ReloadMult - 1) * ReloadBonus) / MagSize
	local ReloadTime = self:GetFireDelay(Missile) * DelayMult

	self:SetNWFloat("Reload", ReloadTime)

	return ReloadTime
end

function ENT:GetFireDelay(Missile)
	if not IsValid(Missile) then
		self:SetNWFloat("Interval", self.LastValidFireDelay or 1)

		return self.LastValidFireDelay or 1
	end

	local BulletData = Missile.BulletData
	local GunData = list.Get("ACFEnts").Guns[BulletData.Id]

	if not GunData then
		self:SetNWFloat("Interval", self.LastValidFireDelay or 1)

		return self.LastValidFireDelay or 1
	end

	local Class = list.Get("ACFClasses").GunClass[GunData.gunclass]
	local Interval = ((BulletData.RoundVolume / 500) ^ 0.60) * (GunData.rofmod or 1) * (Class.rofmod or 1)

	self.LastValidFireDelay = Interval
	self:SetNWFloat("Interval", Interval)

	return Interval
end

function ENT:ACF_Activate( Recalc )
	local EmptyMass = self.RoundWeight or self.Mass or 10
	local PhysObj = self:GetPhysicsObject()

	self.ACF = self.ACF or {}

	if not self.ACF.Area then
		self.ACF.Area = PhysObj:GetSurfaceArea() * 6.45
	end

	if not self.ACF.Volume then
		self.ACF.Volume = PhysObj:GetVolume() * 16.38
	end

	local ForceArmour = self.CustomArmour
	local Armour = ForceArmour or (EmptyMass * 1000 / self.ACF.Area / 0.78) --So we get the equivalent thickness of that prop in mm if all it's weight was a steel plate
	local Health = self.ACF.Volume / ACF.Threshold							--Setting the threshold of the prop area gone
	local Percent = 1

	if Recalc and self.ACF.Health and self.ACF.MaxHealth then
		Percent = self.ACF.Health / self.ACF.MaxHealth
	end

	self.ACF.Health = Health * Percent
	self.ACF.MaxHealth = Health
	self.ACF.Armour = Armour * (0.5 + Percent / 2)
	self.ACF.MaxArmour = Armour
	self.ACF.Type = nil
	self.ACF.Mass = self.Mass
	self.ACF.Density = (self:GetPhysicsObject():GetMass() * 1000) / self.ACF.Volume
	self.ACF.Type = "Prop"
end

function ENT:ACF_OnDamage(Entity, Energy, FrArea, Angle, Inflictor)
	if self.Exploded then
		return {
			Damage = 0,
			Overkill = 1,
			Loss = 0,
			Kill = false
		}
	end

	local HitRes = ACF_PropDamage(Entity, Energy, FrArea, Angle, Inflictor) --Calling the standard damage prop function

	-- If the rack gets destroyed, we just blow up all the missiles it carries
	if HitRes.Kill then
		if hook.Run("ACF_AmmoExplode", self, nil) == false then return HitRes end

		self.Exploded = true

		if IsValid(Inflictor) and Inflictor:IsPlayer() then
			self.Inflictor = Inflictor
		end

		if next(self.Missiles) then
			for _, Missile in pairs(self.Missiles) do
				Missile:SetParent()
				Missile:Detonate()
			end
		end
	end

	return HitRes -- This function needs to return HitRes
end

function ENT:CanLoadCaliber(Caliber)
	return ACF_RackCanLoadCaliber(self.Id, Caliber)
end

function ENT:Link(Crate)
	if not IsValid(Crate) then return false, "Invalid entity!" end
	if Crate:GetClass() ~= "acf_ammo" then return false, "Racks can only be linked to ammo crates!" end
	if self.Crates[Crate] then return false, "Crate is already linked to this gun!" end
	if Crate.RoundType == "Refill" then return false, "Refill crates cannot be linked!" end
	if Crate.Weapons[self] then return false, "Crate is already linked to this gun!" end

	local BulletData = Crate.BulletData
	local GunClass = ACF_GetGunValue(BulletData, "gunclass")
	local Blacklist = ACF.AmmoBlacklist[Crate.RoundType] or {}

	if not GunClass or table.HasValue(Blacklist, GunClass) then return false, "That round type cannot be used with this gun!" end

	local Result, Message = ACF_CanLinkRack(self.Id, BulletData.Id, BulletData, self)
	if not Result then return Result, Message end

	self.Crates[Crate] = true
	Crate.Weapons[self] = true

	return true, "Link successful!"
end

function ENT:Unlink(Target)
	if self.Crates[Target] then
		self.Crates[Target] = nil
		Target.Weapons[self] = nil

		return true, "Unlink successful!"
	else
		return false, "That entity is not linked to this gun!"
	end
end

function ENT:UnloadAmmo()
	-- we're ok with mixed munitions.
end

function ENT:GetUser(Input)
	if not Input then return end

	if WireTable[Input:GetClass()] then
		WireTable[Input:GetClass()](Input, self)
	end

	return Input.Owner or Input:GetOwner()
end

function ENT:TriggerInput(Input, Value)
	if Inputs[Input] then
		Inputs[Input](self, Value)
	end
end

function ENT:FireMissile()
	if CheckLegal(self) and self.Ready and self.PostReloadWait < CurTime() then
		local Attachment, Missile = next(self.Missiles)
		local ReloadTime = 0.5

		if IsValid(Missile) then
			if hook.Run("ACF_FireShell", self, Missile.BulletData) == false then return end

			ReloadTime = self:GetFireDelay(Missile)

			local Pos, Angles = GetMissileAngPos(self, Missile, Attachment)
			local MuzzleVec = Angles:Forward()
			local ConeAng = math.tan(math.rad(self.Inaccuracy * ACF.GunInaccuracyScale))
			local RandDirection = (self:GetUp() * math.Rand(-1, 1) + self:GetRight() * math.Rand(-1, 1)):GetNormalized()
			local Spread = RandDirection * ConeAng * (math.random() ^ (1 / math.Clamp(ACF.GunInaccuracyBias, 0.5, 4)))
			local ShootVec = (MuzzleVec + Spread):GetNormalized()
			local BulletData = Missile.BulletData
			local BulletSpeed = BulletData.MuzzleVel or Missile.MinimumSpeed or 1

			BulletData.Flight = ShootVec * BulletSpeed

			Missile:SetNoDraw(false)
			Missile:SetParent(nil)

			Missile.Filter = { self }

			for _, Load in pairs(self.Missiles) do
				Missile.Filter[#Missile.Filter + 1] = Load
			end

			if Missile.RackModelApplied then
				Missile:SetModelEasy(ACF_GetGunValue(BulletData.Id, "model"))
				Missile.RackModelApplied = nil
			end

			local PhysMissile = Missile:GetPhysicsObject()

			if IsValid(PhysMissile) then
				PhysMissile:SetMass(Missile.RoundWeight)
			end

			Missile:DoFlight(self:LocalToWorld(Pos), ShootVec)
			Missile:Launch()

			if self.Sound and self.Sound ~= "" then
				Missile.BulletData.Sound = self.Sound
			end

			self:UpdateAmmoCount(Attachment)

			Missile:EmitSound("phx/epicmetal_hard.wav", 500, 100)
			--SetLoadedWeight(self)
		else
			self:EmitSound("weapons/pistol/pistol_empty.wav", 500, 100)
		end

		Wire_TriggerOutput(self, "Ready", 0)
		self.Ready = false
		self.NextFire = 0
		self.WaitFunction = self.GetFireDelay
		self.ReloadTime = ReloadTime
	else
		self:EmitSound("weapons/pistol/pistol_empty.wav", 500, 100)
	end
end

function ENT:Reload()
	if not self.Ready and not GetNextAttachName(self) then return end
	if self.AmmoCount >= self.MagSize then return end
	if self.NextFire < 1 then return end

	local Missile = AddMissile(self, GetNextCrate(self))

	self.NextFire = 0
	self.PostReloadWait = CurTime() + 5
	self.WaitFunction = self.GetReloadTime
	self.Ready = false
	self.ReloadTime = IsValid(Missile) and self:GetReloadTime(Missile) or 1

	Wire_TriggerOutput(self, "Ready", 0)
end

function ENT:UpdateAmmoCount(Attachment, Missile)
	self.Missiles[Attachment] = Missile
	self.AmmoCount = self.AmmoCount + (Missile and 1 or -1)

	self:SetNWInt("Ammo", self.AmmoCount)

	Wire_TriggerOutput(self, "Shots Left", self.AmmoCount)
end

function ENT:Think()
	local _, Missile = next(self.Missiles)
	local Time = CurTime()

	if self.LastSend + 1 <= Time then
		TrimDistantCrates(self)
		UpdateRefillBonus(self)
		SetStatusString(self)

		self:GetReloadTime(Missile)

		self.LastSend = Time
	end

	self.NextFire = math.min(self.NextFire + (Time - self.LastThink) / self:WaitFunction(Missile), 1)

	if self.NextFire >= 1 then
		if Missile then
			self.Ready = true

			Wire_TriggerOutput(self, "Ready", 1)

			if self.Firing then
				self:FireMissile()
			elseif self.Inputs.Reload and self.Inputs.Reload.Value ~= 0 then
				self:Reload()
			elseif self.ReloadTime and self.ReloadTime > 1 then
				self:EmitSound("acf_extra/airfx/weapon_select.wav", 500, 100)
				self.ReloadTime = nil
			end
		else
			if self.Inputs.Reload and self.Inputs.Reload.Value ~= 0 then
				self:Reload()
			end
		end
	end

	self:NextThink(Time + 0.5)
	self.LastThink = Time

	return true
end

function ENT:MuzzleEffect()
	self:EmitSound( "phx/epicmetal_hard.wav", 500, 100 )
end

function ENT:ReloadEffect() end

function ENT:PreEntityCopy()
	if next(self.Crates) then
		local EntIDs = {}

		for Crate in pairs(self.Crates) do
			EntIDs[#EntIDs + 1] = Crate:EntIndex()
		end

		if next(EntIDs) then
			local Info = {
				entities = EntIDs
			}

			duplicator.StoreEntityModifier(self, "ACFAmmoLink", Info)
		end
	end

	duplicator.StoreEntityModifier(self, "ACFRackInfo", {
		Id = self.Id,
		MissileId = self.MissileId
	})

	-- Wire dupe info
	self.BaseClass.PreEntityCopy(self)
end

function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
	local AmmoLink = Ent.EntityMods.ACFAmmoLink

	if AmmoLink and AmmoLink.entities then
		for _, Index in pairs(AmmoLink.entities) do
			local Ammo = CreatedEntities[Index]

			if IsValid(Ammo) and Ammo:GetClass() == "acf_ammo" then
				self:Link(Ammo)

				-- Old racks don't have this variable, so we just update them
				if not self.MissileId then
					self.MissileId = Ammo.RoundId
				end
			end
		end

		Ent.EntityMods.ACFAmmoLink = nil
	end

	-- Wire dupe info
	self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
end

function ENT:OnRemove()
	for Crate in pairs(self.Crates) do
		self:Unlink(Crate)
	end

	Wire_Remove(self)
end

function ENT:OnRestore()
	Wire_Restored(self)
end