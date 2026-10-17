--!strict
-- GameConfig: single source of truth for ALL game tuning.
-- Server and client both read this. Balance lives here, logic lives in services.

local GameConfig = {}

----------------------------------------------------------------------
-- Zones (ordered). Every hustle is recognizable from across the map:
-- exaggerated shapes, one signature color per zone (art & feel guide).
----------------------------------------------------------------------

export type ZoneDef = {
	Id: string,
	Name: string,
	Order: number,
	UnlockCost: number, -- 0 = starting zone, no gate
	HustleEarn: number, -- base cash per hustle action
	HustleCooldown: number, -- seconds between hustles (server-enforced)
	SignColor: Color3, -- signature color
	AccentColor: Color3,
	HustleVerb: string, -- flavor on the prompt / popups
}

GameConfig.Zones = {
	{
		Id = "LemonadeStand",
		Name = "Lemonade Stand",
		Order = 1,
		UnlockCost = 0,
		HustleEarn = 5,
		HustleCooldown = 1,
		SignColor = Color3.fromRGB(255, 212, 31),
		AccentColor = Color3.fromRGB(255, 240, 120),
		HustleVerb = "Squeeze",
	},
	{
		Id = "DogWalking",
		Name = "Dog Walking",
		Order = 2,
		UnlockCost = 500,
		HustleEarn = 20,
		HustleCooldown = 1,
		SignColor = Color3.fromRGB(88, 190, 72),
		AccentColor = Color3.fromRGB(150, 230, 120),
		HustleVerb = "Walk",
	},
	{
		Id = "SneakerFlipping",
		Name = "Sneaker Street",
		Order = 3,
		UnlockCost = 5000,
		HustleEarn = 80,
		HustleCooldown = 1,
		SignColor = Color3.fromRGB(128, 115, 255),
		AccentColor = Color3.fromRGB(180, 160, 255),
		HustleVerb = "Flip",
	},
	{
		Id = "CarWash",
		Name = "Car Wash",
		Order = 4,
		UnlockCost = 25000,
		HustleEarn = 300,
		HustleCooldown = 1,
		SignColor = Color3.fromRGB(64, 200, 224),
		AccentColor = Color3.fromRGB(140, 230, 255),
		HustleVerb = "Scrub",
	},
	{
		Id = "FoodTruck",
		Name = "Food Truck",
		Order = 5,
		UnlockCost = 100000,
		HustleEarn = 1100,
		HustleCooldown = 1,
		SignColor = Color3.fromRGB(255, 123, 34),
		AccentColor = Color3.fromRGB(247, 55, 92),
		HustleVerb = "Grill",
	},
	{
		Id = "ContentCreator",
		Name = "Creator Studio",
		Order = 6,
		UnlockCost = 500000,
		HustleEarn = 4000,
		HustleCooldown = 1,
		SignColor = Color3.fromRGB(255, 92, 180),
		AccentColor = Color3.fromRGB(255, 160, 220),
		HustleVerb = "Stream",
	},
	{
		Id = "StockDesk",
		Name = "Stock Desk",
		Order = 7,
		UnlockCost = 2500000,
		HustleEarn = 15000,
		HustleCooldown = 1,
		SignColor = Color3.fromRGB(32, 200, 96),
		AccentColor = Color3.fromRGB(8, 12, 10),
		HustleVerb = "Trade",
	},
	{
		Id = "StartupHQ",
		Name = "Startup HQ",
		Order = 8,
		UnlockCost = 10000000,
		HustleEarn = 60000,
		HustleCooldown = 1,
		SignColor = Color3.fromRGB(240, 246, 255),
		AccentColor = Color3.fromRGB(60, 130, 255),
		HustleVerb = "Pitch",
	},
} :: { ZoneDef }

local zonesById: { [string]: ZoneDef } = {}
for _, zone in GameConfig.Zones do
	zonesById[zone.Id] = zone
end

function GameConfig.getZone(zoneId: string): ZoneDef?
	return zonesById[zoneId]
end

GameConfig.StartingZoneId = "LemonadeStand"

----------------------------------------------------------------------
-- Workers: cute chibi characters whose props show their rarity.
----------------------------------------------------------------------

export type RarityDef = {
	Id: string,
	Name: string,
	IncomePerSec: number, -- base, multiplied by crate Multiplier
	Color: Color3, -- rarity accent (cards, name tags)
	Prop: string, -- "CoffeeCup" | "None" | "Clipboard" | "GoldSuit"
}

-- Ordered common -> rarest
GameConfig.WorkerRarities = {
	{ Id = "Intern", Name = "Intern", IncomePerSec = 2, Color = Color3.fromRGB(170, 170, 180), Prop = "CoffeeCup" },
	{ Id = "Employee", Name = "Employee", IncomePerSec = 6, Color = Color3.fromRGB(88, 190, 72), Prop = "None" },
	{ Id = "Manager", Name = "Manager", IncomePerSec = 20, Color = Color3.fromRGB(64, 140, 255), Prop = "Clipboard" },
	{ Id = "CEO", Name = "CEO", IncomePerSec = 75, Color = Color3.fromRGB(255, 200, 40), Prop = "GoldSuit" },
} :: { RarityDef }

