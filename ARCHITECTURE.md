# Side Hustle Simulator — Architecture Contract (v2)

This file is the binding contract between all modules. **Exact names matter**: remote
names, instance names, config keys and module APIs defined here must be used verbatim
by every script. If a script needs something not listed here, add it here first.

Visual direction: `docs/art-feel-guide.md` (bright, chunky, cartoony; one signature
color per zone; juice on every action). v2 raises the graphics bar with Future
lighting, atmosphere, terrain, materials and particles — still cartoony, never gritty.

## v2 at a glance (what changed from v1)

- **XP + levels** drive progression. Zones unlock at a `UnlockLevel`; cash gates are gone.
- **Per-hustle upgrades** with unique names per zone (3 boosts + 1 **automation** tier).
  Global upgrades became **Perks** (WalkSpeed, WorkerSlots, WorkerEfficiency).
- **Four hustle mechanics** (Tap combo, Hold, Market timing, Charge burst) so every zone
  plays differently — all resolved on the server.
- Rebirth requires `GameConfig.Rebirth.RequiredLevel`; it resets level/XP/cash/upgrades/perks.
- New `LevelService`, new `HustleGui`, new client controllers for automation rigs and
  station feedback. Data schema is v2 (fresh game; v1 saves are reset to defaults).

## Project layout (Rojo)

```
default.project.json            -- Rojo 7 project; `rojo build -o build/SideHustleSimulator.rbxlx`
src/
  ReplicatedStorage/Shared/     -- ModuleScripts shared by server + client
    GameConfig.luau             -- ALL tuning (zones, mechanics, upgrades, perks, levels, quests…)
    Types.luau                  -- shared Luau types
    FormatNumber.luau           -- abbreviate(n), money(n), commas(n)
    ButtonFX.luau               -- ButtonFX.attach(button) press/hover bounce (client-only)
    ClientEffects.luau          -- client juice API (see "ClientEffects API")
    ChibiRig.luau               -- builds a chibi worker Model from primitives (client-only use)
    Mechanics.luau              -- PURE helpers shared by server + client (market phase, level math)
  ServerScriptService/
    GameManager.server.luau     -- entry point: map, remotes, init/start all services
    Services/
      DataService.luau          -- persistence (session GUID locking), cash/XP mutation API, DataSync
      RemoteService.luau        -- remote creation + validation + rate limiting
      LevelService.luau         -- addXp, level-ups, zone unlock queries, LevelUp remote
      ZoneService.luau          -- isZoneUnlocked (level-based); nearest-zone helper
      HustleService.luau        -- the four mechanics, XP/cash grants, automation tick
      WorkerService.luau        -- crates, equip/unequip, passive worker income tick
      UpgradeService.luau       -- per-zone upgrades + perks purchases
      RebirthService.luau       -- rebirth validation/reset
      QuestService.luau         -- quest claiming
    World/
      MapBuilder.luau           -- builds the whole world + lighting/terrain at server start
  StarterPlayerScripts/
    ClientMain.client.luau      -- requires/starts every Controllers ModuleScript
    Controllers/
      ZoneGateController.luau   -- opens gates locally for zones unlocked by level
      WorkerVisualsController.luau   -- companion worker rigs following the player
      AutomationVisualsController.luau -- stationed chibi rigs at zones with automation > 0
      StationFeedbackController.luau   -- market needle / charge bar / combo billboards at stations;
                                          sole owner of the Burst/Peak callouts (HUD must not call them)
      RebirthWatcher.luau       -- RebirthResult SUCCESS -> celebration
ui/
  MainHUD/  HustleGui/  ShopGui/  WorkersGui/  RebirthGui/  QuestsGui/
    <name>.spec.json + *.client.lua ; build/<Name>.rbxmx (+ checklist, previews)
build/SideHustleSimulator.rbxlx
```

Conventions: Luau type annotations where practical; `task.*` only; `pcall` around every
DataStore call; `.Activated` for buttons; generalized iteration; connections that
outlive a player are disconnected on `PlayerRemoving`. **Never trust the client.**
No Toolbox assets; no `require(assetId)`; audio ids only from `GameConfig.Sounds`
(may be ""; never play a sound whose id is ""). Built-in `rbxasset://` textures
(default particle sparkle, default sky) are fine.

## Service pattern

