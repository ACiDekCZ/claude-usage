import Foundation

/// Runs a command line tool to completion, off the main thread.
///
/// Shared by everything the app shells out to — the `claude` CLI and `bunx
/// ccusage` — because a GUI app needs the same three corrections every time:
/// a PATH, a working directory of its own, and a watchdog.
enum Subprocess {
    enum Failure: LocalizedError {
        case notFound(String)
        case exited(tool: String, status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .notFound(let tool):
                return "\(tool) not found"
            case .exited(let tool, let status, let stderr):
                return "\(tool) exited \(status): \(stderr.prefix(200))"
            }
        }
    }

    /// The first of `candidates` that exists and can be run. A `~/` prefix is
    /// resolved against the home directory.
    static func locate(_ candidates: [String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return candidates
            .map { path in
                path.hasPrefix("~/")
                    ? home.appendingPathComponent(String(path.dropFirst(2)))
                    : URL(fileURLWithPath: path)
            }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A folder of our own for spawned tools to work in. A GUI app's working
    /// directory is `/`, and a tool that looks around it from there reaches
    /// into Desktop, Documents and the like — which makes macOS ask for
    /// permission on our behalf, over and over.
    static func scratchDirectory(_ name: String) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeUsage/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// - Returns: everything the tool wrote to stdout.
    static func run(_ executable: URL,
                    _ arguments: [String],
                    workingDirectory: URL,
                    timeout: TimeInterval) async throws -> String {
        let tool = executable.lastPathComponent

        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            // A GUI app doesn't inherit the shell PATH, and these tools spawn
            // helpers of their own that need to be found.
            var environment = ProcessInfo.processInfo.environment
            let binDir = executable.deletingLastPathComponent().path
            environment["PATH"] = "\(binDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = environment
            process.currentDirectoryURL = workingDirectory

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()

            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            // Drain before waiting, so a long report can't fill the pipe buffer
            // and deadlock against waitUntilExit().
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            guard process.terminationStatus == 0 else {
                throw Failure.exited(tool: tool,
                                     status: process.terminationStatus,
                                     stderr: String(data: errData, encoding: .utf8) ?? "")
            }
            return String(data: outData, encoding: .utf8) ?? ""
        }.value
    }
}
