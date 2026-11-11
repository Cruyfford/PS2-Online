import SwiftUI
import UIKit

struct ScreenView: UIViewRepresentable {
    let runner: GameRunner
    let smooth: Bool

    func makeUIView(context: Context) -> ScreenUIView {
        let v = ScreenUIView()
        runner.screen = v
        return v
    }

    func updateUIView(_ v: ScreenUIView, context: Context) {
        v.smooth = smooth
        runner.screen = v
    }
}

struct CoverBox: View {
    let text: String
    let big: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: big ? 0 : 8, style: .continuous)
                .fill(Color(hex: 0x0A0C14).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: big ? 0 : 8, style: .continuous)
                    .stroke(Theme.accentA.opacity(0.8), lineWidth: 1.5))
            Label(text, systemImage: "lock.fill")
                .font(.system(size: big ? 20 : 12, weight: .bold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(4)
        }
    }
}

/// إطار ملوّن حول عدّاد اللاعب + شارة «أنت» تحته (أو شارة وحدها إذا كان النص طويلاً)
struct BadgeBox: View {
    let text: String
    let color: Color
    let sx: CGFloat
    let sy: CGFloat
    let rect: CGRect

    var body: some View {
        let label = Text(text)
            .font(.system(size: max(9, 9 * sy), weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 6 * sx).padding(.vertical, 1.5 * sy)
            .background(Capsule().fill(color))
        if text.count > 4 {
            label.position(x: rect.midX * sx, y: rect.midY * sy)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8 * sx, style: .continuous)
                    .stroke(color, lineWidth: max(2, 2 * sx))
                    .frame(width: rect.width * sx, height: rect.height * sy)
                    .position(x: rect.midX * sx, y: rect.midY * sy)
                label.position(x: rect.midX * sx, y: (rect.maxY + 7) * sy)
            }
        }
    }
}

struct CoverOverlay: View {
    let cover: Cover?

    var body: some View {
        GeometryReader { g in
            if let c = cover {
                if c.full {
                    CoverBox(text: c.text, big: true)
                        .frame(width: g.size.width, height: g.size.height)
                } else if c.badge {
                    let sx = g.size.width / c.space.width, sy = g.size.height / c.space.height
                    BadgeBox(text: c.text, color: Color(hex: c.color), sx: sx, sy: sy, rect: c.rect)
                } else {
                    let sx = g.size.width / c.space.width, sy = g.size.height / c.space.height
                    CoverBox(text: c.text, big: false)
                        .frame(width: c.rect.width * sx, height: c.rect.height * sy)
                        .position(x: c.rect.midX * sx, y: c.rect.midY * sy)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ChatOverlay: View {
    let lines: [ChatLine]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 6) {
                Spacer()
                ForEach(lines.suffix(4).filter { ctx.date.timeIntervalSince($0.time) < 10 }) { l in
                    HStack {
                        if l.mine { Spacer(minLength: 40) }
                        Text("\(l.who): \(l.text)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(l.mine ? Theme.accentA.opacity(0.92) : Color.black.opacity(0.78)))
                            .environment(\.layoutDirection, .rightToLeft)
                        if !l.mine { Spacer(minLength: 40) }
                    }
                    .transition(.opacity)
                }
            }
            .padding(10)
            .animation(.easeOut(duration: 0.25), value: lines)
        }
        .allowsHitTesting(false)
    }
}

struct ChatInputBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .foregroundColor(.white)
            }
            TextField("اكتب رسالة…", text: $text)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Capsule().fill(Color(hex: 0x141822)))
                .overlay(Capsule().stroke(Theme.accentA.opacity(0.8)))
                .foregroundColor(Theme.text)
                .environment(\.layoutDirection, .rightToLeft)
            Button(action: onSend) {
                Image(systemName: "paperplane.fill").font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.accent))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.black.opacity(0.85))
    }
}

