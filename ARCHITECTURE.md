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
    VehicleRig.luau             -- builds cartoon cars / taxis / police car / bus / ice-cream van / delivery truck / blimp / hot-air balloons from primitives
    CityLifeSim.luau            -- PURE city-life simulation (traffic, citizens, shoppers, zebra crowds, zone customers, zone life, pigeons, sky, window washers, city pulse) over CityLayout
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
      HoldPromptController.luau -- stretches Hold prompts locally to the player's current cooldown
      WorkerVisualsController.luau   -- companion worker rigs following the player
      AutomationVisualsController.luau -- stationed chibi rigs at zones with automation > 0
      StationFeedbackController.luau   -- market needle / charge bar / combo billboards at stations;
                                          sole owner of the Burst/Peak callouts (HUD must not call them)
      RebirthWatcher.luau       -- RebirthResult SUCCESS -> celebration
      CityLifeController.luau   -- ambient city life (traffic, citizens, shoppers, zebra crowds, zone customers, zone life, pigeons, blimp, birds, clouds, balloons, window washers, city pulse) via CityLifeSim
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
- `manualCash = round(base * earnMult * mechMult * rebirthCash)`, `manualXp = round(xpBase * xpMult * mechXpMult * rebirthXp)`
  (`round(x) = floor(x + 0.5)` everywhere a payout is computed, server and client previews alike:
  flooring small bases like Lemonade's $5 made the first +25% upgrade and early combo stacks pay nothing)

Each zone's upgrades are found by `Effect` via `GameConfig.getZoneUpgradeByEffect(zoneId, effect)`.

Mechanics (`zone.Mechanic`, params in `GameConfig.Mechanics`):
- **Tap** (LemonadeStand, FoodTruck): server tracks per-player per-zone `lastHit` and `combo`.
  Trigger within `ComboWindow` of the last accepted hit → `combo = min(combo+1, ComboMax)`,
  else `combo = 0`. `mechMult = 1 + ComboBonusPerStack * combo`. Kind "Manual", Combo sent.
- **Hold** (DogWalking 2 s, CarWash 3 s): one hit per completed hold; `mechMult = Hold.PayoutMult`
  (bigger, slower). Kind "Manual". The server prompt's `HoldDuration = zone.HoldDuration` is the
  *shortest* hold (the cooldown at max Speed); the client `HoldPromptController` stretches each
  Hold prompt locally to `Mechanics.cooldownFor(zone, upgrades)`, so the hold itself spans the
  cooldown (no completed hold is ever silently rejected) and the Speed upgrade shortens the hold.
  Server cooldown for Hold zones is a schedule: accept when `now >= nextDue - Hold.TriggerGrace`
  (0.4 s jitter allowance, covering retransmit spikes), then `nextDue = max(now, nextDue) + cooldown`, so the grace never
  compounds into a faster long-run rate (even for a client that skips the hold).
- **Timing** (SneakerFlipping, StockDesk): shared clock —
  `Mechanics.marketFactor(zone, workspace:GetServerTimeNow())` ∈ [0,1] (sine over
  `zone.MarketPeriod`). `marketMult = Timing.MinMult + (Timing.MaxMult - Timing.MinMult) * factor`, taken
  as the max of the value at trigger arrival and `Timing.PeakGrace` (0.2 s) earlier, so a press the
  player saw inside the green window is not judged off-peak because of ping.
  Peak flip (`marketMult >= Timing.PeakThreshold`): `streak = min(streak+1, StreakMax)` (stored in the
  per-zone `combo` slot), `streakMult = 1 + StreakBonusPerStack * (streak-1)`, `mechMult = marketMult *
  streakMult`, `mechXpMult = (1 + PeakXpBonus) * streakMult`, Kind "Peak". Off-peak flip: `streak = 0`,
  `mechMult = marketMult * OffPeakMult`, `mechXpMult = OffPeakMult`, Kind "Manual". Combo (= streak)
  is sent. Simulated: timed play out-earns pressing at every cooldown ~2-3x at every Speed level.
- **Charge** (ContentCreator 5 hits, StartupHQ 8 hits): per-player per-zone `charge`. Each hit:
  `charge += 1`, pays `Charge.HitPercent` of manual (Kind "Manual", Charge/ChargeMax sent).
  When `charge == zone.ChargeMax`: pays `manual * ChargeMax * Charge.BurstMult`, XP
  `manualXp * ChargeMax * (1 + Charge.BurstXpBonus)`, Kind "Burst", charge resets to 0.

Automation (`Auto` upgrade level `A > 0`): every `Auto.Interval` seconds, for every loaded
player and every unlocked zone with `A > 0`, grant `round(manualCash_noMech * (Auto.BasePercent +
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

Built at server start by `ServerScriptService/World/MapBuilder.luau` with its sibling
modules `MapKit` (primitive helpers + palette), `CityBuilder` (the downtown) and
`ZoneDressing` (themed clutter on each pad). The downtown is laid out by the PURE shared
module `ReplicatedStorage/Shared/CityLayout.luau` (API documented at its top), which the
client city-life system also reads, so pedestrians and cars land on the real sidewalks
and lanes.

```
Workspace.SideHustleMap (Folder)
  Ground (Model: terrain-backed island; road-side signposts at `CityLayout.signposts` (warm brown
    posts); no beach palms; see Graphics)
  Plaza (Model) with SpawnLocation (on a flat gold SpawnMedallion disc, 17 dia, top 1.66, with 4
    SpawnEdgeNeon strips on the slab's top edges; all CanCollide false; the slab's size, CFrame,
    Neutral and Duration never change) + SpawnWelcomeMat (an invisible CanCollide / CanQuery /
    CanTouch false ground deck lying on the slab, `MapKit.makeGroundDeck`) carrying SurfaceGui
    "WelcomeMat": a sky-blue rounded Mat with a white stroke, "START" in the half nearer the
    fountain and a white chevron in the far half; the gui's up points at the starting zone (+X),
    so it reads upright from the default camera behind a new player), the ground/street discs
    (BackEdgeOuter, BackAsphalt, BackEdgeInner = the Back Avenue; BlockGround = city-block ground;
    RoadTrim curb, RingRoad = outer sidewalk, Asphalt, InnerSidewalk), PlazaTrim/PlazaFloor, coin
    fountain (a banded white column carrying Model "SpinCoin", attribute CitySpin 40), cobalt lamps
    with festive bunting between them (white StringWire + 60 point-down WedgePart Pennant flags, lowest
    tip ~5.8 above the floor), benches, title billboard
  Zones (Folder)
    <ZoneId> (Model, attribute ZoneId) — colored pad (ZonePad = SignColor 35% toward white;
      5 PadStripe carpet stripes 9.6 x 0.06 x 48 running gate → back (center + outer two at
      SignColor 10% white — Startup HQ: AccentColor 25% white — the two between 60%), none on
      Dog Walking (lawn); PadCurb 2 x 0.5
      signature curbs with PadCurbNeon strips on the 3 non-entrance edges; EntranceCarpet +
      EntranceCarpetNeon on the outer sidewalk from the zebra to the gate, top <= ROAD_TOP + 0.08),
      building, signature prop, decor. A near-white SignColor (Startup HQ) is replaced by the
      AccentColor blue (`MapKit.zoneSignFace`) for pad, stripes, curbs, boards and the whole gate
      (wall, posts, top bar, SignPart, their lights); its neon edge strips are white.
      HustleStation (Model)
        PromptPart (Part) + ProximityPrompt "HustlePrompt"
          (ActionText zone.HustleVerb.."!", ObjectText zone.Name, HoldDuration = zone.HoldDuration
           or 0, MaxActivationDistance 12, RequiresLineOfSight false)
        FeedbackPart (Part, invisible, above the counter) — StationFeedbackController attaches
          its BillboardGui here (market needle / charge bar / combo)
        AutoAnchor (Part, invisible, where the automation rig stands)
      MechanicProp (Model) — static dressing that tells the mechanic from afar
      Dressing (Model) — themed clutter (cafe tables, agility hoops, queued cars ...); never
        on the gate → counter walkway or within 6 studs of PromptPart / AutoAnchor
      EntranceLamp (Model) x2 — lamp posts (LampBase / LampPole / LampBulb) at zone-local
        (±16, −35) in the zone's own colors: pole `zoneSignFace` 15% toward navy, base 35%
      Gate (Model) — only zones with UnlockLevel > 1
        GateWall (Part, CanCollide true, translucent, zone-colored = `MapKit.zoneSignFace`, neon posts)
        SignPart with BillboardGui: zone.Name + "Reach Level <UnlockLevel>" (+ lock glyph "🔒")
  City (Model) — the cartoon downtown (CityBuilder, positions from CityLayout)
    Street      curbs, zebra crosswalks on every zone axis, PAINTED lane dashes: 8 invisible
                flat MarkingDeck<k> parts (one per gap octant, 48 x 26 at r 84, CanCollide /
                CanQuery / CanTouch false) whose lit SurfaceGui "Markings" (LightInfluence 1,
                10 px/stud) holds one Frame per yellow center / white lane dash (120 in all,
                `CityLayout.roadDashes` / `markingDecks`) + 8 BackMarkingDeck<k> (205 x 25,
                5 px/stud) painting the Back Avenue's 72 yellow center dashes (r 260); no dash
                parts. TrafficLight (Model, attribute ZoneId; cobalt mast, cartoon-yellow
                SignalHead; Neon SignalRed / SignalAmber / SignalGreen parts that clients may
                recolor locally)
    Skyline     48 pastel buildings: mid ring r≈232 (24 MidBuilding<k>, 34–60 tall; plaza face:
                part window bands + mullions and a vertical BladeSign (1 x 14 x 4.5 accent board,
                y 12–26, one white letter per line on both unlit faces: CAFE, TOYS, GYM ... HOTEL) +
                a white neon edge; side faces: PAINTED bands above the rowhouses (SurfaceGui
                "Windows"); back face (the Back Avenue's inner wall): a giant painted wall ad
                (SurfaceGui "Mural": accent Panel y 11..H-3 with soft circles, a stripe and a
                two-line LuckiestGuy slogan — DREAM BIG, HUSTLE HARD ... YOU GOT THIS) over a
                BackAwning and a BackDoor), outer ring r≈292 (18 OuterBuilding<k>, 64–112 tall;
                front + both sides carry PAINTED window bands, sills and front mullions (SurfaceGui
                "Windows", no part bands); every outer front — the face lining the Back Avenue,
                r≈277 — has an accent Awning, a Door and a warm DisplayWindow; OuterBuilding1 and
                OuterBuilding13 carry a slewing yellow tower crane instead of a water tower: a
                static CraneMast (roof → y 136) with white collars + Model "CraneTop" (attribute
                CitySpin +4 / −3, WorldPivot on the mast axis at y 137; jib x −12..+38 at y 141.5–
                144.1, apex + tie bars to 153.1, cab, counterweight, trolley, hook line, a two-plank
                load down to y 125.8 always at r ≥ 268.5, red neon tip light; CityLayout.TowerCranes
                / Crane) and 6
                landmark HeroTower<k> in outer slots
                k = 2, 7, 10, 14, 19, 22 (CityLayout.HeroTowers): "Stepped" (3 setback tiers to 150 +
                white spire, red neon tip at ~185), "Round" (30-dia drum x 140, window rings, neon
                ring, candy RoofDome + DomeFinial, antenna) and "Billboard" (34 x 130 x 26 slab,
                stepped crown, 30 x 12 unlit rooftop billboard "HUSTLE CITY" / "GO BIG!"). Plus 24
                Rowhouse<k> infills (20 tall, r 220–238) closing the mid-ring gaps into one street
                wall. Roof props: setback + antenna, coral water tower (slate legs), roof sign, dome.
    BackPockets a tree in an accent-rimmed planter (angles 30k) or a lamp post (15 + 30k) at r 241.5
                in every pocket behind the rowhouses (CityLayout.pocketTrees / pocketLamps; trunks and
                poles collide and are in CityLayout.footprints)
    Shops       16 storefronts in the gaps (one-storey at r 140, 3-storey + rooftop billboard at r 170):
                accent name boards with white text, warm-lit display windows, flower boxes on B;
                the B rooftop Billboard is 20 x 8.5 in a per-gap color never shared with either
                neighbouring zone
    Anchors     Anchor<ZoneId> (attribute ZoneId): landmark right behind each pad (zone-local
                z +46), 30 + 4·(Order−1) tall, signature colors, giant 40 x 11.5 rooftop name sign
                (signature board, white text, white neon marquee) + giant icon in child Model "Icon"
                (attribute CitySpin 25, WorldPivot at the icon base; its sweep clears the sign)
    Furniture   street trees in planters, hydrants, trash cans, news boxes, bus stops and 24
                tall double lamps (outer-sidewalk furniture strip r 105–112): 8 gap lamps (g + 5,
                PointLight) + 16 zone lamps (zone axis ± 10.5°, slid clear of furniture / the
                signpost boards, no light), every one with a BannerBar (y 12.7) and two 1.9 x 4.4
                festival Banners in the tangential plane (`MapKit.zoneSignFace` of the zone beside
                it; a gap lamp: lower-angle zone left, higher-angle zone right as seen from the
                plaza); all from `CityLayout.streetFurniture` (kind "Lamp", bannerZones)
    GapBlocks   Gap<k>: café terrace in front of every Shop A (a CafeTerrace rug — 18.5 x 0.08 x
                8.5 in the shop accent 45% toward white, top 0.28, CanCollide / CanQuery false,
                a lit Top SurfaceGui "Checker" with a white border + 2 x 2 white checks —
                under 2 tables, two-tone umbrellas, stools: CityLayout.cafeTerraces / cafes /
                cafeSeats) + 4 street trees in accent planters beside the shops (CityLayout.gapTrees)
    Parks       pocket-park lawns + trees behind the shops (gap bisectors, r≈200)
    PlazaBuzz   food carts, balloon vendor, colored plaza inlay + sunburst, 5 raised round
                flower planters (CityLayout.plazaPlanters, collidable)
```
Spinning decor: any Model carrying a numeric `CitySpin` attribute (degrees/s) is turned about
world Y around its `GetPivot()` by the client city-life sim; the world builder sets `WorldPivot`
explicitly and `tools/check_map.luau` checks every tagged model's full turn sweeps clear of its
neighbours and of the blimp path (torus r 250, y 120, tube 12). Signs: every board is a bright
face (zone signature color, shop accent, white or gold) with white or colored FredokaOne /
LuckiestGuy text; `MapKit.makeTextLabel` gives every TextLabel a navy `UIStroke`: on SurfaceGuis
clamp(round(0.055 · labelPx), 4, 9) px with labelPx = face height (studs) · PixelsPerStud · the
label's height scale (through parent frames), so big boards keep a readable outline from the
plaza; 3 px on BillboardGuis. **Face-frame rule:** every
Block sign board passes its own color as `faceColor` (7th argument) to `MapKit.addSurfaceText`,
which parents a full-face Frame "Face" (ZIndex 1, text ZIndex 2) to an unlit SurfaceGui
(LightInfluence 0, Brightness 1.1), so a board shows its true color whatever the sun angle (never
a dull grey slab in shade). Exceptions: the round BUS disc and the money-bag "$" labels (text
only). **Sign hierarchy:** zone boards (anchor AnchorSign, 40 x 11.5) are the largest rooftop
boards and the only ones in their zone color; Shop B rooftop billboards are smaller (20 x 8.5)
saturated boards with white slogans inside white neon marquees, colored per gap so no billboard
shares a hue with either neighbouring zone (`tools/check_map.luau`: ≥ 25° of hue apart). NAVY
(4,4,53) is reserved for text outlines, tires, the gate lock BillboardGui panel and darkened tints.
No `UnlockPrompt` in v2. Gates open per-player on the client (ZoneGateController) when
`Level >= UnlockLevel`; the server rejects hustles in locked zones anyway.

Street cross-section (`CityLayout.Street`, radii from the plaza center, tops are world Y):
plaza floor r 55 (1.5) → plaza rim r 58 (1.3) → inner sidewalk to r 66 (0.75) → asphalt
r 66–104 (0.6; 4 lanes, right-hand traffic: inner two lanes drive with increasing angle) →
outer sidewalk r 104–120 (0.5, `ROAD_TOP`) → white trim to r 122.5 (0.3) → city-block ground
to r 250 (0.2; park lawns 0.3) → white edge r 250–250.6 (0.16) → Back Avenue asphalt to r 270
(0.12; 2 lanes `CityLayout.backLaneLoops` r 255 / 265, kept out of `laneLoops`) → white edge to
r 270.6 (0.08) → Pavement terrain (0). Disc tops stay >= 0.04 apart (no z-fighting).
Pads start at r 118 on each zone axis. Pedestrian loops: r 113.5 (outer) and r 62 (inner);
Back Avenue sidewalks `CityLayout.backSidewalkLoops`: "BackInner" r 247.3 (Y 0.2, between the
mid-ring backs ≤ 245.4 and the avenue edge) and "BackOuter" r 273.4 (Y 0, between the avenue
edge 270.6 and the outer fronts / pillars / round plinths ≥ 275.5), kept out of `sidewalkLoops`;
the zone-axis walkway (|zone-local x| < 10 from the plaza to the gate) never holds a City
collider. `tools/check_map.luau` audits all of this plus the life paths (loops, lanes, back
lanes, back sidewalk loops at walker body extent r ± 1.45 / h 0.3–4.9, crosswalks, plaza wander
area, café seats) against every part, that the rowhouses never cut into their neighbours, the
CitySpin sweeps, and the round-5 rules: every one of the 192 former dash parts has exactly one
painted frame within 0.05 studs on the 16 decks (no LaneDash / CenterDash / BackDash / Palm*
parts left), no Metal LampPole / LampBase and no near-black street hardware, both EntranceLamp
poles of every zone in its color, the sign hierarchy, the café terraces (under every stool, clear
of the curb, door lanes, trees and crosser lines) and the START mat facing the starting zone. Hero towers stay inside the 30-deep outer footprint (fronts ≥ 275.5), so the blimp
path (r 250, y 120) keeps ≥ 27 studs from every face and the high clouds (y 260) clear the
185-stud skyline top.

**Graphics (MapBuilder)**: `Lighting` — ClockTime ~13, Brightness 2.5–3, GlobalShadows,
ShadowSoftness 0.6, EnvironmentDiffuseScale 0.85 / SpecularScale 0.6, bright warm fill (Ambient
(162,154,146), OutdoorAmbient (206,198,188)) so shaded facades stay pastel;
children: `Atmosphere` (Density 0.20, Offset 0.2, light blue Haze 0.2 so the far half of the
ring keeps its colors, Glare ~0.15), `SunRaysEffect` (~0.08), `BloomEffect` (subtle), `ColorCorrectionEffect`
(Saturation 0.3, Contrast 0.08), `Sky` using the built-in `rbxasset://textures/sky/sky512_*.tex` set.
`Lighting.Technology = Future` is set by `default.project.json` (not scriptable).
Terrain: a city island of warm cream `Pavement` (r 314; no animated blades, so nothing pokes
through parts) ringed by a thin `Grass` belt (to r 330), a `Sand` beach rim (to r 360) and a
shallow `Water` ring; no hills. `Terrain:SetMaterialColor` (scriptable, unlike `Terrain.Decoration`
which the Rojo project sets) tints Pavement (226,216,200), Sand (250,224,156) and Grass
(108,200,76). Materials: SmoothPlastic everywhere by default (street discs, plaza floor and
spawn pad, cartoon blue SmoothPlastic asphalt (68,72,94) — no Cobblestone; every lamp post,
signal mast, pole, leg and post is SmoothPlastic toy-city cobalt `MapKit.STREET_POLE`
(60,96,196) on `MapKit.STREET_BASE` (44,72,160) foot plates — never gunmetal / near-black —
except the zone entrance lamps (zone colors); traffic-light heads cartoon yellow (255,200,40);
tree trunks and signpost posts warm brown SmoothPlastic `MapKit.TRUNK` (150,102,64)), Neon accents (signs,
white marquee frames, signals, lamp globes, pad curb strips), Glass only for shop display windows
(over a warm-lit panel) / bus shelters (building windows are light blue or warm SmoothPlastic
bands), Wood/WoodPlanks, Fabric canopies, Metal/DiamondPlate props, Marble fountain. Palette: soft
pastels for the city (coral, peach, butter, mint, teal, sky, periwinkle, lavender, bubblegum,
lime — no cream: it read khaki in shade) so every zone's signature color stays the most
saturated thing on screen; the zone pads are the brightest ground in town; zone anchors are a
rich signature tint (32% white; a bright yellow signature — luminance 0.75–0.85, Lemonade — 50%
toward pure white = butter (255,234,143) with (255,246,205) pillars; a near-white one — Startup
HQ — keyed to its AccentColor: sky-blue body (177,205,255), accent glass bands, white pillars,
accent plinth, accent neon trim); plinths are only lightly darkened (body 18% toward slate) so
nothing reads as grime. Stock Desk's backdrop, ticker screens, TICKER board and ticker pillars
are a deep ticker green (`MapKit.STOCK_DEEP_GREEN` (18,84,58), a local override: GameConfig keeps
its near-black AccentColor). Plaza floor: peach inlay (255,186,140) with (255,158,112) /
(112,214,200) sunburst rays. **Paint, don't build:** faces seen only from >= 150 studs (outer-
ring fronts + sides, mid-ring sides above the rowhouses) carry painted windows —
`MapKit.paintBands` (a lit SurfaceGui "Windows": LightInfluence 1, 2 px/stud, one Frame per band
+ a sill, front mullions) — and the mid-ring backs a painted `Mural` (LightInfluence 0.4,
Brightness 1.4); near faces (mid-ring fronts, anchors, hero towers, shops, rowhouses) keep
chunky part bands. Flat ground markings are painted too: every lane dash is a Frame on a
`MapKit.makeGroundDeck` deck (an invisible flat part whose up-facing BACK face carries the gui, so
painted positions follow Roblox's unambiguous side-face orientation: gui up = part +Y), placed
with `MapKit.deckPixel` / `deckRotation` in UDim2 scale (UDim offsets are whole pixels). Particles (default sparkle texture): grill smoke, car-wash foam
bubbles, dog-park hearts, stock-desk money sparkle, creator-studio neon motes, lemonade citrus
sparkle. PointLights on lamp posts and neon signs. Small decor is CanCollide false + CastShadow
false; buildings, poles and big props collide. Part budget (round-5 envelopes): ≤ 4,400 map parts
(≈4,340 today, asserted by `tools/check_map.luau`; the 192 dash parts became 16 painted decks and
the 80 unseen beach-palm parts are gone), ≤ 6,930 exported in total (hard cap 7,000 including the
client-life preview `tools/render/preview_life.luau`, which gets everything the map leaves free).

## City life (client-only ambient motion)

`StarterPlayerScripts/Controllers/CityLifeController.luau` (auto-started by ClientMain) is a thin
shell over the PURE shared simulation `ReplicatedStorage/Shared/CityLifeSim.luau`, which builds every
rig once with `ChibiRig` (citizens, shoppers, customers, window washers) and `VehicleRig` (vehicles,
the car-wash car, blimp, hot-air balloons) and moves them on the `CityLayout` sidewalks (incl. the Back
Avenue sidewalks), lanes, back lanes, crosswalks, café seats, Shop A doors, storefronts and plaza
spots, and - planned in `bindMap` from the replicated zone models - on every zone pad (customers and
the zone life). The offline render runs the very same simulation (`tools/render/preview_life.luau`:
4.5 s warm-up, then one full snapshot into `Workspace.LifePreview`), so renders show what players see.

**Client-owned Workspace folders** (created locally by client controllers; the server never creates
or uses these names): `WorkerRigs` (WorkerVisualsController), `AutomationRigs`
(AutomationVisualsController), `CityLife` (CityLifeController; children `Traffic`, `Citizens`
(walkers incl. shoppers, crossers, idlers and the 2 walkers' dogs), `Customers` (zone customers + their
coins, created in `bindMap`), `ZoneLife` (the car-wash car + the 2 agility dogs, created in `bindMap`),
`Plaza` (street-act props + pigeons), `Sky` (blimp, birds, clouds, balloons, rooftop coins, the 2
window-washer cradles)).

Rules: every CityLife part is Anchored with CanCollide / CanQuery / CanTouch false, CastShadow false
except a vehicle's chassis / the bus body / the truck's cab and cargo box. One Heartbeat connection
and one `workspace:BulkMoveTo` (`FireCFrameChanged`) per frame over reused arrays: no Instance creation
or table allocation per frame. Property writes: a dog leash's Size (only when its hand -> collar
length changes by > 0.06), a window-washer cable's Size (at most every 0.25 s), the car-wash car's 2
body colors once per pass, and the city pulse's Color / Transparency sets on the map's own neon (10 Hz,
only on change). The zone life also moves map parts LOCALLY by CFrame (the hero-prop spinners) - only
non-colliding, non-contract parts (see Zone life); `sim:unbindMap()` puts them back. Distance LOD from
the camera: citizens and pigeons update every frame with limb animation within 140 studs, every 2nd
frame (still animated) to 260, every 4th frame in a rest pose to 400, and are parked out of sight
beyond; idlers other than the street dancer pose every 2nd frame; resting pigeons and stopped
(settled) vehicles are emitted once, not every frame; vehicles update every frame within 260
(suspension bob / brake pitch), every 2nd frame to 400 and hide beyond; birds hide beyond 400, the
blimp and clouds beyond 1500 (clouds move every 2nd frame). Zone customers, the car-wash car and the
agility dogs follow the citizen LOD (standing customers pose every 2nd frame); the zone spinners turn
only within 260 studs of the camera (beyond that they hold their pose); the window washers move every
2nd frame and hide beyond 400; the balloons move every 2nd frame (the other parity from the clouds)
and hide beyond 1500 like the blimp.
Budgets: <= 108 citizens (incl. 12 shoppers and 2 window washers) + 33 zone customers, <= 20 vehicles,
customers <= 435 parts (417 today), zone life <= 40 parts (34), <= 2,520 life parts (2,510 today; map
4,338 + life = 6,848 exported, under the 6,930 envelope and the 7,000 cap). No sounds (only ever via
`GameConfig.Sounds` + `ClientEffects.playSound`). If the map ever outgrows its 4,400 envelope, the
first life cuts are the window washers (-32 parts), then 4 shoppers (~-56), then 2 crossers per zebra
(laterals -3.5 / +3.5).

- **Traffic**: 18 vehicles on the 4 ring-road `CityLayout.laneLoops` (5 taxis, a police car, the bus,
  the ice-cream van, a delivery box truck, 9 cars; 4 / 4 / 6 / 4 per lane, evenly spaced; right-hand
  traffic, cruise 18 / 20 / 21 studs/s, the outermost bus + truck lane 13), so they never touch a pad
  or the plaza, plus 2 on the Back Avenue `CityLayout.backLaneLoops` (the Back1 taxi at 356 degrees,
  framed by `r2_backstreet`, and the Back2 car at 42; 16 / 17 studs/s, Y from `loop.y`; no lights,
  never counted at a zebra). Each keeps an evenly spaced schedule slot (catch-up <= +30%), a 5-stud
  bumper gap to the vehicle ahead, eases speed exponentially (6/s) and never overshoots a stop (hard
  clamp). Ring-road vehicles stop at amber / red crosswalk lights (commit through amber only when they
  cannot stop at 40 studs/s^2); every vehicle stops for any player standing in its lane ahead or beside
  it; the bus dwells 3 s at every `CityLayout.busStops` stop. The truck's box tops out at Y 9.6 (+ <=
  0.27 bob / pitch) under the signal heads (bottom 10.2); the ice-cream van's cone (13) only drives the
  inner lanes, which no signal part overhangs. The police car (`VehicleRig` kind `Police`, Outer1 at
  180 degrees, the Car's dimensions, speed and rules) is WHITE with a blue hood, blue doors painted
  with "POLICE" (SurfaceGui frames, 0 parts) and a roof lightbar (dark 4.4 x 0.6 x 1.2 base + Neon red
  / blue halves) whose halves alternate Transparency 0 / 0.7 at 2.5 Hz (city pulse, within 500 studs).
- **Crosswalk lights**: one state machine per zone axis (green -> amber 1.6 s -> red -> green; min
  green 10 s, min red 2.5 s, max red 16 s). A waiting crosser requests the light; crossers step off
  only on red AND when no ring-road vehicle has its nose past the stop line with its tail still in
  the zebra band. Rush hour: at that moment every ready crosser of the zebra goes, joined by every
  idle one there whose wait ends within 8 s (`CrossJoinWindow`), each after a 0-0.8 s hash delay, so
  groups pour across from both sides; committed crossers hold the light red until each is off the
  asphalt (the rest of the walk is on the sidewalk). A player on a zebra holds it red. The controller
  recolors the map's `TrafficLight` lamps (`SignalRed` / `SignalAmber` / `SignalGreen`, matched by the
  model's `ZoneId`) LOCALLY: the lit lamp is Neon, the others dimmed SmoothPlastic. Each light is red
  ~35-39% of the time (a group every ~25 s); 66-75 crossings per zebra per 10 minutes.
- **Citizens** (ChibiRig at scale 1.25 so adults read at player height, kids / teens 1.0; NameTag and
  the invisible RootPart removed; shirts avoid the worker rarity colors; varied skin, pants and hair
  (bob / ponytail / bun), hats, backpacks, shopping bags, balloons, a few coffee cups and sunglasses;
  accessories follow their limb by part NAME):
  - 35 sidewalk walkers: 24 on the outer sidewalk (two opposite lanes of 12 at r 113.6 / 115.9, spread
    evenly with +-14% jitter, that tuck in to r 112.0 / 114.15 within ~11 degrees of each zone axis,
    clear of the zone entrance lamps at zone-local (+-16, -35) and of the furniture strip), 10 on the
    inner sidewalk (two lanes of 5 at r 61.4 / 63.4) and 1 on the Back Avenue: BackInner's dog-walker
    (`CityLayout.backSidewalkLoops`, r 247.3, Y 0.2, clockwise = +angle, sidestep band r 246.9-248.5;
    framed by `r3_back_walk`); BackOuter (r 273.4) is empty (its crowd moved to the outer sidewalk,
    where every player walks; its door window-shopping stays available). Two dog-walkers (leash in the
    left hand) with a chibi dog (7 parts: ball body (230,180,120) and head, ears, nose, a tail wagging
    at 6 Hz and a leash re-spanned hand -> collar every step) that sits while its walker stops: OuterA's
    first walker (dog 1.2 studs ahead and 1.25 out on the walker's left = outward, r ~114.85 between the
    zones and ~113.25 at the zone axes, never past the lane's outer sidestep bound: clear of the entrance
    lamps, signposts, bus stops and >= 1.28 studs from the crossers waiting at r 116.5) and BackInner's
    (2 ahead, 1 toward the avenue). Walkers waddle (limb swing about shoulders / hips), sometimes stop 5
    degrees (inner sidewalk: 9, outside the crosser lines) before a zone axis to window-shop (facing the
    zone, head turning, some waving), sidestep players, or wait politely and squeeze past after 3 s.
    On the outer sidewalk everyone (walkers + shoppers) keeps 3 studs (+ a dog's lead) behind whoever
    walks ahead in its lane (`FollowGap`: nobody walks into a window-shopper's back or a merging
    shopper). On the ring sidewalks they also stop at the edge of a zebra crosser's line while that
    crosser is about to pass (at most 2.5 s; a dog-walker earlier, by its dog's lead), and a crosser
    about to walk into a walker - or a walker's dog - already in its line lets it pass (at most 1.5 s),
    so nobody walks through anybody.
  - 12 shoppers (adults in the citizen palette; their own one-part `ShoppingBag` in their accent color,
    parked while they carry none) circulate between the 8 Shop A doors: each walks the OuterA or OuterB
    lane (same sidestep, yield and follow rules) to its next Shop A, leaves the lane at Shop-A-local
    x 10 (~5 degrees before the gap bisector), walks up the door lane (x 7.5-10.5, clear of the café
    terrace x -13.5..5, the window shopper and the gap-tree planters) at 4.4 studs/s, glances at the
    display window from (9.5, -12) for 2.2-3.6 s, steps up onto the 1.2-tall plinth into the door
    (8.5, -8.2) and disappears for 5-9 s (hash), comes back out facing the plaza with a bag (a hop
    down), walks back down the door lane, waits for a gap in its lane and walks on in its lane's
    direction to the neighbouring gap's Shop A. Start states are staggered so ~4 are on frontages at
    any moment (3.8 average over 10 minutes, every shopper 15+ visits); the render snapshot has one
    at the PIZZA window (`gap`) and one walking down the DONUTS frontage with its bag (`r5_sidewalk_tan`).
  - 24 rush-hour crossers, a group of 3 per zebra: A at lateral -5, B at 0, C at +5 (tangential offset
    from the zone axis inside the 16-wide zebra), each keeping its own line in both directions so
    crossers never meet. A and B start in front of the gate (r 116.5 / 116.6, on the zone's
    `EntranceCarpet` - the feet follow its top), C on the plaza rim (r 57); after a crossing each
    waits 12-20 s on its new side (hash), so the sides mix. Speed 5.6-7.4 studs/s (hash), kids +10%,
    waddle clock scaled by speed. While waiting: a weight-shift sway and look-both-ways head turns, B
    points across the road now and then, the others wave at the traffic. The render snapshot has six
    zebras mid-crossing (their lights start at red) and the Sneaker Street / Startup HQ groups
    waiting at the outer curb.
  - 8 plaza idlers: 3 kids hopping at the balloon vendor, a queue of 3 at the hot-dog cart, 2 friends
    chatting on the bench at 300 degrees.
  - 8 storefront loiterers, one in front of the display window of every Shop A at Shop-A-local
    (4.5, -10.5) (on the café-terrace rug, left of the shoppers' door lane), facing the window with
    idle head turns; every 25-40 s they turn to face the plaza for 4 s. They never walk.
  - 8 café sitters on the first `CityLayout.cafeSeats` stool of every gap (seated, legs forward,
    facing the table, forearms on it) with a coffee cup and a slow sip cycle.
  - The street act at `CityLayout.ringPos(34, 250)`: a breakdancer on a cardboard mat (6 dia) next
    to a boombox with neon pink speakers dives into a head spin (300 deg/s for 3 s), flips back up and
    hops + waves for 2 s; 6 spectators on a 6.5 ring (open toward the plaza center) clap at 2 Hz with
    random small hops and cheer during the hop. A 7.5-stud circle there is reserved: no other idler
    or pigeon is placed inside it.
  - A fountain selfie trio (teens, r 14.5 at 135 / 145 / 155 degrees, facing outward): the middle
    one holds a phone up; "say cheese" (outer arms up, a tiny hop) every 6 s.
  - 2 window washers (see Sky).
- **Zone customers** (`CityLife.Customers`, 33 ChibiRig customers: adults 1.25, kids at 1.0; the
  citizen shirt palette, NameTag removed, everything Anchored with CanCollide / CanQuery / CanTouch
  false - CanQuery false keeps the HustlePrompt line of sight intact). Planned in zone-local space
  (`Mechanics.zoneGroundCFrame` at the pad top, -Z to the plaza; feet on the pad stripes, the Dog
  Walking lawn +0.2) and built in `bindMap` from the replicated zone models, present in locked zones
  too (seen through the gate as the busy shop you are working toward):
  - a queue at every counter: the Lemonade Stand 4 at (-7.5, 6) / (-9.5, 3.6) / (-11.5, 1.2) /
    (-13.5, -1.2) facing the stand (the 3rd a kid with a balloon, the new tail a kid holding a
    (255,230,90) lemonade cup); Sneaker Street 3 sneakerheads inside the velvet-rope lane at
    (14 / 17 / 20, 5) facing the store door (-X), the middle one filming with a phone up; Dog Walking 3
    in a line running sideways from the counter's end at (-7.5 / -10.3 / -13.1, -10.5) (the generic
    line's 3rd spot would stand on the paw-print trail); every other zone 3 at the first candidate
    (from the counter center P = the real `CounterTop`) P + (-7.5, -2) / (-9.5, -4.4) / (-11.5, -6.8),
    then (-9, -6) / (-11, -8.4) / (-13, -10.8), then (7, -6) / (9, -8.4) / (11, -10.8) (a head pair +
    a tail spot with the same spacing) whose spots validate unmoved and have a valid walk-back loop
    (else the best: most spots, a loop, least slide).
  - one extra per zone: seated where the zone has seats (found by name in `<Zone>.Dressing`, nearest the
    plan point): 2 café-stool sitters at the Lemonade Stand ((-16.6 / 16.6, -10), seat top 1.6, facing
    their `TableTop`, sipping lemon (255,230,90) cups), a soda sipper on the Food Truck `PicnicBench`
    near (20, -13.6) facing its `PicnicTop`, a creator filming on the couch `Cushion` near (-21.8, 2.4)
    facing the `CouchSeat` look, a kid bouncing on the Startup `Beanbag` near (-22, 8) facing the
    counter; else a browser strolling a 3-waypoint loop at 2.5 studs/s with 1.5-3 s pauses (Dog Walking
    around the hoops, Car Wash between the two queued cars at (-14.5, 0.8) / (-12.5, -2.6) / (-15.2,
    -4.8), >= 2.4 studs from the wash car's lane, Stock Desk between the money bags).
  - Validation (bindMap, pure math on the zone model's visible parts): every standing spot keeps 1.2
    studs from every visible zone part from 0.3 to 4.9 above the feet (ankle-high floor decals - paw
    prints, the walk mat, the conveyor bed - only keep 0.8 from the feet), >= 4.5 (XZ) from
    `PromptPart`, >= 4 from `AutoAnchor`, >= 4 from the gate -> prompt walkway segment, on the pad, and
    >= 2.4 from the other customers; a blocked queue spot slides 1 stud at a time away from the counter
    (up to 6), else that customer is dropped. Walk paths (the buyer's step + loop, browse loops) keep
    1.0 at 0.5-stud samples, the walkway rule and the pad. Every zone's spots and paths are recorded
    (`sim.customerGeo`) so the zone life keeps its distance from them. A scratch harness re-checks all
    of it against the real map with point sampling.
  - Behaviour: idle head turns, a weight-shift sway and an occasional wave toward the nearest player
    (else toward the gate). Every 5.5-8.5 s (hash-timed per zone, so a gold coin pops at every zone
    about every 7 s; the Lemonade Stand's first at 4 s so the render catches it, Dog Walking / Car Wash
    / Stock Desk after 5 s so their renders show the full line) the head of the queue buys: it steps
    1.2 studs toward the counter and hops 0.4 s with both arms up while the zone's coin (Ball 1.0, Neon
    (255,206,40), parked when idle) pops 3 studs up from the counter top over 0.6 s; then it walks a
    ~6 s loop around the queue's outer side (Sneaker Street: out of the rope lane's front, around the
    ropes and back in at the far end) and rejoins the tail while the others shuffle forward with the
    waddle. Anyone walking up the line keeps 2.4 studs behind the one ahead until that one stands at
    its spot (the new head: behind the buyer until it has stepped away), so a rejoining buyer never
    walks into a still-shuffling tail. A player within 2.5 studs makes a standing customer step 1.5
    studs aside (one of 8 pre-validated directions, the most "away" one) and return 2 s after the
    player left; a walking customer waits for a player standing right ahead (at most 2.5 s).
- **Zone life** (`CityLifeSim._bindZoneLife`, bound once in `bindMap` from `SideHustleMap.Zones`,
  client-local like the customers): the hustle zones' hero props in motion, so the zones - not the
  traffic - are where the eye goes. HARD RULE: nothing here ever moves or recolors `PromptPart`,
  `HustlePrompt`, `FeedbackPart`, `AutoAnchor`, `HustleStation` (or anything in it), `CounterTop`, any
  `Gate*` part or any part with CanCollide true; an entry whose named parts are missing or collide is
  skipped and all skipped entries are reported in ONE warning.
  - Spinners about world Y (map parts moved LOCALLY by CFrame, within 260 studs of the camera; their
    angle at the render snapshot is set per entry): the Lemonade Stand's `GiantLemon` + 2 `LemonTip`s
    (20 deg/s, about the lemon's center); the 3 mini sneakers (`MiniSole` / `MiniUpper` / `MiniToe`)
    on Sneaker Street's `DisplayPedestal`s (45 deg/s, alternating directions, each about its pedestal
    top center); Startup HQ's rocket (`RocketNose` x4, `RocketFin` x4, `RocketWindow`; 20 deg/s about
    the `RocketBody` axis - the collidable body never moves: it is a vertical cylinder on the spin axis,
    so the rocket still reads as turning; no bob for the same reason); the Creator Studio neon heart
    (`HeartBody` + 2 `HeartLobe`s, 35 deg/s about the `HeartPost` axis, plus a heartbeat: Transparency
    0 -> 0.3 -> 0 over 1.2 s, city pulse); the Food Truck's roof burger (`BurgerBunBottom`, `Patty`,
    `Cheese`, `Lettuce`, `BunTop`, 3 `SesameSeed`s, 25 deg/s). Sneaker Street's giant sneaker (30 deg/s
    about the `SneakerPedestal` top) is SKIPPED today: its `SneakerSole` / `SneakerHeel` / `SneakerBody`
    / `SneakerToe` collide (it spins with no code change once they are CanCollide false). A full turn of
    every spinner was checked against every neighbouring visible part (inside at all 72 angles or none,
    the CitySpin rule). `unbindMap` puts every spun part back in its built pose.
  - Stock Desk ticker chase (city pulse, 10 Hz, property sets only): the hype board's 5 `TickerStrip`
    segments (climbing), the office screens' 4 `TickerLine`s and the 4 pillars' `TickerStripe`s each
    run their own chase: every 0.3 s one segment is lit (Transparency 0, Color (60,255,120)) while the
    rest sit at Transparency 0.5 in their own color. Restored by `unbindMap`.
  - Car wash (`CityLife.ZoneLife.WashCar`: a `VehicleRig` Car scaled 0.62 to the zone's 8-stud cars, 20
    parts): it rolls zone-locally along the conveyor centerline (`ConveyorBase` z; riding on the
    `ConveyorRoller` tops) at 2.5 studs/s with 0.5 s eases: in at the -X end (the queued cars' end),
    2 s stopped under the first `RollerBrush` with a 0.15-stud scrub bob, out of the +X end where it
    eases to a stop, 0.5 s parked, 4 s hidden (PARK), then the next pass in the next color ((255,206,40)
    -> (255,120,170) -> (90,200,255) -> (140,230,110)): one pass every 11.8 s. The tunnel's middle bay
    holds the map's own collidable demo car (`CarBody` / `CarCabin` / `CarWheel` directly under
    `Zones.CarWash`), which may never move: the moving car stops nose-to-tail behind it and continues
    from just past its front bumper - a swap hidden by the tunnel roof, its 4.5-tall front wall and the
    taller demo car. A player standing on the conveyor ahead holds it. Validated in `bindMap`: its +-4
    wide footprint (h 0.3-6) >= 4.5 (XZ) from `PromptPart` (18.9), >= 4 from `AutoAnchor` (16.0), >= 2.4
    from every customer spot and walk path (3.2); it passes between the tunnel walls and the brushes
    scrub its flank. The snapshot catches it (yellow) 85% down its exit roll, half out of the tunnel
    (`r4_zone_top`).
  - Dog Walking agility course (`CityLife.ZoneLife.AgilityDog1/2`: the walker-dog rig with a collar
    instead of a leash, 7 parts each; one (230,180,120), one (250,250,250) with brown ears), planned
    from the real `HoopBar` / `WeavePole` / `ParkLawn` parts: up the hoop line through both hoops (a
    +1.5-stud, 0.4 s hop through each, its apex 0.25 past the hoop plane so the body clears the bottom
    bar on the way up and the tail on the way down; pitch follows the arc), a left turn into the weave,
    a semicircle round each weave pole on alternate sides (radius = half the pole spacing, so every
    pole stays exactly 1.0 from the course), a happy loop at the top, down the free lane between the
    hoop posts and the fence (x = hoop line - 5.3), a U-turn back onto the hoop line: 93.5 studs, a lap
    every 15.6 s at 6 studs/s, half a lap apart, tails wagging at 6 Hz. Validated in `bindMap`: the
    dog's column (0.3-2.2 above the feet) keeps 1.0 from every visible zone part (the hoops excepted
    only while hopping through them; the posed dogs were point-checked over a whole lap: >= 0.12 from
    any hoop bar), the prompt / anchor rules and >= 2.4 from every customer (4.4). A dog sits for 1.5 s
    when a player comes within 3 studs (never mid-hop) and keeps 3 studs behind the other dog. The
    snapshot catches dog 1 rising into the first hoop (`r4_dog_inside`, whose foreground Dog Walking
    queue hides the rest of the course).
- **Plaza pigeons**: 3 flocks of 6 (body / head balls, wedge beak, two small wings) on free plaza
  spots (`isPlazaPointFree` with the flock's spread + 1, r 18-46, outside the street-act circle and
  >= 8 studs from every idler). They peck (head dips 0.3 every 1-3 s) and make short turning hops.
  A player or a walking citizen within 6 studs (or, now and then, nothing at all) flushes the flock:
  it flaps up in an arc (peak +7) and lands 10-16 studs away (away from the threat, clear of the
  other flocks) within 1.5 s.
- **Sky**: a "SIDE HUSTLE CITY" blimp circling at r 250, y 120 (6 studs/s); three V flocks of five
  white birds over the plaza (r 62-94, y 58-70, flapping with glides); 12 chunky cartoon clouds (5
  white SmoothPlastic balls each, scale 0.8-1.4): 10 on a ring at r 400 / 480, y 165-225 (17-30
  degrees above the horizon from spawn, just over the skyline) + 2 high ones at r 200, y 260, orbiting
  the origin at 0.5 deg/s with a 0.5-stud bob; a spinning gold "$" coin floating above every skyline
  `DomeFinial`; and every map part or model carrying a numeric `CitySpin` attribute (degrees/s) spins
  about world Y around its `GetPivot()` (today: the 8 anchor `Icon` models at 25, `Plaza.SpinCoin`
  at 40 and the 2 `CraneTop`s); 5 hot-air balloons in the zone colors (`VehicleRig.buildBalloon`: a
  14-dia envelope, a WHITE equator band 14.4 x 1.4, a wooden 3 x 2.4 x 3 basket 5 studs below the
  envelope, 2 ropes; 25 parts) orbiting the origin at 0.8 deg/s in alternating directions with a
  1.5-stud / 8 s bob and a +-3 degree sway: yellow r 178 y 96 (framed by the spawn view over the
  Lemonade Stand), green r 152 y 106, cyan r 186 y 124, pink r 157 y 114 (framed by the plaza view),
  blue r 174 y 116 (envelope centers). The + balloons fly the outer orbits and the - ones the inner
  orbits, so opposite-direction balloons always pass >= 15 studs apart radially (17 studs minimum over
  a full orbit); every orbit is >= 57 studs (radially) inside the blimp path, and each basket bottom
  (14.4 below the center, minus the bob) stays >= 25 studs above every roof, sign and icon under its
  orbit (checked against the real map). Two window washers (pure `CityLayout` data, 16 parts each): a
  10 x 1 x 2.4 (255,170,40) cradle 1.5 studs in front of the plaza face of `MidBuilding0` (7.5
  degrees, behind the Lemonade Stand; cradle at building-local x -12) and `MidBuilding13` (202.5
  degrees; x +6) - on the side away from each blade sign (x = +-(W/2 - 4)), clear of the window bands
  / mullions (<= 0.8 proud) and above the awnings (top 9.2) - with a worker in a (255,206,40) hard hat
  facing the wall and scrubbing in circles, and 2 cables (0.2 thick, from just above the cornice,
  resized at most every 0.25 s). The cradle rides from under the cornice (platform center H - 7) down
  to a platform bottom of y 12 and back every 60 s (point-checked against every map part over the
  whole ride).

- **City pulse** (0 parts; `CityLifeSim._bindPulse`, collected once in `bindMap` from
  `SideHustleMap.City` and the plaza): a hierarchy - running lights mean "hustle here". Marquee frames
  (4-bar `NeonFrame` / the title billboard's `BillboardTrim`, grouped by parent model and nearest text
  board, ordered clockwise as seen from the board's text face) chase ONLY on the 8 zone `AnchorSign`s,
  the plaza title billboard (`BillboardBoard`) and the 2 `HeroTower` `Billboard`s (11 frames): one bar
  at a time takes its board's face color (`board.Color`), running clockwise with a hash phase per
  frame - every 0.3 s on the anchor frames, with the lit bar at Transparency 0 and the other 3 at
  0.35; every 0.45 s on the title / hero frames. The Shop-B rooftop `Billboard`s and the bus ads stay
  steady NEON_WHITE / pink (never touched). Each anchor's `NeonTrim` breathes Transparency 0 <-> 0.4
  over 2 s with a phase of zone Order x 0.25 s, so a wave runs round the 8 zones. Also: the 18
  aviation tips (`AntennaTip`, `SpireTip`, the cranes' `JibTipLight`) blink - Transparency 0 for 0.35 s
  every 1.8 s and 0.8 otherwise (hash phase, ~20% duty); the 24 `BladeSignNeon` edges breathe -
  Transparency 0 -> 0.35 -> 0 over 3 s, phase (k - 1) / 24 of the period for `MidBuilding<k>`, a wave
  round the ring; the zone-life ticker chase and heartbeat; the police lightbar. Runs at 10 Hz from
  the one Heartbeat via an accumulator, only for parts within 500 studs of the camera, property sets
  only and only on change, no per-step allocation; the originals are stored and `sim:unbindMap()`
  restores them (the controller calls it when the city life stops). Never touches zone contract parts
  or zone neon (`GatePost`, `GateTopBar`, `PadCurbNeon`, `EntranceCarpetNeon`), traffic lights or sign
  faces.

World-builder contract for the life: keep `CityLayout` (laneLoops, backLaneLoops, sidewalkLoops,
backSidewalkLoops, crosswalks, busStops, plazaProps, plazaPlanters / wanderAreas obstacles, shops,
storefronts, cafeSeats, cafeTerraces, skyline specs incl. door placement) the single source of truth;
keep the zone model names the customers read (`Zones.<ZoneId>`, `HustleStation.CounterTop` /
`PromptPart` / `AutoAnchor`, the Lemonade `StandTop`, the Dressing seats `Stool` / `TableTop`,
`PicnicBench` / `PicnicTop`, `Cushion` / `CouchSeat`, `Beanbag`) - a moved prop is fine, the validation
follows it; keep the zone-life names (`GiantLemon` / `LemonTip`; `SneakerPedestal` + `Sneaker*`;
`DisplayPedestal` + `MiniSole` / `MiniUpper` / `MiniToe`; `RocketBody` + `RocketNose` / `RocketFin` /
`RocketWindow`; `HeartPost` + `HeartBody` / `HeartLobe`; `BurgerBunBottom` + the burger parts and
`SesameSeed`; `ConveyorBase` / `ConveyorEnd` / `ConveyorRoller` / `RollerBrush` and the tunnel demo
car; `HoopBar` / `HoopPost` / `WeavePole` / `ParkLawn`; `TickerStrip` / `TickerLine` / `TickerStripe`)
and keep every part the zone life spins non-colliding (a collidable one only skips its entry); keep
the car-wash conveyor lane (+-4 of its centerline) >= 4.5 / 4 studs from the prompt / anchor and the
agility course (the hoop line, the weave, the lane between the hoop posts and the fence) free; keep
each zone's `EntranceCarpet` a thin slab (crossers stand on its top); keep the three crosser lines on
every zone axis (laterals -5 / 0 / +5, from r 57 to r 116.6, body extent +-1.45 up to 4.9 above the
surface) free of parts - `tools/check_map.luau` checks them - and the pad edge / gate wall at r >= 118;
keep every Shop A door lane free (Shop-A-local x 7.5..10.5 from the walk line to the door at
(8.5, -8), body extent 1.45, 0.3-4.9 above the surface; the door's plinth 1.2 tall) and the window
shopper's spot (4.5, -10.5); keep the pulse names (`NeonFrame` bars as children of the same model as
their text board, `AnchorSign` in `Anchor<ZoneId>` (with its `ZoneId` attribute and `NeonTrim`), the
plaza `BillboardBoard` + `BillboardTrim`, the `HeroTower<k>` `Billboard`, `AntennaTip`, `SpireTip`,
`JibTipLight`, `BladeSignNeon` under `MidBuilding<k>`); keep the plaza faces of `MidBuilding0` and
`MidBuilding13` free 1.5-4 studs out at the cradles' x (-17..-7 and 1..11) from y 11.5 to the cornice;
keep the Back Avenue walking bands free from the surface up to 5 studs (r 245.45-249.95 and
270.65-274.85); keep everything under the balloon orbits (r 145-193) at least 25 studs below the
baskets (below Y 55 for r 171-185, 65 for r 145-159, 73 for r 150-164, 75 for r 167-181 and 83 for
r 179-193); keep the TrafficLight lamp names and `ZoneId`; keep the `DomeFinial` part name; keep
`ringPos(34, 250)` free for the street act (7.5-stud circle); keep the ring lanes clear up to the
tallest vehicle (world Y 10 over the Outer2 lane, Y 14 over the inner lanes for the van's cone); on the
outer sidewalk keep the walking band free of parts from the surface up to 5 studs: r 110.5-115.6 within
~10 degrees of each zone axis and r 112.1-117.4 between the zones (walkers sidestepping a player may
briefly use r 108-117.6).

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
