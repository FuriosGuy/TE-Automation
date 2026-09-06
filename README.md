# TsunamiEscape Automation

Scheduled Roblox Experience Event synchronization for the main and DEV universes.

## GitHub Actions secrets

Add these repository secrets:

- `ROBLOX_EVENT_MAIN_API_KEY` for the main workflow
- `ROBLOX_EVENT_API_KEY` for the DEV workflow
- `ROBLOX_NOTIFICATION_MAIN_API_KEY` for hourly main reward notifications

Keep API keys out of JSON files, `.env`, commits, and workflow output.

## Workflows

- `Main Version` syncs `config.github-main.json` hourly.
- `DEV Version` syncs `config.github-dev.json` hourly.
- `Main Reward Notifications` scans ready reward state hourly and sends at most one notification per offline user per run.

Both workflows support manual runs from the GitHub Actions tab.

## Local run

Copy `tools/RobloxEventSync/.env.example` to `.env`, set the matching API key, then run from this repository root:

```powershell
./tools/RobloxEventSync/Sync-BloodMoonEvent.ps1 -ConfigPath ./tools/RobloxEventSync/config.json -Apply
```

Use `config.github-main.json` or `config.github-dev.json` for a dry run without local config.

## Reward notification sync

Copy `tools/RobloxNotificationSync/.env.example` to `tools/RobloxNotificationSync/.env`, set `ROBLOX_NOTIFICATION_API_KEY`, then run from this repository root:

```powershell
./tools/RobloxNotificationSync/Sync-RewardNotifications.ps1 `
  -ConfigPath ./tools/RobloxNotificationSync/config.github-main.json
```

The default is read-only notification dry-run. Add `-Apply` to send notifications. The scanner reads `PlayerStats_v1`, checks Roblox presence before sending, checks group membership only when Group Reward is otherwise the highest-priority ready reward, and sends no Blood Moon or other event notifications. Restrict the API key to the main universe with Data Store read and User Notification create permissions.

DEV notification config is disabled to prevent notification leakage from the private DEV universe.
