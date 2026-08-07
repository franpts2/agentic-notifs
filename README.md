# Agentic Notifs

Agentic Notifs adds clickable macOS notifications to coding agents running in Ghostty or Zed terminals. It does not provide another terminal, orchestrate agents, or run Git commands.

Supported agents:

- OpenCode
- Claude Code
- Codex CLI

## What It Does

1. Your agents continue running in their existing Ghostty or Zed terminals.
2. Small adapters forward lifecycle events to the local `agentic-notify` CLI.
3. Events are normalized into live session state and actionable notification events.
4. A native menu-bar widget shows each active agent as `Running`, `Ready`, `Waiting for answer`, `Approval`, or `Error`, with its session title.
5. Clicking a notification returns to Ghostty or the originating Zed window, based on where the agent is running.

No prompts, transcripts, source code, or Git data leave your machine. The app accepts project paths, session titles, and lifecycle metadata only.

## Requirements

- macOS 13 or newer
- Swift 6 or newer
- Node.js 18 or newer for development tests
- Ghostty and/or Zed; install Zed's CLI for the best project focusing behavior

Install Zed's CLI from `Cmd+Shift+P` > `cli: install cli binary`. With it installed, Agentic Notifs uses Zed's exact workspace matching so notification clicks cannot replace an unrelated window. It falls back to `open -a Zed <project>` when the CLI is unavailable.

## Install

Download or clone this repository, then run the installer from the repository root:

```sh
./Scripts/install.sh
```

The installer:

- Builds and installs `~/Applications/Agentic Notifs.app`
- Installs `~/.local/bin/agentic-notify`
- Installs the OpenCode plugin under `$XDG_CONFIG_HOME/opencode/plugins`, or `~/.config/opencode/plugins` when `XDG_CONFIG_HOME` is unset
- Adds notification hooks to `~/.claude/settings.json`
- Adds notification hooks to `~/.codex/hooks.json`
- Creates a private local event token under `~/Library/Application Support/Agentic Notifs`
- Creates an initial `*.agentic-notifs-backup` before changing an existing JSON settings file

Allow notifications when macOS prompts you, then restart active agent sessions. Codex requires one additional confirmation: run `/hooks`, inspect the new user hooks, and trust them. Run the installer again after upgrading so the latest lifecycle hooks are added.

The installer preserves unrelated hooks and is safe to run again. It refuses to replace symlink-managed adapter or settings files, so those files can be updated explicitly by their configuration manager.

Set `AGENTIC_NOTIFS_APP_DIR` to install the app somewhere other than `~/Applications/Agentic Notifs.app`. Set `AGENTIC_NOTIFS_NO_LAUNCH=1` to install without opening the app afterward.

The app is built from source and ad hoc signed on your Mac, so installation does not require an Apple Developer account. The bundle identifier, URL scheme, install paths, and generated token contain no maintainer-specific account details.

## Test A Notification

From a project terminal:

```sh
~/.local/bin/agentic-notify emit \
  --agent opencode \
  --event done \
  --project-path "$PWD" \
  --message "The test notification worked."
```

Click the notification to return to the terminal app where the agent is running.

## Menu-Bar Widget

The menu-bar item always shows the number of active top-level agents. Open its menu to see every session as `<session title> · <agent>`, with a colored leading icon representing its state. OpenCode titles are read from its local session database during process scans; Claude Code and Codex fall back to the project name when their hooks do not provide one. Selecting a row returns to the app hosting that session.

`Running` starts when an agent begins a turn. `Ready` means the turn finished and the session is still open. `Waiting for answer` uses a question-bubble icon when the agent asks a question. Question, approval, and error states remain visible until that session continues or ends.

At launch, the app detects each interactive top-level agent process, resolves its working directory, and labels it `Active` until a lifecycle event supplies a more precise state. Background helpers and subagents are excluded. Choose **Reload Agent States** from the menu, or press `R` while it is open, to scan again. Failed or incomplete scans preserve the current rows, and a missing session must be absent from two successful scans before it is removed.

## Event Coverage

| Agent | Running | Ready | Question | Approval | Ended |
| --- | --- | --- | --- | --- | --- |
| OpenCode | `session.status` busy/retry | `session.idle` | `question.asked` | `permission.asked` | `session.deleted` |
| Claude Code | `UserPromptSubmit` | `Stop` | Actionable `Notification` types | `PermissionRequest` | `SessionEnd` |
| Codex | `UserPromptSubmit` | `Stop` | Manual emit | `PermissionRequest` | `SessionEnd` |

`session.error` and `StopFailure` set the error state. The adapters intentionally use only stable lifecycle events exposed by each agent. Any tool can send another normalized event through `agentic-notify emit`.

## Architecture

```text
OpenCode plugin ─┐
Claude hooks ────┼─> agentic-notify ─> agentic-notifs://emit ─> menu-bar state
Codex hooks ─────┘                                            ├─> macOS notification
                                                             └─> Ghostty or zed <project>
```

The CLI targets the app by bundle identifier rather than whichever app is registered as the default URL handler. Each URL is authenticated with a random, private local capability token and contains only:

- Agent and normalized event type
- Project path and display name
- Optional session identifier, session title, host app, and short message

The app rejects duplicate, unknown, oversized, or malformed URL parameters and validates that project paths are absolute. Before activating the host app, it verifies that the path exists and is a directory. Event input is never treated as a shell command.

## Development

```sh
./Scripts/test.sh
```

This validates the app resources, compiles the app and CLI, and runs deterministic self-tests for event encoding, hook normalization, OpenCode lifecycle handling, adapter cleanup, and repeatable configuration installation. A full Xcode installation is not required.

The project has no external Swift or Node.js dependencies and requires no `.env` file.

To build a release without installing it:

```sh
swift build -c release
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Security issues should follow the private reporting process in [SECURITY.md](SECURITY.md).

## Current Limitation

Ghostty and Zed do not expose a public API for selecting an exact terminal tab. Agentic Notifs remembers the native Zed window where each turn starts and focuses it directly; if that window has closed, it falls back to the matching project workspace. Multiple agent terminals inside the same Zed window still cannot be distinguished.

Live states and session titles are kept in memory. After the menu-bar app restarts, active processes and OpenCode session titles are detected immediately.

## License

Agentic Notifs is available under the [MIT License](LICENSE).
