# Codex Switch

A small Windows CLI for saving multiple Codex logins as named profiles and switching between them.

> [!IMPORTANT]
> This is an unofficial community utility, not an OpenAI product. It works by replacing Codex's local `auth.json`; future Codex updates may change this behavior.

## Features

- Add accounts through the normal `codex login` browser flow
- Save, list, rename, remove, and switch named profiles
- Automatically preserve the current login before adding another account
- Configure Codex to use file-based credentials so Desktop and CLI read the switched profile
- Add accounts without calling `codex logout`, which could invalidate the profile just saved
- Keep credentials outside the Git repository in a user-local data directory
- Support custom `CODEX_HOME` and `CODEX_SWITCH_HOME` locations
- Diagnose the Codex installation, paths, login state, and running Desktop/CLI/IDE clients
- Preserve refreshed credentials even when the recorded active profile is out of date
- Refresh and validate saved logins through the installed Codex CLI before applying a switch

## Requirements

- Windows 10 or 11
- [Codex CLI](https://developers.openai.com/codex/) available as the `codex` command
- PowerShell 7 recommended; Windows PowerShell 5.1 is used as a fallback

## Install

Clone the repository or download and extract its ZIP:

```powershell
git clone https://github.com/paranmir/codex-switch.git
cd codex-switch
.\codexSwitch.cmd doctor
.\codexSwitch.cmd setup
```

No administrator rights or installer are required. Add the repository directory to your user `PATH` if you want to call `codexSwitch` from anywhere.

## Quick start

Save your existing Codex login:

```powershell
.\codexSwitch.cmd save work
```

Add another account. A browser login will open; you do not need to locate or copy any configuration file yourself:

```powershell
.\codexSwitch.cmd add personal
```

Switch whenever needed:

```powershell
# First close Codex Desktop (including the tray), CLI sessions, and Codex in your IDE.
.\codexSwitch.cmd switch work
.\codexSwitch.cmd switch personal
```

Run without arguments for an interactive menu:

```powershell
.\codexSwitch.cmd
```

After closing all Codex clients, choose **7. Register the currently signed-in account** to save its last active account without starting another browser login. The equivalent command is:

```powershell
.\codexSwitch.cmd save <name>
```

## Commands

| Command | Description |
| --- | --- |
| `whoami` | Show the active profile, email, and auth method |
| `list` | List saved profiles |
| `save <name>` | Save the current Codex login |
| `add <name>` | Preserve the current login, sign in, and save a new account |
| `switch <name>` | Switch to a saved account |
| `rename <old> <new>` | Rename a profile |
| `remove <name>` | Permanently delete a profile |
| `delete <name>` | Alias for `remove` |
| `files` | Open the profile data directory |
| `setup` | Configure Codex to use file-based credential storage |
| `doctor` | Check Codex, login status, and actual paths |
| `help` | Show command-line help |

Names must be 1–40 characters, start with a letter or number, and contain only letters, numbers, `.`, `_`, or `-`.

`list` marks the profile matching the current `auth.json` with `*`. `whoami` also uses the actual file and warns if the recorded active name is stale. These commands describe credentials on disk; an already-running Desktop, CLI, or IDE session can still hold an earlier login in memory.

Before switching, the tool saves the current credentials to their matching profile, even if the recorded active name is different. An account that has no matching profile is preserved as `recovered-YYYYMMDD-HHMMSS`.

The target login is then checked in an isolated temporary Codex home. The installed CLI refreshes it through `account/read` and, for ChatGPT accounts, verifies access through `account/rateLimits/read`. Only a successful check allows the target to become active. Switching therefore needs network access and a Codex CLI with these app-server methods. `codex login status` alone only reports cached login state and is not sufficient to validate a saved login.

Refreshed credentials are saved back to the profile even if a later network check fails, because refresh tokens can rotate. The previously active account is retained on validation failure. If the target is already the current account, its refreshed credentials are also retained in the current auth file.

## How `add` works

`codexSwitch add personal`:

1. Finds an existing profile for the current account and refreshes that profile instead of creating another recovery copy.
2. If the existing login has no matching profile, preserves it once as `previous-YYYYMMDD-HHMMSS` or `recovered-YYYYMMDD-HHMMSS`.
3. Temporarily moves the current local `auth.json` aside without calling `codex logout`.
4. Runs `codex login` with file-based credential storage enabled.
5. Saves the newly created Codex auth file as `personal`. If login fails, the previous login is restored.

You normally never need to handle `auth.json` manually.

## Finding Codex configuration files

The default Codex home on Windows is:

```text
%USERPROFILE%\.codex
```

Typical files:

- Configuration: `%USERPROFILE%\.codex\config.toml`
- Login credentials: `%USERPROFILE%\.codex\auth.json`

Check the effective paths without displaying credential contents:

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$codexHome
Test-Path (Join-Path $codexHome 'config.toml')
Test-Path (Join-Path $codexHome 'auth.json')
```

Or use:

```powershell
.\codexSwitch.cmd doctor
```

When `CODEX_HOME` is set, Codex Switch uses that directory instead of the default `.codex` directory.

Modern Codex can keep credentials either in `auth.json` or in the operating-system keyring. Codex Switch manages files, so `setup`, `add`, and `switch` explicitly set this user-level option in `config.toml`:

```toml
cli_auth_credentials_store = "file"
```

If a configuration file already exists, its original contents are backed up once as `config.toml.codex-switch.bak`. See the [official Codex authentication documentation](https://learn.chatgpt.com/docs/auth#credential-storage) for the supported credential stores.

## Profile storage

Profiles are deliberately stored outside the repository:

```text
%LOCALAPPDATA%\CodexSwitch\
├── profiles.json
└── profiles\
    ├── work.auth.json
    └── personal.auth.json
```

Override the location when needed:

```powershell
$env:CODEX_SWITCH_HOME = 'D:\Secure\CodexSwitch'
.\codexSwitch.cmd list
```

Older repository-local `profiles.json` and `profiles/` data are copied to the new location on first run. After verifying the migration, remove the old copies securely.

## Security

- `auth.json` and `*.auth.json` contain sensitive account tokens.
- Never paste their contents into terminals, issues, chats, email, or GitHub.
- Do not sync `%LOCALAPPDATA%\CodexSwitch` to cloud storage or place it in a public repository.
- On Windows, the tool attempts to restrict its data directory to the current user and SYSTEM.
- `remove` deletes a profile permanently without using the Recycle Bin.
- On shared computers, separate Windows user accounts are safer than shared profile files.
- Follow your organization's security policy; do not use this tool if credential-file copying is prohibited.

## Troubleshooting

```powershell
.\codexSwitch.cmd doctor
codex login status
```

- **`codex` not found:** install Codex CLI and open a new terminal.
- **Switch not reflected:** close Codex Desktop completely (including its tray/background process), exit every Codex CLI session, and close or disable the Codex extension in your IDE. Run `doctor` to inspect remaining executable names, PIDs, and parent processes, run `switch` again, and then reopen your clients. Existing processes can retain the old login and write it back to `auth.json`; Codex Switch refuses to replace credentials while any of these clients is running.
- **Codex asks you to sign in after switching:** update Codex Switch, close all Codex clients, and run `codexSwitch setup`. Profiles created by an older release may have been invalidated by its `codex logout` step; re-add that account once with `codexSwitch add <name>`, then switch again.
- **Saved login cannot be refreshed:** a revoked or invalid refresh token cannot be repaired by copying it. If you have already signed in to that account again in Codex, close all clients and run `codexSwitch save <name>` to update the profile; otherwise run `codexSwitch add <name>` once. Future switches validate and preserve the refreshed login. A connectivity or server error can also prevent validation; retry after connectivity is restored.
- **Profiles show the same account:** run `doctor`. It reports profiles that contain the same account and detects when the current login differs from the recorded active profile. Re-add any profile that was already overwritten; lost credentials cannot be reconstructed from the duplicate file.
- **A profile file was deleted manually:** the next `list`, menu refresh, or other command removes the missing entry from `profiles.json`. The interactive menu also provides **Delete a profile** so manual file deletion is normally unnecessary.
- **Login interrupted:** run `add` again, or complete `codex login` and then run `save <name>`.
- **Windows PowerShell shows garbled text:** install PowerShell 7 so `pwsh` is available.

## Tests

The regression suite uses temporary directories and fake credentials; it does not change your Codex accounts:

```powershell
pwsh -NoLogo -NoProfile -File .\tests\codex-switch.tests.ps1
```

## Before publishing or contributing

The credential paths are ignored, but always verify before committing:

```powershell
git status --short
git ls-files | Select-String -Pattern 'auth\.json|profiles\.json'
```

The second command must produce no output. Never use `git add -f` on profile or auth files.

## License

[MIT](LICENSE)
