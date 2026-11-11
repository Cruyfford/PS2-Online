// PS2 Online (Cruyfford) — WebSocket + account + lobby against the SNES Online server.
// SPDX-License-Identifier: GPL-3.0+

import Foundation
import SwiftUI
import UIKit

enum NPConfig {
    static let defaultServer = "wss://snes-online-relay.cruyfford4488.workers.dev"
    static let platform = "iOS"

    static var server: String {
        let s = UserDefaults.standard.string(forKey: "np.server") ?? ""
        return s.isEmpty ? defaultServer : s
    }

    static var httpBase: String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasPrefix("wss://") { return "https://" + s.dropFirst(6) }
        if s.hasPrefix("ws://") { return "http://" + s.dropFirst(5) }
        return s
    }

    /// Both players must run the same build: the core version, the netplay hook and the settings it pins.
    static var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let b = (info["PS2OnlineBuild"] as? String) ?? ""
        let v = (info["CFBundleShortVersionString"] as? String) ?? "?"
        return b.isEmpty ? v : "\(v)-\(b)"
    }
}

// MARK: - WebSocket

/// One WebSocket. Callbacks run on the socket's own serial queue, not the main thread.
final class NPSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let onData: @Sendable (Data) -> Void
    private let onText: @Sendable (String) -> Void
    private let onClose: @Sendable () -> Void

    init(url: URL,
         onData: @escaping @Sendable (Data) -> Void,
         onText: @escaping @Sendable (String) -> Void,
         onClose: @escaping @Sendable () -> Void) {
        self.onData = onData
        self.onText = onText
        self.onClose = onClose
        super.init()
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: q)
        let t = s.webSocketTask(with: url)
        t.maximumMessageSize = 64 * 1024 * 1024
        session = s
        task = t
        t.resume()
        receive()
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.isClosed else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .data(let d): self.onData(d)
                case .string(let s): self.onText(s)
                @unknown default: break
                }
                self.receive()
            case .failure:
                self.finish()
            }
        }
    }

    func send(_ data: Data) {
        guard !isClosed else { return }
        task?.send(.data(data)) { _ in }
    }

    func sendText(_ text: String) {
        guard !isClosed else { return }
        task?.send(.string(text)) { _ in }
    }

    func close() {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        guard !was else { return }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func finish() {
        lock.lock()
        let was = closed
        closed = true
        lock.unlock()
        guard !was else { return }
        onClose()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }
}

// MARK: - Account

struct NPUser: Codable, Equatable {
    var id: String
    var username: String
    var av: Int
}

@MainActor
final class NPAccount: ObservableObject {
    static let shared = NPAccount()

    @Published private(set) var user: NPUser?
    @Published private(set) var token: String = ""

    var isLoggedIn: Bool { user != nil && !token.isEmpty }

    private static let errors: [String: String] = [
        "taken": "اسم المستخدم مستخدم من شخص آخر",
        "bad_username": "اسم المستخدم من 3 إلى 20 حرفاً (حروف وأرقام و _ . - فقط)",
        "bad_password": "كلمة المرور يجب أن تكون 6 أحرف على الأقل",
        "wrong": "اسم المستخدم أو كلمة المرور غير صحيحة",
        "locked": "محاولات كثيرة — انتظر دقيقة ثم حاول مرة أخرى",
        "network": "تعذّر الاتصال بالسيرفر — تأكد من الإنترنت",
        "auth": "انتهت الجلسة — سجّل الدخول من جديد",
    ]

    private init() {
        let d = UserDefaults.standard
        token = d.string(forKey: "np.token") ?? ""
        if let data = d.data(forKey: "np.user"), let u = try? JSONDecoder().decode(NPUser.self, from: data) {
            user = u
        }
        if token.isEmpty { user = nil }
    }

    private func call(_ path: String, body: [String: Any]? = nil, auth: Bool = false) async -> (Int, [String: Any]) {
        guard let url = URL(string: NPConfig.httpBase + path) else { return (0, ["error": "network"]) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let b = body {
            req.httpMethod = "POST"
            req.httpBody = try? JSONSerialization.data(withJSONObject: b)
        }
        if auth { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (code, obj)
        } catch {
            return (0, ["error": "network"])
        }
    }

    private static func parseUser(_ o: Any?) -> NPUser? {
        guard let d = o as? [String: Any], let id = d["id"] as? String,
              let name = d["username"] as? String else { return nil }
        return NPUser(id: id, username: name, av: (d["av"] as? NSNumber)?.intValue ?? 0)
    }

    private func save(token t: String?, user u: NPUser?) {
        let d = UserDefaults.standard
        if let t { token = t; d.set(t, forKey: "np.token") }
        user = u
        if let u, let data = try? JSONEncoder().encode(u) { d.set(data, forKey: "np.user") }
    }

    /// nil = success, else an Arabic error message
    func auth(register: Bool, username: String, password: String) async -> String? {
        let (code, res) = await call(register ? "/auth/register" : "/auth/login",
                                     body: ["username": username, "password": password])
        if code == 200, let t = res["token"] as? String, let u = NPAccount.parseUser(res["user"]) {
            save(token: t, user: u)
            return nil
        }
        if res["error"] as? String == "locked", let r = res["retry"] as? Int {
            return "محاولات كثيرة — انتظر \(r) ثانية"
        }
        return NPAccount.errors[res["error"] as? String ?? ""] ?? "حدث خطأ — حاول مرة أخرى"
    }

    func refresh() async {
        guard !token.isEmpty else { return }
        let (code, res) = await call("/auth/me", auth: true)
        if code == 200, let u = NPAccount.parseUser(res["user"]) {
            save(token: nil, user: u)
        } else if code == 401 {
            clear()
        }
    }

    func logout() {
        let t = token
        if !t.isEmpty {
            Task { _ = await self.call("/auth/logout", body: [:], auth: true) }
        }
        clear()
    }

    private func clear() {
        UserDefaults.standard.removeObject(forKey: "np.token")
        token = ""
        user = nil
    }
}

// MARK: - Lobby

struct NPPlayer: Identifiable, Equatable {
    let id: String
    let name: String
    let platform: String
    let game: String
    let status: String
    var playing: Bool { status == "playing" }
    var isIOS: Bool { platform.contains("iOS") }
}

struct NPChallenge: Identifiable, Equatable {
    let id = UUID()
    let fromId: String
    let fromName: String
    let game: String
    let crc: UInt32
    let room: String
}

@MainActor
final class NPLobby: ObservableObject {
    @Published private(set) var players: [NPPlayer] = []
    @Published private(set) var online = 0
    @Published private(set) var connected = false
    @Published var incoming: NPChallenge?

