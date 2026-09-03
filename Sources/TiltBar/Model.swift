import Foundation

/// Mirrors the status buckets the Tilt web UI uses for its sidebar summary.
enum Health: Int, Comparable {
    case error = 0, building, pending, healthy, none, disabled
    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
}

struct TiltResource {
    let name: String
    let labels: [String]
    let updateStatus: String
    let runtimeStatus: String
    let hasPendingChanges: Bool
    let manualTrigger: Bool
    let disabled: Bool
    let endpoints: [URL]
    let lastDeployTime: Date?
    let pendingBuildSince: Date?
    let podStatus: String?
    let isLocal: Bool

    var isTiltfile: Bool { name == "(Tiltfile)" }

    /// Same combination rules as Tilt's web UI: error beats pending beats healthy.
    var health: Health {
        if disabled { return .disabled }
        if updateStatus == "error" || runtimeStatus == "error" { return .error }
        if updateStatus == "in_progress" { return .building }
        if updateStatus == "pending" || runtimeStatus == "pending" { return .pending }
        if Self.isNone(updateStatus) && Self.isNone(runtimeStatus) { return .none }
        return .healthy
    }

    /// True when the resource is waiting for the user: a manual-trigger resource
    /// with unapplied file changes, or a failed update/runtime.
    var needsReload: Bool {
        !disabled && (hasPendingChanges || health == .error)
    }

    var groupLabel: String { labels.first ?? "uncategorized" }

    var statusSummary: String {
        var parts: [String] = []
        if hasPendingChanges { parts.append("pending changes") }
        parts.append("update: \(updateStatus.isEmpty ? "none" : updateStatus)")
        if !Self.isNone(runtimeStatus) { parts.append("runtime: \(runtimeStatus)") }
        if let pod = podStatus, !pod.isEmpty { parts.append("pod: \(pod)") }
        if let t = lastDeployTime { parts.append("deployed \(Self.relative(t))") }
        return parts.joined(separator: " · ")
    }

    static func isNone(_ s: String) -> Bool {
        s.isEmpty || s == "none" || s == "not_applicable"
    }

    static func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

struct Snapshot {
    let resources: [TiltResource]
    let fetchedAt: Date

    /// Counts match the web UI header: Tiltfile, disabled and status-less resources are excluded.
    var counted: [TiltResource] {
        resources.filter { !$0.isTiltfile && $0.health != .disabled && $0.health != .none }
    }
    var errors: [TiltResource] { counted.filter { $0.health == .error } }
    var pending: [TiltResource] { counted.filter { $0.health == .pending || $0.health == .building } }
    var healthy: [TiltResource] { counted.filter { $0.health == .healthy } }
    var total: Int { counted.count }
    var needsReload: [TiltResource] { resources.filter { $0.needsReload && !$0.isTiltfile } }
    var pendingChanges: [TiltResource] { resources.filter { $0.hasPendingChanges && !$0.disabled } }

    static func parse(_ data: Data) throws -> Snapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            throw TiltError.badResponse("uiresources list was not JSON")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? {
            guard let s = v as? String else { return nil }
            return iso.date(from: s) ?? isoPlain.date(from: s)
        }
        let resources: [TiltResource] = items.compactMap { item in
            guard let meta = item["metadata"] as? [String: Any],
                  let name = meta["name"] as? String else { return nil }
            let status = item["status"] as? [String: Any] ?? [:]
            let labelMap = meta["labels"] as? [String: String] ?? [:]
            let disable = status["disableStatus"] as? [String: Any]
            let k8s = status["k8sResourceInfo"] as? [String: Any]
            let specs = status["specs"] as? [[String: Any]] ?? []
            let links = (status["endpointLinks"] as? [[String: Any]] ?? [])
                .compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
            return TiltResource(
                name: name,
                labels: labelMap.values.sorted(),
                updateStatus: status["updateStatus"] as? String ?? "",
                runtimeStatus: status["runtimeStatus"] as? String ?? "",
                hasPendingChanges: status["hasPendingChanges"] as? Bool ?? false,
                manualTrigger: (status["triggerMode"] as? Int ?? 0) != 0,
                disabled: (disable?["state"] as? String) == "Disabled",
                endpoints: links,
                lastDeployTime: date(status["lastDeployTime"]),
                pendingBuildSince: date(status["pendingBuildSince"]),
                podStatus: k8s?["podStatus"] as? String,
                isLocal: specs.contains { ($0["type"] as? String) == "local" }
            )
        }
        return Snapshot(resources: resources.sorted { $0.name.lowercased() < $1.name.lowercased() },
                        fetchedAt: Date())
    }
}

enum TiltError: Error, CustomStringConvertible {
    case notRunning(String)
    case badResponse(String)

    var description: String {
        switch self {
        case .notRunning(let s): return s
        case .badResponse(let s): return s
        }
    }
}
