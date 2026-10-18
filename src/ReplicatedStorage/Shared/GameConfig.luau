--!strict
-- GameConfig (v2): single source of truth for ALL game tuning.
-- Server and client both read this. Balance lives here, logic lives in services.

local GameConfig = {}

----------------------------------------------------------------------
-- Map constants (MapBuilder and Mechanics.zoneCenter must agree)
----------------------------------------------------------------------

GameConfig.Map = {
	ZoneRadius = 150, -- distance of each zone center from the plaza origin
	ZoneAngleStep = 45, -- degrees between zones around the ring
}

----------------------------------------------------------------------
-- Upgrade effects (per-zone upgrades reference these by Effect)
----------------------------------------------------------------------

GameConfig.UpgradeEffects = {
	Earn = { PerLevel = 0.25 }, -- +25% cash per level
	Xp = { PerLevel = 0.2 }, -- +20% XP per level
	Speed = { PerLevel = 0.08, MinCooldownFactor = 0.5 }, -- -8% cooldown per level, floor 50%
	Auto = { Interval = 2, BasePercent = 0.4, PercentPerLevel = 0.25 }, -- auto hustle every 2s
}

----------------------------------------------------------------------
-- Mechanic parameters
----------------------------------------------------------------------

GameConfig.Mechanics = {
	Tap = { ComboWindow = 1.8, ComboMax = 10, ComboBonusPerStack = 0.1 }, -- up to x2
	Hold = { PayoutMult = 1 }, -- payout is tuned via HustleEarn; hold just paces it
	Timing = { MinMult = 0.5, MaxMult = 1.5, PeakThreshold = 1.35, PeakXpBonus = 1.0 },
	Charge = { HitPercent = 0.3, BurstMult = 1.5, BurstXpBonus = 2.0 },
}

----------------------------------------------------------------------
-- Zones (ordered). Each has a mechanic, level gate and 4 unique upgrades
-- (Effects: Earn, Xp, Speed, Auto). Costs scale with the zone's earn.
----------------------------------------------------------------------

export type ZoneUpgradeDef = {
	Id: string,
	Name: string,
	Description: string,
	Effect: string, -- "Earn" | "Xp" | "Speed" | "Auto"
	BaseCost: number,
	CostMultiplier: number,
	MaxLevel: number,
}

export type ZoneDef = {
	Id: string,
	Name: string,
	Order: number,
	UnlockLevel: number,
	Mechanic: string, -- "Tap" | "Hold" | "Timing" | "Charge"
	HustleEarn: number, -- base cash per manual action (before mechanic/upgrades)
	XpPerHustle: number, -- base XP per manual action
	HustleCooldown: number, -- seconds (reduced by the Speed upgrade)
	HoldDuration: number, -- Hold zones only (0 otherwise)
	MarketPeriod: number, -- Timing zones only (seconds per hype cycle)
	ChargeMax: number, -- Charge zones only (hits per burst)
	SignColor: Color3,
	AccentColor: Color3,
	HustleVerb: string,
	Tagline: string, -- mechanic hint shown in HustleGui
	Upgrades: { ZoneUpgradeDef },
}

local function upgrades(earn: number, defs: { { string } }, autoCostMult: number?): { ZoneUpgradeDef }
	-- defs: { {Id, Name, Description}, ... } in Effect order Earn, Xp, Speed, Auto
	local effects = { "Earn", "Xp", "Speed", "Auto" }
	local baseMult = { Earn = 40, Xp = 30, Speed = 60, Auto = 250 }
	local costMult = { Earn = 1.6, Xp = 1.6, Speed = 1.8, Auto = autoCostMult or 2.2 }
	local maxLevel = { Earn = 10, Xp = 10, Speed = 5, Auto = 5 }
	local result = {}
	for index, def in defs do
		local effect = effects[index]
		table.insert(result, {
			Id = def[1],
			Name = def[2],
			Description = def[3],
			Effect = effect,
			BaseCost = math.floor(earn * baseMult[effect]),
			CostMultiplier = costMult[effect],
			MaxLevel = maxLevel[effect],
		})
	end
	return result
end

