# Icon checklist — all screens (merged)

**16 distinct icons to upload**, from the gvesster *Free Icon Pack v3.1*.
Until uploaded, icon slots render blank (`rbxassetid://0`).

## How to upload

1. In Roblox Studio: **View → Asset Manager → Bulk Import**, pick the 256px files below.
2. Right-click each uploaded image → **Copy Asset ID**.
3. Paste the ids back to Claude as `icon name = id` lines to get the `.rbxmx` files rebuilt
   with every id baked in — or add them to each spec's `icon_ids` and rerun
   `python3 .roblox-ui-tools/scripts/build_ui.py <spec> --out <screen>/build` yourself.

## Icons

| # | Icon | Pack file (256px) | Used by |
|---|---|---|---|
| 1 | Currency/Cash/Green Cash 1st Outline | `Free Icon Pack v3.1 (Basic)/Currency/Cash/256px/Green Cash 1st Outline 256px.png` | MainHUD |
| 2 | Item/Box/Box 1st | `Free Icon Pack v3.1 (Basic)/Item/Box/256px/Box 1st 256px.png` | ShopGui |
| 3 | Item/Box/Golden Box 1st | `Free Icon Pack v3.1 (Basic)/Item/Box/256px/Golden Box 1st 256px.png` | ShopGui |
| 4 | Item/Chest/Chest 1st | `Free Icon Pack v3.1 (Basic)/Item/Chest/256px/Chest 1st 256px.png` | ShopGui |
| 5 | Item/Scroll/Scroll 1st Outline | `Free Icon Pack v3.1 (Basic)/Item/Scroll/256px/Scroll 1st Outline 256px.png` | MainHUD |
| 6 | Item/Shoe/Blue Shoe 1st | `Free Icon Pack v3.1 (Basic)/Item/Shoe/256px/Blue Shoe 1st 256px.png` | ShopGui |
| 7 | Main/Rebirth and Auto Open/Rebirth 1st | `Free Icon Pack v3.1 (Basic)/Main/Rebirth and Auto Open/256px/Rebirth 1st 256px.png` | RebirthGui |
| 8 | Main/Rebirth and Auto Open/Rebirth 1st Outline | `Free Icon Pack v3.1 (Basic)/Main/Rebirth and Auto Open/256px/Rebirth 1st Outline 256px.png` | MainHUD |
| 9 | Main/Shopping Cart/Golden Shopping Cart 1st Outline | `Free Icon Pack v3.1 (Basic)/Main/Shopping Cart/256px/Golden Shopping Cart 1st Outline 256px.png` | MainHUD |
| 10 | Nature/Thunderstorm/Thunderstorm 1st | `Free Icon Pack v3.1 (Basic)/Nature/Thunderstorm/256w/Thunderstorm 1st 256px.png` | ShopGui |
| 11 | Player/Add Player/Add Player 1st | `Free Icon Pack v3.1 (Basic)/Player/Add Player/256px/Add Player 1st 256px.png` | ShopGui |
| 12 | Player/Arm/Arm 1st | `Free Icon Pack v3.1 (Basic)/Player/Arm/256px/Arm 1st 256px.png` | ShopGui |
| 13 | Player/Friend/Friend 1st Outline | `Free Icon Pack v3.1 (Basic)/Player/Friend/256px/Friend 1st Outline 256px.png` | MainHUD |
| 14 | Player/Player/Player 1st | `Free Icon Pack v3.1 (Basic)/Player/Player/256px/Player 1st 256px.png` | WorkersGui |
| 15 | UI/Checkmark/Checkmark 1st | `Free Icon Pack v3.1 (Basic)/UI/Checkmark/256px/Checkmark 1st 256px.png` | QuestsGui |
| 16 | UI/Close Button/Close Button 1st Outline | `Free Icon Pack v3.1 (Basic)/UI/Close Button/256px/Close Button 1st Outline 256px.png` | QuestsGui, RebirthGui, ShopGui, WorkersGui |

Per-screen checklists with exact placement locations live in `ui/<Screen>/build/ICON_CHECKLIST.md`.
