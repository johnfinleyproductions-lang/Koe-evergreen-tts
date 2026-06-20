//
//  KoeLocalServer.swift
//  ReadFlow / Koe
//
//  A tiny loopback-only HTTP listener so the Koe BROWSER EXTENSION (and any other
//  local helper) can hand selected text to the app for reading. Browsers don't
//  expose their selection to macOS accessibility, so the on-page extension POSTs
//  the highlighted text here instead.
//
//  Security posture:
//    * Binds to the LOOPBACK interface only (127.0.0.1) — never reachable off-box.
//    * Accepts only `POST /read` (+ CORS preflight). Body capped. No file access,
//      no shell, no eval — it can only ask Koe to read a string aloud.
//    * On a valid POST it posts `.readFlowReadExternalText` on the main thread;
//      the AppDelegate turns that into `manager.read(text)`.
//
//  Plain (non-actor) class: NWListener/NWConnection callbacks run on our own
//  queue; we hop to main only to post the notification (so we never touch the
//  MainActor manager from here directly).
//

import Foundation
import Network

/// `@unchecked Sendable`: the Network framework invokes its handlers as
/// `@Sendable` closures. All mutable state here is touched only on `queue`
/// (the connection handlers) or on the main thread (start/stop), never both at
/// once for the same field, so capturing `self` in those handlers is safe.
final class KoeLocalServer: @unchecked Sendable {

    /// Loopback port. 8765 is unobtrusive; the extension targets the same.
    let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "koe.localserver")
    private let maxBody = 1_000_000   // 1 MB cap on a single read request

    init(port: UInt16 = 8765) { self.port = port }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback     // 127.0.0.1 ONLY
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: nwPort) else {
            NSLog("KOE: local server could NOT bind 127.0.0.1:%d (in use?)", Int(port))
            return
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { state in
            if case .failed(let e) = state { NSLog("KOE: server failed: %@", "\(e)") }
        }
        l.start(queue: queue)
        listener = l
        NSLog("KOE: local listener up on 127.0.0.1:%d", Int(port))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }

            if buf.count > self.maxBody {
                self.send(conn, status: "413 Payload Too Large"); return
            }
            if let parsed = Self.parse(buf), parsed.complete {
                self.handle(conn, method: parsed.method, path: parsed.path, body: parsed.body)
                return
            }
            if isComplete || error != nil { conn.cancel(); return }
            self.receive(conn, buffer: buf)   // keep reading until the request is whole
        }
    }

    private func handle(_ conn: NWConnection, method: String, path: String, body: Data) {
        if method == "OPTIONS" {                       // CORS preflight
            send(conn, status: "204 No Content"); return
        }
        if method == "POST", path.hasPrefix("/read") {
            if let text = String(data: body, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("KOE: local listener received read (len=%d)", text.count)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .readFlowReadExternalText, object: text)
                }
                send(conn, status: "200 OK", contentType: "text/plain", payload: "ok")
            } else {
                send(conn, status: "400 Bad Request", payload: "empty")
            }
            return
        }
        send(conn, status: "404 Not Found", payload: "not found")
    }

    // MARK: - Response

    private func send(_ conn: NWConnection, status: String, contentType: String? = nil, payload: String = "") {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Access-Control-Allow-Origin: *\r\n"
        headers += "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
        headers += "Access-Control-Allow-Headers: Content-Type\r\n"
        if let contentType { headers += "Content-Type: \(contentType)\r\n" }
        headers += "Content-Length: \(payload.utf8.count)\r\n"
        headers += "Connection: close\r\n\r\n"
        let response = Data((headers + payload).utf8)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Minimal HTTP request parsing

    private struct Parsed { let method: String; let path: String; let body: Data; let complete: Bool }

    /// Parse a (possibly partial) HTTP/1.1 request. Returns nil until the header
    /// block is present; once headers are in, reports completeness by Content-Length.
    private static func parse(_ data: Data) -> Parsed? {
        let sep = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: sep) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]), path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyAll = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        let complete = bodyAll.count >= contentLength
        let body = complete ? Data(bodyAll.prefix(contentLength)) : bodyAll
        return Parsed(method: method, path: path, body: body, complete: complete)
    }
}