struct GameView: View {
    @ObservedObject var runner: GameRunner
    @ObservedObject var session: Session
    let smooth: Bool
    let onExit: () -> Void
    @State private var chatOpen = false
    @State private var chatText = ""
    @State private var seenChat = 0
    @AppStorage("enhance") private var enhance = false
    @State private var showVolume = false
    @FocusState private var chatFocused: Bool

    init(runner: GameRunner, smooth: Bool, onExit: @escaping () -> Void) {
        self.runner = runner
        self.session = runner.session
        self.smooth = smooth
        self.onExit = onExit
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape {
                    screen
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    GamepadView(input: runner.input, landscape: true)
                        .opacity(0.8)
                    VStack { hud; Spacer() }
                } else {
                    VStack(spacing: 10) {
                        hud
                        screen.padding(.horizontal, 8)
                        Spacer(minLength: 6)
                        GamepadView(input: runner.input, landscape: false)
                            .padding(.bottom, 18)
                    }
                }
                if session.desync {
                    VStack {
                        Spacer()
                        Text("⚠  عدم تطابق — أعد الانضمام للمزامنة")
                            .font(.footnote.weight(.bold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Capsule().fill(Theme.danger))
                            .foregroundColor(.white)
                            .padding(.bottom, landscape ? 12 : geo.size.height * 0.42)
                    }
                }
                if chatOpen {
                    VStack {
                        Spacer()
                        ChatInputBar(text: $chatText, focused: $chatFocused, onSend: sendChat,
                                     onClose: { chatOpen = false; chatFocused = false })
                    }
                }
                if session.phase != .running { waiting }
            }
        }
        .onChange(of: session.chat.count) { n in
            if chatOpen { seenChat = n }
            if let last = session.chat.last, !last.mine { Haptics.tap() }
        }
        .environment(\.layoutDirection, .leftToRight)
        .statusBarHidden(true)
    }

    private var screen: some View {
        ScreenView(runner: runner, smooth: smooth)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay(CoverOverlay(cover: runner.cover))
            .overlay(ChatOverlay(lines: session.chat))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Theme.accentA.opacity(0.25), radius: 18)
    }

    private func sendChat() {
        if session.sendChat(chatText) {
            chatText = ""
            seenChat = session.chat.count
        }
        chatFocused = false
        chatOpen = false
    }

    private func pingColor(_ r: Double) -> Color {
        r < 70 ? Theme.good : (r < 140 ? Theme.warn : Theme.danger)
    }

    private var volumeBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.wave.2.fill").font(.system(size: 13))
            Image(systemName: "speaker.fill").font(.system(size: 12)).foregroundColor(Theme.muted)
            Slider(value: $runner.voiceVolume, in: 0...2)
                .tint(Theme.accentB)
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12)).foregroundColor(Theme.muted)
            Text("\(Int(runner.voiceVolume * 100))%")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .frame(width: 44)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.8)).overlay(Capsule().stroke(Color.white.opacity(0.12))))
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
    }

    private var hud: some View {
        VStack(spacing: 8) {
            hudRow
            if showVolume && runner.voiceOn { volumeBar.transition(.opacity) }
        }
    }

    private var hudRow: some View {
        HStack {
            Button(action: onExit) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .foregroundColor(.white)
            }
            Spacer()
            HStack(spacing: 10) {
                Text(session.mode == .offline ? "تجربة" : (session.isHost ? "P1" : "P2"))
                    .font(.system(size: 12, weight: .heavy))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent))
                    .foregroundColor(.white)
                if let r = session.rtt {
                    HStack(spacing: 5) {
                        Circle().fill(pingColor(r)).frame(width: 7, height: 7)
                        Text("\(Int(r))ms")
                    }
                }
                if session.mode != .offline { Text("تأخير \(session.delay)") }
                if let p = session.peer {
                    Text("ضد \(p)" + (session.peerPlatform.map { " · \($0)" } ?? ""))
                        .lineLimit(1)
                }
                if runner.peerTalking {
                    Image(systemName: "speaker.wave.2.fill").foregroundColor(Theme.good)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.6))
                .overlay(Capsule().stroke(Color.white.opacity(0.1))))
            Spacer()
            if session.mode != .offline {
                Button {
                    chatOpen.toggle()
                    chatFocused = chatOpen
                    seenChat = session.chat.count
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(chatOpen ? Theme.accentA : Color.white.opacity(0.12)))
                            .foregroundColor(.white)
                        if session.chat.count > seenChat && !chatOpen {
                            Circle().fill(Theme.danger).frame(width: 10, height: 10).offset(x: 2, y: -2)
                        }
                    }
                }
            }
            Button {
                enhance.toggle()
                cb_set_enhance(enhance)
                Haptics.tap()
            } label: {
                Text(enhance ? "2x" : "1x")
                    .font(.system(size: 12, weight: .heavy))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(enhance ? Theme.accentA : Color.white.opacity(0.12)))
                    .foregroundColor(.white)
            }
            if runner.voiceOn {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showVolume.toggle() }
                } label: {
                    Image(systemName: runner.voiceVolume < 0.05 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(showVolume ? Theme.accentA : Color.white.opacity(0.12)))
                        .foregroundColor(.white)
                }
                Button {
                    runner.micMuted.toggle()
                    Haptics.tap()
                } label: {
                    Image(systemName: runner.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(runner.micMuted ? Theme.danger.opacity(0.85)
                                                  : (runner.meTalking ? Theme.good : Color.white.opacity(0.12))))
                        .foregroundColor(.white)
                }
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var waiting: some View {
        let bad = session.phase == .error || session.phase == .closed
        return ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 16) {
                if bad {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 46))
                        .foregroundColor(Theme.danger)
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Theme.accentA))
                        .scaleEffect(1.5)
                }
                Text(!runner.waitingHint.isEmpty && session.phase == .waiting ? runner.waitingHint
                     : (session.status.isEmpty ? "..." : session.status))
                    .font(.system(size: 17, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Theme.text)
                if session.mode == .host && session.phase == .waiting && runner.waitingHint.isEmpty {
                    Text("كود الغرفة — أرسله لصديقك").font(.footnote).foregroundColor(Theme.muted)
                    Text(session.room.map { String($0) }.joined(separator: " "))
                        .font(.system(size: 40, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white)
                    Button {
                        UIPasteboard.general.string = session.room
                        Haptics.tap()
                    } label: {
                        Label("نسخ الكود", systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.surface2))
                            .foregroundColor(Theme.text)
                    }
                }
                Button(action: onExit) {
                    Text("خروج").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 26).padding(.vertical, 10)
                        .overlay(Capsule().stroke(Color.white.opacity(0.25)))
                        .foregroundColor(Theme.muted)
                }
                .padding(.top, 8)
            }
            .padding(30)
        }
    }
}

