# macOS Backup & Restore Scripts

These scripts create a portable snapshot of key macOS settings and developer/audio tooling, and help restore them on a new system.

- `backup_mac.sh` gathers lists, configs, and selected folders into a timestamped folder: `System_Backup_YYYYMMDD_HHMMSS`.
- `restore_mac.sh` restores from that folder with progress logs and sensible safety checks.

## Requirements
- macOS with Terminal access.
- `sudo` for restoring system-level items (e.g., `/Library/*`).
- `rsync` (uses Homebrew rsync if available, falls back to Apple’s).
- Optional: `brew`, `mas` if you want Homebrew and Mac App Store items listed/restored.

## Backup
1) Configure backup destination in `backup_mac.sh`:
   - Default: `BACKUP_ROOT=/Volumes/BACKUP` (change to suit your drive).
   - Backups are staged in a local temp folder first (override with `STAGING_ROOT`) to avoid iCloud uploading while the archive is built, then moved to `BACKUP_ROOT`.
   - Staging leftovers in `/tmp` are pruned automatically on exit (items older than `STAGING_RETENTION_DAYS`, default 3). Set `STAGING_RETENTION_DAYS=0` to disable pruning.
   - If `BACKUP_ROOT` is in iCloud Drive and you create a tar/zip, the script waits for the archive to upload and then asks iCloud to evict the local copy (uses `mdls`/`brctl` if present).
   - Home-folder rsync skips protected system/provider cache areas to avoid permission errors (FileProvider, Signal Crashpad, CoreSpeech caches, secure-control-center prefs).
2) Run (choose output format):
   - Tar archive (default): `./backup_mac.sh` → creates `System_Backup_<ts>.tgz`
   - Folder only: `./backup_mac.sh dir`
   - Zip archive: `./backup_mac.sh zip`
   - Per-folder Desktop/Documents/Downloads/Pictures/Movies archives are OFF by default; enable with `--archives` (or keep them skipped with `--no-archives`)
   - Add `--clean` with `tar` or `zip` to remove the original backup folder after creating the archive:
     - `./backup_mac.sh tar --clean`
     - `./backup_mac.sh zip --clean`
     - Note: `--clean` has no effect with `dir` (there is nothing to replace the folder).

What it captures (high level):
- App inventories: `/Applications`, `~/Applications`, `brew list`, `brew bundle` (Brewfile), optional `mas list`.
- System/UI lists: Dock prefs (readable + plist), crontab, launch agents.
- Fonts: user and system fonts.
- Audio: common plugin folders (Components, VST, VST3, MAS, ARA, AAX) + MIDI drivers/configs.
- DAW data: selected Ableton/Pro Tools/Logic folders (adjust as needed).
- Dev/CLI configs: `~/.ssh`, `~/.gnupg`, `~/.config`, common dotfiles, `~/bin`, `~/.local/bin`.
- Editors: VS Code, Sublime Text User settings, Cursor user settings and extensions.
- Color profiles & QuickLook plugins: user and system.
- Apple Mail data and plist.
- Services, Shortcuts, Calendars.
- Entire home directory to `User_Folder/` with sensible excludes (caches, logs, cloud storage, containers, large dev caches, common library folders). See inline `--exclude` list in the script to tailor.
- Separate archives for `Desktop`, `Documents`, `Downloads`, `Pictures`, and `Movies` are created under `archives/` as `.tar.gz`. Before archiving, the script waits for any iCloud Drive placeholders in those folders to be fully downloaded. The `Pictures` archive excludes large managed libraries like `Photos Library.photoslibrary` and `iPhoto Library.photolibrary` by default.

Output layout:
- `System_Backup_<timestamp>/`
  - `files/` – actual configs, fonts, plugins, data copies
  - `lists/` – inventories and readable summaries
  - `User_Folder/` – rsync copy of `~` with excludes
  - `archives/` – compressed backups of Desktop/Documents/Downloads/Pictures/Movies

Notes:
- A tarball step is included but commented. Uncomment to produce `System_Backup_<timestamp>.tgz` alongside the folder.

## Restore
Run with either a backup directory or an archive file:
- From a folder: `./restore_mac.sh "/path/to/System_Backup_YYYYMMDD_HHMMSS"`
- From a tarball: `./restore_mac.sh "/path/to/System_Backup_*.tgz"`
- From a zip: `./restore_mac.sh "/path/to/System_Backup_*.zip"`

Options:
- `--clean`: If you pass an archive, the script extracts it to `~/Desktop/restore_extract_<timestamp>/`. With `--clean`, that temporary extract folder is deleted after a successful restore.
  - Example: `./restore_mac.sh --clean /Volumes/BACKUP/System_Backup_20250101_120000.tgz`
