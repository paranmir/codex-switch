# Automatic application restart on account switch

`codexSwitch switch <profile>` discovers local Codex clients, closes their owning applications, validates and applies the saved account, and reopens the applications. Applications run independently; no editor adapters, launch wrapper, or background service is installed.

## Restart policy

1. **Windows Restart Manager first.** If the owning window process registered for restart and permits update restarts, Windows handles normal shutdown and its registered restart command.
2. **Close and relaunch fallback.** Otherwise, capture the original executable, argument tail and current working directory in memory before closing anything. Request normal GUI close, then reopen that executable through the Windows Shell's normal `open` operation (`UseShellExecute=true`), as when opening an executable in Explorer. This uses the OS graphical shell, not command interpretation by cmd/PowerShell. Native session setup failure also uses this fallback when capture succeeded. A confirmed stopped application that Windows failed to restart can use the captured recipe too.
3. **Keep terminal parents open.** An interactive Codex runtime below a shell is interrupted and relaunched in a new console. Its original terminal/editor stays open. ACP and `app-server` clients instead require their owning GUI application to restart so the app can recreate its connections.

Window ownership and process ancestry determine targets; editor names are presentation labels. Multiple clients owned by the same selected app produce one restart target. PID plus creation time is checked before closing, and the coordinator's ancestors are excluded.

Fallback GUI shutdown waits ten seconds by default. A remaining visible window (including a save/cancel dialog) stops the switch without forcing it. If all of the target's visible windows closed but its process remains in the background/tray, the original process and its still-running, identified Codex runtime children are terminated. Other child tool jobs are not terminated. New or surviving Codex clients still prevent credential replacement.

## Operation and recovery

```text
Discover → Choose native/fallback → Capture launch information → Recheck identities
    → Close applications → Wait for Codex exit → Validate/apply account
    → Reopen closed applications → Record result
```

- A failed launch capture for a fallback target stops preparation before shutdown.
- A named mutex prevents simultaneous account operations in the same Windows session.
- Existing credential preservation, refresh-token rotation handling and validation run after clients exit.
- Restart is attempted in `finally`, including when shutdown partially succeeds or authentication validation fails. Live originals are not duplicated.
- Windows Restart Manager is asked to restart even after a partial native shutdown failure, as required by its API.
- `%LOCALAPPDATA%\CodexSwitch\last-operation.json` records target names/identities, mechanism, stage and whether account switching completed. `status [-Json]` reads it. It contains no credentials, raw command lines or executable replay recipes.
- `AccountChanged` means the configured auth file was applied. `ClientAuthenticationVerified=false` explicitly distinguishes that from verifying the account used inside an editor or an agent. Successful process launch alone does not establish an authenticated switch.
- GUI fallback no longer uses direct `Process.Start` with `UseShellExecute=false`, which let relaunched app logs inherit Switch's terminal streams. The ordinary Windows Shell launch owns stream setup; Switch does not assign `NUL`, redirect app logs or maintain draining pipes. This matches the executable-open route, not every behavior of app-specific command-line launchers or shortcuts with additional settings. Completion reports app/CLI target counts; `status` retains authentication caveats and a CLI console warning appears only for actual console targets.
- Power loss or termination of the switch coordinator itself prevents in-memory recovery. The journal is diagnostic; it does not automatically execute persisted commands.

## Restoration limits

Reopening an application is implemented; exact restoration of every workspace or conversation is **not guaranteed**. Native registration is evidence of a restart command, not evidence of restored editor state. Fallback restores launch context; tabs, unsaved buffers and agent conversations depend on the application's own persistence and settings. An app that opened other workspaces after its original launch may not restore them from its original arguments alone.

CLI restarts do not reattach the original terminal's input/output pipes or reconstruct its in-memory conversation. Original process environment variables are not copied; restarted processes inherit the switch coordinator's environment. A custom credential home or independently stored OAuth login may therefore be outside the switched file store. Only the configured `CODEX_HOME` is changed; runtime detection does not prove a shared credential store.