// MARK: - Gamepad

struct PadButton: View {
    let label: String
    let bit: Int
    let color: Color
    let input: InputState
    var size: CGFloat = 60
    @State private var down = false

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.36, weight: .heavy))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(down ? 1 : 0.78)))
            .overlay(Circle().stroke(Color.white.opacity(down ? 0.6 : 0.15), lineWidth: 2))
            .scaleEffect(down ? 0.92 : 1)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in press(true) }
                .onEnded { _ in press(false) })
    }

    private func press(_ on: Bool) {
        guard on != down else { return }
        down = on
        input.set(bit, on)
        if on { Haptics.tap() }
    }
}

struct PillButton: View {
    let label: String
    let bit: Int
    let input: InputState
    var width: CGFloat = 78
    @State private var down = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .heavy))
            .foregroundColor(Theme.text)
            .frame(width: width, height: 30)
            .background(Capsule().fill(Color.white.opacity(down ? 0.35 : 0.13)))
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in press(true) }
                .onEnded { _ in press(false) })
    }

    private func press(_ on: Bool) {
        guard on != down else { return }
        down = on
        input.set(bit, on)
        if on { Haptics.tap() }
    }
}

struct DPadView: View {
    let input: InputState
    var size: CGFloat = 150
    @State private var dir: UInt16 = 0

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.05))
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.2))
                .frame(width: size * 0.34, height: size * 0.94)
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.2))
                .frame(width: size * 0.94, height: size * 0.34)
            arrow("arrowtriangle.up.fill", Btn.up, 0, -1)
            arrow("arrowtriangle.down.fill", Btn.down, 0, 1)
            arrow("arrowtriangle.left.fill", Btn.left, -1, 0)
            arrow("arrowtriangle.right.fill", Btn.right, 1, 0)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in update(v.location) }
            .onEnded { _ in setDir(0) })
    }

    private func arrow(_ name: String, _ bit: Int, _ dx: CGFloat, _ dy: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.12))
            .foregroundColor(dir & Btn.bit(bit) != 0 ? Theme.accentB : Color.white.opacity(0.55))
            .offset(x: dx * size * 0.32, y: dy * size * 0.32)
    }

    private func update(_ p: CGPoint) {
        let dx = p.x - size / 2, dy = p.y - size / 2
        var m: UInt16 = 0
        if hypot(dx, dy) > size * 0.1 {
            let deg = atan2(dy, dx) * 180 / .pi
            if deg > -67.5 && deg < 67.5 { m |= Btn.bit(Btn.right) }
            if deg > 112.5 || deg < -112.5 { m |= Btn.bit(Btn.left) }
            if deg > 22.5 && deg < 157.5 { m |= Btn.bit(Btn.down) }
            if deg < -22.5 && deg > -157.5 { m |= Btn.bit(Btn.up) }
        }
        setDir(m)
    }

    private func setDir(_ m: UInt16) {
        guard m != dir else { return }
        if m & ~dir != 0 { Haptics.tap() }
        dir = m
        input.setDirections(m)
    }
}

