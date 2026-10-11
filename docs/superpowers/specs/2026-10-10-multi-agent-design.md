# Multi-agent support and rename to AgentSentinel — design

**Date:** 2026-10-10
**Status:** approved; implemented by docs/superpowers/plans/2026-10-10-multi-agent.md

## Problem

The app only knows Claude Code. People run several CLI coding agents side by side —
Codex, Gemini CLI, Copilot CLI, Hermes, OpenCode — and the question the app answers
("which terminal tab is waiting on me?") is the same for every one of them. Today the
Claude-specific knowledge is spread across three places: the hook payload shape
(`HookPayload`), process recognition (`ClaudeMatcher`), and the event-to-state mapping
(`HookEventKind` in `HookProcessor`). Everything downstream of those — the session
store, badge, alerts, visits, jumping — is already agent-agnostic.

This edition makes the agent a first-class, pluggable concept, ships adapters for the
four agents that expose JSON lifecycle hooks with a session id and working directory,
and renames the app to reflect that it is no longer Claude-only.

## Feasibility findings

Verified against official documentation on 2026-10-10. The user's machine has Claude
Code and Codex CLI 0.155.0 installed; `codex features list` reports `hooks` as
`stable true`.

| Agent | Hook mechanism | Turn finished | Needs permission | Payload carries id + cwd | Verdict |
|---|---|---|---|---|---|
| Claude Code | `~/.claude/settings.json` `hooks` | `Stop` | `Notification` | yes | shipped today |
| Codex CLI | `~/.codex/hooks.json` or `[hooks]` in `config.toml`; stdin JSON with the same field names as Claude | `Stop` with `last_assistant_message` | `PermissionRequest` | yes, plus `model` | near drop-in |
| Gemini CLI | `~/.gemini/settings.json` `hooks` | `AfterAgent` with `prompt_response` | `Notification` (`notification_type: ToolPermission`) | yes | easy |
| Copilot CLI | `~/.copilot/hooks/*.json`, `version: 1` | `agentStop` | `permissionRequest`; also `notification` type `permission_prompt` | `sessionId`, `cwd` (camelCase) | easy |
| Hermes Agent | `hooks:` block in `~/.hermes/config.yaml`, first-run consent allowlist | `post_llm_call` (approximate) | `on_human_input_request` is documented for plugins; shell binding unconfirmed | yes | later; needs a live probe |
| OpenCode | TypeScript plugin in `~/.config/opencode/plugins/`, may shell out | `session.idle` event | `permission.asked` event | via SDK client | later; adapter ships a JS file, not JSON |
| Cursor CLI | `~/.cursor/hooks.json` | `stop` | `beforeShellExecution` returning `ask` | yes | later; forum reports the CLI fires only shell events |
| Aider, Goose, others | none | — | — | — | presence-only via process scan, later |

Two facts shape the design more than the rest:

1. Codex's hook payload is deliberately Claude-compatible in shape (`session_id`, `cwd`,
   `hook_event_name`, `Stop`, `PreToolUse`). Sniffing the agent from the payload would be
   fragile, so the agent is passed explicitly at registration time instead.
2. Gemini and Copilot are Node programs. Their process rows show `argv0 = node`, so the
   current argv0-basename matcher cannot recognise them. The matcher has to look at the
   script path as well.

## Decisions

- **Scope:** Claude, Codex, Gemini CLI, Copilot CLI. Hermes, OpenCode, Cursor and the
  hookless process-scan fallback are explicitly out of scope for this edition; the
  adapter interface leaves room for them.
- **Approach:** explicit adapters. Hooks are registered as `tnav hook --agent <kind>`;
  the hook never guesses which agent it is talking to.
- **Row identity:** every row carries a short agent tag. The model name is shown when
  the payload supplies it (Codex does), on the secondary line and tooltip, never on the
  main line.
- **Registration:** `make install` registers hooks for every agent whose config
  directory exists. Diagnostics shows per-agent status and offers to register an agent
  installed afterwards.
- **Name:** the app becomes **AgentSentinel**. The CLI stays `tnav`.

## Section 1 — Core model (TNavCore)

### `AgentKind`