- If your backup was created with `--no-archives` (the default), the restore step for Desktop/Documents/Downloads/Pictures/Movies will just log that the archives directory is missing and continue.

If no argument is provided, it uses the first `System_Backup_*` on your Desktop.

What it restores:
- Fonts, ColorSync profiles, QuickLook plugins (uses `ditto` for system paths).
- SSH, GPG, `~/.config`, common dotfiles, `~/bin`, `~/.local/bin`.
- Editor settings (VS Code, Cursor settings and extensions, Sublime Text User).
- Audio plugins (user + system) and MIDI configurations.
- DAW data: Logic (`Audio Music Apps`), Ableton, and Pro Tools folders.
- Apple Mail data and plist (quit Mail first).
- Services, Shortcuts, Calendars (quit Calendar first).
- Extracts archived Desktop/Documents/Downloads/Pictures/Movies into your home.
- LaunchAgents and cron (if present).
- Homebrew from `Brewfile` (installs Homebrew if missing, then `brew bundle`).
- Optional Dock layout via saved plist.

Logging:
- A timestamped log is written to `~/Desktop/restore_log_<timestamp>.txt`.
- The script pre-auths `sudo` and keeps it alive to avoid mid-run prompts.
- Each backup includes `backup_summary.txt` inside the root folder/tar/zip listing which sections were captured and their paths.

## Running Daily via `launchd` (with sudo inside the script, not as root)
- Install the plist: copy `automation/com.eric.dailybackup.plist` to `~/Library/LaunchAgents/` and edit the `ProgramArguments` path so it points to your clone (no sudo wrapper; the agent runs as your user).
- The LaunchAgent triggers at 15:15 daily and skips a run if a backup already completed today, so you get one backup per day.
- Allow non-interactive sudo for the few commands the scripts invoke: add a sudoers drop-in with `sudo visudo -f /etc/sudoers.d/osx_backup_restore` containing:
  ```
  Cmnd_Alias OSX_BACKUP_CMDS=/opt/homebrew/bin/rsync,/usr/bin/rsync,/Users/eric/Dropbox/Development\\ Projects/osx_backup_restore/automation/daily_backup.sh,/Users/eric/Dropbox/Development\\ Projects/osx_backup_restore/backup_mac.sh
  eric ALL=(root) NOPASSWD: OSX_BACKUP_CMDS
  ```
  Replace `eric` and the paths with your username/clone path. The `-n` flag in the plist makes sudo fail fast if this rule is not present.
- Grant Full Disk Access to the `rsync` binary that will run (and to the shell if you prefer) so launchd does not prompt each time it touches Documents/Desktop/Mail. In System Settings → Privacy & Security → Full Disk Access, add `/usr/bin/rsync` and, if you use Homebrew’s, `/opt/homebrew/bin/rsync`. If you run the scripts with a custom shell (e.g., `/bin/bash` or `/opt/homebrew/bin/bash`), add that binary too. This must be done once per binary path; launchd inherits the allowance.
- Load the agent with `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.osxbackup.daily.plist` then `launchctl kickstart -k gui/$UID/com.osxbackup.daily` to test. Confirm `sudo -n /Users/eric/Dropbox/Development\ Projects/osx_backup_restore/automation/daily_backup.sh` works with no prompt before relying on the agent. Because the LaunchAgent runs as your user, Homebrew commands stay non-root and won’t trigger the “running Homebrew as root” error.
- After editing the plist, run `./automation/update_launch_agent.sh` to copy it into `~/Library/LaunchAgents/` and reload/kickstart the agent automatically.
- Daily runs keep only the five most recent `System_Backup_*.tgz` files in your backup destination to conserve space.

## Verify a Backup
- Every run writes `backup_summary.txt` inside `System_Backup_<timestamp>/`.
- Use `./verify_backup.sh /path/to/System_Backup_<timestamp>` (or the `.tgz`/`.zip` archive) to list required/optional pieces and exit nonzero if required items are missing.

## Customization
- Add/remove paths you care about directly in the scripts (sections are clearly labeled).
- Adjust the rsync exclude list in `backup_mac.sh` to include/exclude large folders.
- If you use other editors/DAWs, add their config paths in the relevant sections.

## Git Hygiene
This repo includes a `.gitignore` to keep local/macOS artifacts and script outputs out of version control:
- macOS system files (`.DS_Store`, `.AppleDouble`, Spotlight, etc.).
- Shell temp/swap/backup/log files.
- Script artifacts: `System_Backup_*/`, `System_Backup_*.tgz`, `restore_log_*.txt`.
- Cursor IDE project metadata: `.cursor/`, `.cursor-*`.

## Safety
- Close Mail and Calendar before restoring related data.
- Restoring writes into your home directory and selected system locations; review the script sections if you need stricter control.
- Always keep an independent backup (Time Machine, disk image) for redundancy.
