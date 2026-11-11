import Foundation
import QuartzCore

enum Phase { case connecting, waiting, syncing, running, error, closed }

struct ChatLine: Identifiable, Equatable {
    let id = UUID()
    let who: String
    let text: String
    let mine: Bool
    let time: Date
}

/// جلسة اللعب أونلاين (lockstep) — نفس بروتوكول نسخة الكمبيوتر حرفياً،
/// لذلك يستطيع الآيفون اللعب مع الكمبيوتر أو مع آيفون آخر.
final class Session: ObservableObject {
    enum Mode { case offline, host, join }

    static let proto = 2
    static let system = "PS1"
    static let chunk = 128 * 1024
    static let checkEvery = 120
    static let platform = "iOS"

    private enum Msg {
        static let hello: UInt8 = 1, state: UInt8 = 2, start: UInt8 = 3, ready: UInt8 = 4
        static let input: UInt8 = 5, check: UInt8 = 6, ping: UInt8 = 7, pong: UInt8 = 8, voice: UInt8 = 9, chat: UInt8 = 10
        static let mcd: UInt8 = 11
    }

    private static let serverErrors = [
        "room_taken": "هذه الغرفة مستخدمة — اختر كوداً آخر",
        "room_full": "الغرفة ممتلئة (لاعبان فقط)",
        "no_room": "لا توجد غرفة بهذا الكود — تأكد أن المضيف أنشأها أولاً",
    ]

    let mode: Mode
    let isHost: Bool
    let player: Int
    let plugin: ViewPlugin
    let name: String
    let room: String
    let core: Core
    let romCRC: UInt32
    let bios: String

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var status = ""
    @Published private(set) var rtt: Double?
    @Published private(set) var peer: String?
    @Published private(set) var peerPlatform: String?
    @Published private(set) var desync = false
    @Published private(set) var lastLog = ""
    @Published private(set) var chat: [ChatLine] = []
    private(set) var delay: Int
    private(set) var frame = 0
    /// حزم صوت µ-law واردة من الخصم
    var onVoice: ((Data) -> Void)?
    private var voiceSeq: UInt16 = 0

    private var net: Net?
    private var local: [Int: UInt16] = [:]
    private var remote: [Int: UInt16] = [:]
    private var remoteMax = 0
    private var chkL: [Int: UInt32] = [:]
    private var chkR: [Int: UInt32] = [:]
    private var chunks: [Int: Data] = [:]
    private var chunkTotal = 0
    private var lastPing: CFTimeInterval = 0
    private let srmURL: URL
    private var serverHost = ""