`GameManager.server.luau`: `MapBuilder.build()` first → `RemoteService.init()` → require
all 9 services from `script.Parent.Services` → `init(services)` on each → `start()` on
each → PlayerAdded (`DataService.loadPlayer` + `sync`) / PlayerRemoving
(`DataService.unloadPlayer` + every `cleanupPlayer`) → players already present →
auto-save loop (`GameConfig.Data.SaveInterval`).

`services` keys: `DataService, RemoteService, LevelService, ZoneService, HustleService,
WorkerService, UpgradeService, RebirthService, QuestService`. Services never require
each other; dependencies come through `init(services)`.

## Data schema v2 (DataService)

DataStore name: `GameConfig.Data.StoreName` ("SideHustleData_v2"). Key `"Player_" .. UserId`.

```lua
export type PlayerData = {
  DataVersion: number,            -- 2
  Cash: number,
  Level: number,                  -- 1..GameConfig.Levels.MaxLevel
  Xp: number,                     -- progress within the current level
  Rebirths: number,
  Upgrades: { [string]: { [string]: number } }, -- zoneId -> upgradeId -> level
  Perks: { [string]: number },    -- WalkSpeed, WorkerSlots, WorkerEfficiency
  Workers: { WorkerEntry },       -- survive rebirth
  Stats: {                        -- lifetime; survive rebirth (quests read these)
    HustleCount: number, AutoHustleCount: number, TotalCashEarned: number,
    WorkersHired: number, HighestLevel: number, TotalRebirths: number, PlayTime: number,
  },
  ClaimedQuests: { [string]: boolean },
  LastSeen: number,
}
```
Zone unlock state is **derived**: `zone unlocked ⇔ data.Level >= zone.UnlockLevel`.

Session locking: stored value `{ Data, Lock = { JobId, SessionId, Time }? }`; ownership by
`SessionId`; foreign fresh lock → retry ×5 then kick; same-server rejoin waits for the
in-flight leave save; auto-saves never re-assert an ended session's lock; final save
clears the lock; `BindToClose` drains in-flight saves (25 s deadline). Reconcile loaded
data against `GameConfig.Data.Defaults()`; a stored `DataVersion ~= 2` is replaced by
defaults (fresh game, no live players).

**Mutation API** (the only way services change these fields):
- `DataService.getData(player)`, `getLoadedPlayers()`, `sync(player)`
- `addCash(player, amount)` → Cash + Stats.TotalCashEarned, leaderstats, DataSync
- `spendCash(player, amount): boolean`
- `LevelService.addXp(player, amount)` → handles level-ups (see below); the only XP writer
- Rebirth reset carve-out: RebirthService may assign fields directly, then `DataService.sync`.
- leaderstats: `Cash`, `Level`, `Rebirths` (IntValues) kept in sync by DataService.sync.

## Remotes (ReplicatedStorage.Remotes — exact names)

| Name | Dir | Payload |
|---|---|---|
| `DataSync` | S→C | `snapshot: PlayerData` (on load and after every mutation; ≥1/s) |
| `HustleResult` | S→C | `zoneId: string, result: HustleResultPayload` (below) |
| `LevelUp` | S→C | `newLevel: number, unlockedZoneId: string?` (zone whose UnlockLevel == newLevel) |
| `Toast` | S→C | `message: string, kind: "error"\|"info"\|"success"` |
| `HireWorker` | C→S | `crateId: string` (cooldown 0.5) |
| `WorkerHired` | S→C | `worker: WorkerEntry` |
| `EquipWorker` / `UnequipWorker` | C→S | `workerUid: string` (cooldown 0.2) |
| `BuyUpgrade` | C→S | `zoneId: string, upgradeId: string` (cooldown 0.25) |
| `BuyPerk` | C→S | `perkId: string` (cooldown 0.3) |
| `RequestRebirth` | C→S | none (cooldown 2) |
| `RebirthResult` | S→C | `"SUCCESS", newRebirths, cashMult` or `"INSUFFICIENT", requiredLevel` |
| `ClaimQuest` | C→S | `questId: string` (cooldown 0.3) |

```lua
export type HustleResultPayload = {
  Amount: number,        -- cash granted (0 allowed for a Charge hit with no payout)
  Xp: number,
  Kind: "Manual" | "Auto" | "Burst" | "Peak",  -- Burst = charge completed, Peak = timing peak
  Mult: number,          -- effective multiplier shown to the player (combo/market), 1 if n/a
  Combo: number?,        -- Tap zones: current combo stack (0..ComboMax)
  Charge: number?,       -- Charge zones: current charge after this hit (0 after a burst)
  ChargeMax: number?,
}
```
Hustling uses **ProximityPrompt.Triggered** (server-side). Server re-validates: data
loaded, zone unlocked by level, distance < 20 studs, per-zone cooldown.

