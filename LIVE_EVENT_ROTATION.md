# Live Event Rotation

This repository mirrors the event timeline shown by the game in Roblox
Experience Events. It does not decide gameplay, grant event wins, or activate
environments. Those responsibilities remain in `SpeedBrainrotDev`.

## Rotation

- Production transition anchor is `2026-09-30T23:00:00Z`, aligned with the
  current Blood Moon window. Version `3` and seed must match the game's server
  `CoreConfig`.
- The first window is sequence `4` and keeps current Blood Moon active for its
  original 3 days, followed by the new 2-day grace period.
- A deterministic enabled Major event is selected first.
- After its active and grace windows, a deterministic enabled Minor event is selected.
- After the Minor event, selection returns to the Major tier.
- If a tier has no enabled candidate, the sync falls back to any enabled tiered event so the timeline remains recoverable.
- Event IDs are sorted before deterministic selection, so every runner derives the same result.

After the preserved Blood Moon window, the next event is Neon Rush starting at
`2026-10-05T23:00:00Z`. All later windows use these durations:

- `Bloodmoon`: Major, 2 days active, 2 days grace.
- `NeonRush`: Minor, 1 day active, 2 days grace.
- `FrostbiteRally`: Minor, 1 day active, 2 days grace; thumbnail `75464816447978`.

A Major/Minor pair now spans 7 days, down from 10 days. The separate DEV
universe keeps its private schedule.

`Weekend2x` remains an independent recurring event and can overlap the tiered
rotation. Frostbite Rally's thumbnail is mirrored here; its kart catalog and
particle assets remain authoritative in `SpeedBrainrotDev`.

## Sync behavior

Each run stages at most the current tiered window and its next window. The next
window stays private while the previous active window is still running. Once
that previous active window ends, the next scheduled run publishes it using its
final visibility, even though its own start time may still be in the future.
The game's separate in-game 24-hour display gate does not control this
Experience Events visibility.

The state file is keyed by event key and window start. This prevents a later
run from creating a duplicate platform event for the same rotation window.

Use `-NowUtcOverride` for read-only previews. Do not use `-Apply` until the
payloads and visibility changes have been reviewed.