local raritiesById: { [string]: RarityDef } = {}
for _, rarity in GameConfig.WorkerRarities do
	raritiesById[rarity.Id] = rarity
end

function GameConfig.getRarity(rarityId: string): RarityDef?
	return raritiesById[rarityId]
end

export type CrateDef = {
	Id: string,
	Name: string,
	Cost: number,
	Multiplier: number, -- multiplies the rarity's IncomePerSec
	-- Weights by rarity Id; need not sum to 100, they are normalized.
	Weights: { [string]: number },
}

GameConfig.WorkerCrates = {
	StarterCrate = {
		Id = "StarterCrate",
		Name = "Starter Crate",
		Cost = 100,
		Multiplier = 1,
		Weights = { Intern = 60, Employee = 28, Manager = 10, CEO = 2 },
	},
	ProCrate = {
		Id = "ProCrate",
		Name = "Pro Crate",
		Cost = 10000,
		Multiplier = 12,
		Weights = { Intern = 40, Employee = 35, Manager = 18, CEO = 7 },
	},
	EliteCrate = {
		Id = "EliteCrate",
		Name = "Elite Crate",
		Cost = 1000000,
		Multiplier = 150,
		Weights = { Intern = 20, Employee = 35, Manager = 30, CEO = 15 },
	},
} :: { [string]: CrateDef }

-- First names give workers personality; full name = "<first> the <rarity>".
GameConfig.WorkerNames = {
	"Benny", "Pixel", "Mo", "Greta", "Ziggy", "Luna", "Chip", "Olive",
	"Rocco", "Daisy", "Felix", "Wanda", "Gus", "Penny", "Sunny", "Bram",
	"Coco", "Milo", "Trixie", "Alfie", "Nova", "Biscuit", "Pepper", "Scout",
}

GameConfig.Workers = {
	BaseEquipSlots = 3, -- + WorkerSlots upgrade level
	MaxStorage = 50,
	IncomeTickSeconds = 1,
}

-- Income/sec for one worker entry (before upgrades/rebirth multipliers).
function GameConfig.getWorkerIncome(rarityId: string, crateId: string): number
	local rarity = raritiesById[rarityId]
	local crate = GameConfig.WorkerCrates[crateId]
	if not rarity or not crate then
		return 0
	end
	return rarity.IncomePerSec * crate.Multiplier
end

----------------------------------------------------------------------
-- Upgrades (reset on rebirth). cost = BaseCost * CostMultiplier ^ level
----------------------------------------------------------------------

export type UpgradeDef = {
	Id: string,
	Name: string,
	Description: string,
	BaseCost: number,
	CostMultiplier: number,
	MaxLevel: number,
}

GameConfig.Upgrades = {
	HustlePower = {
		Id = "HustlePower",
		Name = "Hustle Power",
		Description = "+25% cash per hustle, per level",
		BaseCost = 100,
		CostMultiplier = 1.5,
		MaxLevel = 25,
	},
	WorkerEfficiency = {
		Id = "WorkerEfficiency",
		Name = "Worker Hustle",
		Description = "+20% worker income, per level",
		BaseCost = 250,
		CostMultiplier = 1.5,
		MaxLevel = 25,
	},
	WalkSpeed = {
		Id = "WalkSpeed",
		Name = "Fast Shoes",
		Description = "+1 walk speed, per level",
		BaseCost = 500,
		CostMultiplier = 2,
		MaxLevel = 8,
	},
	WorkerSlots = {
		Id = "WorkerSlots",
		Name = "Worker Slot",
		Description = "+1 equipped worker, per level",
		BaseCost = 25000,
		CostMultiplier = 8,
		MaxLevel = 3,
	},
} :: { [string]: UpgradeDef }

function GameConfig.getUpgradeCost(upgradeId: string, currentLevel: number): number?
	local def = GameConfig.Upgrades[upgradeId]
	if not def or currentLevel >= def.MaxLevel then
		return nil
	end
	return math.floor(def.BaseCost * def.CostMultiplier ^ currentLevel)
end

-- Multiplier contributions (used by HustleService / WorkerService)
GameConfig.HustlePowerPerLevel = 0.25
GameConfig.WorkerEfficiencyPerLevel = 0.2
GameConfig.BaseWalkSpeed = 16

----------------------------------------------------------------------
-- Rebirth
----------------------------------------------------------------------

GameConfig.Rebirth = {
	BaseRequirement = 25000, -- CashThisLife needed for first rebirth
	RequirementMultiplier = 4, -- requirement = Base * Mult ^ Rebirths
	BonusPerRebirth = 0.5, -- rebirthMult = 1 + Bonus * Rebirths
	MaxRebirths = 100,
}