## Earnings, XP and mechanics (HustleService)

Per zone: `base = zone.HustleEarn`, `xpBase = zone.XpPerHustle`. Upgrade levels
`U = data.Upgrades[zoneId]` (missing → 0). Effects (`GameConfig.UpgradeEffects`):
- `earnMult = 1 + Earn.PerLevel * U[<Earn upgrade>]`, `xpMult = 1 + Xp.PerLevel * U[<Xp upgrade>]`
- `cooldown = zone.HustleCooldown * max(Speed.MinCooldownFactor, 1 - Speed.PerLevel * U[<Speed>])`
- `rebirthCash = GameConfig.getRebirthCashMultiplier(Rebirths)`, `rebirthXp = GameConfig.getRebirthXpMultiplier(Rebirths)`
- `manualCash = floor(base * earnMult * mechMult * rebirthCash)`, `manualXp = floor(xpBase * xpMult * mechXpMult * rebirthXp)`

Each zone's upgrades are found by `Effect` via `GameConfig.getZoneUpgradeByEffect(zoneId, effect)`.

Mechanics (`zone.Mechanic`, params in `GameConfig.Mechanics`):
- **Tap** (LemonadeStand, FoodTruck): server tracks per-player per-zone `lastHit` and `combo`.
  Trigger within `ComboWindow` of the last accepted hit → `combo = min(combo+1, ComboMax)`,
  else `combo = 0`. `mechMult = 1 + ComboBonusPerStack * combo`. Kind "Manual", Combo sent.
- **Hold** (DogWalking, CarWash): prompt `HoldDuration = zone.HoldDuration`; one hit per
  hold; `mechMult = Hold.PayoutMult` (bigger, slower). Kind "Manual".
- **Timing** (SneakerFlipping, StockDesk): shared clock —
  `Mechanics.marketFactor(zone, workspace:GetServerTimeNow())` ∈ [0,1] (sine over
  `zone.MarketPeriod`). `mechMult = Timing.MinMult + (Timing.MaxMult - Timing.MinMult) * factor`.
  If `mechMult >= Timing.PeakThreshold` → Kind "Peak", `mechXpMult = 1 + Timing.PeakXpBonus`.
- **Charge** (ContentCreator, StartupHQ): per-player per-zone `charge`. Each hit:
  `charge += 1`, pays `Charge.HitPercent` of manual (Kind "Manual", Charge/ChargeMax sent).
  When `charge == zone.ChargeMax`: pays `manual * ChargeMax * Charge.BurstMult`, XP
  `manualXp * ChargeMax * (1 + Charge.BurstXpBonus)`, Kind "Burst", charge resets to 0.

Automation (`Auto` upgrade level `A > 0`): every `Auto.Interval` seconds, for every loaded
player and every unlocked zone with `A > 0`, grant `floor(manualCash_noMech * (Auto.BasePercent +
Auto.PercentPerLevel * (A-1)))` cash and the same fraction of `manualXp_noMech`
(`mechMult = 1`), Kind "Auto", `Stats.AutoHustleCount += 1`. One `DataSync` per tick per player:
`DataService.addCash(player, amount, deferSync)` skips its sync when a `LevelService.addXp` follows
(manual hits use the same pattern).

Every manual hit: `Stats.HustleCount += 1`, `DataService.addCash`, `LevelService.addXp`,
fire `HustleResult`. Per-player state cleared in `cleanupPlayer`.

## Levels (LevelService)

- `GameConfig.getXpForLevel(level)` = XP needed to go from `level` to `level+1`.
- `addXp(player, amount)`: `Xp += amount`; while `Xp >= need and Level < MaxLevel`: `Xp -= need`,
  `Level += 1`, `Stats.HighestLevel = max(...)`, apply WalkSpeed unchanged, fire
  `LevelUp(newLevel, GameConfig.getZoneUnlockedAtLevel(newLevel) and its Id or nil)`, Toast.
  Then `DataService.sync`. At MaxLevel XP is capped at `need - 1`.
- `isZoneUnlocked(player, zoneId)` = `data.Level >= zone.UnlockLevel` (ZoneService delegates).

## Upgrades & perks (UpgradeService)