GameConfig.Zones = {
	{
		Id = "LemonadeStand",
		Name = "Lemonade Stand",
		Order = 1,
		UnlockLevel = 1,
		Mechanic = "Tap",
		HustleEarn = 3,
		XpPerHustle = 2,
		HustleCooldown = 0.6,
		HoldDuration = 0,
		MarketPeriod = 0,
		ChargeMax = 0,
		SignColor = Color3.fromRGB(255, 212, 31),
		AccentColor = Color3.fromRGB(255, 240, 120),
		HustleVerb = "Squeeze",
		Tagline = "Mash SQUEEZE to build a combo!",
		Upgrades = upgrades(3, {
			{ "BiggerPitcher", "Bigger Pitcher", "+25% cash per squeeze" },
			{ "ExtraSugar", "Extra Sugar", "+20% XP per squeeze" },
			{ "IceCold", "Ice Cold", "-8% squeeze cooldown" },
			{ "AutoSqueezer", "Auto-Squeezer", "A robot arm squeezes for you every 2s" },
		}),
	},
	{
		Id = "DogWalking",
		Name = "Dog Walking",
		Order = 2,
		UnlockLevel = 4,
		Mechanic = "Hold",
		HustleEarn = 60,
		XpPerHustle = 7,
		HustleCooldown = 2,
		HoldDuration = 1.2,
		MarketPeriod = 0,
		ChargeMax = 0,
		SignColor = Color3.fromRGB(88, 190, 72),
		AccentColor = Color3.fromRGB(150, 230, 120),
		HustleVerb = "Walk",
		Tagline = "Hold to walk the whole pack - big payouts, slow and steady.",
		Upgrades = upgrades(60, {
			{ "ExtraLeash", "Extra Leash", "+25% cash per walk" },
			{ "TreatPouch", "Treat Pouch", "+20% XP per walk" },
			{ "ComfySneakers", "Comfy Sneakers", "-8% walk cooldown" },
			{ "DogSitter", "Dog Sitter", "A sitter walks the dogs for you every 2s" },
		}),
	},
	{
		Id = "SneakerFlipping",
		Name = "Sneaker Street",
		Order = 3,
		UnlockLevel = 8,
		Mechanic = "Timing",
		HustleEarn = 85,
		XpPerHustle = 8,
		HustleCooldown = 1.5,
		HoldDuration = 0,
		MarketPeriod = 6,
		ChargeMax = 0,
		SignColor = Color3.fromRGB(128, 115, 255),
		AccentColor = Color3.fromRGB(180, 160, 255),
		HustleVerb = "Flip",
		Tagline = "Watch the hype meter - flip when it peaks!",
		Upgrades = upgrades(85, {
			{ "HypeDrops", "Hype Drops", "+25% cash per flip" },
			{ "SneakerheadNetwork", "Sneakerhead Network", "+20% XP per flip" },
			{ "FastListings", "Fast Listings", "-8% flip cooldown" },
			{ "ResellerBot", "Reseller Bot", "A bot flips pairs for you every 2s" },
		}),
	},
	{
		Id = "CarWash",
		Name = "Car Wash",
		Order = 4,
		UnlockLevel = 13,
		Mechanic = "Hold",
		HustleEarn = 600,
		XpPerHustle = 30,
		HustleCooldown = 2,
		HoldDuration = 1.2,
		MarketPeriod = 0,
		ChargeMax = 0,
		SignColor = Color3.fromRGB(64, 200, 224),
		AccentColor = Color3.fromRGB(140, 230, 255),
		HustleVerb = "Scrub",
		Tagline = "Hold to scrub the whole car clean.",
		Upgrades = upgrades(600, {
			{ "FoamCannon", "Foam Cannon", "+25% cash per scrub" },
			{ "WaxFinish", "Wax Finish", "+20% XP per scrub" },
			{ "PowerWasher", "Power Washer", "-8% scrub cooldown" },
			{ "ConveyorTunnel", "Conveyor Tunnel", "The tunnel washes cars for you every 2s" },
		}),
	},
	{
		Id = "FoodTruck",
		Name = "Food Truck",
		Order = 5,
		UnlockLevel = 19,
		Mechanic = "Tap",
		HustleEarn = 350,
		XpPerHustle = 27,
		HustleCooldown = 0.6,
		HoldDuration = 0,
		MarketPeriod = 0,
		ChargeMax = 0,
		SignColor = Color3.fromRGB(255, 123, 34),
		AccentColor = Color3.fromRGB(247, 55, 92),
		HustleVerb = "Grill",
		Tagline = "Mash GRILL to keep the orders flying!",
		Upgrades = upgrades(350, {
			{ "DoublePatty", "Double Patty", "+25% cash per order" },
			{ "SecretSauce", "Secret Sauce", "+20% XP per order" },
			{ "FlatTopGrill", "Flat-Top Grill", "-8% grill cooldown" },
			{ "FryCookCrew", "Fry Cook Crew", "A crew grills orders for you every 2s" },
		}),
	},
	{
		Id = "ContentCreator",
		Name = "Creator Studio",
		Order = 6,
		UnlockLevel = 26,
		Mechanic = "Charge",
		HustleEarn = 900,
		XpPerHustle = 43,
		HustleCooldown = 0.8,
		HoldDuration = 0,
		MarketPeriod = 0,
		ChargeMax = 5,
		SignColor = Color3.fromRGB(255, 92, 180),
		AccentColor = Color3.fromRGB(255, 160, 220),
		HustleVerb = "Stream",
		Tagline = "Fill the hype bar to GO VIRAL!",
		Upgrades = upgrades(900, {
			{ "RingLightPro", "Ring Light Pro", "+25% cash per stream" },
			{ "ViralEditing", "Viral Editing", "+20% XP per stream" },
			{ "StreamDeck", "Stream Deck", "-8% stream cooldown" },
			{ "ContentScheduler", "Content Scheduler", "Scheduled posts earn for you every 2s" },
		}),
	},
	{
		Id = "StockDesk",
		Name = "Stock Desk",
		Order = 7,
		UnlockLevel = 34,
		Mechanic = "Timing",
		HustleEarn = 8000,
		XpPerHustle = 980,
		HustleCooldown = 1.5,
		HoldDuration = 0,
		MarketPeriod = 4,
		ChargeMax = 0,
		SignColor = Color3.fromRGB(32, 200, 96),
		AccentColor = Color3.fromRGB(8, 12, 10),
		HustleVerb = "Trade",
		Tagline = "Buy low, sell high - trade when the ticker peaks!",
		Upgrades = upgrades(8000, {
			{ "InsiderNewsletter", "Insider Newsletter", "+25% cash per trade" },
			{ "MarketAnalyst", "Market Analyst", "+20% XP per trade" },
			{ "HotkeyTrading", "Hotkey Trading", "-8% trade cooldown" },
			{ "AlgoTrader", "Algo Trader", "An algorithm trades for you every 2s" },
		}),
	},
	{
		Id = "StartupHQ",
		Name = "Startup HQ",
		Order = 8,
		UnlockLevel = 43,
		Mechanic = "Charge",
		HustleEarn = 11000,
		XpPerHustle = 1000,
		HustleCooldown = 0.8,
		HoldDuration = 0,
		MarketPeriod = 0,
		ChargeMax = 5,
		SignColor = Color3.fromRGB(240, 246, 255),
		AccentColor = Color3.fromRGB(60, 130, 255),
		HustleVerb = "Pitch",
		Tagline = "Pitch investors until the round is FUNDED!",
		Upgrades = upgrades(11000, {
			{ "PitchDeck2", "Pitch Deck 2.0", "+25% cash per pitch" },
			{ "VentureNetwork", "Venture Network", "+20% XP per pitch" },
			{ "CoffeeIVDrip", "Coffee IV Drip", "-8% pitch cooldown" },
			{ "CoFounder", "Co-Founder", "Your co-founder pitches for you every 2s" },
		}),
	},
} :: { ZoneDef }

