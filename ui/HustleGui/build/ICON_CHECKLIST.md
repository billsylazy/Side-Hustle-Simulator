# Icon checklist — HustleGui

**7 icon(s) to upload.** Until you do, these show as blank images (they use the placeholder `rbxassetid://0`).

## How to upload

1. In Roblox Studio open **View → Asset Manager**, click **Bulk Import**, and pick the 256px files listed below (from your icon pack folder).
2. Right-click each uploaded image → **Copy Asset ID**.
3. Easiest: paste the IDs back to Claude as `icon name = id` and it will rebuild the file with every ID filled in. Or fill them in by hand at the locations listed.

## Icons to upload

| # | Icon | Upload this file | Used at |
|---|---|---|---|
| 1 | Currency/Cash/Green Cash 1st | `Free Icon Pack v3.1 (Basic)/Currency/Cash/256px/Green Cash 1st 256px.png` | `StarterGui.HustleGui.Main.Panel.Detail.Rows.UpgradeRowTemplate.Icon.Image`<br>`StarterGui.HustleGui.HustleController (script)` |
| 2 | Currency/Cash/Green Cash 1st Outline | `Free Icon Pack v3.1 (Basic)/Currency/Cash/256px/Green Cash 1st Outline 256px.png` | `StarterGui.HustleGui.Main.CashPill.CashIcon.Image` |
| 3 | Item/Lock/Lock 1st | `Free Icon Pack v3.1 (Basic)/Item/Lock/256px/Lock 1st 256px.png` | `StarterGui.HustleGui.Main.Panel.Tabs.HustleTabTemplate.LockIcon.Image`<br>`StarterGui.HustleGui.Main.Panel.Detail.LockedNote.LockGlyph.Image` |
| 4 | Main/Lighting/Lighting 1st | `Free Icon Pack v3.1 (Basic)/Main/Lighting/256px/Lighting 1st 256px.png` | `StarterGui.HustleGui.HustleController (script)` |
| 5 | Main/Rebirth and Auto Open/Auto Open 1st | `Free Icon Pack v3.1 (Basic)/Main/Rebirth and Auto Open/256px/Auto Open 1st 256px.png` | `StarterGui.HustleGui.HustleController (script)` |
| 6 | Main/Star/Blue Star 1st | `Free Icon Pack v3.1 (Basic)/Main/Star/256px/Blue Star 1st 256px.png` | `StarterGui.HustleGui.HustleController (script)` |
| 7 | UI/Close Button/Close Button 1st Outline | `Free Icon Pack v3.1 (Basic)/UI/Close Button/256px/Close Button 1st Outline 256px.png` | `StarterGui.HustleGui.Main.CloseButton.Image` |

## Other things to fill in

- [ ] Upload the icons listed above, then paste the asset ids into icon_ids and rebuild (the per-effect row icons in HustleController are icon tokens and update with the same build)

## Files

- `HustleGui.rbxmx` — drag into **StarterGui** in the Explorer
