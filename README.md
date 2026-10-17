# Side Hustle Simulator 💸

A bright, chunky Roblox simulator: squeeze lemonade, walk dogs, flip sneakers and
pitch startups your way around a hub island. Earn **cash and XP**, level up to unlock
new hustles, buy each hustle's own upgrades until it **runs itself**, hire chibi
workers (Intern → CEO), then **rebirth** for a permanent multiplier and do it all
again — faster.

Built in the style of the [Art & Feel Guide](docs/art-feel-guide.md): cartoony and
saturated, one signature color per zone, Fredoka One / Luckiest Guy UI, juice on
every action (money popups, combo callouts, level-up banners, a full-screen rebirth
celebration), now with Future lighting, atmosphere, terrain and particles.

## The game loop (v2)

```
HUSTLE (each zone plays differently) ──> CASH + XP
   ^                                       │
   │                        LEVEL UP ──> new hustle unlocks (Lv 1, 4, 8, 13, 19, 26, 34, 43)
   │                                       │
   └── REBIRTH at Lv 50 (x1.5, x2 …) <── CASH buys each hustle's unique upgrades + AUTOMATION
```

### Eight hustles, four mechanics

| Zone | Unlock | Mechanic | Unique upgrades (Earn / XP / Speed / **Automation**) |
|---|---|---|---|
| Lemonade Stand | Lv 1 | **Tap** — mash to build a combo (up to ×2) | Bigger Pitcher / Extra Sugar / Ice Cold / **Auto-Squeezer** |
| Dog Walking | Lv 4 | **Hold** — slow, big payouts | Extra Leash / Treat Pouch / Comfy Sneakers / **Dog Sitter** |
| Sneaker Street | Lv 8 | **Timing** — flip when the hype meter peaks | Hype Drops / Sneakerhead Network / Fast Listings / **Reseller Bot** |
| Car Wash | Lv 13 | **Hold** | Foam Cannon / Wax Finish / Power Washer / **Conveyor Tunnel** |
| Food Truck | Lv 19 | **Tap** combo | Double Patty / Secret Sauce / Flat-Top Grill / **Fry Cook Crew** |
| Creator Studio | Lv 26 | **Charge** — fill the hype bar to GO VIRAL | Ring Light Pro / Viral Editing / Stream Deck / **Content Scheduler** |
| Stock Desk | Lv 34 | **Timing** — trade at the ticker peak | Insider Newsletter / Market Analyst / Hotkey Trading / **Algo Trader** |
| Startup HQ | Lv 43 | **Charge** — pitch until FUNDED | Pitch Deck 2.0 / Venture Network / Coffee IV Drip / **Co-Founder** |

Every mechanic is resolved on the server (combo windows, market phase from the shared
server clock, charge counters), so exploiters can't fake outcomes. Automation stations
a chibi worker at the zone that hustles for you every 2 s.

- **Workers** (companions) come from Starter / Pro / Elite crates with weighted rarities
  and waddle behind you earning cash every second. **Perks** (Fast Shoes, Worker Slot,
  Worker Hustle) are the global upgrades in the Shop.
- **Quests** pay out from lifetime stats and survive rebirth.
- All balance lives in one file: `src/ReplicatedStorage/Shared/GameConfig.luau`.

## Getting it into Roblox Studio

### Option A — open the built place (fastest)

1. Download `build/SideHustleSimulator.rbxlx` and open it in Roblox Studio.
2. **Game Settings → Security → Enable Studio Access to API Services** (needed for
   DataStore saves while testing).
3. Press **Play**.

### Option B — Rojo (for development)

```sh
rojo build -o build/SideHustleSimulator.rbxlx   # or `rojo serve` + the Studio plugin
```

The tree is defined in `default.project.json` (it also sets `Lighting.Technology =
Future`); all code is under `src/`, UI model files under `ui/*/build/`.

### Option C — manual import

Insert the six UI files from `ui/*/build/*.rbxmx` into **StarterGui**, then recreate
`src/` as instances (folder names map 1:1). Options A/B are much less error-prone.

### Using the Roblox Studio MCP with Claude

The Studio MCP server runs on your computer, so it is only reachable from a Claude
session that also runs there (Claude Desktop app, or `claude remote-control` in this
folder). From such a session Claude can build straight into Studio and playtest.

## After importing — two TODO lists

1. **UI icons** — `ui/ICON_CHECKLIST.md`. Upload the listed 256px icons from the
   gvesster *Free Icon Pack v3.1* via **View → Asset Manager → Bulk Import**, then paste
   the asset ids back (or send them to Claude to rebuild the `.rbxmx` files with ids
   baked in). Until then icon slots render blank.
2. **Sounds** — `GameConfig.Sounds` has empty ids (Coin / Buy / Error / LevelUp / Hire /
   Rebirth / Click / Combo / Burst). Paste your own `rbxassetid://…` ids; empty entries
   are silently skipped.

## Repo map

| Path | What |
|---|---|
| `ARCHITECTURE.md` | The binding contract: remotes, data schema, mechanics math, map + UI instance tree, module APIs |
| `docs/art-feel-guide.md` | Art direction (from the original design PDF) |
| `src/ReplicatedStorage/Shared/` | GameConfig (all tuning), Mechanics (pure shared helpers), Types, FormatNumber, ButtonFX, ClientEffects, ChibiRig |
| `src/ServerScriptService/` | GameManager entry point + 9 services (data, remotes, levels, zones, hustles, workers, upgrades, rebirth, quests) |
| `src/ServerScriptService/World/MapBuilder.luau` | Builds the island (terrain, lighting, 8 zones, props, particles) from primitives at server start |
| `src/StarterPlayerScripts/` | Client bootstrapper + controllers (gates, worker rigs, automation rigs, station feedback, rebirth celebration) |
| `ui/` | roblox-ui-builder specs, controllers, built `.rbxmx`, previews, icon checklist |
| `tools/check_luau.luau` | `lune run tools/check_luau.luau <files>` — syntax-check Luau sources |

## Security & data notes

- All currency/XP/ownership mutations happen server-side; clients only send intents
  (ProximityPrompts for hustling, rate-limited RemoteEvents for purchases).
- Player data uses session-GUID locking over `UpdateAsync` (prevents multi-server and
  fast-rejoin data loss), retry-with-kick on load failure, auto-save, and a
  `BindToClose` drain of in-flight saves.
- Gates are enforced economically: walking through a locked gate is possible for an
  exploiter but worthless — hustles in locked zones are rejected server-side.

## Testing checklist (in Studio)

- [ ] Output shows GameManager/services initialized, no red errors
- [ ] Squeezing at the Lemonade Stand pays cash + XP, combo counter climbs on mashing
- [ ] Level 4 banner fires and the Dog Walking gate opens
- [ ] Hustles panel buys Bigger Pitcher; Auto-Squeezer stations a rig that earns while idle
- [ ] Sneaker Street hype meter swings; flipping at the peak shows PEAK FLIP!
- [ ] Creator Studio charge bar fills to a VIRAL! burst
- [ ] Shop hires a worker; it waddles behind you and cash ticks up
- [ ] Rebirth at level 50 triggers the celebration and resets level/upgrades
- [ ] Leave and rejoin — cash, level, upgrades, workers and rebirths persist
