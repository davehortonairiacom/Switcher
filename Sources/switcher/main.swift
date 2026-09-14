import Foundation
import SwitcherKit

// Phase 1 CLI: parity with gateway-on.command / gateway-off.command, so the
// .command files can be retired before any UI exists.

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = Paths.live
let controller = GatewayController(paths: paths)

func usage() -> String {
    """
    switcher — route Claude Code through the Airia gateway, or direct to Anthropic.

    USAGE
      switcher status            Show current mode and agent state (default)
      switcher direct            Go direct to Anthropic  (was: gateway-off.command)
      switcher gateway           Route through the gateway (was: gateway-on.command)
      switcher toggle            Flip to the other mode

    OPTIONS
      --json                     Machine-readable status
      --no-agent                 Don't start/stop the airiad LaunchAgent
      -h, --help                 This help

    ENVIRONMENT
      SWITCHER_CLAUDE_DIR        Operate on a different ~/.claude (for testing)
    """
}

let wantsJSON = arguments.contains("--json")
let manageAgent = !arguments.contains("--no-agent")
let verbs = arguments.filter { !$0.hasPrefix("-") }
let command = verbs.first ?? "status"

let engine = GatewayController(paths: paths, manageAgent: manageAgent)

func describe(_ mode: Mode) -> String {
    switch mode {
    case let .gateway(url):    return "GATEWAY  →  \(url)"
    case .direct:              return "DIRECT   →  api.anthropic.com"
    case let .unreadable(why): return "UNKNOWN  →  \(why)"
    }
}

func emitStatus(_ mode: Mode, _ agent: AgentStatus, notes: [String] = []) {
    if wantsJSON {
        var payload: [String: Any] = ["agent": agent.label, "notes": notes]
        switch mode {
        case let .gateway(url): payload["mode"] = "gateway"; payload["baseURL"] = url
        case .direct:           payload["mode"] = "direct"
        case let .unreadable(why): payload["mode"] = "unknown"; payload["error"] = why
        }
        let data = try! JSONSerialization.data(withJSONObject: payload,
                                               options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }
    if paths.isRedirected {
        print("[SWITCHER_CLAUDE_DIR active: \(paths.claudeDir.path)]")
    }
    for note in notes { print("  \(note)") }
    if !notes.isEmpty { print("") }
    print("Mode:  \(describe(mode))")
    print("Agent: airiad \(agent.label)")
    if mode.isDirect || !notes.isEmpty {
        print("\nRestart any running Claude Code session so it re-reads settings.")
    }
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("switcher: \(error.localizedDescription)\n".utf8))
    exit(1)
}

switch command {
case "-h", "--help", "help":
    print(usage())

case "status":
    emitStatus(engine.currentMode(), engine.agentStatus())

case "direct", "off":
    do { let out = try engine.switchToDirect(); emitStatus(out.mode, out.agent, notes: out.notes) }
    catch { fail(error) }

case "gateway", "on":
    do { let out = try engine.switchToGateway(); emitStatus(out.mode, out.agent, notes: out.notes) }
    catch { fail(error) }

case "toggle":
    do {
        let out = engine.currentMode().isGateway
            ? try engine.switchToDirect()
            : try engine.switchToGateway()
        emitStatus(out.mode, out.agent, notes: out.notes)
    } catch { fail(error) }

default:
    FileHandle.standardError.write(Data("switcher: unknown command '\(command)'\n\n".utf8))
    FileHandle.standardError.write(Data((usage() + "\n").utf8))
    exit(2)
}
