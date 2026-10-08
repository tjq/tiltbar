import Darwin
import Foundation

/// A Tiltfile TiltBar can run `tilt up` against, plus any Tiltfile args (`tilt up -- <args>`).
struct TiltfileRef: Codable, Equatable {
    let path: String
    var args: [String] = []

    var dir: String { (path as NSString).deletingLastPathComponent }

    /// `~/code/workstation`, with the file name only when it isn't the default `Tiltfile`.
    var displayName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var name = dir == home || dir.hasPrefix(home + "/") ? "~" + dir.dropFirst(home.count) : dir
        let file = (path as NSString).lastPathComponent
        if file != "Tiltfile" { name += "/\(file)" }
        if !args.isEmpty { name += " -- " + args.joined(separator: " ") }
        return name
    }

    /// Most recent first, one entry per Tiltfile path, kept in UserDefaults.
    static var recents: [TiltfileRef] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "recentTiltfiles") else { return [] }
            return (try? JSONDecoder().decode([TiltfileRef].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.prefix(8))), forKey: "recentTiltfiles")
        }
    }

    static func remember(_ ref: TiltfileRef) {
        recents = [ref] + recents.filter { $0.path != ref.path }
    }
}

/// Starts and stops `tilt up` processes. A Tilt started from a terminal can be stopped
/// too: it is found by the process listening on the web port.
final class TiltRunner {
    let logURL: URL
    private let webPort: Int
    /// The `tilt up` this app started, while it is running.
    private(set) var child: Process?
    /// Called on the main queue when a child started by `start` exits on its own
    /// (not through `stop`), with its exit status.
    var onUnexpectedExit: ((TiltfileRef, Int32) -> Void)?
    private var stopping: Set<pid_t> = []

    init(webPort: Int) {
        self.webPort = webPort
        logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TiltBar/tilt.log")
    }

    /// Runs `tilt up` in the Tiltfile's directory through the user's login shell, so PATH
    /// and the rest of the environment match a terminal (kubectl, docker, nvm, ...).
    /// Output goes to `logURL`, replaced on each start. Tilt keeps running if TiltBar quits.
    func start(_ ref: TiltfileRef) throws {
        guard FileManager.default.fileExists(atPath: ref.path) else {
            throw TiltError.notRunning("No Tiltfile at \(ref.path)")
        }
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        var command = ["exec", "tilt", "up", "--file", ref.path]
        if !ref.args.isEmpty { command += ["--"] + ref.args }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.loginShell)
        p.arguments = ["-l", "-i", "-c", command.map(Self.shellQuote).joined(separator: " ")]
        p.currentDirectoryURL = URL(fileURLWithPath: ref.dir)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            try? log.close()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.child === proc { self.child = nil }
                if self.stopping.remove(proc.processIdentifier) == nil {
                    self.onUnexpectedExit?(ref, proc.terminationStatus)
                }
            }
        }
        try p.run()
        child = p
    }

    /// The running `tilt up`: the child this app started, or whichever tilt serves the web port.
    func runningPID() -> pid_t? {
        if let c = child, c.isRunning { return c.processIdentifier }
        return Self.listeningPID(port: webPort).flatMap { Self.executableName($0) == "tilt" ? $0 : nil }
    }

    /// Ctrl-C equivalent: SIGINT, then SIGTERM after 10s and SIGKILL after 20s if Tilt
    /// hangs on shutdown. Completion runs on the main queue once the process is gone.
    func stop(_ pid: pid_t, completion: @escaping () -> Void) {
        stopping.insert(pid)
        kill(pid, SIGINT)
        let started = Date()
        var escalated: Int32 = SIGINT
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            // kill(pid, 0) fails once the process is gone (our own child is reaped by Process).
            guard kill(pid, 0) == 0 else {
                timer.invalidate()
                // Our child's terminationHandler clears its own entry; anything else is cleared here.
                if self?.child?.processIdentifier != pid { self?.stopping.remove(pid) }
                completion()
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 20, escalated != SIGKILL { escalated = SIGKILL; kill(pid, SIGKILL) }
            else if elapsed > 10, escalated == SIGINT { escalated = SIGTERM; kill(pid, SIGTERM) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: process helpers

    private static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell, !String(cString: shell).isEmpty {
            return String(cString: shell)
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// POSIX single-quoting; also valid for fish.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func listeningPID(port: Int) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").compactMap { pid_t($0) }.first
    }

    private static func executableName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return (String(cString: buf) as NSString).lastPathComponent
    }
}
