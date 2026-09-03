import Foundation

/// Talks to a running `tilt up`:
///  - resource status comes from Tilt's apiserver (address + bearer token in ~/.tilt-dev/config)
///  - triggers go through the web server (localhost:10350), which wants the session
///    token it hands out as a cookie on GET /.
final class TiltClient: NSObject, URLSessionDelegate {
    struct APIConfig {
        let server: URL
        let token: String
    }

    let webBase: URL
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()
    private var webToken: String?
    private let configPath: String

    init(webPort: Int, configPath: String) {
        self.webBase = URL(string: "http://localhost:\(webPort)/")!
        self.configPath = configPath
    }

    // MARK: apiserver config

    /// Minimal parse of Tilt's kubeconfig-style file: first `server:` and `token:` lines.
    func loadConfig() -> APIConfig? {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        var server: URL?
        var token: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if server == nil, line.hasPrefix("server:") {
                server = URL(string: line.dropFirst("server:".count).trimmingCharacters(in: .whitespaces))
            } else if token == nil, line.hasPrefix("token:") {
                token = line.dropFirst("token:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let s = server, let t = token, !t.isEmpty else { return nil }
        return APIConfig(server: s, token: t)
    }

    // MARK: status

    func fetchResources(completion: @escaping (Result<Snapshot, Error>) -> Void) {
        guard let cfg = loadConfig() else {
            completion(.failure(TiltError.notRunning("No Tilt apiserver config at \(configPath)")))
            return
        }
        var req = URLRequest(url: cfg.server.appendingPathComponent("apis/tilt.dev/v1alpha1/uiresources"))
        req.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.failure(TiltError.notRunning("Tilt apiserver unreachable: \(err.localizedDescription)")))
                return
            }
            guard let http = resp as? HTTPURLResponse, let data = data else {
                completion(.failure(TiltError.badResponse("empty response")))
                return
            }
            guard http.statusCode == 200 else {
                completion(.failure(TiltError.badResponse("apiserver HTTP \(http.statusCode)")))
                return
            }
            do { completion(.success(try Snapshot.parse(data))) } catch { completion(.failure(error)) }
        }.resume()
    }

    // MARK: triggers

    func trigger(_ names: [String], completion: @escaping (Error?) -> Void) {
        withWebToken(forceRefresh: false) { [self] token in
            guard let token = token else {
                completion(TiltError.notRunning("Tilt web server unreachable at \(webBase)"))
                return
            }
            postTrigger(names, token: token) { [self] err, unauthorized in
                guard unauthorized else { completion(err); return }
                // Session token rotates when tilt restarts; fetch a fresh one and retry once.
                withWebToken(forceRefresh: true) { [self] token in
                    guard let token = token else { completion(err); return }
                    postTrigger(names, token: token) { err, _ in completion(err) }
                }
            }
        }
    }

    private func postTrigger(_ names: [String], token: String, completion: @escaping (Error?, Bool) -> Void) {
        var req = URLRequest(url: webBase.appendingPathComponent("api/trigger"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Tilt-Token")
        // build_reason 16 == BuildReasonFlagTriggerWeb, same as the UI's refresh button.
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["manifest_names": names, "build_reason": 16])
        session.dataTask(with: req) { data, resp, err in
            if let err = err { completion(err, false); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let unauthorized = code == 401 || code == 403 || body.contains("session token")
            if code == 200 && !unauthorized { completion(nil, false); return }
            completion(TiltError.badResponse("trigger failed (HTTP \(code)): \(body.trimmingCharacters(in: .whitespacesAndNewlines))"), unauthorized)
        }.resume()
    }

    private func withWebToken(forceRefresh: Bool, completion: @escaping (String?) -> Void) {
        if !forceRefresh, let t = webToken { completion(t); return }
        session.dataTask(with: URLRequest(url: webBase)) { [self] _, resp, _ in
            guard let http = resp as? HTTPURLResponse else { completion(nil); return }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields as? [String: String] ?? [:], for: webBase)
            let token = cookies.first { $0.name == "Tilt-Token" }?.value
            webToken = token
            completion(token)
        }.resume()
    }

    // MARK: TLS

    /// Tilt's apiserver uses a self-signed localhost certificate.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           host == "127.0.0.1" || host == "localhost" || host == "::1",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
