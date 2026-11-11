import AVFoundation
import Foundation
import QuartzCore

/// مكالمة صوتية خاصة خارج اللعب — تمرّ عبر نظام الغرف في السيرفر (نفس بروتوكول الكمبيوتر)
final class VoiceCall: ObservableObject {
    enum State: Equatable { case connecting, ringing, active, ended(String) }

    let peerId: String
    let peerName: String
    let isCaller: Bool
    let room: String

    @Published private(set) var state: State = .connecting
    @Published private(set) var started: Date?
    @Published var muted = false
    @Published private(set) var meTalking = false
    @Published private(set) var peerTalking = false
    @Published private(set) var micDenied = false
    var onEnded: ((String) -> Void)?

    private var net: Net?
    private var audio: AudioOut?
    private var seq: UInt16 = 0
    private var lastPeer: CFTimeInterval = 0
    private var timer: Timer?
    private var ringTimeout: Timer?

    init(peerId: String, peerName: String, isCaller: Bool, room: String, server: String, myName: String) {
        self.peerId = peerId
        self.peerName = peerName
        self.isCaller = isCaller
        self.room = room
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: base + "/room/" + room) else {
            state = .ended("رابط السيرفر غير صحيح")
            return
        }
        comps.queryItems = [URLQueryItem(name: "role", value: isCaller ? "host" : "guest"),
                            URLQueryItem(name: "name", value: myName),
                            URLQueryItem(name: "token", value: Account.shared.token)]
        guard let url = comps.url else {
            state = .ended("رابط السيرفر غير صحيح")
            return
        }
        let n = Net(url: url)
        n.onMessage = { [weak self] m in self?.handle(m) }
        n.onClose = { [weak self] in self?.finish("انقطع الاتصال") }
        net = n
        if isCaller {
            ringTimeout = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { [weak self] _ in
                guard let self = self, self.state != .active else { return }
                self.finish("لم يتم الرد")
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let t = CACurrentMediaTime() - self.lastPeer < 0.35
            if t != self.peerTalking { self.peerTalking = t }
        }
    }

    var isEnded: Bool { if case .ended = state { return true } else { return false } }

    private func handle(_ m: URLSessionWebSocketTask.Message) {
        switch m {
        case .string(let s):
            guard let d = s.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
            switch o["t"] as? String {
            case "welcome":
                if state == .connecting { state = .ringing }
            case "peer_join":
                ringTimeout?.invalidate()
                state = .active
                started = Date()
                startAudio()
            case "peer_left":
                finish("انتهت المكالمة")
            case "error":
                finish("تعذّرت المكالمة")
            default:
                break
            }
        case .data(let d):
            guard d.count > 3, d[d.startIndex] == 9 else { return }
            audio?.voiceBuffer.push(Data(d.dropFirst(3)))
            lastPeer = CACurrentMediaTime()
        @unknown default:
            break
        }
    }

    private func startAudio() {
        guard audio == nil else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isEnded else { return }
                self.micDenied = !granted
                let a = AudioOut(sampleRate: 16000, voice: true, game: false)
                a.voiceBuffer.gain = Float(UserDefaults.standard.object(forKey: "voiceVolume") as? Double ?? 1)
                a.onMicFrame = { [weak self] data, talking in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        let t = talking && !self.muted && granted
                        if t != self.meTalking { self.meTalking = t }
                        if t, let d = data { self.sendVoice(d) }
                    }
                }
                self.audio = a
            }
        }
    }

    private func sendVoice(_ d: Data) {
        guard state == .active, let n = net else { return }
        seq &+= 1
        var m = Data([9])
        m.appendLE(seq)
        m.append(d)
        n.send(m)
    }

    func setVolume(_ v: Double) { audio?.voiceBuffer.gain = Float(v) }

    func finish(_ reason: String) {
        guard !isEnded else { return }
        state = .ended(reason)
        timer?.invalidate()
        ringTimeout?.invalidate()
        audio?.stop()
        audio = nil
        net?.close()
        net = nil
        onEnded?(reason)
    }
}