- `BuyUpgrade(zoneId, upgradeId)`: zone + upgrade exist (`GameConfig.getZoneUpgrade`), zone
  unlocked by level (else Toast), `level < MaxLevel` (else "Maxed out!"), cost
  `GameConfig.getZoneUpgradeCost(zoneId, upgradeId, level)`, `spendCash`, `level += 1`, sync,
  Toast success. The `Auto` upgrade going 0→1 should Toast "<Automation name> hired!".
- `BuyPerk(perkId)`: `GameConfig.Perks[perkId]`, cost `GameConfig.getPerkCost(perkId, level)`,
  WalkSpeed applied immediately (`GameConfig.BaseWalkSpeed + level`) and on every spawn.
- Worker equip cap = `GameConfig.Workers.BaseEquipSlots + Perks.WorkerSlots`; worker income
  × `(1 + WorkerEfficiencyPerLevel * Perks.WorkerEfficiency) × rebirthCash`; the income
  tick counts at most `cap` equipped workers and syncs every player every tick.

## Rebirth (RebirthService)

Requires `Level >= GameConfig.Rebirth.RequiredLevel` and `Rebirths < MaxRebirths`. Resets:
`Cash=0, Level=1, Xp=0, Upgrades={}, Perks all 0`; unequips workers beyond the base cap;
WalkSpeed back to base. Keeps `Workers, Stats, ClaimedQuests`. `Rebirths += 1`,
`Stats.TotalRebirths += 1`, sync, `RebirthResult("SUCCESS", n, getRebirthCashMultiplier(n))`.

## Map contract (MapBuilder → Workspace)

```
Workspace.SideHustleMap (Folder)
  Ground (Model: terrain-backed island; see Graphics)   Plaza (Model) with SpawnLocation
  Zones (Folder)
    <ZoneId> (Model, attribute ZoneId) — colored pad, building, signature prop, decor
      HustleStation (Model)
        PromptPart (Part) + ProximityPrompt "HustlePrompt"
          (ActionText zone.HustleVerb.."!", ObjectText zone.Name, HoldDuration = zone.HoldDuration
           or 0, MaxActivationDistance 12, RequiresLineOfSight false)
        FeedbackPart (Part, invisible, above the counter) — StationFeedbackController attaches
          its BillboardGui here (market needle / charge bar / combo)
        AutoAnchor (Part, invisible, where the automation rig stands)
      Gate (Model) — only zones with UnlockLevel > 1
        GateWall (Part, CanCollide true, translucent, zone-colored, neon posts)
        SignPart with BillboardGui: zone.Name + "Reach Level <UnlockLevel>" (+ lock glyph "🔒")
```
No `UnlockPrompt` in v2. Gates open per-player on the client (ZoneGateController) when
`Level >= UnlockLevel`; the server rejects hustles in locked zones anyway.

**Graphics (MapBuilder)**: `Lighting` — ClockTime ~13, Brightness 2.5–3, GlobalShadows,
ShadowSoftness 0.6, EnvironmentDiffuseScale/SpecularScale ~0.6, warm Ambient/OutdoorAmbient;
children: `Atmosphere` (Density ~0.32, Offset ~0.3, soft blue haze, Glare ~0.15),
`SunRaysEffect` (~0.08), `BloomEffect` (subtle), `ColorCorrectionEffect` (Saturation 0.2,
Contrast 0.08), `Sky` using the built-in `rbxasset://textures/sky/sky512_*.tex` set.
`Lighting.Technology = Future` is set by `default.project.json` (not scriptable).
Terrain: island of `Grass` (with `Terrain.Decoration = true` for animated blades) under
the plaza/zones, `Sand` beach rim, `Water` ring beyond ~380 studs, a few low hills of Grass
at the edges. Materials on props: Wood/WoodPlanks, Fabric canopies, Metal/DiamondPlate
truck, Glass windows (transparency), Marble plaza, Cobblestone road, Neon accents.
Particles (default sparkle texture): grill smoke, car-wash foam bubbles, dog-park hearts,
stock-desk money sparkle, creator-studio neon motes, lemonade citrus sparkle. PointLights
on lamp posts and neon signs. Keep total part count under ~3500.

## UI contract (StarterGui — exact ScreenGui names)

Style: pack look — FredokaOne / LuckiestGuy titles, cream panels, #040435 strokes, pill
counters, UIScale bounce on open, `ScreenInsets: "CoreUISafeInsets"`. Real icon ids are
NOT available yet; specs keep icon keys, user uploads later.

