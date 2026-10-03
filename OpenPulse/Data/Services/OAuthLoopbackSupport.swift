import Foundation
import CryptoKit
import Network

enum OAuthPKCE {
    static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class OAuthCallbackBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func wait(timeoutSeconds: TimeInterval) async throws -> Value {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, timeoutSeconds)))
                self?.finish(.failure(NSError(domain: "OpenPulse.OAuth", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "登录超时，请重试。")
                ])))
            } catch { /* Completion cancelled this timer. */ }
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    precondition(self.continuation == nil, "Only one OAuth waiter is supported")
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func succeed(_ value: Value) {
        finish(.success(value))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

struct HTTPRequest {
    let path: String
    let queryItems: [URLQueryItem]
}

struct HTTPResponse {
    let statusCode: Int
    let contentType: String
    let body: Data

    static func text(statusCode: Int, text: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func html(statusCode: Int, body: String) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "text/html; charset=utf-8", body: Data(body.utf8))
    }
}

final class SimpleHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "OpenPulse.CodexOAuthServer")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse

    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        listener = try NWListener(using: parameters, on: port)
        self.handler = handler
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class StartState: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false
            }

            let state = StartState()

            listener.stateUpdateHandler = { newState in
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.resumed else { return }
                switch newState {
                case .ready:
                    state.resumed = true
                    continuation.resume()
                case .failed(let error):
                    state.resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    state.resumed = true
                    continuation.resume(throwing: NSError(
                        domain: "OpenPulse.CodexOAuth",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "本地登录回调服务已取消。"]
                    ))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [handler] connection in
                connection.start(queue: DispatchQueue(label: "OpenPulse.CodexOAuthConnection"))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    let request = parseRequest(from: data ?? Data())
                    Task {
                        let response = await handler(request)
                        connection.send(content: renderResponse(response), completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                }
            }

            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}

func parseRequest(from data: Data) -> HTTPRequest {
    let requestLine = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? "GET / HTTP/1.1"
    let parts = requestLine.split(separator: " ")
    let target = parts.count > 1 ? String(parts[1]) : "/"
    let components = URLComponents(string: "http://127.0.0.1\(target)")
    return HTTPRequest(path: components?.path ?? "/", queryItems: components?.queryItems ?? [])
}

func renderResponse(_ response: HTTPResponse) -> Data {
    let header = """
    HTTP/1.1 \(response.statusCode) OK\r
    Content-Type: \(response.contentType)\r
    Content-Length: \(response.body.count)\r
    Connection: close\r
    \r
    """
    return Data(header.utf8) + response.body
}

/// Reject ambiguous callback parameters before validating state or exchanging a code.
func oauthCallbackParameters(_ items: [URLQueryItem]) -> [String: String]? {
    var seenNames = Set<String>()
    var parameters: [String: String] = [:]
    for item in items {
        guard seenNames.insert(item.name).inserted else { return nil }
        if let value = item.value {
            parameters[item.name] = value
        }
    }
    return parameters
}
