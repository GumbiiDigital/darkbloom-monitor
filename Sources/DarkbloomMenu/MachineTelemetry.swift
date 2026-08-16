import DarkbloomCore
import Foundation

enum MachineTelemetrySource: String, Sendable {
    case local = "This Mac"
    case ssh = "10G telemetry"
    case unconfigured = "No SSH target"
}

struct MachineTelemetry: Sendable {
    var state: DaemonState?
    var checkedAt: Date
    var source: MachineTelemetrySource
    var error: String?

    var isFresh: Bool { state?.isFresh() ?? false }
}

enum MachineTelemetryReader {
    private static let remoteStateCommand = "/bin/cat $HOME/.darkbloom/daemon-state.json"

    static func collect(
        roster: [FleetRosterEntry],
        localSerial: String?,
        localState: DaemonState?
    ) async -> [String: MachineTelemetry] {
        await withTaskGroup(of: (String, MachineTelemetry).self) { group in
            for entry in roster {
                group.addTask {
                    if entry.serialNumber == localSerial {
                        return (entry.serialNumber, MachineTelemetry(
                            state: localState,
                            checkedAt: Date(),
                            source: .local,
                            error: localState == nil ? "Daemon state unavailable" : nil
                        ))
                    }
                    return (entry.serialNumber, readRemote(target: entry.sshTarget))
                }
            }

            var results: [String: MachineTelemetry] = [:]
            for await (serial, telemetry) in group {
                results[serial] = telemetry
            }
            return results
        }
    }

    private static func readRemote(target: String?) -> MachineTelemetry {
        let checkedAt = Date()
        guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines),
              isSafeSSHTarget(target)
        else {
            return MachineTelemetry(state: nil, checkedAt: checkedAt, source: .unconfigured, error: "Configure an SSH target in Fleet settings")
        }

        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "ConnectTimeout=4",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=2",
            "-o", "ServerAliveCountMax=1",
            target,
            remoteStateCommand,
        ]
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return MachineTelemetry(state: nil, checkedAt: checkedAt, source: .ssh, error: "SSH state read unavailable")
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let state = try DaemonState.decode(data)
            return MachineTelemetry(state: state, checkedAt: checkedAt, source: .ssh, error: nil)
        } catch {
            return MachineTelemetry(state: nil, checkedAt: checkedAt, source: .ssh, error: "SSH state read unavailable")
        }
    }

    private static func isSafeSSHTarget(_ target: String) -> Bool {
        guard !target.hasPrefix("-"), !target.isEmpty else { return false }
        return target.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._@:-")).contains($0)
        }
    }
}

enum RemoteProviderController {
    static func run(target: String?, verb: String, models: [String] = [], prewarm: Bool = false) -> String? {
        guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines),
              isSafeSSHTarget(target),
              ["start", "stop", "restart"].contains(verb),
              models.allSatisfy(isSafeModelID)
        else { return "Remote provider target is not configured" }

        let command: String
        if verb == "start" {
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let flags = (prewarm ? ["--local-endpoint"] : []) + models.flatMap { ["--model", $0] }
            let renderedFlags = flags.joined(separator: " ")
            command = "mkdir -p ~/.darkbloom/savepoints; if [ -f ~/.config/darkbloom/provider.toml ]; then cp ~/.config/darkbloom/provider.toml ~/.darkbloom/savepoints/provider-\(timestamp).toml; fi; exec ~/.darkbloom/bin/darkbloom start \(renderedFlags)"
        } else {
            command = "exec ~/.darkbloom/bin/darkbloom \(verb)"
        }

        let process = Process()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            target,
            command,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return "Remote darkbloom \(verb) failed"
            }
            return nil
        } catch {
            return "Remote darkbloom \(verb) could not start"
        }
    }

    private static func isSafeSSHTarget(_ target: String) -> Bool {
        guard !target.hasPrefix("-"), !target.isEmpty else { return false }
        return target.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._@:-")).contains($0)
        }
    }

    private static func isSafeModelID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }
    }
}
