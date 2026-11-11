import Foundation

struct LobbyPlayer: Identifiable, Equatable {
    let id: String
    let name: String
    let platform: String
    let game: String
    let status: String
    var av: Int = 0
    var playing: Bool { status == "playing" }
}

struct DMMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let mine: Bool
    let time: Date
}

struct CallInvite: Identifiable {
    let id = UUID()
    let fromId: String
    let fromName: String
    let room: String
}

struct Challenge: Identifiable {
    let id = UUID()
    let fromId: String
    let fromName: String
    let game: String
    let crc: UInt32
    let room: String
}

/// الاتصال بقائمة اللاعبين على السيرفر: العدد + الأسماء + طلبات التحدي
final class Lobby: ObservableObject {
    @Published private(set) var players: [LobbyPlayer] = []
    @Published private(set) var online = 0
    @Published private(set) var connected = false
    @Published var incoming: Challenge?
    @Published var incomingCall: CallInvite?
    @Published private(set) var dms: [String: [DMMessage]] = [:]
    @Published var unread: [String: Int] = [:]
    /// المحادثة المفتوحة حالياً (لا نحسب رسائلها كغير مقروءة)
    var openChat: String?
    var totalUnread: Int { unread.values.reduce(0, +) }

    /// (من، قبول؟، السبب)
    var onAnswer: ((String, Bool, String) -> Void)?
    var onCancel: ((String) -> Void)?
    var onCallAnswer: ((String, Bool, String) -> Void)?
    var onCallEnd: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    /// يُسأل قبل عرض التحدي: هل نحن مشغولون؟
    var isBusy: (() -> Bool)?
    var isInCall: (() -> Bool)?

    var myId: String { Account.shared.user?.id ?? "" }
    private var net: Net?
    private var server = ""
    private var name = ""
    private var status = "idle"
    private var game = ""
    private var retry: Timer?

    private var token = ""
    private var av = 0

    init() {}

    /// لاعبو PS2 Online فقط (السيرفر مشترك مع SNES Online و PS1 Online)
    var others: [LobbyPlayer] { players.filter { $0.id != myId && $0.platform.contains("PS2") } }
    var onlinePS2: Int { players.filter { $0.platform.contains("PS2") }.count }

    func connect(server: String, name: String) {
        let clean = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let acc = Account.shared
        guard acc.isLoggedIn else { disconnect(); players = []; online = 0; return }
        let av = acc.user?.av ?? 0
        if clean == self.server && name == self.name && acc.token == token && av == self.av && net != nil { return }
        disconnect()
        self.server = clean
        self.name = name
        self.token = acc.token
        self.av = av
        open()
    }

    private func open() {
        retry?.invalidate()
        retry = nil
        var base = server
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, !base.contains("YOUR-NAME"), !token.isEmpty,
              var comps = URLComponents(string: base + "/lobby") else { return }
        comps.queryItems = [URLQueryItem(name: "id", value: myId),
                            URLQueryItem(name: "name", value: name.isEmpty ? "Player" : name),
                            URLQueryItem(name: "platform", value: Session.platform + " PS2"),
                            URLQueryItem(name: "game", value: game),
                            URLQueryItem(name: "status", value: status),
                            URLQueryItem(name: "token", value: token)]
        guard let url = comps.url else { return }
        let n = Net(url: url)
        n.onMessage = { [weak self] m in self?.handle(m) }
        n.onClose = { [weak self] in self?.closed() }
        net = n
    }

    func disconnect() {
        retry?.invalidate()
        retry = nil
        net?.close()
        net = nil
        connected = false
    }

