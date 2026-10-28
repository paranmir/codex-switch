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
- Inspect every detected local Codex runtime and its process relationships with a read-only restart plan
- Automatically restart owning applications when switching: Windows Restart Manager first, then close-and-relaunch fallback

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
# Run from Explorer or an independent terminal, outside apps that will close.
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
| `switch <name>` | Automatically close clients, switch account and reopen applications |
| `switch <name> -Manual` | Switch after clients have been closed manually |
| `status [-Json]` | Inspect the last automatic restart operation |
| `rename <old> <new>` | Rename a profile |
| `remove <name>` | Permanently delete a profile |
| `delete <name>` | Alias for `remove` |
| `files` | Open the profile data directory |
| `setup` | Configure Codex to use file-based credential storage |
| `doctor` | Check Codex, login status, and actual paths |
| `plan [name] [-Json]` | Inspect restart targets, strategies and blockers without changes |
| `help` | Show command-line help |

Names must be 1–40 characters, start with a letter or number, and contain only letters, numbers, `.`, `_`, or `-`.

## Automatic restart

Normal `switch` and the menu's switch option now handle shutdown and relaunch. Applications registered with Windows Restart Manager use their native restart command first. Other applications use a fallback that captures their executable, arguments and current working directory before closing and reopening them. No editor adapters or special application launch workflow are required.

GUI apps receive a normal close request. Save/cancel dialogs stop switching; apps that close their windows but remain in the tray are then terminated and reopened. Independent CLI runtimes restart in a **new console**, preserving their parent terminal/editor. Hosted ACP/app-server clients restart through their owning GUI app. Already-closed apps are reopened even if account validation fails.

Fallback GUI relaunch uses the Windows Shell's normal `open` operation, like opening the executable from Explorer, with its captured arguments and working directory. Switch does not redirect app output to `NUL` or install a log-draining helper. Completion shows the requested app/CLI counts; the new-console notice appears only when CLI sessions were relaunched. `status` retains the in-app authentication verification limitation.

**This restores launch context, not a universal memory snapshot.** Previous workspaces, tabs, unsaved buffers and conversations depend on the app's persistence. Original process environment variables are not restored. Only the configured `CODEX_HOME` is switched; separate OAuth stores or remote agents are outside that file operation.

Inspect the proposed targets and read the last operation result:

```powershell
.\codexSwitch.cmd plan
.\codexSwitch.cmd plan work
.\codexSwitch.cmd plan -Json
.\codexSwitch.cmd status
```

`plan` does not stop/restart processes, initialize the profile store, change ACLs or settings, or read/refresh authentication. An optional profile name checks only whether its saved file exists. No installation in an editor, launch wrapper, or change to normal application use is required. The interactive menu also offers inspection, but the menu itself retains its existing account/store initialization behavior; use the direct `plan` command for a strictly read-only invocation.

Discovery follows verified parent chains, including intermediate shells and launchers. Every detected Codex runtime is included, even under an unknown application. It also reports related ancestors and descendants as context; they are **not shutdown targets**. Known editor/terminal names are descriptive labels, not a support allowlist. A shell beneath an editor does not prove whether Codex is running as a CLI or agent.

The JSON report includes `Clients`, `RelatedProcesses`, `RestartTargets`, `Blockers`, and `Coverage`. Each target identifies `windows-restart-manager` or `close-and-relaunch`. Client modes distinguish hosted `app-server` and `acp` processes. `CanAutoRestart` describes a candidate plan; actual execution rechecks identities and captures fallback launch information before closing anything. `WorkspaceRestoreVerified` remains false because successful relaunch does not prove restored conversation state.

Replacing `auth.json` is **not a verified live account switch**. Isolated fake-account probes of the installed Zed engine and two VS Code extension engines retained account A after file replacement and a refresh request, then loaded B after server restart. Existing-terminal re-execution remains unimplemented. See [the experiment and terminal control limits](docs/automatic-restart.md#running-account-behavior-zed-and-vs-code).

Detection covers local Windows Codex executables, known ACP executables, and specific Node entry scripts. Remote/WSL/container runtimes, renamed executables, arbitrary wrappers, and connections unrelated to parent/child relationships may escape discovery. A process query failure fails inspection; zero matches means only **no known clients detected**. Reports omit raw command lines, which can contain tokens and prompts, but paths, process metadata, and a requested profile name may still be private. Do not commit personal reports.

See [restart behavior and code design](docs/automatic-restart.md) for failure recovery, discovery limits and validation.

The whole application uses an Application Service for operation ordering, a Repository for profile/config files, a Runtime module for Windows/Codex access, and a console UI for presentation. Paths and process discovery are passed through an explicit Context. Process analysis remains a pure module shared by planning and the existing switch guard. See [code design](docs/automatic-restart.md#code-design).

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
- **Switch blocked:** run `plan` to see the target and reason. If the switch is running inside an app it must close, launch `codexSwitch.cmd` separately. Resolve save/cancel dialogs and retry. Run `status` after a partial failure; it distinguishes an account switch from an application restart failure. The tool still refuses to replace credentials while detected Codex clients remain.
- **Switch not reflected after reopening:** verify that the application uses this `CODEX_HOME` and file-based credentials. An independent OAuth store, API key or remote instance is not changed by replacing this local `auth.json`.
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
pwsh -NoLogo -NoProfile -File .\tests\switch-plan.tests.ps1
pwsh -NoLogo -NoProfile -File .\tests\module-isolation.tests.ps1
pwsh -NoLogo -NoProfile -File .\tests\automatic-restart.tests.ps1
pwsh -NoLogo -NoProfile -File .\tests\windows-restart.tests.ps1
pwsh -NoLogo -NoProfile -File .\tests\windows-restart.tests.ps1 -Platform x86
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