function GameConfig.getRebirthRequirement(rebirths: number): number
	return math.floor(GameConfig.Rebirth.BaseRequirement * GameConfig.Rebirth.RequirementMultiplier ^ rebirths)
end

function GameConfig.getRebirthMultiplier(rebirths: number): number
	return 1 + GameConfig.Rebirth.BonusPerRebirth * rebirths
end

----------------------------------------------------------------------
-- Quests: one-time, progress read from lifetime Stats (survive rebirth).
-- Stat must be one of: HustleCount, TotalCashEarned, WorkersHired,
-- ZonesUnlockedCount, TotalRebirths.
----------------------------------------------------------------------

export type QuestDef = {
	Id: string,
	Name: string,
	Description: string,
	Stat: string,
	Target: number,
	Reward: number, -- cash
}

GameConfig.Quests = {
	{ Id = "FirstSqueeze", Name = "First Squeeze", Description = "Do 10 hustles", Stat = "HustleCount", Target = 10, Reward = 100 },
	{ Id = "Grinder", Name = "Grinder", Description = "Do 100 hustles", Stat = "HustleCount", Target = 100, Reward = 1000 },
	{ Id = "HustleMachine", Name = "Hustle Machine", Description = "Do 1,000 hustles", Stat = "HustleCount", Target = 1000, Reward = 25000 },
	{ Id = "FirstGrand", Name = "First Grand", Description = "Earn $1,000 total", Stat = "TotalCashEarned", Target = 1000, Reward = 250 },
	{ Id = "SixFigures", Name = "Six Figures", Description = "Earn $100,000 total", Stat = "TotalCashEarned", Target = 100000, Reward = 10000 },
	{ Id = "Millionaire", Name = "Millionaire", Description = "Earn $1,000,000 total", Stat = "TotalCashEarned", Target = 1000000, Reward = 100000 },
	{ Id = "FirstHire", Name = "First Hire", Description = "Hire a worker", Stat = "WorkersHired", Target = 1, Reward = 200 },
	{ Id = "TeamBuilder", Name = "Team Builder", Description = "Hire 10 workers", Stat = "WorkersHired", Target = 10, Reward = 5000 },
	{ Id = "Corporation", Name = "Corporation", Description = "Hire 25 workers", Stat = "WorkersHired", Target = 25, Reward = 100000 },
	{ Id = "NewVenture", Name = "New Venture", Description = "Unlock 3 hustles", Stat = "ZonesUnlockedCount", Target = 3, Reward = 2000 },
	{ Id = "Mogul", Name = "Mogul", Description = "Unlock every hustle", Stat = "ZonesUnlockedCount", Target = 8, Reward = 500000 },
	{ Id = "BornAgain", Name = "Born Again", Description = "Rebirth once", Stat = "TotalRebirths", Target = 1, Reward = 50000 },
} :: { QuestDef }

local questsById: { [string]: QuestDef } = {}
for _, quest in GameConfig.Quests do
	questsById[quest.Id] = quest
end

function GameConfig.getQuest(questId: string): QuestDef?
	return questsById[questId]
end

----------------------------------------------------------------------
-- Data persistence
----------------------------------------------------------------------

GameConfig.Data = {
	StoreName = "SideHustleData_v1",
	SaveInterval = 120, -- seconds
	LockTimeout = 120, -- seconds before a foreign session lock is considered dead
	LockRefreshInterval = 60,
}

function GameConfig.Data.Defaults(): { [string]: any }
	return {
		DataVersion = 1,
		Cash = 0,
		CashThisLife = 0,
		Rebirths = 0,
		UnlockedZones = { GameConfig.StartingZoneId },
		Upgrades = {
			HustlePower = 0,
			WorkerEfficiency = 0,
			WalkSpeed = 0,
			WorkerSlots = 0,
		},
		Workers = {},
		Stats = {
			HustleCount = 0,
			TotalCashEarned = 0,
			WorkersHired = 0,
			ZonesUnlockedCount = 1,
			TotalRebirths = 0,
			PlayTime = 0,
		},
		ClaimedQuests = {},
		LastSeen = 0,
	}
end

----------------------------------------------------------------------
-- Sounds: asset ids the user uploads/sources themselves.
-- Leave "" to disable a sound; ClientEffects.playSound no-ops on "".
-- TODO(user): paste your sound asset ids, e.g. "rbxassetid://123456789"
----------------------------------------------------------------------

GameConfig.Sounds = {
	Coin = "", -- TODO: short coin "cha-ching" for every hustle/earn
	Buy = "", -- TODO: purchase confirm
	Error = "", -- TODO: soft "nope" for failed actions
	LevelUp = "", -- TODO: upgrade purchased sparkle sound
	Hire = "", -- TODO: crate open / worker hired
	Rebirth = "", -- TODO: big celebration fanfare
	Click = "", -- TODO: UI button click
}

return GameConfig
