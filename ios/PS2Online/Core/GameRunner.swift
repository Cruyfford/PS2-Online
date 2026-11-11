import AVFoundation
import GameController
import QuartzCore
import UIKit

/// مدخلات اللاعب: أزرار الشاشة + يد تحكم (MFi / Xbox / PlayStation)
final class InputState {
    private(set) var touch: UInt16 = 0
    private var dirs: UInt16 = 0
    private static let dirMask = Btn.bit(Btn.up) | Btn.bit(Btn.down) | Btn.bit(Btn.left) | Btn.bit(Btn.right)

    func set(_ bit: Int, _ on: Bool) {
        if on { touch |= Btn.bit(bit) } else { touch &= ~Btn.bit(bit) }
    }

    func setDirections(_ m: UInt16) { dirs = m & InputState.dirMask }

    func reset() { touch = 0; dirs = 0 }

    var mask: UInt16 { touch | dirs | gamepad() }

    private func gamepad() -> UInt16 {
        var m: UInt16 = 0
        for c in GCController.controllers() {
            guard let g = c.extendedGamepad else { continue }
            // نفس أماكن أزرار PS2: الأسفل=✕، اليمين=○، اليسار=□، الأعلى=△
            if g.buttonA.isPressed { m |= Btn.bit(Btn.b) }
            if g.buttonB.isPressed { m |= Btn.bit(Btn.a) }
            if g.buttonX.isPressed { m |= Btn.bit(Btn.y) }
            if g.buttonY.isPressed { m |= Btn.bit(Btn.x) }
            if g.leftShoulder.isPressed { m |= Btn.bit(Btn.l) }
            if g.rightShoulder.isPressed { m |= Btn.bit(Btn.r) }
            if g.leftTrigger.isPressed { m |= Btn.bit(Btn.l2) }
            if g.rightTrigger.isPressed { m |= Btn.bit(Btn.r2) }
            if g.leftThumbstickButton?.isPressed == true { m |= Btn.bit(Btn.l3) }
            if g.rightThumbstickButton?.isPressed == true { m |= Btn.bit(Btn.r3) }
            if g.buttonMenu.isPressed { m |= Btn.bit(Btn.start) }
            if g.buttonOptions?.isPressed == true { m |= Btn.bit(Btn.select) }
            if g.dpad.up.isPressed || g.leftThumbstick.yAxis.value > 0.5 { m |= Btn.bit(Btn.up) }
            if g.dpad.down.isPressed || g.leftThumbstick.yAxis.value < -0.5 { m |= Btn.bit(Btn.down) }
            if g.dpad.left.isPressed || g.leftThumbstick.xAxis.value < -0.5 { m |= Btn.bit(Btn.left) }
            if g.dpad.right.isPressed || g.leftThumbstick.xAxis.value > 0.5 { m |= Btn.bit(Btn.right) }
        }
        return m
    }
}

/// صوت الخصم: µ-law → عينات 16kHz تُشغَّل من خيط الصوت
final class VoiceBuffer {
    private var buf: [Float] = []
    private let lock = NSLock()
    /// مستوى صوت المحادثة (0 = صامت، 1 = عادي، 2 = ضعف)
    var gain: Float = 1

    func push(_ d: Data) {
        lock.lock()
        let g = gain
        for b in d { buf.append(max(-1, min(1, MuLaw.table[Int(b)] * g))) }
        if buf.count > 12000 { buf.removeFirst(buf.count - 3200) }
        lock.unlock()
    }

    func read(into out: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        let n = min(count, buf.count)
        for i in 0..<n { out[i] = buf[i] }
        if n > 0 { buf.removeFirst(n) }
        lock.unlock()
        if n < count { for i in n..<count { out[i] = 0 } }
    }
}

