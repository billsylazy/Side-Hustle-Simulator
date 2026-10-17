--!strict
-- Shared type definitions. See ARCHITECTURE.md "Data schema".

export type WorkerEntry = {
	Uid: string,
	Id: string, -- reserved for future distinct worker characters; currently rarity id
	Rarity: string, -- "Intern" | "Employee" | "Manager" | "CEO"
	Crate: string, -- crate id the worker was hired from
	Name: string,
	Equipped: boolean,
}

export type PlayerStats = {
	HustleCount: number,
	TotalCashEarned: number,
	WorkersHired: number,
	ZonesUnlockedCount: number,
	TotalRebirths: number,
	PlayTime: number,
}

export type PlayerData = {
	DataVersion: number,
	Cash: number,
	CashThisLife: number,
	Rebirths: number,
	UnlockedZones: { string },
	Upgrades: { [string]: number },
	Workers: { WorkerEntry },
	Stats: PlayerStats,
	ClaimedQuests: { [string]: boolean },
	LastSeen: number,
}

export type ToastKind = "error" | "info" | "success"

return nil
