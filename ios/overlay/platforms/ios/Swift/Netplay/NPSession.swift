// PS2 Online (Cruyfford) — the netplay session: room relay, sync, inputs.
// SPDX-License-Identifier: GPL-3.0+

import AVFoundation
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Games in the ARMSX2 library

struct NPGame: Identifiable, Hashable {
    let name: String      // ISO name as ARMSX2 lists it (what bootGame takes)
    let path: String
    var id: String { name }
    var title: String { (name as NSString).deletingPathExtension }

    static func library() -> [NPGame] {
        ARMSX2Bridge.availableISOEntries().compactMap { e in
            guard let name = e["name"] as? String, let path = e["path"] as? String, !name.isEmpty else { return nil }
            if name.lowercased().hasSuffix(".elf") { return nil }
            return NPGame(name: name, path: path)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Disc fingerprint: CRC32 of the whole file, as the PC version does. Cached by path+size+date.
enum NPDisc {
    private static func key(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mt = Int((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return "np.crc:\(path):\(size):\(mt)"
    }

    static func cached(_ path: String) -> UInt32? {
        guard let k = key(path), let v = UserDefaults.standard.object(forKey: k) as? NSNumber else { return nil }
        return v.uint32Value
    }

    /// Reads the whole file (slow the first time — call off the main thread).
    static func crc(_ path: String) -> UInt32? {
        if let c = cached(path) { return c }
        guard let k = key(path), let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var c: UInt32 = 0
        while true {
            let chunk = autoreleasepool { h.readData(ofLength: 8 << 20) }
            if chunk.isEmpty { break }
            c = chunk.withUnsafeBytes { raw in
                PS2Netplay.crc32(c, bytes: raw.baseAddress!, length: UInt(raw.count))
            }
        }
        UserDefaults.standard.set(NSNumber(value: c), forKey: k)
        return c
    }

    static func biosHash() -> String? {
        let name = ARMSX2Bridge.defaultBIOSName()
        guard !name.isEmpty else { return nil }
        let path = (ARMSX2Bridge.biosDirectory() as NSString).appendingPathComponent(name)
        return fileHash(path)
    }

    static func fileHash(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        let c = d.withUnsafeBytes { raw in PS2Netplay.crc32(0, bytes: raw.baseAddress!, length: UInt(raw.count)) }
        return String(format: "%08x-%d", c, d.count)
    }

    /// The local BIOS file (name) with this hash, if any
    static func bios(withHash h: String) -> String? {
        for info in ARMSX2Bridge.availableBIOSInfos() where info.valid {
            if fileHash(info.filePath) == h { return info.fileName }
        }
        return nil
    }
}

// MARK: - Chat

struct NPChatLine: Identifiable, Equatable {
    let id = UUID()
    let who: String
    let text: String
    let mine: Bool
    let time: Date
}

// MARK: - Session

@MainActor
final class NPSession: ObservableObject {
    enum Mode { case host, join }
    enum Phase { case connecting, waiting, syncing, running, error, closed }

    static let proto = 1
    static let chunk = 128 * 1024

    private enum Msg {
        static let hello: UInt8 = 1, state: UInt8 = 2, start: UInt8 = 3, ready: UInt8 = 4
        static let input: UInt8 = 5, check: UInt8 = 6, ping: UInt8 = 7, pong: UInt8 = 8, voice: UInt8 = 9
        static let chat: UInt8 = 10, mcd: UInt8 = 11, setup: UInt8 = 12
    }

    private static let serverErrors = [
        "room_taken": "هذه الغرفة مستخدمة — اختر كوداً آخر",
        "room_full": "الغرفة ممتلئة (لاعبان فقط)",
        "no_room": "لا توجد غرفة بهذا الكود — تأكد أن المضيف أنشأها أولاً",
    ]

    let mode: Mode
    let game: NPGame
    let room: String
    let crc: UInt32
    var isHost: Bool { mode == .host }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var status = ""
    @Published private(set) var rtt: Double?
    @Published private(set) var peer: String?
    @Published private(set) var peerPlatform: String?
    @Published private(set) var desync = false
    @Published private(set) var chat: [NPChatLine] = []
    @Published private(set) var progress: Double?
    @Published var waitingHint = ""
    @Published private(set) var voiceOn = false
    @Published private(set) var meTalking = false
    @Published private(set) var peerTalking = false
    @Published var muted = false {
        didSet { voiceSink.muted = muted }
    }
    @Published var voiceVolume: Double = UserDefaults.standard.object(forKey: "np.voiceVolume") as? Double ?? 1 {
        didSet {
            voiceSink.gain = Float(voiceVolume)
            UserDefaults.standard.set(voiceVolume, forKey: "np.voiceVolume")
        }
    }
    private(set) var delay: Int
    private let voiceSink = NPVoiceSink()
    private var voice: NPVoiceEngine?
    private var talkTimer: Timer?

    private var sock: NPSocket?
    private var booted = false
    private var bios: String?
    private var chunks: [UInt8: [Int: Data]] = [:]
    private var totals: [UInt8: Int] = [:]
    private var setup: [String: Any]?
    private var chkL: [UInt32: UInt32] = [:]
    private var chkR: [UInt32: UInt32] = [:]
    private var pingTimer: Timer?
    private let tmpDir: URL

    init(mode: Mode, game: NPGame, room: String, delay: Int, crc: UInt32) {
        self.mode = mode
        self.game = game
        self.room = room
        self.delay = max(1, min(delay, 15))
        self.crc = crc
        voiceSink.gain = Float(voiceVolume)
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ps2online", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    // MARK: start / stop

    func start() {
        guard ARMSX2Bridge.isJITAvailable() else {
            fail("JIT غير مفعّل — افتح StikDebug لتفعيله ثم ارجع وحاول مرة أخرى")
            return
        }
        bios = NPDisc.biosHash()
        guard bios != nil else {
            fail("لا يوجد بايوس PS2 — أضفه من مكتبة البايوس في التطبيق")
            return
        }
        installHandlers()
        if isHost {
            PS2Netplay.configure(asHost: true, delay: delay, guestCard: nil)
            guard AppState.shared.bootGameForNetplay(isoName: game.name) else {
                PS2Netplay.stop()
                fail("تعذّر تشغيل اللعبة")
                return
            }
            booted = true
        }
        connect()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ping() }
        }
    }

    func stop() {
        stopVoice()
        pingTimer?.invalidate()
        pingTimer = nil
        PS2Netplay.setSendInput(nil, sendCheck: nil, stateSaved: nil, stateLoaded: nil)
        PS2Netplay.stop()
        sock?.close()
        sock = nil
        if booted { AppState.shared.stopGame() }
        booted = false
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func connect() {
        var base = NPConfig.server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: base + "/room/" + room) else {
            fail("رابط السيرفر غير صحيح")
            return
        }
        comps.queryItems = [URLQueryItem(name: "role", value: isHost ? "host" : "guest"),
                            URLQueryItem(name: "name", value: NPAccount.shared.user?.username ?? "Player"),
                            URLQueryItem(name: "token", value: NPAccount.shared.token)]
        guard let url = comps.url else { fail("رابط السيرفر غير صحيح"); return }
        status = "جارِ الاتصال بالسيرفر..."
        let sink = voiceSink
        sock = NPSocket(url: url,
                        onData: { [weak self] d in
                            if d.count > 3, d[d.startIndex] == Msg.voice {
                                sink.push(d.subdata(in: (d.startIndex + 3)..<d.endIndex))
                                return
                            }
                            // Inputs go straight to the core from the socket's queue: the emulator may be
                            // waiting for exactly this frame.
                            if d.count >= 5 + 18, d[d.startIndex] == Msg.input {
                                let f: UInt32 = d.npLE(1)
                                PS2Netplay.pushRemoteInput(f, data: d.subdata(in: (d.startIndex + 5)..<(d.startIndex + 23)))
                                return
                            }
                            Task { @MainActor in self?.onPeer(d) }
                        },
                        onText: { [weak self] s in Task { @MainActor in self?.onServer(s) } },
                        onClose: { [weak self] in Task { @MainActor in self?.netClosed() } })
        sockRef?.socket = sock
    }

    /// The core calls these on its CPU thread.
    private func installHandlers() {
        let sockRef = SocketRef()
        self.sockRef = sockRef
        PS2Netplay.setSendInput({ @Sendable frame, data in
            var m = Data([Msg.input])
            m.npAppendLE(frame)
            m.append(data)
            sockRef.socket?.send(m)
        }, sendCheck: { @Sendable [weak self] frame, crc in
            var m = Data([Msg.check])
            m.npAppendLE(frame)
            m.npAppendLE(crc)
            sockRef.socket?.send(m)
            Task { @MainActor in self?.localCheck(frame, crc) }
        }, stateSaved: { @Sendable [weak self] path, ok in
            Task { @MainActor in self?.stateSaved(path, ok) }
        }, stateLoaded: { @Sendable [weak self] ok in
            Task { @MainActor in self?.stateLoaded(ok) }
        })
    }

    private var sockRef: SocketRef?

    final class SocketRef: @unchecked Sendable {
        private let lock = NSLock()
        private weak var _socket: NPSocket?
        var socket: NPSocket? {
            get { lock.lock(); defer { lock.unlock() }; return _socket }
            set { lock.lock(); _socket = newValue; lock.unlock() }
        }
    }

    private func send(_ d: Data) { sock?.send(d) }

    private func fail(_ s: String) {
        phase = .error
        status = s
    }

    // MARK: server events

    private func onServer(_ text: String) {
        sockRef?.socket = sock
        guard let d = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        switch o["t"] as? String {
        case "welcome":
            phase = .waiting
            status = isHost ? "الغرفة جاهزة — بانتظار انضمام اللاعب الآخر..." : "بانتظار المضيف..."
        case "peer_join":
            peer = (o["name"] as? String) ?? "?"
            sendHello()
        case "peer_left":
            peer = nil
            peerPlatform = nil
            if isHost {
                PS2Netplay.waitForPeer()
                phase = .waiting
                status = "اللاعب الآخر خرج — بانتظار عودته..."
            } else {
                PS2Netplay.stop()
                phase = .closed
                status = "المضيف خرج من الغرفة"
            }
        case "error":
            let code = (o["code"] as? String) ?? ""
            fail(NPSession.serverErrors[code] ?? "خطأ من السيرفر: \(code)")
        default:
            break
        }
    }

    private func netClosed() {
        guard phase != .error else { return }
        PS2Netplay.stop()
        status = phase == .connecting ? "تعذّر الوصول إلى السيرفر — تأكد من الإنترنت" : "انقطع الاتصال بالسيرفر"
        phase = .closed
    }

    private func sendHello() {
        let info: [String: Any] = ["proto": NPSession.proto, "system": "PS2", "engine": "ARMSX2",
                                   "crc": crc, "name": NPAccount.shared.user?.username ?? "Player",
                                   "core": NPConfig.build, "platform": NPConfig.platform, "bios": bios ?? ""]
        guard let json = try? JSONSerialization.data(withJSONObject: info) else { return }
        var m = Data([Msg.hello])
        m.append(json)
        send(m)
    }

    // MARK: peer messages

    private func onPeer(_ d: Data) {
        sockRef?.socket = sock
        guard let k = d.first else { return }
        let p = d.dropFirst()
        switch k {
        case Msg.hello:
            guard let info = (try? JSONSerialization.jsonObject(with: Data(p))) as? [String: Any] else { return }
            hello(info)
        case Msg.check:
            guard p.count >= 8 else { return }
            let f: UInt32 = p.npLE(0)
            let c: UInt32 = p.npLE(4)
            chkR[f] = c
            compare(f)
        case Msg.ping:
            var out = Data([Msg.pong])
            out.append(p)
            send(out)
        case Msg.pong:
            guard p.count >= 8 else { return }
            let bits: UInt64 = p.npLE(0)
            rtt = max(0, (CACurrentMediaTime() - Double(bitPattern: bits)) * 1000)
        case Msg.setup:
            setup = (try? JSONSerialization.jsonObject(with: Data(p))) as? [String: Any]
            phase = .syncing
            status = "جارِ استقبال اللعبة من المضيف..."
        case Msg.mcd, Msg.state:
            guard p.count >= 4 else { return }
            let idx: UInt16 = p.npLE(0)
            let total: UInt16 = p.npLE(2)
            chunks[k, default: [:]][Int(idx)] = Data(p.dropFirst(4))
            totals[k] = Int(total)
            if k == Msg.state { progress = Double(chunks[k]?.count ?? 0) / Double(max(1, Int(total))) }
            if k == Msg.mcd, chunks[k]?.count == Int(total) { guestCardReady() }
        case Msg.start:
            guard let dl = p.first else { return }
            guestStateReady(delay: Int(dl))
        case Msg.ready:
            if isHost {
                phase = .running
                status = ""
            }
        case Msg.chat:
            let text = String(decoding: Data(p), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { addChat(NPChatLine(who: peer ?? "الخصم", text: String(text.prefix(200)), mine: false, time: Date())) }
        default:
            break
        }
    }

    private func hello(_ info: [String: Any]) {
        if (info["system"] as? String ?? "SNES") != "PS2" {
            return fail("اللاعب الآخر يستخدم برنامج \(info["system"] as? String ?? "SNES") Online وليس PS2 Online")
        }
        if (info["engine"] as? String) != "ARMSX2" {
            return fail("اللاعب الآخر يستخدم نسخة الكمبيوتر — اللعب بين الآيفون والكمبيوتر غير مدعوم بعد في PS2 Online")
        }
        if (info["proto"] as? Int) != NPSession.proto || (info["core"] as? String) != NPConfig.build {
            return fail("نسخة التطبيق مختلفة عند اللاعبين — ثبّتا نفس ملف PS2Online.ipa")
        }
        if (info["crc"] as? NSNumber)?.uint32Value != crc {
            return fail("ملف اللعبة مختلف عند اللاعبين! يجب أن يكون نفس ملف ISO بالضبط")
        }
        peerPlatform = info["platform"] as? String
        // The guest picks its own copy of the host's BIOS when SETUP arrives, and says so if it has none.
        if isHost { hostSendSync() }
    }

    // MARK: host

    private func hostSendSync() {
        phase = .syncing
        status = "جارِ إرسال اللعبة للاعب الآخر..."
        let setupInfo: [String: Any] = ["delay": delay, "bios": bios ?? ""]
        if let json = try? JSONSerialization.data(withJSONObject: setupInfo) {
            var m = Data([Msg.setup])
            m.append(json)
            send(m)
        }
        var card = Data()
        if let p = PS2Netplay.hostCardPath(), let d = FileManager.default.contents(atPath: p),
           let z = try? (d as NSData).compressed(using: .zlib) as Data {
            card = z
        }
        sendChunks(Msg.mcd, card)
        let path = tmpDir.appendingPathComponent("host.p2s").path
        try? FileManager.default.removeItem(atPath: path)
        PS2Netplay.requestSync(path)
    }

    private func stateSaved(_ path: String, _ ok: Bool) {
        guard isHost else { return }
        guard ok, let st = FileManager.default.contents(atPath: path) else {
            status = "تعذّر حفظ حالة اللعبة — إعادة المحاولة..."
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.peer != nil else { return }
                PS2Netplay.requestSync(path)
            }
            return
        }
        chkL = [:]
        chkR = [:]
        desync = false
        sendChunks(Msg.state, st)
        send(Data([Msg.start, UInt8(delay)]))
        status = "جارِ مزامنة اللعبة مع اللاعب الآخر..."
    }

    private func sendChunks(_ kind: UInt8, _ blob: Data) {
        let n = max(1, (blob.count + NPSession.chunk - 1) / NPSession.chunk)
        for i in 0..<n {
            var m = Data([kind])
            m.npAppendLE(UInt16(i))
            m.npAppendLE(UInt16(n))
            if !blob.isEmpty {
                m.append(blob.subdata(in: (i * NPSession.chunk)..<min(blob.count, (i + 1) * NPSession.chunk)))
            }
            send(m)
        }
    }

    // MARK: guest

    private func blob(_ kind: UInt8) -> Data? {
        guard let total = totals[kind], let parts = chunks[kind], parts.count == total else { return nil }
        var out = Data()
        for i in 0..<total {
            guard let c = parts[i] else { return nil }
            out.append(c)
        }
        chunks[kind] = nil
        totals[kind] = nil
        return out
    }

    private func guestCardReady() {
        guard !isHost, !booted, let card = blob(Msg.mcd) else { return }
        let s = setup ?? [:]
        delay = (s["delay"] as? Int) ?? delay
        guard let hostBios = s["bios"] as? String, let name = NPDisc.bios(withHash: hostBios) else {
            return fail("بايوس المضيف غير موجود عندك — استورد نفس ملف البايوس الذي يستخدمه المضيف")
        }
        if ARMSX2Bridge.defaultBIOSName() != name { ARMSX2Bridge.setDefaultBIOS(name) }
        let cardName = "PS2Online-Netplay.ps2"
        let cardPath = (PS2Netplay.memoryCardFolder() as NSString).appendingPathComponent(cardName)
        try? FileManager.default.removeItem(atPath: cardPath)
        if !card.isEmpty, let raw = try? (card as NSData).decompressed(using: .zlib) as Data {
            FileManager.default.createFile(atPath: cardPath, contents: raw)
        }
        PS2Netplay.configure(asHost: false, delay: delay, guestCard: cardName)
        status = "جارِ تشغيل اللعبة..."
        guard AppState.shared.bootGameForNetplay(isoName: game.name) else {
            PS2Netplay.stop()
            return fail("تعذّر تشغيل اللعبة")
        }
        booted = true
        status = "جارِ استقبال حالة اللعبة..."
    }

    private func guestStateReady(delay dl: Int) {
        guard !isHost else { return }
        progress = nil
        guard let st = blob(Msg.state) else { return fail("وصلت حالة اللعبة ناقصة") }
        let path = tmpDir.appendingPathComponent("guest-\(UUID().uuidString).p2s").path
        guard FileManager.default.createFile(atPath: path, contents: st) else { return fail("تعذّر حفظ حالة اللعبة") }
        delay = dl
        PS2Netplay.provideState(path, delay: dl)
        status = "جارِ تحميل حالة اللعبة..."
    }

    private func stateLoaded(_ ok: Bool) {
        guard !isHost else { return }
        if ok {
            phase = .running
            status = ""
            chkL = [:]
            chkR = [:]
            desync = false
            send(Data([Msg.ready]))
        } else {
            fail("فشل تحميل حالة اللعبة من المضيف (نسخة مختلفة أو بايوس مختلف؟)")
            PS2Netplay.stop()
        }
    }

    // MARK: voice

    /// Opens the mic (asks for permission the first time). Off by default.
    func toggleVoice() {
        if voiceOn { stopVoice(); return }
        Task { @MainActor [weak self] in
            let granted = await AVAudioApplication.requestRecordPermission()
            guard let self, granted else {
                self?.addChat(NPChatLine(who: "PS2 Online", text: "اسمح للتطبيق باستخدام الميكروفون من الإعدادات", mine: false, time: Date()))
                return
            }
            self.startVoice()
        }
    }

    private func startVoice() {
        guard voice == nil, let ref = sockRef else { return }
        let sink = voiceSink
        let engine = NPVoiceEngine(sink: sink) { @Sendable [weak self] data, talking in
            if let d = data, let s = ref.socket {
                var m = Data([Msg.voice])
                m.npAppendLE(sink.nextSeq())
                m.append(d)
                s.send(m)
            }
            Task { @MainActor in
                guard let self, self.meTalking != talking else { return }
                self.meTalking = talking
            }
        }
        guard engine.start() else {
            addChat(NPChatLine(who: "PS2 Online", text: "تعذّر تشغيل الميكروفون", mine: false, time: Date()))
            return
        }
        voice = engine
        voiceOn = true
        talkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let t = CACurrentMediaTime() - self.voiceSink.lastPeer < 0.35
                if t != self.peerTalking { self.peerTalking = t }
            }
        }
    }

    private func stopVoice() {
        talkTimer?.invalidate()
        talkTimer = nil
        voice?.stop()
        voice = nil
        voiceOn = false
        meTalking = false
        peerTalking = false
    }

    // MARK: checks, ping, chat

    private func localCheck(_ f: UInt32, _ c: UInt32) {
        chkL[f] = c
        compare(f)
    }

    private func compare(_ f: UInt32) {
        guard let a = chkL[f], let b = chkR[f] else { return }
        chkL[f] = nil
        chkR[f] = nil
        if a != b { desync = true }
    }

    private func ping() {
        // The game was closed from ARMSX2's own menu: the session ends with it.
        if booted && AppState.shared.runningGameName == nil {
            NPCenter.shared.leave()
            return
        }
        guard peer != nil else { return }
        var m = Data([Msg.ping])
        m.npAppendLE(CACurrentMediaTime().bitPattern)
        send(m)
    }

    var canTalk: Bool { sock != nil && peer != nil && phase != .error && phase != .closed }

    @discardableResult
    func sendChat(_ text: String) -> Bool {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !t.isEmpty, canTalk else { return false }
        var m = Data([Msg.chat])
        m.append(Data(t.utf8))
        send(m)
        addChat(NPChatLine(who: "أنت", text: t, mine: true, time: Date()))
        return true
    }

    private func addChat(_ l: NPChatLine) {
        chat.append(l)
        if chat.count > 50 { chat.removeFirst(chat.count - 50) }
    }
}

// MARK: - little-endian helpers

extension Data {
    mutating func npAppendLE<T: FixedWidthInteger>(_ v: T) {
        var x = v
        for _ in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: x))
            x >>= 8
        }
    }

    func npLE<T: FixedWidthInteger>(_ offset: Int) -> T {
        var v: T = 0
        let start = startIndex + offset
        for i in 0..<MemoryLayout<T>.size {
            v |= T(truncatingIfNeeded: self[start + i]) << (8 * i)
        }
        return v
    }
}
