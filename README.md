# TsunamiEscape Automation

Scheduled Roblox Experience Event synchronization for the main and DEV universes.

## GitHub Actions secrets

Add these repository secrets:

- `ROBLOX_EVENT_MAIN_API_KEY` for the main workflow
- `ROBLOX_EVENT_API_KEY` for the DEV workflow

Keep API keys out of JSON files, `.env`, commits, and workflow output.

## Workflows

- `Main Version` syncs `config.github-main.json` hourly.
- `DEV Version` syncs `config.github-dev.json` hourly.

Both workflows support manual runs from the GitHub Actions tab.

## Local run

Copy `tools/RobloxEventSync/.env.example` to `.env`, set the matching API key, then run from this repository root:

```powershell
./tools/RobloxEventSync/Sync-BloodMoonEvent.ps1 -ConfigPath ./tools/RobloxEventSync/config.json -Apply
```

Use `config.github-main.json` or `config.github-dev.json` for a dry run without local config.
