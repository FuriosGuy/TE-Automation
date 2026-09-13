# Automation

Scheduled Roblox Experience Event synchronization for the main and DEV universes.
The event sync mirrors the game's deterministic Major/Minor rotation for
dashboard visibility and analytics; gameplay state remains authoritative in
SpeedBrainrotDev.

## GitHub Actions secrets

Add these repository secrets:

- `ROBLOX_EVENT_MAIN_API_KEY` for the main workflow
- `ROBLOX_EVENT_API_KEY` for the DEV workflow
- `ROBLOX_NOTIFICATION_MAIN_API_KEY` for main reward notifications every 30 minutes

Keep API keys out of JSON files, `.env`, commits, and workflow output.

## Workflows

- `Main Version` syncs `config.github-main.json` hourly.
- `DEV Version` syncs `config.github-dev.json` hourly.
- `Main Reward Notifications` scans ready reward state every 30 minutes and sends at most one notification per offline user per run.
- Tiered events use the configured rotation: Major, then Minor, then Major.
- `Weekend2x` remains independently scheduled, and disabled events are not synced.

All workflows support manual runs from the GitHub Actions tab.

## Local run

Copy `tools/RobloxEventSync/.env.example` to `.env`, set the matching API key, then run from this repository root:

```powershell
./tools/RobloxEventSync/Sync-BloodMoonEvent.ps1 -ConfigPath ./tools/RobloxEventSync/config.json -Apply
```

Use `config.github-main.json` or `config.github-dev.json` for a dry run without local config.
The script name is retained for workflow compatibility even though it now syncs
all configured events.

## Event rotation

`tools/RobloxEventSync/config*.json` contains the same rotation anchor, seed,
and version used by the game. Blood Moon is the Major event, while Neon Rush
and Frostbite Rally are Minor-event candidates. The sync derives only the
current event and the next event window, so it does not create a second
independent schedule.

Run a safe preview with a fixed timestamp before applying changes:

```powershell
./tools/RobloxEventSync/Sync-BloodMoonEvent.ps1 `
  -ConfigPath ./tools/RobloxEventSync/config.github-main.json `
  -NowUtcOverride 2026-09-14T12:00:00Z
```

Review the generated payloads first. Add `-Apply` only when the dashboard
events should be created or updated.

## Reward notification sync

Copy `tools/RobloxNotificationSync/.env.example` to `tools/RobloxNotificationSync/.env`, set `ROBLOX_NOTIFICATION_API_KEY`, then run from this repository root:

```powershell
./tools/RobloxNotificationSync/Sync-RewardNotifications.ps1 `
  -ConfigPath ./tools/RobloxNotificationSync/config.github-main.json
```

The default is read-only notification dry-run. Add `-Apply` to send notifications. The scanner reads `PlayerStats_v1`, checks Roblox presence before sending, checks group membership only when Group Reward is otherwise the highest-priority ready reward, and sends no Blood Moon or other event notifications. Restrict the API key to the main universe with Data Store read and User Notification create permissions.

DEV notification config is disabled to prevent notification leakage from the private DEV universe.
