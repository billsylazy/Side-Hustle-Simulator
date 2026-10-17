# Side Hustle Simulator — Architecture Contract

This file is the binding contract between all modules. **Exact names matter**: remote
names, instance names, config keys and module APIs defined here must be used verbatim
by every script. If a script needs something not listed here, add it here first.

Visual direction comes from `docs/art-feel-guide.md` (bright, chunky, cartoony;
SmoothPlastic + Neon; every zone has a signature color; juice on every action).

## Project layout (Rojo)

```
default.project.json            -- Rojo 7 project; `rojo build -o build/SideHustleSimulator.rbxlx`
src/
  ReplicatedStorage/Shared/     -- ModuleScripts shared by server + client
    GameConfig.luau             -- ALL tuning: zones, workers, crates, upgrades, quests, rebirth, sounds
    Types.luau                  -- shared Luau types
    FormatNumber.luau           -- abbreviate(n) -> "1.2K", money(n) -> "$1.2K"
    ButtonFX.luau               -- ButtonFX.attach(button) press/hover bounce (client-only guard inside)
    ClientEffects.luau          -- client-only juice API (money popups, screen pop, sparkle, sounds, celebration)
  ServerScriptService/
    GameManager.server.luau     -- entry point: builds map, creates remotes, init/start all services
    Services/                   -- ModuleScripts, init(services)/start() dependency-injection pattern
      DataService.luau          -- persistence (session locking), cash mutation API, leaderstats, DataSync
      RemoteService.luau        -- remote creation + validation + rate limiting wrapper
      ZoneService.luau          -- zone unlock purchases (gate ProximityPrompts)
      HustleService.luau        -- hustle action handling (station ProximityPrompts), earnings math
      WorkerService.luau        -- crate hiring (weighted RNG), equip/unequip, passive income tick
      UpgradeService.luau       -- upgrade purchases + multiplier queries
      RebirthService.luau       -- rebirth validation, reset, multiplier
      QuestService.luau         -- quest progress (from Stats), claiming
    World/
      MapBuilder.luau           -- builds the whole map + lighting from primitives at server start
  StarterPlayerScripts/
    ClientMain.client.luau      -- client bootstrapper: requires/initializes controllers below
    Controllers/                -- ModuleScripts with .start()
      ZoneGateController.luau   -- local gate visuals/collision for unlocked zones
      WorkerVisualsController.luau -- renders local player's equipped workers as chibi rigs
      RebirthWatcher.luau       -- listens for RebirthResult SUCCESS -> full-screen celebration
ui/
  MainHUD/    ShopGui/    WorkersGui/    RebirthGui/    QuestsGui/
    <name>.spec.json + *.client.lua      -- roblox-ui-builder sources
    build/<Name>.rbxmx (+ checklist, previews)
build/SideHustleSimulator.rbxlx          -- one-click place file (committed)
```

Conventions: Luau type annotations where practical; `task.*` only (never `wait()`);
`pcall` around every DataStore call; `.Activated` for buttons; generalized iteration
(`for k, v in t do`); every `:Connect` that outlives a player is disconnected on
`PlayerRemoving`. **Never trust the client**: every client-triggered action is
validated server-side (type, existence, cost, cooldown, ownership).
No Toolbox assets; audio/image asset ids live in `GameConfig.Sounds` / UI icon
checklist as placeholders the user fills in. Guard: never play a Sound whose id is "".

## Service pattern

`GameManager.server.luau`:
1. `require` MapBuilder, call `MapBuilder.build()` (idempotent; builds `Workspace.SideHustleMap` + Lighting).
2. Create `ReplicatedStorage.Remotes` folder and every remote listed below (via RemoteService).
3. `require` all services; call `Service.init(services)` on each (dependency injection —
   no cross-requires between services), then `Service.start()` on each.
4. Connect PlayerAdded/PlayerRemoving (DataService load/unload, cleanup on every service
   exposing `cleanupPlayer(player)`), handle players already present, auto-save loop
   (`GameConfig.Data.SaveInterval`), `game:BindToClose` sync save.

Service module shape:
```lua
local FooService = {}
function FooService.init(services) ... end   -- stash injected deps; create nothing yet
function FooService.start() ... end          -- connect remotes/prompts, start loops
function FooService.cleanupPlayer(player) end -- optional; clear per-player state
return FooService
```
`services` table keys: `DataService, RemoteService, ZoneService, HustleService,
WorkerService, UpgradeService, RebirthService, QuestService`.

## Data schema (DataService)

DataStore name: `GameConfig.Data.StoreName` ("SideHustleData_v1"). Key: `"Player_" .. UserId`.

