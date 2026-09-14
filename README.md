# Switcher

A macOS menu bar app for switching Claude Code between the Airia gateway and
going direct to Anthropic — and, unlike the shell scripts it replaces, *holding*
that choice.

Replaces `gateway-on.command` / `gateway-off.command`.

> **What this is for.** Airia's AI Discovery agent (`airiad`) can enforce a tenant
> policy that routes Claude Code through an Airia gateway. Engineers testing or
> demoing that agent need to flip routing on and off repeatedly — the scripts this
> replaces came from Airia's own *Sideloading & Testing the Agent* runbook. This is
> that workflow with a UI, for machines you administer yourself. It is not a way
> around someone else's policy: it needs local admin of the agent, and Unmanaged
> mode exists precisely so tenant policy can win.

## Why

The scripts were fire-and-forget. They edited `~/.claude/settings.json`, paused
the `com.airia.airiad` LaunchAgent, and recorded what they'd done in marker
files. That state drifted from reality:

- `launchctl bootout` **does not survive a reboot**. The agent comes back at
  login and re-applies the tenant enforce policy.
- So a machine last switched to Direct on 26 Aug was quietly back on the gateway
  by 13 Sep, with the `agent-was-running` marker still sitting there unconsumed.
- Nothing surfaced any of that.

Switcher derives the current mode by **reading `settings.json`**, never from a
marker, and re-asserts your chosen mode whenever something changes it.

## Install

Requires only the Xcode Command Line Tools — no full Xcode.

```sh
brew tap davehortonairiacom/tap
brew install switcher
ln -sfn "$(brew --prefix)/opt/switcher/Switcher.app" ~/Applications/Switcher.app
open ~/Applications/Switcher.app
```

Or from a clone:

```sh
make install          # builds universal, bundles, ad-hoc signs → ~/Applications
open ~/Applications/Switcher.app
```

Then tick **Start at login** in the panel.

Switcher starts in **Unmanaged**, so installing it changes nothing until you pick a route.

## Using it

Click the menu bar icon for the routing panel. It lists **Anthropic** (direct)
plus every gateway you've added; click one to switch. The row matching
`settings.json` right now is badged **LIVE**, and the ticked row is the one
Switcher will hold for you.

| Icon | Meaning |
|---|---|
| `arrow.triangle.branch` | routed through a gateway |
| `arrow.up.right` | direct to Anthropic |
| `exclamationmark.triangle.fill` | enforcement gave up — open the panel |

### Gateways

**Add Gateway…** opens an editor for a name, URL, API key and header name;
hovering a row reveals a pencil to edit or delete it. Switching between two
gateways swaps the URL *and* the key together.

The API key goes in your **login Keychain**, not on disk — `profiles.json`
holds only the name, URL and header name. (A key still reaches `settings.json`
in plaintext while that gateway is active; that's how Claude Code consumes it.)

An existing script-based setup is imported as a profile the first time Switcher
runs, so you don't start from an empty list.

### Enforce

Untick **Enforce** to drop into Unmanaged: Switcher keeps showing the truth but
never corrects drift. Use it when you want the tenant policy to win.

> Claude Code reads `settings.json` at startup. The panel warns when a session is
> running with stale settings — restart it (or reload the VS Code window) to pick
> up a switch.

## CLI

The same logic ships as a CLI, usable on its own:

```sh
~/Applications/Switcher.app/Contents/MacOS/switcher status
~/Applications/Switcher.app/Contents/MacOS/switcher direct     # was gateway-off.command
~/Applications/Switcher.app/Contents/MacOS/switcher gateway    # was gateway-on.command
~/Applications/Switcher.app/Contents/MacOS/switcher toggle
~/Applications/Switcher.app/Contents/MacOS/switcher status --json
```

`--no-agent` leaves the LaunchAgent alone (equivalent to `MANAGE_AGENT=0`).

## Safety

- **Atomic writes.** Temp file + `rename(2)`, so an interrupted write can never
  truncate `settings.json` — which the scripts' in-place write could.
- **Rolling backups.** The last 10 writes are kept in
  `~/.claude/gateway-toggle/backups/`.
- **Permissions preserved.** `settings.json` and `stash.json` stay `0600`;
  both can hold the gateway key.
- **Corrupt files are never overwritten.** A `settings.json` that won't parse is
  reported, not guessed at.
- **Script compatibility.** The stash keeps the scripts' path and JSON shape, so
  `gateway-on.command` / `gateway-off.command` still work as a fallback.

### Why enforcement can't spin

Enforcement only acts when actual ≠ desired. After a correction they match, so
the write our own watcher sees produces no further action. A circuit breaker
(5 corrections/minute) is a backstop for the adversarial case — an agent actively
rewriting the file — and trips into notify-only rather than fighting.

## Distributing it

Builds are **universal** (x86_64 + arm64), so they run on Intel Macs too. The
Makefile builds each slice separately and `lipo`s them, because SwiftPM's
`--arch` flag needs full Xcode and this project targets CLT only.

```sh
Tools/release.sh 0.1.0     # tags, then prints the url + sha256 for the formula
```

Copy `Formula/switcher.rb` into `davehortonairiacom/homebrew-tap` as
`Formula/switcher.rb`, updating `url` and `sha256` from that output.

The app is **ad-hoc signed**, which is fine when each user builds locally —
Gatekeeper only gates files carrying a quarantine attribute, and a local build
has none. A *downloaded* copy would be rejected; that needs a Developer ID
certificate and notarisation (`notarytool` and `stapler` are already in the CLT).

> Ad-hoc signatures change on every rebuild, so macOS may ask permission for
> Switcher to read its own Keychain items after you rebuild. Users installing
> once via Homebrew won't see this.

## Development

```sh
make build     # swift build -c release
make test      # runs the self-test suite
make app       # build the .app bundle into dist/
make run       # build and launch
```

Tests are a plain executable (`switcher-selftest`), not XCTest: Apple ships
XCTest with Xcode, not the Command Line Tools, and this package deliberately
builds with CLT alone. Swap in a real `.testTarget` if Xcode is ever installed.

If SwiftPM reports `accessing build database … disk I/O error` (some sandboxed
environments dislike SQLite under the repo), build out of tree:

```sh
make BUILD_DIR=~/.cache/switcher-build
```

## Layout

```
Sources/SwitcherKit/     core logic, no UI — all of it unit-tested
  SettingsStore.swift    settings.json read/write (atomic, backed up)
  Stash.swift            stash.json, script-compatible
  AgentController.swift  launchctl wrapper, injectable for tests
  SettingsWatcher.swift  FS watch with inode re-arming
  Enforcer.swift         sticky mode + circuit breaker
  GatewayController.swift  orchestration
Sources/switcher/        the CLI
Sources/SwitcherApp/     the MenuBarExtra app
Tests/SelfTest/          assertions + harness
```

## Adding more toggles later

`GatewayController` is self-contained and the menu is built from `AppModel`.
A second toggle (switch model, flip an MCP server, change AWS profile) means a
new controller in `SwitcherKit` plus a section in `MenuContent` — nothing in the
existing gateway path needs to change.
