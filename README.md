# Side Hustle Simulator 💸

A bright, chunky Roblox simulator: squeeze lemonade, walk dogs, flip sneakers and
pitch startups your way around a hub plaza. Hire chibi workers (Intern → CEO), buy
upgrades, unlock all 8 hustle zones behind paywall gates, then **rebirth** for a
permanent multiplier and do it all again — faster.

Built in the style of the [Art & Feel Guide](docs/art-feel-guide.md): SmoothPlastic +
Neon, one signature color per zone, Fredoka One / Luckiest Guy UI, and juice on
every action (money popups, button bounces, sparkles, a full-screen rebirth
celebration).

## The game loop

```
HUSTLE (prompt at each zone station) ──> CASH ──> UPGRADES + WORKER CRATES
   ^                                              │
   │                                              v
REBIRTH (x1.5, x2, x2.5... permanent) <── UNLOCK ZONES ($500 ... $10M)
```

- **8 zones** (ring around the spawn plaza): Lemonade Stand → Dog Walking → Sneaker
  Street → Car Wash → Food Truck → Creator Studio → Stock Desk → Startup HQ.
  Each gate shows its price and is visible from spawn.
- **Workers** are hired from crates (Starter / Pro / Elite) with weighted rarities —
  Intern (coffee cup), Employee, Manager (clipboard), CEO (sunglasses + gold suit).
  Equipped workers waddle behind you and earn cash every second.
- **Upgrades**: Hustle Power, Worker Hustle, Fast Shoes, Worker Slots.
- **Quests** pay out from lifetime stats and survive rebirth.
- All balance lives in one file: `src/ReplicatedStorage/Shared/GameConfig.luau`.

## Getting it into Roblox Studio

### Option A — open the built place (fastest)

1. Download `build/SideHustleSimulator.rbxlx` and open it in Roblox Studio.
2. **Game Settings → Security → Enable Studio Access to API Services** (needed for
   DataStore saves while testing).
3. Press **Play**. That's the whole game.

### Option B — Rojo (for development)

```sh
rojo build -o build/SideHustleSimulator.rbxlx   # or `rojo serve` + the Studio plugin
```

The project tree is defined in `default.project.json`; all code is under `src/`,
UI model files under `ui/*/build/`.

### Option C — manual import

1. Insert the five UI files from `ui/*/build/*.rbxmx` into **StarterGui**
   (right-click StarterGui → *Insert from File…*).
2. Recreate `src/` as instances: folder names map 1:1 (`Services/*.luau` →
   ModuleScripts in a `Services` folder, `GameManager.server.luau` → a Script in
   ServerScriptService, `Shared/*.luau` → ModuleScripts in
   `ReplicatedStorage/Shared`, StarterPlayerScripts likewise). Option A/B is much
   less error-prone.

## After importing — two TODO lists

The game runs immediately, but two kinds of assets are intentionally placeholders
(no Toolbox assets are ever auto-inserted):

1. **UI icons** — see `ui/ICON_CHECKLIST.md`. Upload the listed 256px icons from the
   gvesster *Free Icon Pack* via **View → Asset Manager → Bulk Import**, then paste
   the asset ids back (or send them to Claude to rebuild the `.rbxmx` files with ids
   baked in). Until then, icon slots render blank.
2. **Sounds** — `GameConfig.Sounds` has empty ids for Coin / Buy / Error / LevelUp /
   Hire / Rebirth / Click. Paste your own `rbxassetid://…` ids; empty entries are
   silently skipped.

## Repo map

| Path | What |
|---|---|
| `ARCHITECTURE.md` | The binding contract: remotes, data schema, map + UI instance tree, module APIs |
| `docs/art-feel-guide.md` | Art direction (from the original design PDF) |
| `src/ReplicatedStorage/Shared/` | GameConfig (all tuning), Types, FormatNumber, ButtonFX, ClientEffects |
| `src/ServerScriptService/` | GameManager entry point + 8 services (data, remotes, zones, hustles, workers, upgrades, rebirth, quests) |
| `src/ServerScriptService/World/MapBuilder.luau` | Builds the whole map from primitives at server start |
| `src/StarterPlayerScripts/` | Client bootstrapper + controllers (gates, worker rigs, rebirth celebration) |
| `ui/` | roblox-ui-builder specs, controllers, built `.rbxmx`, previews, icon checklist |
| `tools/check_luau.luau` | `lune run tools/check_luau.luau <files>` — syntax-check Luau sources |

## Security & data notes

- All currency/ownership mutations happen server-side; clients only send intents
  (ProximityPrompts for hustling/unlocking, rate-limited RemoteEvents for the rest).
- Player data uses a session-locked `UpdateAsync` pattern (prevents multi-server
  data loss), retry-with-kick on load failure, auto-save, and `BindToClose` saves.
- Gates are enforced economically: walking through a locked gate is possible for an
  exploiter but worthless — earnings in locked zones are rejected server-side.

## Testing checklist (in Studio)

- [ ] Output shows GameManager/services initialized, no red errors
- [ ] Hustle prompt at the Lemonade Stand pays out with a money popup
- [ ] Dog Walking gate unlocks at $500 and the wall opens
- [ ] Shop buys an upgrade (sparkle + level up), crate hires a worker
- [ ] Worker waddles behind you and cash ticks up every second
- [ ] Rebirth at $25K triggers the full-screen celebration and resets zones
- [ ] Leave and rejoin — cash, workers, zones and rebirths persist