Still rejected before shutdown: inaccessible or elevated/different-user processes, missing launch data, a hosted stdio agent with no discoverable GUI owner, noninteractive `exec`/`review` commands that would be replayed, and a target containing the switch coordinator. For the last case, launch `codexSwitch.cmd` separately from Explorer or an independent terminal.

Discovery covers local Windows Codex binaries, known ACP binaries and specific Node entry scripts, regardless of the owning app. Remote/WSL/container instances, renamed binaries, arbitrary wrappers and unrelated external OAuth connections cannot be exhaustively discovered from this process snapshot.

### Zed findings

Both the older `@zed-industries/codex-acp` and current `@agentclientprotocol/codex-acp` Node entries are recognized, as are the published `codex-acp-x64-windows.exe` and `codex-acp-arm64-windows.exe` binaries. An ACP process is a GUI-hosted agent even if its inner Codex app-server is currently absent; it must not be reopened as a detached console process.

The installed registry adapter's ChatGPT login delegates to Codex app-server authentication. Logging in through Zed does not by itself imply a separate OAuth store. Effective `CODEX_HOME`, credential-store configuration, environment and the chosen provider determine whether it shares the file managed by Switch. [Zed's external agent documentation](https://zed.dev/docs/ai/external-agents#codex) distinguishes Codex-owned authentication from Zed's own model-provider settings; [the ACP adapter](https://github.com/agentclientprotocol/codex-acp#authentication) documents its authentication modes.

The integrated-terminal issue remains: terminating its Codex child and calling `CREATE_NEW_CONSOLE` opens a separate terminal, not the original Zed/VS Code tab. The implementation does not type `exit` into that tab. Restarting the editor alone also cannot guarantee re-execution of the original interactive Codex command. Exact terminal-session restoration is not implemented.

### Running-account behavior: Zed and VS Code

On 2026-09-15, `tests/auth-cache-probe.py` ran each installed engine with fake accounts A/B and a disposable `CODEX_HOME`. No real credentials, login/logout, model prompts or user editor shutdowns were used. HTTP proxies pointed to a closed localhost port; this is a cached identity experiment, not a successful authenticated model request.

| Installed engine | Initially | Replace file with B | `account/read`, `refreshToken: true` | Restart server |
| --- | --- | --- | --- | --- |
| Zed registry `@agentclientprotocol/codex-acp` 1.10.0 bundled Codex | A | A | A | B |
| VS Code `openai.chatgpt` 26.903.61454 | A | A | A | B |
| VS Code `openai.chatgpt` 26.908.40401 | A | A | A | B |

The [Codex authentication manager](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs) explicitly caches managed authentication. Its refresh path guards against changing account IDs. `refreshToken: true` is not an account-switch command. External-token mode has a different lifecycle; injecting a token using `chatgptAuthTokens` would also require its owner to implement future refresh callbacks, so it is not a substitute for switching file-managed OAuth credentials.

The installed VS Code extension starts a private stdio app-server and refreshes its UI on `account/updated`. Its own server-restart UI invokes `workbench.action.reloadWindow`; its manifest does not expose a standalone external restart command. An unexpected server exit produces an error, not a verified reconnect/resume operation. Zed's installed ACP adapter also owns a stdio connection. It has an internal restart-and-resume path for provider changes, but killing its server or replacing the auth file does not invoke that path. Switch therefore selects the owning GUI process for both, including when hidden helper processes or shells intervene. Neither engine's initial account after restart proves that the editor restored a particular conversation or made a request with that account.

### Re-executing inside an existing terminal

VS Code provides `Terminal.sendText` and `TerminalShellIntegration.executeCommand` in its [extension API](https://github.com/microsoft/vscode/blob/main/src/vscode-dts/vscode.d.ts). Zed provides internal [`terminal::SendText` keymap actions](https://zed.dev/docs/terminal#sending-text-and-keystrokes). These are APIs inside their respective applications; no supported external endpoint for targeting a particular existing terminal was found in the installed applications. They are not directly callable by a standalone PowerShell process without host cooperation or UI automation.

Simply omitting `CREATE_NEW_CONSOLE` does not target the old tab: a child inherits the launcher's console. Attaching to another console also does not coordinate the original shell, which resumes after its old Codex child exits. Reusing its input/output requires addressing that ownership problem as well. Switch currently has no verified solution for this under the no-additional-integration constraint; the new-console fallback must not be described as same-tab restoration.

## Inspection

`plan [profile] [-Json]` performs read-only discovery and native capability inspection. It does not read/refresh credentials, create the store, close apps or capture private launch recipes. `RestartTargets` shows `windows-restart-manager` or `close-and-relaunch`; `Blockers` explains actual preparation exclusions. `CanAutoRestart` indicates a candidate plan, subject to launch capture and fresh process checks during execution. `WorkspaceRestoreVerified` remains false.

`switch <profile> -Manual` retains the previous requirement that clients already be closed. Normal `switch` and the menu's switch option use automatic restart by default.

## Code design

```text
codex-switch.ps1          Composition root, parameters and top-level errors
src/
  SwitchContext.psm1      Explicit paths, OS backend and dependencies
  ConsoleUI.psm1          Commands, menu, operation lock and presentation
  AccountService.psm1     Account operation ordering and queries
  RestartService.psm1     Restart transaction and partial-failure recovery
  ProfileStore.psm1       Credentials, registry, config, journal and mutex
  CodexRuntime.psm1       Codex login/authentication protocol and process query
  ProcessAnalysis.psm1    Pure runtime classification and ancestry
  RestartPlan.psm1        Pure owner selection and restart policy
  WindowsRestart.psm1    Injectable OS operations
  WindowsRestart.cs      Windows Restart Manager interop
  FallbackRestart.cs     Launch capture, identity checks, close and Shell/console launch
```

Application services order operations; the repository owns persisted data; the Windows backend owns OS mechanisms. Explicit Context dependencies keep tests and separate stores isolated. Process analysis and restart policy accept observations without performing I/O. Native restart and fallback are two strategies behind the same backend; there is no per-editor class hierarchy or plugin installation.

Working-directory capture reads the relevant Windows process-parameter field only, with size/address checks and x64/WOW64 layouts. It does not read the full environment or process memory into reports. This Windows-internal layout can change; failure stops preparation instead of silently substituting another folder. Use 64-bit PowerShell on 64-bit Windows.

## Validation

- Fake OS scenarios: native preference, fallback, mixed owners, native setup/restart failure, partial shutdown, cancel without duplicates, validation failure, launch failure, missing capture, stale PID, self-owner protection and CLI parent preservation.
- Disposable Windows GUI fixture: actual normal close and relaunch with original cwd/quoted literal arguments, no inherited Switch console or output pipes on Shell relaunch, cancellation, stale identity rejection, registered Restart Manager shutdown/restart. Tests terminate only their own fixture executables in isolated temporary directories.
- Existing account tests: rotated-token preservation, invalid logins, login rollback, registry reconciliation and module/context isolation.
- Installed-engine cache probe: `python tests/auth-cache-probe.py --codex C:\path\to\codex.exe`. The probe reports both intermediate identities and asserts that the initial/restarted servers read A/B respectively, allowing future engines' live-reload behavior to be observed rather than assuming it remains unchanged.
- No real user editor/workspace is closed by these tests. Restored user conversations and a subsequent in-app request under the selected account have not been verified across every application.

Native contracts: [GetApplicationRestartSettings](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getapplicationrestartsettings), [RmShutdown](https://learn.microsoft.com/en-us/windows/win32/api/restartmanager/nf-restartmanager-rmshutdown), [RmRestart](https://learn.microsoft.com/en-us/windows/win32/api/restartmanager/nf-restartmanager-rmrestart).
