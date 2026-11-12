// PS2 Online (Cruyfford) — in-game voice chat, same wire format as SNES/PS1 Online:
// [9][seq u16][µ-law 16 kHz mono, 640 samples per 40 ms frame], relayed by the room.
// SPDX-License-Identifier: GPL-3.0+

import AVFoundation
import Foundation
import QuartzCore

enum NPMuLaw {
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

/// Shared between the socket queue, the audio threads and the main thread.
final class NPVoiceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buf: [Float] = []
    private var _enabled = false
    private var _muted = false
    private var _gain: Float = 1
    private var _lastPeer: CFTimeInterval = 0
    private var _seq: UInt16 = 0

    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; if !newValue { buf.removeAll() }; lock.unlock() }
    }
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; lock.unlock() }
    }
    var gain: Float {
        get { lock.lock(); defer { lock.unlock() }; return _gain }
        set { lock.lock(); _gain = newValue; lock.unlock() }
    }
    var lastPeer: CFTimeInterval {
        lock.lock(); defer { lock.unlock() }
        return _lastPeer
    }

    func nextSeq() -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        _seq &+= 1
        return _seq
    }

    /// The peer's µ-law frame (socket queue).
    func push(_ d: Data) {
        lock.lock()
        _lastPeer = CACurrentMediaTime()
        if _enabled {
            let g = _gain
            for b in d { buf.append(max(-1, min(1, NPMuLaw.table[Int(b)] * g))) }
            if buf.count > 12000 { buf.removeFirst(buf.count - 3200) }
        }
        lock.unlock()
    }

    /// Audio render thread.
    func read(into out: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        let n = min(count, buf.count)
        for i in 0..<n { out[i] = buf[i] }
        if n > 0 { buf.removeFirst(n) }
        lock.unlock()
        if n < count { for i in n..<count { out[i] = 0 } }
    }
}

/// Mic in (echo-cancelled) and the peer's voice out, on an engine of its own next to the game's audio.
final class NPVoiceEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var micAccum: [Int16] = []
    private var hang = 0
    private let sink: NPVoiceSink
    private let onFrame: @Sendable (Data?, Bool) -> Void
    private(set) var running = false

    init(sink: NPVoiceSink, onFrame: @escaping @Sendable (Data?, Bool) -> Void) {
        self.sink = sink
        self.onFrame = onFrame
    }

    func start() -> Bool {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth])
            try s.setActive(true)
        } catch {
            return false
        }
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)   // echo cancellation
            // Keep the game at full volume while the mic is open.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            // Without echo cancellation it still works with headphones.
        }

        guard let vfmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
        else { return false }
        let sink = self.sink
        let node = AVAudioSourceNode(format: vfmt) { _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            if let out = list[0].mData?.assumingMemoryBound(to: Float.self) {
                sink.read(into: out, count: Int(frameCount))
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: vfmt)

        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: inFmt, to: target) else { return false }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
            self?.processMic(buf, target: target)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        running = true
        sink.enabled = true
        return true
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
        let muted = sink.muted
        while micAccum.count >= 640 {
            let frame = Array(micAccum[0..<640])
            micAccum.removeFirst(640)
            var sum: Double = 0
            for i in stride(from: 0, to: 640, by: 4) { sum += Double(frame[i]) * Double(frame[i]) }
            let rms = (sum / 160).squareRoot()
            hang = rms > 450 ? 8 : max(0, hang - 1)
            if hang > 0 && !muted {
                var d = Data(count: 640)
                d.withUnsafeMutableBytes { raw in
                    let o = raw.bindMemory(to: UInt8.self)
                    for i in 0..<640 { o[i] = NPMuLaw.encode(frame[i]) }
                }
                onFrame(d, true)
            } else {
                onFrame(nil, false)
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        sink.enabled = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Back to what ARMSX2's own audio expects.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