```lua
export type PlayerData = {
  DataVersion: number,          -- 1
  Cash: number,                 -- spendable; resets on rebirth
  CashThisLife: number,         -- earned since last rebirth; rebirth requirement reads this
  Rebirths: number,
  UnlockedZones: { string },    -- zone Ids; always contains "LemonadeStand"
  Upgrades: { [string]: number },-- upgradeId -> level (HustlePower, WorkerEfficiency, WalkSpeed, WorkerSlots)
  Workers: { WorkerEntry },     -- survive rebirth
  Stats: {                      -- lifetime, survive rebirth (quests read these)
    HustleCount: number, TotalCashEarned: number, WorkersHired: number,
    ZonesUnlockedCount: number, TotalRebirths: number, PlayTime: number,
  },
  ClaimedQuests: { [string]: boolean },
  LastSeen: number,
}
export type WorkerEntry = { Uid: string, Id: string, Rarity: string, Crate: string,
                            Name: string, Equipped: boolean }
```

**Session locking** (SE-1): stored value is `{ Data = PlayerData, Lock = { JobId: string,
Time: number }? }`. On load (UpdateAsync): if a foreign lock is younger than
`GameConfig.Data.LockTimeout` (120 s), retry up to 5× with 2 s waits, then kick
("Your data is still saving from another server — rejoin in a minute."). Otherwise
claim the lock. A 60 s loop refreshes `Lock.Time` for loaded players. Saves keep our
lock; the final save on leave/shutdown sets `Lock = nil`. Validate before every save
(numbers are numbers, no NaN/inf, Cash >= 0); skip the save if corrupt. Reconcile
loaded data against `GameConfig.Data.Defaults()` (fill missing keys recursively).

**Cash API** — the ONLY way any service changes cash:
- `DataService.getData(player): PlayerData?`
- `DataService.addCash(player, amount: number)` — adds to Cash, CashThisLife,
  Stats.TotalCashEarned; updates leaderstats; fires DataSync.
- `DataService.spendCash(player, amount: number): boolean` — false if insufficient;
  updates leaderstats; fires DataSync.
- `DataService.sync(player)` — fires `DataSync` to that player with a snapshot (see below).
- leaderstats: `Cash` (IntValue), `Rebirths` (IntValue), kept in sync by DataService.

## Remotes (ReplicatedStorage.Remotes — exact names)

Created by RemoteService at startup. C→S handlers go through RemoteService.register
(type validation + per-remote cooldown + rate limit + violation kick, as in the
rate-limit pattern: timestamps pruned over a 10 s window, kick after 5 violations).

| Name | Class | Direction | Payload |
|---|---|---|---|
| `DataSync` | RemoteEvent | S→C | `snapshot: PlayerData` (full table; sent on load and after every mutation) |
| `HustleResult` | RemoteEvent | S→C | `zoneId: string, amount: number` (client plays money popup + sound) |
| `Toast` | RemoteEvent | S→C | `message: string, kind: "error"\|"info"\|"success"` |
| `HireWorker` | RemoteEvent | C→S | `crateId: string` (cooldown 0.5 s) |
| `WorkerHired` | RemoteEvent | S→C | `worker: WorkerEntry` on success |
| `EquipWorker` | RemoteEvent | C→S | `workerUid: string` (cooldown 0.2 s) |
| `UnequipWorker` | RemoteEvent | C→S | `workerUid: string` (cooldown 0.2 s) |
| `BuyUpgrade` | RemoteEvent | C→S | `upgradeId: string` (cooldown 0.3 s) |
| `RequestRebirth` | RemoteEvent | C→S | none (cooldown 2 s) |
| `RebirthResult` | RemoteEvent | S→C | `"SUCCESS", newRebirths, newMultiplier` or `"INSUFFICIENT", requirement` |
| `ClaimQuest` | RemoteEvent | C→S | `questId: string` (cooldown 0.3 s) |

Hustling and zone unlocking use **ProximityPrompt.Triggered** (server-side, inherently
distance-checked) — no remotes. Server still re-validates distance (< 20 studs),
zone unlock state, cost and cooldown (`HustleCooldown` per zone, tracked per player).

## Earnings math

- Hustle: `floor(zone.HustleEarn * (1 + 0.25*HustlePowerLevel) * rebirthMult)`
- Worker income/sec: `sum(rarity.IncomePerSec * crate.Multiplier for equipped) *
  (1 + 0.2*WorkerEfficiencyLevel) * rebirthMult`, applied by a 1 s server tick
  (`DataService.addCash`). DataSync therefore fires ≥1/s per player — fine, keep
  snapshots plain tables.
- `rebirthMult = 1 + GameConfig.Rebirth.BonusPerRebirth * Rebirths` (RebirthService.getMultiplier).
- Equipped worker cap: `GameConfig.Workers.BaseEquipSlots + WorkerSlotsLevel`.
- WalkSpeed upgrade: humanoid WalkSpeed = 16 + level (applied server-side on spawn + purchase).
- Rebirth requirement: `GameConfig.Rebirth.BaseRequirement *
  GameConfig.Rebirth.RequirementMultiplier ^ Rebirths`, checked against **CashThisLife**.
  Rebirth resets: Cash, CashThisLife, UnlockedZones (back to LemonadeStand), Upgrades.
  Keeps: Workers (all unequip stays as-is), Stats, ClaimedQuests, Rebirths(+1).

