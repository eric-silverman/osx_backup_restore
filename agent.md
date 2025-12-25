# Launch Agent Usage

This repo’s backup flow is meant to run non-interactively via the LaunchAgent in `automation/com.eric.dailybackup.plist`. Use this guide when installing, updating, or troubleshooting that agent.

- **Schedule & cadence**: LaunchAgent label `com.osxbackup.daily` runs daily at 15:15, but `automation/daily_backup.sh` skips a run if a backup already completed today (keeps one backup per day).
- **Program path**: `ProgramArguments` call `/bin/bash` with `automation/daily_backup.sh`. Update the plist path if you move the repo, then run `./automation/update_launch_agent.sh`.
- **Environment**: PATH set in the plist to include Homebrew. Overrideable vars: `BACKUP_ROOT` (default `~/Library/Mobile Documents/com~apple~CloudDocs/Backups`), `STAGING_ROOT` (default `${TMPDIR}/mac_backup_staging`), `STAGING_RETENTION_DAYS` (default 3). Agent runs in the user session, not as root.
- **Outputs**: Backups staged at `$STAGING_ROOT/System_Backup_<timestamp>` then archived to `$BACKUP_ROOT/System_Backup_<timestamp>.tgz` with `--clean` to delete the staging folder. Only the archive is kept; staging is removed on success. After completion, only the 10 most recent archives are retained in `BACKUP_ROOT`. Logs now include staged folder size and final tar size to help track growth.
- **Logging & notifications**: Launchd logs to `/tmp/daily_backup.out` and `/tmp/daily_backup.err` (truncated each run). `daily_backup.sh` attempts GUI notifications via `osascript`; if running outside GUI, it targets the console user.

## Permissions & Prereqs
- **sudo**: `backup_mac.sh` uses sudo for system copies (e.g., `/Library/Fonts`, system audio plugins) and for final `--clean` staging removal if files are root-owned. Because LaunchAgent runs non-interactively, configure passwordless sudo for the commands listed in `README.md` (sudoers drop-in) so cleanup and system copies don’t hang. Cleanup now fails fast with a log reminder if sudo prompts would be required.
- **Full Disk Access**: Grant it to the `rsync` binary you use (both `/usr/bin/rsync` and, if installed, `/opt/homebrew/bin/rsync`) and optionally your shell. Needed because launchd inherits these permissions.
- **iCloud destinations**: Default `BACKUP_ROOT` is in iCloud Drive. Script waits for uploads and requests eviction after archiving to save local space (skipped if brctl/mdls missing).

## Install / Update the Agent
- Edit `automation/com.eric.dailybackup.plist` if paths change.
- Run `./automation/update_launch_agent.sh` to copy into `~/Library/LaunchAgents/com.osxbackup.daily.plist`, bootstrap, and kickstart.
- Verify with `launchctl list | grep com.osxbackup.daily` or check `/tmp/daily_backup.out`.
- To generate/install the sudoers drop-in (for non-interactive cleanup/system copies): `./automation/setup_sudoers.sh --apply` (adjust `BACKUP_SUDO_USER`, `STAGING_ROOT`, `SUDOERS_PATH` via env if needed).

## Removal / Refresh
- Refresh after plist edits: `./automation/update_launch_agent.sh`.
- Remove entirely: `./automation/remove_launch_agent.sh`.
- Check if a backup is currently running: `./automation/check_backup_running.sh` (looks for the staging lockfile).

## Troubleshooting (LaunchAgent context)
- **Cleanup failures**: If `--clean` cannot delete the staging folder non-interactively, ensure sudo NOPASSWD is configured for `chflags`, `chmod`, and `rm` on the staging path. Stuck path is usually at `$STAGING_ROOT/System_Backup_<timestamp>`.
- **Skipped runs**: See `/tmp/daily_backup.out` for the “Backup already completed on …; skipping” message (means a backup already ran today).
- **Permissions errors**: Check Full Disk Access and sudoers; the agent cannot prompt for passwords.
- **Notifications missing**: Ensure `osascript` works in the user session; otherwise, messages fall back to the console user via `launchctl asuser`.

## Manual Run (same as agent)
From the repo root (for quick validation):
```
/bin/bash automation/daily_backup.sh
```
Uses the same defaults and cadence logic as the LaunchAgent; override `BACKUP_ROOT`/`STAGING_ROOT` as needed. Avoid running concurrently; the staging lock will block a second run.