- `MainHUD`: top-center **cash pill** (`CashPill.Amount`, bound to leaderstats.Cash with
  count-up + pop, bouncing cash icon) and under it a **level pill + XP bar**
  (`LevelPill.LevelLabel` "Lv 7", `XpBar.Fill` scaled, `XpBar.Label` "120 / 238 XP"), then a
  small rebirth pill (`RebirthPill.Label` "x1.5"). Panels use `DisplayOrder` 5 (above the HUD); the HUD moves its `Toast` into a
  `ToastLayer` ScreenGui (`DisplayOrder` 20) at startup so server toasts show over open panels. Top-left 2-column grid (3 rows; a single column of 5 does not fit a 390px-tall phone) of 5 chunky
  square ImageButtons named exactly `HustlesButton, ShopButton, WorkersButton,
  RebirthButton, QuestsButton` — each toggles its panel's `ScreenGui.Enabled`
  (HustleGui/ShopGui/WorkersGui/RebirthGui/QuestsGui; one open at a time). A hidden
  `Toast` pill. HUDController listens to `HustleResult` (→ `ClientEffects.moneyPopup`,
  `screenPop`, combo popup when Combo ≥ 2; NOT burst/peak callouts — StationFeedbackController owns those), `LevelUp`
  (→ `ClientEffects.levelUp`), `Toast`.
- `HustleGui` (Enabled=false): panel with a left **tab column** cloned from hidden
  `HustleTabTemplate` (one per zone in Order; locked tabs show the lock icon + "Lv N") and a
  right **detail pane**: `ZoneName`, `Tagline` (mechanic hint), and a list cloned from hidden
  `UpgradeRowTemplate` (icon slot, `Name`, `Desc`, `Level` "Lv 2/10", `BuyButton` with
  `Price`), the Auto row visually distinct (gold). Opening auto-selects the nearest zone
  (`Mechanics.nearestZoneId(position)`); refreshes from DataSync; `BuyButton` fires
  `BuyUpgrade(zoneId, upgradeId)`; sparkle + LevelUp sound when a level increases.
- `ShopGui` (Enabled=false): **PERKS** grid (cards named exactly `WalkSpeed`, `WorkerSlots`,
  `WorkerEfficiency` with `Level` + `BuyButton.Price` → `BuyPerk`) and **HIRE WORKERS** grid
  (`StarterCrate`, `ProCrate`, `EliteCrate` with `Odds` + `HireButton.Price` → `HireWorker`;
  `WorkerHired` → sparkle + Hire sound).
- `WorkersGui`, `QuestsGui`: as v1 (`WorkerCardTemplate`, `QuestRowTemplate`); quests now
  read the v2 Stat names.
- `RebirthGui` (Enabled=false): current/next cash multiplier pills, progress bar
  `Level / RequiredLevel`, warning line ("Resets cash, level, upgrades and perks. Keeps
  workers and quests!"), `RebirthButton` → `RequestRebirth`, shake on INSUFFICIENT.

Every panel: overhanging close button, UIScale bounce via `GetPropertyChangedSignal("Enabled")`,
`ButtonFX.attach` on every button, cache the last DataSync snapshot and refresh on open.

## Shared client/server helpers (`Mechanics.luau`, pure, no services)

- `Mechanics.marketFactor(zone, serverTime): number` — 0..1 sine over `zone.MarketPeriod`
- `Mechanics.marketMult(zone, serverTime): number` — maps factor through Timing Min/Max
- `Mechanics.zoneCenter(zoneOrder): Vector3` — ring position (radius `GameConfig.Map.ZoneRadius`,
  angle `(order-1)*45°`) — MapBuilder must place zones with the same function
- `Mechanics.nearestZoneId(position: Vector3): string`

## ClientEffects API (ReplicatedStorage/Shared, client-only)

`moneyPopup(amount)`, `screenPop()`, `sparkle(guiObject)`, `playSound(name)`,
`celebrate(rebirths)`, **new:** `levelUp(newLevel: number, unlockedZone: string?)` (zone **Id or Name**;
the LevelUp remote carries an Id and levelUp resolves it to the display name)
(banner slam-in + confetti burst; if a zone unlocked, a second line "NEW HUSTLE: <name>!"),
`comboPopup(combo: number)` (small "x4 COMBO!" callout near the cash pill),
`worldPopup(position: Vector3, text: string, color: Color3)` (BillboardGui "+$50" rising at a
world point — used by auto hustles at stations), `callout(text: string, color: Color3)`
(big centered "VIRAL!" / "FUNDED!" / "PEAK FLIP!" flash).