```swift
public struct AgentKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public static let claude  = AgentKind(rawValue: "claude")
    public static let codex   = AgentKind(rawValue: "codex")
    public static let gemini  = AgentKind(rawValue: "gemini")
    public static let copilot = AgentKind(rawValue: "copilot")
    public static let known: [AgentKind] = [.claude, .codex, .gemini, .copilot]
}
```

A struct rather than an enum so that any raw string decodes. A record written by a newer
build with a kind this build does not know still loads; it shows its raw value as the
tag and is otherwise treated like any other row. A record without the field (written by
the current build) decodes as `.claude`.

Each kind supplies: `displayName` ("Claude Code", "Codex", "Gemini CLI", "Copilot CLI"),
`tag` (two-letter row label: `CC`, `CX`, `GM`, `CP`), `configDirectory` (the directory
whose presence means "installed"), and its `AgentAdapter`.

### `AgentEvent`

Replaces `HookEventKind`. The normalized vocabulary the state machine consumes:

```swift
public enum AgentEvent: Equatable, Sendable {
    case sessionStart
    case promptSubmitted
    case toolStarting
    case turnComplete(lastMessage: String?)
    case idlePrompt                       // Claude's soft idle_prompt notification only
    case needsPermission(message: String?)
    case sessionEnd
}
```

`idlePrompt` survives because Claude emits it about a minute after every turn and the
current build deliberately treats it as soft; no other agent has an equivalent, and
inventing one would be a guess.

### `AgentAdapter`

```swift
public struct DecodedHook: Equatable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let model: String?
    public let event: AgentEvent?         // nil: event name not mapped; logged and ignored
}

public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    func decode(_ data: Data) throws -> DecodedHook
    func processMatches(_ row: ProcessRow) -> Bool
    var registration: HookRegistration { get }
}
```

One conformance per kind, each in its own file under `Sources/TNavCore/Agents/`. The
event mapping each adapter implements:

| Normalized event | Claude | Codex | Gemini | Copilot |
|---|---|---|---|---|
| `sessionStart` | `SessionStart` | `SessionStart` | `SessionStart` | `sessionStart` |
| `promptSubmitted` | `UserPromptSubmit` | `UserPromptSubmit` | `BeforeAgent` | `userPromptSubmitted` |
| `toolStarting` | `PreToolUse` | `PreToolUse` | `BeforeTool` | `preToolUse` |
| `turnComplete` | `Stop` + `last_assistant_message` | `Stop` + `last_assistant_message` | `AfterAgent` + `prompt_response` | `agentStop` (no message) |
| `idlePrompt` | `Notification`, `notification_type == idle_prompt` | — | — | — |
| `needsPermission` | `Notification`, any other type, + `message` | `PermissionRequest` + `tool_input.description` | `Notification`, `ToolPermission`, + `message` | `permissionRequest`; also `notification` with `notification_type == permission_prompt` |
| `sessionEnd` | `SessionEnd` | `SessionEnd` | `SessionEnd` | `sessionEnd` |
| id / cwd fields | `session_id`, `cwd` | `session_id`, `cwd`, `model` | `session_id`, `cwd` | `sessionId`, `cwd` |

Unknown notification types on Claude and Gemini keep decoding as `needsPermission`, as
today: unknown means urgent, not ignored.

Codex's `PermissionRequest` and Copilot's `permissionRequest` are hooks that *can answer*
the permission prompt by writing JSON to stdout. Ours must exit 0 with empty stdout on
every event, which is already the rule; the adapter tests assert that the hook command
prints nothing.

### `HookProcessor`

`apply` takes `(agent: AgentKind, decoded: DecodedHook, identity: SessionIdentity,
existing: SessionRecord?, now: Double)` and switches on `AgentEvent`. The transitions —
what preserves `since`, what re-arms a notification, what resets `reasonSince` — are
unchanged from the current build. No Claude-specific strings remain in this file.

### `SessionRecord` and `SessionStore`

Record gains `agent: AgentKind` and `model: String?`. The store's filename becomes
`<agent>-<sessionId>.json`. `load` and `all` also read a legacy bare `<sessionId>.json`
and treat it as Claude, so a running Claude session survives the upgrade. The sanitize
rule is unchanged. `tabMuteKey` stays `tty|cwd`: muting a tab mutes whatever agent runs
in it, which is what "mute this terminal" means.

