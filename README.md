# macOS Backup & Restore

Creates a portable snapshot of macOS settings, configs, and developer/audio tooling, and restores them on a new system.

- `backup_mac.sh` — gathers configs, fonts, plugins, and your home directory into a timestamped archive: `System_Backup_YYYYMMDD_HHMMSS.tgz`
- `restore_mac.sh` — restores from that archive with progress logs and safety checks
- `automation/` — launchd agent for daily automated backups

## Requirements

- macOS with Terminal access
- `sudo` for system-level copies and restore (fonts, audio plugins, etc.)
- `rsync` (Homebrew rsync preferred; falls back to Apple's)
- **Recommended**: `brew install gnu-tar pigz`
  - `gtar` (GNU tar) — streams the home folder directly into the archive with no staging copy, cutting peak disk usage from ~200 GB to ~50 GB
  - `pigz` — parallel gzip compression; typically 4–8× faster than single-threaded gzip on multi-core machines
- Optional: `brew`, `mas` for Homebrew/Mac App Store inventory

## Backup

### Usage

```bash
./backup_mac.sh           # tar archive (default) → System_Backup_<ts>.tgz
./backup_mac.sh dir       # folder only, no archive
./backup_mac.sh zip       # zip archive
./backup_mac.sh tar --clean   # archive and delete staging folder after
./backup_mac.sh --archives    # also archive Desktop/Documents/Downloads/Pictures/Movies
```

### How it works

Config files, fonts, plugins, and app data are staged to a local temp folder (`STAGING_ROOT`, default `$TMPDIR/mac_backup_staging`) first. Then:

- **With `gtar` (recommended)**: the home folder is streamed directly into the archive alongside the staged files using `--transform` — no rsync copy needed. Peak disk use is ~50 GB (staged configs + growing .tgz).
- **Without `gtar` (fallback)**: the home folder is rsynced into staging first, then everything is tarred with `--remove-files`. Peak disk use is ~200 GB.

The finished archive is moved to `BACKUP_ROOT` (default: iCloud Drive `~/Library/Mobile Documents/com~apple~CloudDocs/Backups`). If `BACKUP_ROOT` is in iCloud Drive the script waits for the upload to finish, then evicts the local copy to reclaim space.

### What it captures

| Category | Contents |
|---|---|
| App inventories | `/Applications`, `~/Applications`, `brew list`, Brewfile, `mas list` |
| System/UI | Dock prefs (readable + plist), crontab, launch agents list, network services list |
| Package inventories | `npm list -g`, `pip3 list`, `gem list` (lists only, not the packages) |
| Fonts | User (`~/Library/Fonts`) and system (`/Library/Fonts`) |
| Audio plugins | Components, VST, VST3, MAS, ARA, AAX — user and system |
| MIDI | Drivers and configurations |
| DAW data | Logic (`Audio Music Apps`), Ableton, Pro Tools |
| Dev/CLI configs | `~/.ssh`, `~/.config`, dotfiles (`.zshrc`, `.gitconfig`, etc.), `~/bin`, `~/.local/bin` |
| Editors | VS Code, Cursor, Sublime Text user settings; Cursor extensions; Xcode snippets/keybindings/themes |
| System configs | Keyboard layouts (user + system), input methods, user LaunchAgents (files), `/etc/hosts`, printer PPDs, printer list, sudoers drop-ins, system network config |
| Color/display | ColorSync profiles (user + system), QuickLook plugins |
| App data | Apple Mail, Services, Shortcuts, Calendars |
| Home directory | All of `~` with sensible excludes (see below) → `User_Folder/` in archive |
| Optional archives | Desktop, Documents, Downloads, Pictures, Movies as `.tar.gz` under `archives/` (off by default; enable with `--archives`) |

**Home directory excludes**: caches, logs, iCloud/CloudStorage, Library/Containers, Library/Developer, Dropbox, Downloads, Documents, Desktop, Pictures, Movies, dev tool caches (node_modules, .cargo, .nvm, .pyenv, etc.), and TCC-protected Apple system directories that are unreadable without Full Disk Access. The complete list lives in `HOME_EXCLUDES_PATTERNS` in `backup_mac.sh`.

### Output layout

```
System_Backup_<timestamp>/
  files/         configs, fonts, plugins, app data copies
  lists/         inventories and readable summaries
  User_Folder/   home directory contents (with excludes)
  archives/      Desktop/Documents/Downloads/Pictures/Movies .tar.gz (if --archives)
  backup_summary.txt
  backup_log.txt
```

### Disk space

| Setup | Peak staging | Typical archive |
|---|---|---|
| gtar + pigz (recommended) | ~50 GB | ~59 GB |
| Fallback (no gtar) | ~200 GB | ~59 GB |

`daily_backup.sh` checks free space before starting and aborts early if there isn't enough.

---

## Restore

```bash
./restore_mac.sh "/path/to/System_Backup_YYYYMMDD_HHMMSS.tgz"   # from archive
./restore_mac.sh "/path/to/System_Backup_YYYYMMDD_HHMMSS"        # from folder
./restore_mac.sh --clean /path/to/archive.tgz                     # delete extract folder after
```

If no argument is provided, uses the first `System_Backup_*` on your Desktop.

### What it restores

- Fonts, ColorSync profiles, QuickLook plugins (uses `ditto` for system paths)
- SSH keys, GPG, `~/.config`, dotfiles, `~/bin`, `~/.local/bin`
- Editor settings (VS Code, Cursor, Sublime Text)
- Audio plugins (user + system) and MIDI configurations
- DAW data: Logic, Ableton, Pro Tools
- Apple Mail data and plist (quit Mail first)
- Services, Shortcuts, Calendars (quit Calendar first)
- Desktop/Documents/Downloads/Pictures/Movies archives (if present)
- Keyboard layouts (user + system) and input methods
- Xcode user data (snippets, key bindings, color themes, behaviors)
- `/etc/hosts` — copied to `~/Desktop/etc_hosts_from_backup.txt` with a diff shown; merge manually
- sudoers drop-ins — copied to `~/Desktop/sudoers_d_from_backup/` for manual review and application
- System network config restored to `/Library/Preferences/SystemConfiguration/` (reboot recommended)
- Printer PPDs restored to `/etc/cups/ppd/`; printer list saved to `~/Desktop/printers_from_backup.txt`
- User LaunchAgents (`.plist` files) and crontab
- Homebrew from Brewfile (installs Homebrew if missing, then `brew bundle`)
- Optional Dock layout via saved plist

A timestamped log is written to `~/Desktop/restore_log_<timestamp>.txt`. The script pre-auths sudo and keeps it alive to avoid mid-run prompts.

---

## Daily Automation (launchd)

See `agent.md` for full detail. Quick summary:

### Setup

```bash
./automation/install.sh
```

The interactive installer detects your username, repo path, and defaults, then walks you through:
1. Choosing a backup schedule (default 15:15)
2. Installing the LaunchAgent to `~/Library/LaunchAgents/`
3. Optionally installing the sudoers drop-in for passwordless system copies

After installation, grant **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access) to:
- `/usr/bin/rsync` and `/opt/homebrew/bin/rsync` — needed for sudo rsync of system fonts and audio plugins
- `/opt/homebrew/bin/gtar` — needed to read home directory files

