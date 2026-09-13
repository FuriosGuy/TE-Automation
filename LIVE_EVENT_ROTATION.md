# Live Event Rotation

This repository mirrors the event timeline shown by the game in Roblox
Experience Events. It does not decide gameplay, grant event wins, or activate
environments. Those responsibilities remain in `SpeedBrainrotDev`.

## Rotation

- The rotation starts at `2026-09-10T23:00:00Z`, aligned with the current live Blood Moon event.
- The configured seed and version must match the game's `CoreConfig` values.
- A deterministic enabled Major event is selected first.
- After its active and grace windows, a deterministic enabled Minor event is selected.
- After the Minor event, selection returns to the Major tier.
- If a tier has no enabled candidate, the sync falls back to any enabled tiered event so the timeline remains recoverable.
- Event IDs are sorted before deterministic selection, so every runner derives the same result.

Current configured tiered events:

- `Bloodmoon`: Major, 3 days active, 3 days grace.
- `NeonRush`: Minor, 2 days active, 2 days grace.
- `FrostbiteRally`: Minor, 2 days active, 2 days grace; thumbnail `75464816447978`.

`Weekend2x` remains an independent recurring event and can overlap the tiered
rotation. Frostbite Rally's thumbnail is mirrored here; its kart catalog and
particle assets remain authoritative in `SpeedBrainrotDev`.

## Sync behavior

Each run stages at most the current tiered window and its next window. The next
window is private when the root config requests publication only after the
previous window ends. When that window becomes current, the next scheduled run
updates it to the final visibility.

The state file is keyed by event key and window start. This prevents a later
run from creating a duplicate platform event for the same rotation window.

Use `-NowUtcOverride` for read-only previews. Do not use `-Apply` until the
payloads and visibility changes have been reviewed.