local zonesById: { [string]: ZoneDef } = {}
local zoneUpgradesById: { [string]: { [string]: ZoneUpgradeDef } } = {}
local zoneUpgradesByEffect: { [string]: { [string]: ZoneUpgradeDef } } = {}
for _, zone in GameConfig.Zones do
	zonesById[zone.Id] = zone
	zoneUpgradesById[zone.Id] = {}
	zoneUpgradesByEffect[zone.Id] = {}
	for _, upgrade in zone.Upgrades do
		zoneUpgradesById[zone.Id][upgrade.Id] = upgrade
		zoneUpgradesByEffect[zone.Id][upgrade.Effect] = upgrade
	end
end

GameConfig.StartingZoneId = "LemonadeStand"

function GameConfig.getZone(zoneId: string): ZoneDef?
	return zonesById[zoneId]
end

function GameConfig.getZoneUpgrade(zoneId: string, upgradeId: string): ZoneUpgradeDef?
	local byId = zoneUpgradesById[zoneId]
	return if byId then byId[upgradeId] else nil
end

function GameConfig.getZoneUpgradeByEffect(zoneId: string, effect: string): ZoneUpgradeDef?
	local byEffect = zoneUpgradesByEffect[zoneId]
	return if byEffect then byEffect[effect] else nil
end

-- cost = BaseCost * CostMultiplier ^ currentLevel; nil when maxed/unknown
function GameConfig.getZoneUpgradeCost(zoneId: string, upgradeId: string, currentLevel: number): number?
	local def = GameConfig.getZoneUpgrade(zoneId, upgradeId)
	if not def or currentLevel >= def.MaxLevel then
		return nil
	end
	return math.floor(def.BaseCost * def.CostMultiplier ^ currentLevel)
end