    /// (from, accepted, reason)
    var onAnswer: ((String, Bool, String) -> Void)?
    var isBusy: (() -> Bool)?

    private var sock: NPSocket?
    private var status = "idle"
    private var game = ""
    private var retryTask: Task<Void, Never>?

    var myId: String { NPAccount.shared.user?.id ?? "" }
    /// PS2 Online players only (the server is shared with SNES Online and PS1 Online)
    var others: [NPPlayer] { players.filter { $0.id != myId && $0.platform.contains("PS2") } }
    var onlinePS2: Int { players.filter { $0.platform.contains("PS2") }.count }

    func connect() {
        let acc = NPAccount.shared
        guard acc.isLoggedIn else { disconnect(); return }
        guard sock == nil else { return }
        var base = NPConfig.server
        while base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: base + "/lobby") else { return }
        comps.queryItems = [URLQueryItem(name: "id", value: myId),
                            URLQueryItem(name: "name", value: acc.user?.username ?? "Player"),
                            URLQueryItem(name: "platform", value: NPConfig.platform + " PS2"),
                            URLQueryItem(name: "game", value: game),
                            URLQueryItem(name: "status", value: status),
                            URLQueryItem(name: "token", value: acc.token)]
        guard let url = comps.url else { return }
        sock = NPSocket(url: url,
                        onData: { [weak self] d in
                            guard let s = String(data: d, encoding: .utf8) else { return }
                            Task { @MainActor in self?.handle(s) }
                        },
                        onText: { [weak self] s in Task { @MainActor in self?.handle(s) } },
                        onClose: { [weak self] in Task { @MainActor in self?.closed() } })
    }

    func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        sock?.close()
        sock = nil
        connected = false
        players = []
        online = 0
    }

    private func closed() {
        sock = nil
        connected = false
        players = []
        online = 0
        guard NPAccount.shared.isLoggedIn else { return }
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.connect() }
        }
    }

    private func handle(_ text: String) {
        guard let d = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        let from = o["from"] as? [String: Any] ?? [:]
        let fromId = from["id"] as? String ?? ""
        switch o["t"] as? String {
        case "players":
            let list = o["players"] as? [[String: Any]] ?? []
            players = list.map {
                NPPlayer(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "Player",
                         platform: $0["platform"] as? String ?? "", game: $0["game"] as? String ?? "",
                         status: $0["status"] as? String ?? "idle")
            }
            online = (o["online"] as? Int) ?? players.count
            connected = true
        case "challenge":
            let room = o["room"] as? String ?? ""
            if isBusy?() == true || incoming != nil {
                answer(to: fromId, accept: false, room: room, reason: "busy")
                return
            }
            incoming = NPChallenge(fromId: fromId, fromName: from["name"] as? String ?? "لاعب",
                                   game: o["game"] as? String ?? "",
                                   crc: (o["crc"] as? NSNumber)?.uint32Value ?? 0, room: room)
        case "answer":
            onAnswer?(fromId, (o["accept"] as? Bool) ?? false, o["reason"] as? String ?? "")
        case "cancel":
            if incoming?.fromId == fromId { incoming = nil }
        case "call":
            // Voice calls are not in the iPhone version yet.
            send(["t": "call_answer", "to": fromId, "accept": false, "room": o["room"] as? String ?? "", "reason": "busy"])
        default:
            break
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        sock?.sendText(s)
    }

    func setStatus(_ status: String, game: String) {
        self.status = status
        self.game = game.isEmpty ? "" : "PS2 · " + game
        send(["t": "status", "status": status, "game": self.game])
    }

    func challenge(to: String, game: String, crc: UInt32, room: String) {
        send(["t": "challenge", "to": to, "game": "PS2 · " + game, "crc": crc, "room": room])
    }

    func answer(to: String, accept: Bool, room: String, reason: String = "") {
        send(["t": "answer", "to": to, "accept": accept, "room": room, "reason": reason])
    }

    func cancel(to: String) { send(["t": "cancel", "to": to]) }
}
