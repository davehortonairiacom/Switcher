import Foundation
import SwitcherKit

/// Minimal assertion harness — stands in for XCTest, which is unavailable
/// without Xcode. Collects failures and reports them all at the end.
enum T {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var currentSuite = ""

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        do {
            try body()
        } catch {
            record("threw unexpectedly: \(error)", line: 0)
        }
    }

    static func record(_ message: String, line: UInt) {
        failures.append("\(currentSuite):\(line)  \(message)")
    }

    static func expect(_ condition: Bool, _ message: String, line: UInt = #line) {
        checks += 1
        if !condition { record(message, line: line) }
    }

    static func equal<V: Equatable>(_ actual: V, _ expected: V, _ message: String, line: UInt = #line) {
        checks += 1
        if actual != expected {
            record("\(message)\n      expected: \(expected)\n      actual:   \(actual)", line: line)
        }
    }

    static func isNil(_ value: Any?, _ message: String, line: UInt = #line) {
        checks += 1
        if value != nil { record("\(message) (got \(value!))", line: line) }
    }

    static func notNil(_ value: Any?, _ message: String, line: UInt = #line) {
        checks += 1
        if value == nil { record("\(message) (got nil)", line: line) }
    }

    static func throwsError(_ message: String, line: UInt = #line, _ body: () throws -> Void) {
        checks += 1
        do {
            try body()
            record("\(message) — expected a throw, got none", line: line)
        } catch { /* expected */ }
    }

    static func report() -> Never {
        print("")
        if failures.isEmpty {
            print("PASS  \(checks) checks")
            exit(0)
        }
        print("FAIL  \(failures.count) of \(checks) checks")
        for failure in failures { print("  ✗ \(failure)") }
        exit(1)
    }
}

/// A scratch ~/.claude that is torn down afterwards. The real one is never touched.
func withTempClaudeDir(_ body: (Paths) throws -> Void) rethrows {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("switcher-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(Paths(claudeDir: root))
}

extension Paths {
    func seed(_ json: String) throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try json.write(to: settings, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: settings.path)
    }
    func rawText() -> String {
        (try? String(contentsOf: settings, encoding: .utf8)) ?? ""
    }
}

/// Thread-safe counter for the integration test.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