## Section 2 — Hook path, process matching, nesting

### `tnav hook --agent <kind>`

`HookCommand` parses `--agent`. A missing flag means `claude`, so hooks registered by the
current build keep working until the user reinstalls. An unrecognised kind is logged and
the hook exits 0.

### `AgentMatcher`

Replaces `ClaudeMatcher`. `ProcessRow` gains `argv1` (the first argument after argv0,
read from the same `KERN_PROCARGS2` buffer already fetched). For each `AgentKind` the
matcher checks, cheapest first:

1. `argv0Basename == kind.binaryName`
2. `command == kind.binaryName` (`p_comm`)
3. `executablePath` equals a reference path from the environment where one exists
   (`CLAUDE_CODE_EXECPATH` today; none known yet for the others)
4. for Node-based kinds: `argv0Basename == "node"` and the basename of `argv1`, stripped
   of `.js`/`.mjs`, matches one of the kind's script names (e.g. `gemini`, `copilot`)

`matches(_:) -> AgentKind?` returns which kind matched, so the resolver knows who owns
the TTY.

### `TTYResolver` and nesting

The walk is unchanged except that it counts ancestors matching *any* kind and records the
nearest one's kind. `SessionIdentity.isNested` is `agentAncestors > 1`, which covers
Codex launched from Claude's Bash tool as well as `claude -p` inside Claude. When the
nearest ancestor's kind differs from `--agent`, the hook logs the mismatch and still
treats the event as nested.

Liveness pid: nearest matching agent ancestor, else the first TTY owner. Unchanged.

### Probe before implementation

A throwaway spike, run before the plan is written: register a Codex `SessionStart` hook
that runs `tnav resolve` and append the output to the event log. It answers whether a
Codex hook subprocess sits in the process tree beneath the `codex` process that owns the
TTY, as Claude's do. If Codex detaches hooks from its own tree, the Codex adapter needs a
fallback (match the live `codex` process by `cwd` from the payload) and the plan must
include it. It also shows what Codex's hook trust prompt looks like on first run, which
the install script has to tell the user about.

## Section 3 — Registration and Diagnostics

`scripts/register-hooks.py` becomes a small package: one registrar per agent sharing
the current contract — read, back up to `<file>.tnav-backup`, strip entries recognised
as ours, merge, write atomically, and refuse to touch a file it cannot parse.

| Agent | File | Shape | "Ours" marker |
|---|---|---|---|
| Claude | `~/.claude/settings.json` | `hooks.<Event>[] { hooks: [{type: command, command}] }` | command ends `tnav hook --agent claude`, or contains `ClaudeBar.app` / `TerminalNavigator.app` / bare `tnav hook` (old installs) |
| Codex | `~/.codex/hooks.json` | top-level `hooks.<Event>[] { hooks: [...] }`, same group shape | command ends `tnav hook --agent codex` |
| Gemini | `~/.gemini/settings.json` | `hooks.<Event>[] { hooks: [{type: command, command}] }` | command ends `tnav hook --agent gemini` |
| Copilot | `~/.copilot/hooks/agentsentinel.json` | `{ version: 1, hooks: { <event>: [{type: command, bash, timeoutSec}] } }` | the whole file is ours; written and removed as a unit |

Events registered per agent are exactly the native names in the Section 1 table.

**Detection:** a registrar runs when the agent's config directory exists.
`./scripts/install.sh --agents claude,codex` overrides detection. `uninstall.sh` strips
from all four regardless. Install prints, for Codex, that Codex will ask to trust the
new hook on its next start and that an edited hook is skipped until re-trusted.

**Diagnostics** replaces the single "Hooks in settings" line with a table:

```
Agents:
  Claude Code   installed   hooks registered   3 sessions
  Codex         installed   hooks NOT registered
  Gemini CLI    not installed
  Copilot CLI   not installed
```

Each installed-but-unregistered agent gets a "Register hooks for Codex…" button that
runs that agent's registrar with the bundled `tnav` path. The check reads each agent's
config file and looks for a command ending in `tnav hook --agent <kind>` on the
turn-complete and permission events.

## Section 4 — UI