The individual scripts still work standalone if you prefer manual setup:
- `./automation/update_launch_agent.sh [--hour H] [--minute M]` — install/reload the LaunchAgent (optional schedule override)
- `./automation/setup_sudoers.sh [--apply]` — preview/install the sudoers drop-in

### Cadence & state

- Runs daily at **15:15**; skips if a backup already completed today
- Keeps the **10 most recent** archives in `BACKUP_ROOT`
- State files (last run timestamp, backup manifest) stored locally in `~/.local/share/osx_backup_restore/` — not in iCloud — to avoid `bird` daemon contention
- **iCloud-aware pruning**: iCloud can make cloud-only files invisible to shell globs. The manifest file is the authoritative archive list; glob-visible files are merged into it each run, then old entries beyond 10 are pruned
- Logs: `/tmp/daily_backup.out` and `/tmp/daily_backup.err` — truncated each run, cleared on reboot

### Troubleshooting

| Symptom | Check |
|---|---|
| "Backup already completed … skipping" | Normal — only one backup per day |
| Backup hasn't run in days | Check `/tmp/daily_backup.err` for the failure reason |
| "Not enough disk space" | Need ~50 GB free (with gtar) or ~200 GB (fallback) |
| Spurious "Failed" notification | Check if the archive itself is in iCloud and was evicted before the size check ran |
| Cleanup left root-owned files | Ensure NOPASSWD sudo is configured for rsync |

### Management

```bash
./automation/check_backup_running.sh   # check if a backup is running
./automation/update_launch_agent.sh    # reload after plist changes
./automation/remove_launch_agent.sh    # unload and remove the agent
```

---

## Verify a Backup

```bash
./verify_backup.sh /path/to/System_Backup_<timestamp>      # folder
./verify_backup.sh /path/to/System_Backup_<timestamp>.tgz  # archive
```

Lists required and optional items; exits nonzero if required items are missing. Each backup also includes `backup_summary.txt` inside the archive root.

---

## Customization

- Add/remove paths in `backup_mac.sh` — sections are clearly labeled
- Adjust `HOME_EXCLUDES_PATTERNS` to include/exclude folders from the home directory sweep
- Add other editor or DAW config paths in the relevant sections
- Override `BACKUP_ROOT` or `STAGING_ROOT` via environment variable before running

---

## Safety

- Close Mail and Calendar before restoring related data
- Restoring writes into your home directory and selected system paths; review script sections if you need finer control
- Always keep an independent backup (Time Machine, disk image) for redundancy

---

## Git Hygiene

`.gitignore` excludes:
- macOS artifacts (`.DS_Store`, Spotlight, etc.)
- Script outputs: `System_Backup_*/`, `System_Backup_*.tgz`, `restore_log_*.txt`
- Cursor IDE metadata: `.cursor/`, `.cursor-*`