-- Level of a zone upgrade from a data table (missing -> 0).
function GameConfig.getZoneUpgradeLevel(upgradesTable: any, zoneId: string, upgradeId: string): number
	if typeof(upgradesTable) ~= "table" then
		return 0
	end
	local zoneTable = upgradesTable[zoneId]
	if typeof(zoneTable) ~= "table" then
		return 0
	end
	local level = zoneTable[upgradeId]
	return if typeof(level) == "number" then level else 0
end

-- Level of the upgrade with the given Effect in a zone (missing -> 0).
function GameConfig.getZoneEffectLevel(upgradesTable: any, zoneId: string, effect: string): number
	local def = GameConfig.getZoneUpgradeByEffect(zoneId, effect)
	if not def then
		return 0
	end
	return GameConfig.getZoneUpgradeLevel(upgradesTable, zoneId, def.Id)
end

-- The zone that becomes available exactly at this level (nil if none).
function GameConfig.getZoneUnlockedAtLevel(level: number): ZoneDef?
	for _, zone in GameConfig.Zones do
		if zone.UnlockLevel == level then
			return zone
		end
	end
	return nil
end

function GameConfig.isZoneUnlockedAtLevel(zoneId: string, level: number): boolean
	local zone = zonesById[zoneId]
	return zone ~= nil and level >= zone.UnlockLevel
end

----------------------------------------------------------------------
-- Levels: xp needed to go from `level` to `level + 1`
----------------------------------------------------------------------

GameConfig.Levels = {
	MaxLevel = 100,
	BaseXp = 50,
	Growth = 1.22,
}

function GameConfig.getXpForLevel(level: number): number
	return math.floor(GameConfig.Levels.BaseXp * GameConfig.Levels.Growth ^ (level - 1))
end

----------------------------------------------------------------------
-- Perks (global, bought with cash, reset on rebirth)
----------------------------------------------------------------------

export type PerkDef = {
	Id: string,
	Name: string,
	Description: string,
	BaseCost: number,
	CostMultiplier: number,
	MaxLevel: number,
}

GameConfig.Perks = {
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
	WorkerEfficiency = {
		Id = "WorkerEfficiency",
		Name = "Worker Hustle",
		Description = "+20% worker income, per level",
		BaseCost = 250,
		CostMultiplier = 1.5,
		MaxLevel = 25,
	},
} :: { [string]: PerkDef }

GameConfig.PerkOrder = { "WalkSpeed", "WorkerSlots", "WorkerEfficiency" }

function GameConfig.getPerkCost(perkId: string, currentLevel: number): number?
	local def = GameConfig.Perks[perkId]
	if not def or currentLevel >= def.MaxLevel then
		return nil
	end
	return math.floor(def.BaseCost * def.CostMultiplier ^ currentLevel)
end

GameConfig.WorkerEfficiencyPerLevel = 0.2
GameConfig.BaseWalkSpeed = 16

----------------------------------------------------------------------
-- Workers: cute chibi companions whose props show their rarity.
----------------------------------------------------------------------

export type RarityDef = {
	Id: string,
	Name: string,
	IncomePerSec: number,
	Color: Color3,
	Prop: string, -- "CoffeeCup" | "None" | "Clipboard" | "GoldSuit"
}

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
	Multiplier: number,
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

GameConfig.CrateOrder = { "StarterCrate", "ProCrate", "EliteCrate" }

GameConfig.WorkerNames = {
	"Benny", "Pixel", "Mo", "Greta", "Ziggy", "Luna", "Chip", "Olive",
	"Rocco", "Daisy", "Felix", "Wanda", "Gus", "Penny", "Sunny", "Bram",
	"Coco", "Milo", "Trixie", "Alfie", "Nova", "Biscuit", "Pepper", "Scout",
}

GameConfig.Workers = {
	BaseEquipSlots = 3, -- + WorkerSlots perk level
	MaxStorage = 50,
	IncomeTickSeconds = 1,
}

function GameConfig.getWorkerIncome(rarityId: string, crateId: string): number
	local rarity = raritiesById[rarityId]
	local crate = GameConfig.WorkerCrates[crateId]
	if not rarity or not crate then
		return 0
	end
	return rarity.IncomePerSec * crate.Multiplier
end

----------------------------------------------------------------------
-- Rebirth (level-gated)
----------------------------------------------------------------------

GameConfig.Rebirth = {
	RequiredLevel = 50,
	CashBonusPerRebirth = 0.5, -- cash x(1 + 0.5n)
	XpBonusPerRebirth = 0.25, -- xp x(1 + 0.25n)
	MaxRebirths = 100,
}