struct FaceButtons: View {
    let input: InputState
    var size: CGFloat = 58

    var body: some View {
        ZStack {
            // أزرار PS2: △ أعلى، ○ يمين، ✕ أسفل، □ يسار
            PadButton(label: "△", bit: Btn.x, color: Color(hex: 0x1FB89A), input: input, size: size)
                .offset(y: -size * 0.95)
            PadButton(label: "○", bit: Btn.a, color: Color(hex: 0xE5374F), input: input, size: size)
                .offset(x: size * 0.95)
            PadButton(label: "✕", bit: Btn.b, color: Color(hex: 0x4F7BFF), input: input, size: size)
                .offset(y: size * 0.95)
            PadButton(label: "□", bit: Btn.y, color: Color(hex: 0xE86FB6), input: input, size: size)
                .offset(x: -size * 0.95)
        }
        .frame(width: size * 3, height: size * 3)
    }
}

struct GamepadView: View {
    let input: InputState
    let landscape: Bool

    var body: some View {
        if landscape {
            HStack(alignment: .bottom) {
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        PillButton(label: "L2", bit: Btn.l2, input: input, width: 60)
                        PillButton(label: "L1", bit: Btn.l, input: input, width: 60)
                    }
                    DPadView(input: input, size: 140)
                    PillButton(label: "SELECT", bit: Btn.select, input: input)
                }
                Spacer()
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        PillButton(label: "R1", bit: Btn.r, input: input, width: 60)
                        PillButton(label: "R2", bit: Btn.r2, input: input, width: 60)
                    }
                    FaceButtons(input: input, size: 52)
                    PillButton(label: "START", bit: Btn.start, input: input)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        } else {
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    PillButton(label: "L2", bit: Btn.l2, input: input, width: 64)
                    PillButton(label: "L1", bit: Btn.l, input: input, width: 64)
                    Spacer()
                    PillButton(label: "R1", bit: Btn.r, input: input, width: 64)
                    PillButton(label: "R2", bit: Btn.r2, input: input, width: 64)
                }
                HStack {
                    DPadView(input: input, size: 150)
                    Spacer()
                    FaceButtons(input: input, size: 56)
                }
                HStack(spacing: 22) {
                    PillButton(label: "SELECT", bit: Btn.select, input: input)
                    PillButton(label: "START", bit: Btn.start, input: input)
                }
            }
            .padding(.horizontal, 22)
        }
    }
}