- **Row:** `project · CX · needs permission · 2m`. The tag is a short monospaced label in
  the muted secondary colour, placed between project and state. When `model` is present
  the secondary line reads `codex · gpt-6-astra — <last message>`; without a model it
  reads `codex — <last message>`. The tooltip carries the full agent name and model.
- **Legend:** a new "Agents" group lists each tag with its full name.
- **Banner:** "ProjectNeuron (Codex) needs permission".
- **Strings:** "Claude is working in this tab" → "An agent is working in this tab";
  "No Claude sessions running" → "No agent sessions running"; "Show Claude's last
  message" → "Show the agent's last message". The config key behind that toggle keeps
  its current name so existing `config.json` files still apply.
- **`tnav list`:** gains an agent column; `tnav jump` and `--dump-menu` carry the tag.
- **Unchanged:** icon, colours, badge count, oldest-first jump, mute, snooze, forget,
  alert policy. The agent is a label on a row, not a new dimension of state.

## Section 5 — Rename and state directory

- `ClaudeBar` → `AgentSentinel`: Package.swift product and target names, the `.app`
  bundle, bundle id `com.ayekarimba.agentsentinel`, LaunchAgent label, Makefile help,
  menu titles, README, `make-app.sh`, `install.sh`, `uninstall.sh`. The source directory
  `Sources/ClaudeBarApp` becomes `Sources/AgentSentinelApp`.
- Old-name markers (`ClaudeBar.app`, `TerminalNavigator.app`, bare `tnav hook`) stay in
  the Claude registrar's "ours" test so a reinstall cleans up a previous install's hooks
  rather than leaving duplicates.
- State directory moves from `~/.claude/tnav/` to
  `~/Library/Application Support/AgentSentinel/`. On first launch, if the new directory
  does not exist and the old one does, the app copies `config.json`, `visits.json`,
  `alerts.json`, `events.log` and the `sessions/` directory, then leaves the old
  directory untouched. `TNAV_STATE_DIR` still overrides everything. `uninstall.sh
  --purge` removes the new directory; it also offers to remove the old one.
- The hook binary stays `tnav`, inside the bundle, as today.

## Section 6 — Testing

- **Adapters:** one test file per agent under `Tests/TNavCoreTests/Agents/` with
  payload fixtures. Codex fixtures are captured live from the probe. Gemini and Copilot
  fixtures are built from the documented field names and marked as doc-derived in a
  comment, so a live correction is one fixture edit.
- **HookProcessor:** existing tests rewritten against `AgentEvent`; behaviour
  assertions unchanged.
- **AgentMatcher / TTYResolver:** rows for a Node-based agent (`argv0 = node`,
  `argv1 = /…/gemini.js`); a Codex-under-Claude ancestry asserting `isNested`; a
  mismatched `--agent` versus nearest ancestor.
- **SessionRecord / SessionStore:** a record without `agent` decodes as Claude; a legacy
  bare filename loads; an unknown `agent` raw value decodes without throwing.
- **Integration (`scripts/integration-test.sh`):** parametrised over the four agents.
  Each emits its native payloads through `tnav hook --agent <kind>` and asserts the
  resulting record, including empty stdout on the permission event.
- **Registrars:** Python tests against a temporary `HOME` for each format: merge into a
  file with other tools' hooks, strip on uninstall, idempotent re-run, refusal on
  malformed JSON, legacy ClaudeBar entries removed.
- **Manual:** Codex end to end on this machine. Gemini and Copilot are listed in the
  README as "hooks registered, not yet verified live" until someone runs them.

## Section 7 — Out of scope

Hermes Agent, OpenCode and Cursor CLI adapters; presence-only rows for agents without
hooks (process scan); iTerm2 and Ghostty. Each is one adapter conformance plus one
registrar, or one `TabController` conformance, against the interfaces above.

## Open items the plan must resolve

1. Result of the Codex `tnav resolve` probe (Section 2).
2. Exact script basenames for Gemini and Copilot's Node entry points, to be read from
   their npm packages when writing the matcher.
3. Whether Copilot's `agentStop` should also carry the last message from
   `transcriptPath`; the current decision is no, consistent with the rule that the app
   never opens transcripts.