    private func closed() {
        net = nil
        connected = false
        players = []
        online = 0
        retry?.invalidate()
        guard Account.shared.isLoggedIn else { return }
        retry = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.open() }
    }

    private func handle(_ m: URLSessionWebSocketTask.Message) {
        var text: String?
        switch m {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8)
        @unknown default: break
        }
        guard let t = text, let d = t.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        let from = o["from"] as? [String: Any] ?? [:]
        let fromId = from["id"] as? String ?? ""
        switch o["t"] as? String {
        case "players":
            let list = o["players"] as? [[String: Any]] ?? []
            players = list.map {
                LobbyPlayer(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "Player",
                            platform: $0["platform"] as? String ?? "", game: $0["game"] as? String ?? "",
                            status: $0["status"] as? String ?? "idle",
                            av: ($0["av"] as? NSNumber)?.intValue ?? 0)
            }
            online = (o["online"] as? Int) ?? players.count
            connected = true
        case "challenge":
            let room = o["room"] as? String ?? ""
            if isBusy?() == true || incoming != nil {
                answer(to: fromId, accept: false, room: room, reason: "busy")
                return
            }
            incoming = Challenge(fromId: fromId, fromName: from["name"] as? String ?? "لاعب",
                                 game: o["game"] as? String ?? "",
                                 crc: (o["crc"] as? NSNumber)?.uint32Value ?? 0, room: room)
        case "answer":
            onAnswer?(fromId, (o["accept"] as? Bool) ?? false, o["reason"] as? String ?? "")
        case "cancel":
            if incoming?.fromId == fromId { incoming = nil }
            onCancel?(fromId)
        case "dm":
            let text = o["text"] as? String ?? ""
            guard !text.isEmpty else { return }
            dms[fromId, default: []].append(DMMessage(text: text, mine: false, time: Date()))
            if openChat != fromId { unread[fromId, default: 0] += 1 }
            Haptics.tap()
        case "dm_failed":
            onNotice?("لم تصل الرسالة — اللاعب غير متصل")
        case "call":
            let room = o["room"] as? String ?? ""
            if isBusy?() == true || isInCall?() == true || incomingCall != nil {
                callAnswer(to: fromId, accept: false, room: room, reason: "busy")
                return
            }
            incomingCall = CallInvite(fromId: fromId, fromName: from["name"] as? String ?? "لاعب", room: room)
        case "call_answer":
            onCallAnswer?(fromId, (o["accept"] as? Bool) ?? false, o["reason"] as? String ?? "")
        case "call_end":
            if incomingCall?.fromId == fromId {
                incomingCall = nil
                onNotice?("مكالمة فائتة من \(from["name"] as? String ?? "لاعب")")
            }
            onCallEnd?(fromId)
        default:
            break
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        net?.sendText(s)
    }

    func setStatus(_ status: String, game: String) {
        let game = game.isEmpty ? "" : "PS2 · " + game
        self.status = status
        self.game = game
        send(["t": "status", "status": status, "game": game])
    }

    func challenge(to: String, game: String, crc: UInt32, room: String) {
        send(["t": "challenge", "to": to, "game": "PS2 · " + game, "crc": crc, "room": room])
    }

    func answer(to: String, accept: Bool, room: String, reason: String = "") {
        send(["t": "answer", "to": to, "accept": accept, "room": room, "reason": reason])
    }

    func cancel(to: String) {
        send(["t": "cancel", "to": to])
    }

    func name(of id: String) -> String { players.first { $0.id == id }?.name ?? "لاعب" }

    func markRead(_ id: String) { unread[id] = nil }

    @discardableResult
    func sendDM(to: String, text: String) -> Bool {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !t.isEmpty, net != nil else { return false }
        send(["t": "dm", "to": to, "text": t])
        dms[to, default: []].append(DMMessage(text: t, mine: true, time: Date()))
        return true
    }

    func call(to: String, room: String) { send(["t": "call", "to": to, "room": room]) }

    func callAnswer(to: String, accept: Bool, room: String, reason: String = "") {
        send(["t": "call_answer", "to": to, "accept": accept, "room": room, "reason": reason])
    }

    func callEnd(to: String) { send(["t": "call_end", "to": to]) }
}

/// G.711 µ-law (مطابق لنسخة الكمبيوتر)
enum MuLaw {
    static func encode(_ s: Int16) -> UInt8 {
        var sample = Int(s)
        let sign = sample < 0 ? 0x80 : 0
        if sample < 0 { sample = -sample }
        if sample > 32635 { sample = 32635 }
        sample += 0x84
        var exponent = 7
        var mask = 0x4000
        while exponent > 0 && (sample & mask) == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (sample >> (exponent + 3)) & 0x0F
        return UInt8(~(sign | (exponent << 4) | mantissa) & 0xFF)
    }

    static func decode(_ b: UInt8) -> Int16 {
        let u = ~Int(b) & 0xFF
        let t = (((u & 0x0F) << 3) + 0x84) << ((u & 0x70) >> 4)
        return Int16((u & 0x80) != 0 ? (0x84 - t) : (t - 0x84))
    }

    static let table: [Float] = (0..<256).map { Float(decode(UInt8($0))) / 32768 }
}