/// محرك الصوت: صوت اللعبة + (اختياري) المحادثة الصوتية مع إلغاء الصدى
final class AudioOut {
    private let engine = AVAudioEngine()
    private var gameNode: AVAudioSourceNode?
    private var voiceNode: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private var micAccum: [Int16] = []
    private var hang = 0
    private let tmp = UnsafeMutablePointer<Int16>.allocate(capacity: 8192 * 2)
    let voiceBuffer = VoiceBuffer()
    private(set) var voiceEnabled = false
    /// يُستدعى من خيط الصوت لكل 40ms من الكلام: (µ-law, يتكلم الآن؟)
    var onMicFrame: ((Data?, Bool) -> Void)?

    init(sampleRate: Double, voice: Bool, game: Bool = true) {
        let s = AVAudioSession.sharedInstance()
        if voice {
            try? s.setCategory(.playAndRecord, mode: .voiceChat,
                               options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
        } else {
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? s.setPreferredIOBufferDuration(0.01)
        try? s.setActive(true)
        if voice {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)   // إلغاء الصدى
                voiceEnabled = true
            } catch {
                voiceEnabled = false
            }
        }

        if game, let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 2, interleaved: false) {
            let tmp = self.tmp
            let src = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                let n = min(Int(frameCount), 8192)
                let got = cb_audio_pull(tmp, n)
                guard list.count >= 2,
                      let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                for i in 0..<Int(frameCount) {
                    if i < got {
                        l[i] = Float(tmp[i * 2]) / 32768
                        r[i] = Float(tmp[i * 2 + 1]) / 32768
                    } else {
                        l[i] = 0
                        r[i] = 0
                    }
                }
                return noErr
            }
            gameNode = src
            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: fmt)
        }

        if voiceEnabled { setupVoice() }
        do {
            try engine.start()
        } catch {
            voiceEnabled = false
        }
    }

    private func setupVoice() {
        guard let vfmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                       channels: 1, interleaved: false) else { return }
        let vb = voiceBuffer
        let node = AVAudioSourceNode(format: vfmt) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            if let out = list[0].mData?.assumingMemoryBound(to: Float.self) {
                vb.read(into: out, count: Int(frameCount))
            }
            return noErr
        }
        voiceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: vfmt)

        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                         channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: inFmt, to: target) else {
            voiceEnabled = false
            return
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
            self?.processMic(buf, target: target)
        }
    }

    private func processMic(_ buf: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard let conv = converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let p = out.int16ChannelData?[0], out.frameLength > 0 else { return }
        micAccum.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        while micAccum.count >= 640 {
            let frame = Array(micAccum[0..<640])
            micAccum.removeFirst(640)
            var sum: Double = 0
            for i in stride(from: 0, to: 640, by: 4) { sum += Double(frame[i]) * Double(frame[i]) }
            let rms = (sum / 160).squareRoot()
            hang = rms > 450 ? 8 : max(0, hang - 1)
            if hang > 0 {
                var d = Data(count: 640)
                d.withUnsafeMutableBytes { raw in
                    let o = raw.bindMemory(to: UInt8.self)
                    for i in 0..<640 { o[i] = MuLaw.encode(frame[i]) }
                }
                onMicFrame?(d, true)
            } else {
                onMicFrame?(nil, false)
            }
        }
    }

    func stop() {
        if voiceEnabled { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

private final class DisplayTarget: NSObject {
    weak var runner: GameRunner?
    init(_ r: GameRunner) { runner = r }
    @objc func tick() { runner?.tick() }
}

/// حلقة اللعب: تشغيل الإطارات بالتوقيت الصحيح + رسم الصورة + حساب الأقنعة
final class GameRunner: ObservableObject {
    let session: Session
    let input = InputState()
    weak var screen: ScreenUIView?
    @Published private(set) var cover: Cover?
    @Published var micMuted = false
    @Published private(set) var voiceOn = false
    @Published private(set) var meTalking = false
    @Published private(set) var peerTalking = false
    @Published var waitingHint = ""
    @Published var voiceVolume: Double = UserDefaults.standard.object(forKey: "voiceVolume") as? Double ?? 1 {
        didSet {
            audio?.voiceBuffer.gain = Float(voiceVolume)
            UserDefaults.standard.set(voiceVolume, forKey: "voiceVolume")
        }
    }
    private var lastPeerVoice: CFTimeInterval = 0

    private var link: CADisplayLink?
    private var audio: AudioOut?
    private var acc: Double = 0
    private var last: CFTimeInterval = 0
    private var lastSerial: UInt64 = 0

    init(session: Session) { self.session = session }

    func start() {
        cb_audio_clear()
        last = CACurrentMediaTime()
        if session.mode == .offline {
            audio = AudioOut(sampleRate: session.core.sampleRate, voice: false)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { [weak self] in self?.setupAudio(voice: granted) }
            }
        }
        let l = CADisplayLink(target: DisplayTarget(self), selector: #selector(DisplayTarget.tick))
        l.preferredFramesPerSecond = 60
        l.add(to: .main, forMode: .common)
        link = l
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func setupAudio(voice: Bool) {
        guard link != nil else { return }
        let a = AudioOut(sampleRate: session.core.sampleRate, voice: voice)
        a.voiceBuffer.gain = Float(voiceVolume)
        audio = a
        voiceOn = a.voiceEnabled
        guard a.voiceEnabled else { return }
        session.onVoice = { [weak self, weak a] d in
            a?.voiceBuffer.push(d)
            self?.lastPeerVoice = CACurrentMediaTime()
        }
        a.onMicFrame = { [weak self] data, talking in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let t = talking && !self.micMuted
                if t != self.meTalking { self.meTalking = t }
                if t, let d = data { self.session.sendVoice(d) }
            }
        }
    }

    func stop() {
        session.onVoice = nil
        link?.invalidate()
        link = nil
        audio?.stop()
        audio = nil
        session.close()
        cb_audio_clear()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func tick() {
        session.poll()
        let now = CACurrentMediaTime()
        let pt = now - lastPeerVoice < 0.35
        if pt != peerTalking { peerTalking = pt }
        let ft = 1.0 / session.core.fps
        acc = min(acc + now - last, ft * 4)
        last = now
        let btn = input.mask
        while acc >= ft {
            if !session.step(btn) {
                acc = min(acc, ft)
                break
            }
            acc -= ft
        }
        if session.behind { _ = session.step(btn) }

        var w: UInt32 = 0, h: UInt32 = 0, fmt: UInt32 = 0, serial: UInt64 = 0
        var pitch = 0
        guard let p = cb_frame(&w, &h, &pitch, &fmt, &serial), serial != lastSerial, w > 0, h > 0 else { return }
        lastSerial = serial
        let f = FrameInfo(ptr: p, w: Int(w), h: Int(h), pitch: pitch, fmt: Int(fmt))
        screen?.draw(f)
        let c = session.plugin.cover(player: session.player, wram: session.core.memory(2), frame: f)
        if c != cover { cover = c }
    }
}

/// شاشة اللعبة (CALayer مع تكبير بدون تنعيم)
final class ScreenUIView: UIView {
    var smooth = false {
        didSet { layer.magnificationFilter = smooth ? .linear : .nearest }
    }
    private var pixels: [UInt32] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.magnificationFilter = .nearest
        layer.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func draw(_ f: FrameInfo) {
        let n = f.w * f.h
        if pixels.count != n { pixels = [UInt32](repeating: 0, count: n) }
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<f.h {
                let row = f.ptr + y * f.pitch
                let base = y * f.w
                for x in 0..<f.w {
                    out[base + x] = 0xFF00_0000 | FrameInfo.convert(row, x, f.fmt)
                }
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let img = CGImage(width: f.w, height: f.h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: f.w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = img
        CATransaction.commit()
    }
}