    init(romURL: URL, mode: Mode, server: String, room: String, name: String,
         delay: Int, plugin: ViewPlugin, hleBios: Bool) throws {
        self.mode = mode
        self.isHost = mode != .join
        self.player = mode == .join ? 1 : 0
        self.plugin = plugin
        self.name = name
        self.room = room
        self.delay = max(1, min(delay, 20))
        guard let crc = Disc.crc(romURL) else { throw AppError("ملفات القرص ناقصة — تأكد من وجود ملف .cue وكل ملفات .bin بجانبه") }
        self.romCRC = crc
        self.bios = Disc.biosID(hle: hleBios)
        self.srmURL = Paths.saves.appendingPathComponent(romURL.deletingPathExtension().lastPathComponent + ".mcr")
        self.core = try Core(path: romURL.path, biosDir: Paths.bios.path, savesDir: Paths.saves.path, hleBios: hleBios)

        do {
            if isHost { loadSRM() }
            resetLockstep()
            if mode == .offline {
                phase = .running
            } else {
                var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
                if base.isEmpty || base.contains("YOUR-NAME") {
                    throw AppError("لم تكتب رابط السيرفر بعد.\nافتح الإعدادات ⚙ واكتب رابط سيرفرك بصيغة wss://….workers.dev")
                }
                while base.hasSuffix("/") { base.removeLast() }
                guard var comps = URLComponents(string: base + "/room/" + room),
                      let scheme = comps.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
                    throw AppError("رابط السيرفر غير صحيح — يجب أن يبدأ بـ wss://")
                }
                comps.queryItems = [URLQueryItem(name: "role", value: isHost ? "host" : "guest"),
                                    URLQueryItem(name: "name", value: name),
                                    URLQueryItem(name: "token", value: Account.shared.token)]
                guard let url = comps.url else { throw AppError("رابط السيرفر غير صحيح") }
                serverHost = comps.host ?? base
                status = "جارِ الاتصال بالسيرفر..."
                let n = Net(url: url)
                n.onMessage = { [weak self] m in self?.handle(m) }
                n.onClose = { [weak self] in self?.netClosed() }
                net = n
            }
        } catch {
            core.close()
            throw error
        }
    }

    // MARK: - helpers

    private func resetLockstep() {
        frame = 0
        local = [:]
        remote = [:]
        for f in 0..<delay { local[f] = 0; remote[f] = 0 }
        remoteMax = delay - 1
        chkL = [:]
        chkR = [:]
        desync = false
    }

    private func addLog(_ s: String) {
        lastLog = s
        print("[PS1Online]", s)
    }

    private func fail(_ s: String) {
        phase = .error
        status = s
        addLog(s)
    }

    private func loadSRM() {
        guard let mem = core.memory(0), let data = try? Data(contentsOf: srmURL) else { return }
        let n = min(data.count, mem.count)
        data.copyBytes(to: mem.baseAddress!, count: n)
    }

    private func saveSRM() {
        guard let mem = core.memory(0), mem.contains(where: { $0 != 0 }) else { return }
        try? Data(buffer: mem).write(to: srmURL)
    }

    private func send(_ d: Data) { net?.send(d) }

    private func sendHello() {
        let info: [String: Any] = ["proto": Session.proto, "system": Session.system, "crc": romCRC, "name": name,
                                   "plugin": plugin.name, "core": core.version, "platform": Session.platform,
                                   "bios": bios]
        guard let json = try? JSONSerialization.data(withJSONObject: info) else { return }
        var m = Data([Msg.hello])
        m.append(json)
        send(m)
    }

    private func sendSync() {
        // بطاقة الذاكرة ليست داخل حالة PCSX — نرسلها أولاً حتى تكون نفسها عند الضيف
        if let mem = core.memory(0), let z = Z.compress(Data(buffer: UnsafeBufferPointer(mem))) {
            var m = Data([Msg.mcd])
            m.append(z)
            send(m)
        }
        guard let st = core.saveState(), let z = Z.compress(st) else {
            fail("فشل حفظ حالة اللعبة")
            return
        }
        let n = max(1, (z.count + Session.chunk - 1) / Session.chunk)
        for i in 0..<n {
            var m = Data([Msg.state])
            m.appendLE(UInt16(i))
            m.appendLE(UInt16(n))
            m.append(z.subdata(in: (i * Session.chunk)..<min(z.count, (i + 1) * Session.chunk)))
            send(m)
        }
        resetLockstep()
        send(Data([Msg.start, UInt8(delay)]))
        phase = .syncing
        status = "جارِ مزامنة اللعبة مع اللاعب الآخر..."
    }

    // MARK: - network events

    private func handle(_ m: URLSessionWebSocketTask.Message) {
        switch m {
        case .string(let s):
            if let d = s.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                onServer(o)
            }
        case .data(let d):
            if !d.isEmpty { onPeer(d) }
        @unknown default:
            break
        }
    }

    private func onServer(_ o: [String: Any]) {
        switch o["t"] as? String {
        case "welcome":
            phase = .waiting
            status = isHost ? "الغرفة جاهزة — بانتظار انضمام اللاعب الآخر..." : "بانتظار المضيف..."
        case "peer_join":
            let p = (o["name"] as? String) ?? "?"
            peer = p
            addLog("انضم: \(p)")
            sendHello()
        case "peer_left":
            addLog("خرج: \(peer ?? "")")
            peer = nil
            peerPlatform = nil
            phase = .waiting
            status = "اللاعب الآخر خرج — بانتظار عودته..."
        case "error":
            let code = (o["code"] as? String) ?? ""
            fail(Session.serverErrors[code] ?? "خطأ من السيرفر: \(code)")
        default:
            break
        }
    }

    private func onPeer(_ d: Data) {
        let k = d[d.startIndex]
        let p = d.dropFirst()
        switch k {
        case Msg.input:
            guard p.count >= 6 else { return }
            let f = Int(p.le(0) as UInt32)
            let b: UInt16 = p.le(4)
            remote[f] = b
            if f > remoteMax { remoteMax = f }
        case Msg.check:
            guard p.count >= 8 else { return }
            let f = Int(p.le(0) as UInt32)
            let c: UInt32 = p.le(4)
            chkR[f] = c
            compare(f)
        case Msg.ping:
            var out = Data([Msg.pong])
            out.append(p)
            send(out)
        case Msg.pong:
            guard p.count >= 8 else { return }
            let bits: UInt64 = p.le(0)
            let t0 = Double(bitPattern: bits)
            rtt = max(0, (CACurrentMediaTime() - t0) * 1000)
        case Msg.hello:
            guard let info = (try? JSONSerialization.jsonObject(with: Data(p))) as? [String: Any] else { return }
            if ((info["system"] as? String) ?? "SNES") != Session.system {
                fail("اللاعب الآخر يستخدم برنامج SNES Online وليس PS1 Online")
                return
            }
            if (info["proto"] as? Int) != Session.proto {
                fail("إصدار البرنامج مختلف عند اللاعب الآخر — حدّث البرنامجين")
                return
            }
            if (info["crc"] as? NSNumber)?.int64Value != Int64(romCRC) {
                fail("ملف اللعبة مختلف عند اللاعبين! يجب أن يكون نفس القرص بالضبط (ونفس الباتش)")
                return
            }
            let theirBios = (info["bios"] as? String) ?? "?"
            if theirBios != bios {
                fail("البايوس مختلف: عندك \(bios) وعند الخصم \(theirBios) — استخدما نفس ملف البايوس أو HLE عند الاثنين")
                return
            }
            let theirCore = (info["core"] as? String) ?? "?"
            if theirCore != core.version {
                fail("نسخة النواة مختلفة: عندك \(core.version) وعند الخصم \(theirCore)")
                return
            }
            if (info["plugin"] as? String) != plugin.name {
                addLog("تنبيه: اللاعب الآخر يستخدم إضافة عرض مختلفة")
            }
            peerPlatform = info["platform"] as? String
            if isHost { sendSync() }
        case Msg.mcd:
            if let data = Z.decompress(Data(p), capacity: 256 * 1024), let mem = core.memory(0) {
                let n = min(data.count, mem.count)
                data.copyBytes(to: mem.baseAddress!, count: n)
            }
        case Msg.state:
            guard p.count >= 4 else { return }
            let idx: UInt16 = p.le(0)
            let total: UInt16 = p.le(2)
            chunks[Int(idx)] = Data(p.dropFirst(4))
            chunkTotal = Int(total)
        case Msg.start:
            guard let dl = p.first else { return }
            var blob = Data()
            for i in 0..<chunkTotal {
                guard let c = chunks[i] else { fail("وصلت حالة اللعبة ناقصة"); return }
                blob.append(c)
            }
            chunks = [:]
            guard let st = Z.decompress(blob, capacity: core.stateSize * 2 + 4096), core.loadState(st) else {
                fail("فشل تحميل حالة اللعبة من المضيف (نسخة النواة مختلفة؟)")
                return
            }
            delay = Int(dl)
            resetLockstep()
            phase = .running
            status = ""
            send(Data([Msg.ready]))
        case Msg.chat:
            let text = String(decoding: Data(p), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                chat.append(ChatLine(who: peer ?? "الخصم", text: String(text.prefix(200)), mine: false, time: Date()))
                if chat.count > 50 { chat.removeFirst(chat.count - 50) }
            }
        case Msg.voice:
            if p.count > 2 { onVoice?(Data(p.dropFirst(2))) }
        case Msg.ready:
            if isHost {
                phase = .running
                status = ""
                addLog("بدأت المباراة!")
            }
        default:
            break
        }
    }

    private func netClosed() {
        guard phase != .error else { return }
        status = phase == .connecting
            ? "تعذّر الوصول إلى السيرفر\n\(serverHost)\nتأكد من الرابط في الإعدادات وأن السيرفر منشور"
            : "انقطع الاتصال بالسيرفر"
        phase = .closed
    }

    private func compare(_ f: Int) {
        guard let a = chkL[f], let b = chkR[f] else { return }
        chkL[f] = nil
        chkR[f] = nil
        if a != b {
            desync = true
            addLog("عدم تطابق (desync) عند الإطار \(f)")
        }
    }

    // MARK: - emulation

    func poll() {
        guard net != nil, peer != nil else { return }
        let now = CACurrentMediaTime()
        if now - lastPing > 1.0 {
            lastPing = now
            var m = Data([Msg.ping])
            m.appendLE(now.bitPattern)
            send(m)
        }
    }

    var behind: Bool {
        net != nil && phase == .running && remoteMax - frame > delay + 1
    }

    /// يشغّل إطاراً واحداً إذا كانت مدخلات الطرفين متوفرة
    func step(_ buttons: UInt16) -> Bool {
        guard phase == .running else { return false }
        if mode == .offline {
            core.run(buttons, 0)
            frame += 1
            return true
        }
        let tf = frame + delay
        if local[tf] == nil {
            local[tf] = buttons
            var m = Data([Msg.input])
            m.appendLE(UInt32(tf))
            m.appendLE(buttons)
            send(m)
        }
        guard let r = remote.removeValue(forKey: frame) else { return false }
        let l = local.removeValue(forKey: frame) ?? 0
        if isHost { core.run(l, r) } else { core.run(r, l) }
        if frame % Session.checkEvery == 0 {
            let c = core.wramCRC()
            chkL[frame] = c
            var m = Data([Msg.check])
            m.appendLE(UInt32(frame))
            m.appendLE(c)
            send(m)
            compare(frame)
        }
        frame += 1
        return true
    }

    var canTalk: Bool { net != nil && peer != nil && phase != .error && phase != .closed }

    @discardableResult
    func sendChat(_ text: String) -> Bool {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !t.isEmpty, canTalk else { return false }
        var m = Data([Msg.chat])
        m.append(Data(t.utf8))
        send(m)
        chat.append(ChatLine(who: "أنت", text: t, mine: true, time: Date()))
        if chat.count > 50 { chat.removeFirst(chat.count - 50) }
        return true
    }

    func sendVoice(_ d: Data) {
        guard canTalk else { return }
        voiceSeq &+= 1
        var m = Data([Msg.voice])
        m.appendLE(voiceSeq)
        m.append(d)
        send(m)
    }

    func close() {
        if isHost { saveSRM() }
        net?.close()
        net = nil
        core.close()
    }
}
