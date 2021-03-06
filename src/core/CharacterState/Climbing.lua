local Workspace = game:GetService("Workspace")

local Animation = require(script.Parent.Parent.Animation)
local DebugVisualize = require(script.Parent.Parent.DebugVisualize)
local CollisionMask = require(script.Parent.Parent.CollisionMask)

local START_CLIMB_DISTANCE = 2.5
local KEEP_CLIMB_DISTANCE = 3
local FLOOR_DISTANCE = 2.2
local CLIMB_DEBOUNCE = 0.2
local CLIMB_OFFSET = Vector3.new(0, 0, 0.5) -- In object space

local FALLING_DANGER_THRESHOLD = 0.2 -- How many seconds can we hold onto a bad climbing surface?
local CLIMB_NOT_STEEP_ENOUGH = 0.45
local CLIMB_TOO_OVERHANGY = -0.8

local COLLISION_MASK = {
	LeftFoot = false,
	LeftLowerLeg = false,
	LeftUpperLeg = false,
	LeftHand = false,
	LeftLowerArm = false,
	LeftUpperArm = false,
	RightFoot = false,
	RightLowerLeg = false,
	RightUpperLeg = false,
	RightHand = false,
	RightLowerArm = false,
	RightUpperArm = false,
}

local function getClimbAttachmentCFrame(options)
	local normal = options.normal -- look at the wall
	local worldPosition = options.position
	local part = options.object 
	-- TODO: terrible behavior if look colinear with up (use character up instead?)
	local yAxis = Vector3.new(0, 1, 0) -- up
	local zAxis = normal -- -look (look is -z)
	local xAxis = yAxis:Cross(zAxis).Unit -- right
	-- orthonormalize, keeping look vector
	yAxis = zAxis:Cross(xAxis).Unit
	return part.CFrame:inverse() * CFrame.new(
		worldPosition.x, worldPosition.y, worldPosition.z, 
		xAxis.x, yAxis.x, zAxis.x, 
		xAxis.y, yAxis.y, zAxis.y, 
		xAxis.z, yAxis.z, zAxis.z)
end

local Climbing = {}
Climbing.__index = Climbing

function Climbing.new(simulation)
	local state = {
		simulation = simulation,
		character = simulation.character,
		animation = simulation.animation,

		objects = {},
		refs = {},
		lastStep = nil,
		lastClimbTime = -math.huge,

		-- Raises each frame when we're climbing an unsuitable surface, lowers
		-- each frame when we're climbing a good surface.
		fallingDangerTime = 0,
	}

	setmetatable(state, Climbing)

	return state
end

function Climbing:nearFloor()
	local rayOrigin = self.character.castPoint.WorldPosition
	local rayDirection = Vector3.new(0, -FLOOR_DISTANCE, 0)

	local climbRay = Ray.new(rayOrigin, rayDirection)
	local object = Workspace:FindPartOnRay(climbRay, self.character.instance)

	return not not object
end

function Climbing:cast(distance)
	distance = distance or START_CLIMB_DISTANCE

	local rayOrigin = self.character.instance.PrimaryPart.Position
		+ self.character.instance.PrimaryPart.CFrame:vectorToWorldSpace(CLIMB_OFFSET)
	local rayDirection = self.character.instance.PrimaryPart.CFrame.lookVector * distance

	local climbRay = Ray.new(rayOrigin, rayDirection)
	local object, position, normal = Workspace:FindPartOnRay(climbRay, self.character.instance)

	-- TODO: Use CollectionService?
	local isClimbable = object and not not object:FindFirstChild("Climbable")

	local adornColor
	if isClimbable then
		adornColor = Color3.new(0, 1, 0)
	elseif object then
		adornColor = Color3.new(0, 0, 1)
	else
		adornColor = Color3.new(1, 0, 0)
	end

	DebugVisualize.point(rayOrigin, Color3.new(1, 1, 1))
	DebugVisualize.point(position, adornColor)

	if not isClimbable then
		return nil
	end

	return {
		object = object,
		position = position,
		normal = normal,
	}