## Map contract (MapBuilder → Workspace)

```
Workspace.SideHustleMap (Folder)
  Ground, Plaza (Model)                 -- central spawn plaza w/ SpawnLocation, ring road
  Zones (Folder)
    <ZoneId> (Model) for each of the 8 zones, attribute ZoneId = id
      Building/props…                   -- chunky oversized primitives, zone signature colors
      HustleStation (Model)
        PromptPart (Part, anchored) with ProximityPrompt "HustlePrompt"
          (ActionText "Hustle!", ObjectText zone.Name, HoldDuration 0, MaxActivationDistance 12)
      Gate (Model)                      -- only zones with UnlockCost > 0
        GateWall (Part, anchored, CanCollide true) -- blocks the zone entrance
        SignPart with BillboardGui showing "<zone.Name>\n$<cost> to unlock"
        PromptPart (Part) with ProximityPrompt "UnlockPrompt"
          (ActionText "Unlock", ObjectText "$<cost>", HoldDuration 0.5, MaxActivationDistance 10)
```
Zones are arranged in a ring around the plaza in `Order` (walkable, no obby).
MapBuilder also sets Lighting: bright day (ClockTime 12), soft shadows,
`ColorCorrectionEffect` Saturation 0.15, Brightness 2.5-3, warm ambient.
All parts: Anchored, SmoothPlastic (Neon for glowy accents/signs).

Gate behavior: server ZoneService listens to every UnlockPrompt (validates cash +
sequential order — previous zone must be unlocked). On unlock it fires DataSync;
**per-player gate state is client-side**: ZoneGateController watches DataSync and, for
unlocked zones, locally sets GateWall.CanCollide=false + Transparency 1 and hides the
prompt (server earnings checks make sneaking past gates pointless). It also disables
the local HustlePrompt for locked zones (`prompt.Enabled` is replicated per-player?
No — set `prompt.Enabled=false` locally by destroying/hiding is NOT possible client-side
for server objects; instead HustleService server-side just rejects hustles in locked
zones and fires a Toast "Unlock this zone first!").

## UI contract (StarterGui — exact ScreenGui names)

All built with roblox-ui-builder (specs under `ui/`). Style: pack look — FredokaOne
(LuckiestGuy titles), cream panels, #040435 strokes everywhere, pill counters,
UIScale bounce on open, `ScreenInsets: "CoreUISafeInsets"`.

- `MainHUD` (always on): top-center **cash pill** (green cash icon + amount bound to
  leaderstats.Cash with count-up tween + pop), under it a smaller **rebirth pill**
  (multiplier). Left-middle: vertical stack of 4 big ImageButtons named exactly
  `ShopButton`, `WorkersButton`, `RebirthButton`, `QuestsButton` — each toggles its
  panel's `ScreenGui.Enabled`. HUD controller also listens to `HustleResult` →
  `ClientEffects.moneyPopup(amount)` + screen pop, and `Toast` → toast label.
- `ShopGui` (Enabled=false): panel with two sections — **Upgrades** (4 cards, names =
  upgrade ids: `HustlePower`, `WorkerEfficiency`, `WalkSpeed`, `WorkerSlots`; each shows
  level/max, cost from GameConfig formula, BUY button → `BuyUpgrade`) and **Hire Crates**
  (3 cards, names = crate ids: `StarterCrate`, `ProCrate`, `EliteCrate`; show cost +
  rarity odds; HIRE button → `HireWorker`). Refreshes from DataSync.
- `WorkersGui` (Enabled=false): header "X/Y equipped", ScrollingFrame grid of owned
  workers cloned from a hidden `WorkerCardTemplate` card (shows name, rarity color,
  income/s, EQUIP/UNEQUIP button → `EquipWorker`/`UnequipWorker`). Refreshes from DataSync.
- `RebirthGui` (Enabled=false): current multiplier, next multiplier, progress bar
  CashThisLife/requirement, big REBIRTH button → `RequestRebirth` (disabled until met).
- `QuestsGui` (Enabled=false): ScrollingFrame list cloned from hidden `QuestRowTemplate`
  (name, desc, progress bar from Stats, reward, CLAIM button → `ClaimQuest`; claimed
  quests show a checkmark). Refreshes from DataSync.

Every panel: close button overhanging top-right; open bounce via UIScale inside Main;
`ButtonFX.attach` on every button. Panel controllers live INSIDE their ScreenGui
(LocalScripts, via spec `source_file`).

`ClientEffects` API (ReplicatedStorage/Shared, client-only):
`moneyPopup(amount: number)`, `screenPop()`, `sparkle(guiObject: GuiObject)`,
`playSound(name: string)` (no-op if GameConfig.Sounds[name] == ""),
`celebrate(rebirths: number)` (full-screen rebirth celebration).