function GameConfig.getRebirthCashMultiplier(rebirths: number): number
	return 1 + GameConfig.Rebirth.CashBonusPerRebirth * rebirths
end

function GameConfig.getRebirthXpMultiplier(rebirths: number): number
	return 1 + GameConfig.Rebirth.XpBonusPerRebirth * rebirths
end

----------------------------------------------------------------------
-- Quests: one-time, progress read from lifetime Stats (survive rebirth).
-- Stat must be one of: HustleCount, AutoHustleCount, TotalCashEarned,
-- WorkersHired, HighestLevel, TotalRebirths.
----------------------------------------------------------------------

export type QuestDef = {
	Id: string,
	Name: string,
	Description: string,
	Stat: string,
	Target: number,
	Reward: number,
}

GameConfig.Quests = {
	{ Id = "FirstSqueeze", Name = "First Squeeze", Description = "Do 10 hustles", Stat = "HustleCount", Target = 10, Reward = 50 },
	{ Id = "Grinder", Name = "Grinder", Description = "Do 100 hustles", Stat = "HustleCount", Target = 100, Reward = 1000 },
	{ Id = "HustleMachine", Name = "Hustle Machine", Description = "Do 1,000 hustles", Stat = "HustleCount", Target = 1000, Reward = 25000 },
	{ Id = "FirstGrand", Name = "First Grand", Description = "Earn $1,000 total", Stat = "TotalCashEarned", Target = 1000, Reward = 250 },
	{ Id = "SixFigures", Name = "Six Figures", Description = "Earn $100,000 total", Stat = "TotalCashEarned", Target = 100000, Reward = 10000 },
	{ Id = "Millionaire", Name = "Millionaire", Description = "Earn $1,000,000 total", Stat = "TotalCashEarned", Target = 1000000, Reward = 100000 },
	{ Id = "FirstHire", Name = "First Hire", Description = "Hire a worker", Stat = "WorkersHired", Target = 1, Reward = 200 },
	{ Id = "TeamBuilder", Name = "Team Builder", Description = "Hire 10 workers", Stat = "WorkersHired", Target = 10, Reward = 5000 },
	{ Id = "Corporation", Name = "Corporation", Description = "Hire 25 workers", Stat = "WorkersHired", Target = 25, Reward = 100000 },
	{ Id = "LevelFive", Name = "Getting Started", Description = "Reach level 5", Stat = "HighestLevel", Target = 5, Reward = 500 },
	{ Id = "Climber", Name = "Climber", Description = "Reach level 20", Stat = "HighestLevel", Target = 20, Reward = 20000 },
	{ Id = "Mogul", Name = "Mogul", Description = "Unlock every hustle (level 43)", Stat = "HighestLevel", Target = 43, Reward = 500000 },
	{ Id = "Automated", Name = "Automated", Description = "100 automated hustles", Stat = "AutoHustleCount", Target = 100, Reward = 5000 },
	{ Id = "HandsFree", Name = "Hands Free", Description = "2,000 automated hustles", Stat = "AutoHustleCount", Target = 2000, Reward = 200000 },
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
-- Data persistence (v2 schema)
----------------------------------------------------------------------

GameConfig.Data = {
	Version = 2,
	StoreName = "SideHustleData_v2",
	SaveInterval = 120,
	LockTimeout = 120,
	LockRefreshInterval = 60,
}

function GameConfig.Data.Defaults(): { [string]: any }
	local upgradesByZone = {}
	for _, zone in GameConfig.Zones do
		upgradesByZone[zone.Id] = {}
	end
	return {
		DataVersion = GameConfig.Data.Version,
		Cash = 0,
		Level = 1,
		Xp = 0,
		Rebirths = 0,
		Upgrades = upgradesByZone,
		Perks = {
			WalkSpeed = 0,
			WorkerSlots = 0,
			WorkerEfficiency = 0,
		},
		Workers = {},
		Stats = {
			HustleCount = 0,
			AutoHustleCount = 0,
			TotalCashEarned = 0,
			WorkersHired = 0,
			HighestLevel = 1,
			TotalRebirths = 0,
			PlayTime = 0,
		},
		ClaimedQuests = {},
		LastSeen = 0,
	}
end

----------------------------------------------------------------------
-- Sounds: asset ids the user sources themselves. Leave "" to disable;
-- ClientEffects.playSound no-ops on "". TODO(user): paste rbxassetid://... ids.
----------------------------------------------------------------------

GameConfig.Sounds = {
	Coin = "",
	Buy = "",
	Error = "",
	LevelUp = "",
	Hire = "",
	Rebirth = "",
	Click = "",
	Combo = "",
	Burst = "",
}

return GameConfig
