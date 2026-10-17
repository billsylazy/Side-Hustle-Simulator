--!strict
-- Shared type definitions (v2). See ARCHITECTURE.md "Data schema v2".

export type WorkerEntry = {
	Uid: string,
	Id: string, -- currently the rarity id
	Rarity: string, -- "Intern" | "Employee" | "Manager" | "CEO"
	Crate: string, -- crate id the worker was hired from
	Name: string,
	Equipped: boolean,
}

export type PlayerStats = {
	HustleCount: number,
	AutoHustleCount: number,
	TotalCashEarned: number,
	WorkersHired: number,
	HighestLevel: number,
	TotalRebirths: number,
	PlayTime: number,
}

export type PlayerData = {
	DataVersion: number,
	Cash: number,
	Level: number,
	Xp: number,
	Rebirths: number,
	Upgrades: { [string]: { [string]: number } }, -- zoneId -> upgradeId -> level
	Perks: { [string]: number },
	Workers: { WorkerEntry },
	Stats: PlayerStats,
	ClaimedQuests: { [string]: boolean },
	LastSeen: number,
}

export type HustleKind = "Manual" | "Auto" | "Burst" | "Peak"

export type HustleResultPayload = {
	Amount: number,
	Xp: number,
	Kind: HustleKind,
	Mult: number,
	Combo: number?,
	Charge: number?,
	ChargeMax: number?,
}

export type ToastKind = "error" | "info" | "success"

-- A ModuleScript must return exactly one non-nil value in Roblox.
return {}