end

--[[
	Intended to be used to check whether it's appropriate to transition to the
	Climbing state.
]]
function Climbing:check()
	-- If we just stopped climbing, don't climb again yet
	if Workspace.DistributedGameTime - self.lastClimbTime <= CLIMB_DEBOUNCE then
		return nil
	end

	return self:cast()
end

function Climbing:enterState(oldState, options)
	assert(options.object)
	assert(options.position)
	assert(options.normal)

	self.lastStep = options

	CollisionMask.apply(self.character.instance, COLLISION_MASK)

	self.lastClimbTime = Workspace.DistributedGameTime

	local position0 = Instance.new("Attachment")
	position0.Parent = self.character.instance.PrimaryPart
	position0.Position = -CLIMB_OFFSET
	self.objects[position0] = true

	local position1 = Instance.new("Attachment")
	position1.CFrame = getClimbAttachmentCFrame(options)
	position1.Parent = options.object
	self.refs.positionAttachment = position1
	self.objects[position1] = true

	local position = Instance.new("AlignPosition")
	position.Attachment0 = position0
	position.Attachment1 = position1
	position.Parent = self.character.instance.PrimaryPart
	position.MaxForce = 100000
	position.Responsiveness = 50
	position.MaxVelocity = 7
	self.objects[position] = true

	local align = Instance.new("AlignOrientation")
	align.Attachment0 = position0
	align.Attachment1 = position1
	align.Parent = self.character.instance.PrimaryPart
	self.objects[align] = true

	self.animation:setState(Animation.State.Climbing)
end

function Climbing:leaveState()
	CollisionMask.revert(self.character.instance, COLLISION_MASK)

	self.refs = {}

	for object in pairs(self.objects) do
		object:Destroy()
	end

	self.objects = {}

	self.lastClimbTime = Workspace.DistributedGameTime
	self.fallingDangerTime = 0

	self.animation.animations.climb:AdjustSpeed(1)
	self.animation:setState(Animation.State.None)
end

function Climbing:step(dt, input)
	if input.jump and Workspace.DistributedGameTime - self.lastClimbTime >= CLIMB_DEBOUNCE then
		return self.simulation:setState(self.simulation.states.Walking)
	end

	-- If the user is moving down, check if they could be hitting the floor
	if input.movementY < 0 and self:nearFloor() then
		return self.simulation:setState(self.simulation.states.Walking)
	end

	-- If we've been climbing on a bad surface for too long, fall off!
	if self.fallingDangerTime >= FALLING_DANGER_THRESHOLD then
		return self.simulation:setState(self.simulation.states.Walking)
	end

	local nextStep = self:cast(KEEP_CLIMB_DISTANCE)

	-- We ran out of surface to climb!
	if not nextStep then
		local options = {
			biasImpulse = self.character.instance.PrimaryPart.CFrame.lookVector*3
		}
		return self.simulation:setState(self.simulation.states.Walking, options)
	end

	-- Is the surface the wrong angle for climbing?
	local steepness = nextStep.normal:Dot(Vector3.new(0, 1, 0))
	if steepness >= CLIMB_NOT_STEEP_ENOUGH or steepness <= CLIMB_TOO_OVERHANGY then
		self.fallingDangerTime = self.fallingDangerTime + dt * math.abs(steepness)
	else
		self.fallingDangerTime = math.max(0, self.fallingDangerTime - dt)
	end

	self.animation.animations.climb:AdjustSpeed(input.movementY * 2)

	-- We're transitioning to a new climbable
	if nextStep.object ~= self.lastStep.object then
		return self.simulation:setState(self, nextStep)
	end

	if input.movementX ~= 0 or input.movementY ~= 0 then
		local reference = self.character.instance.PrimaryPart.CFrame
		local change = reference.upVector * input.movementY - reference.rightVector * input.movementX

		self.refs.positionAttachment.CFrame = getClimbAttachmentCFrame(nextStep) + nextStep.object.CFrame:vectorToObjectSpace(change)
	end
end

return Climbing