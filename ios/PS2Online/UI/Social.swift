import SwiftUI
import UIKit

// MARK: - إشعارات أعلى الشاشة: مكالمة جارية / مكالمة واردة / تحدٍ وارد / تنبيه

struct InvitesOverlay: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var lobby: Lobby

    var body: some View {
        VStack(spacing: 8) {
            if let call = app.activeCall {
                CallBar(call: call)
            }
            if let c = lobby.incomingCall {
                Banner(icon: "phone.fill", tint: Theme.good, title: "\(c.fromName) يتصل بك",
                       subtitle: "مكالمة صوتية", acceptTitle: "رد", declineTitle: "رفض",
                       onAccept: { app.acceptCall(c) }, onDecline: { app.declineCall(c) })
            }
            if let ch = lobby.incoming {
                Banner(icon: "bolt.fill", tint: Theme.accentA, title: "\(ch.fromName) يتحداك ⚔️",
                       subtitle: ch.game, acceptTitle: "قبول", declineTitle: "رفض",
                       onAccept: { app.accept(ch) }, onDecline: { app.decline(ch) })
            }
            if let n = app.notice {
                Text(n)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.85))
                        .overlay(Capsule().stroke(Color.white.opacity(0.12))))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: lobby.incomingCall?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: lobby.incoming?.id)
        .animation(.easeOut(duration: 0.25), value: app.notice)
    }
}

struct Banner: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let acceptTitle: String
    let declineTitle: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.heavy)).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundColor(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(action: { Haptics.tap(); onDecline() }) {
                Text(declineTitle).font(.footnote.weight(.bold))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Capsule().fill(Theme.danger.opacity(0.9)))
                    .foregroundColor(.white)
            }
            Button(action: { Haptics.tap(); onAccept() }) {
                Text(acceptTitle).font(.footnote.weight(.heavy))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Theme.good))
                    .foregroundColor(.black)
            }
        }
        .foregroundColor(Theme.text)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(hex: 0x141822).opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(tint.opacity(0.6), lineWidth: 1.5)))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct CallBar: View {
    @ObservedObject var call: VoiceCall
    @EnvironmentObject var app: AppModel
    @AppStorage("voiceVolume") private var volume = 1.0
    @State private var showVolume = false

    private var stateText: String {
        switch call.state {
        case .connecting: return "جارِ الاتصال..."
        case .ringing: return call.isCaller ? "يرن..." : "جارِ الربط..."
        case .active: return ""
        case .ended(let r): return r
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: call.peerTalking ? "waveform" : "phone.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.good))
                VStack(alignment: .leading, spacing: 1) {
                    Text(call.peerName).font(.subheadline.weight(.heavy)).lineLimit(1)
                    if call.state == .active, let started = call.started {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let s = Int(ctx.date.timeIntervalSince(started))
                            Text(String(format: "%02d:%02d", s / 60, s % 60) + (call.micDenied ? " · الميكروفون غير مسموح" : ""))
                                .font(.caption.monospacedDigit()).foregroundColor(Theme.good)
                        }
                    } else {
                        Text(stateText).font(.caption).foregroundColor(Theme.muted)
                    }
                }
                Spacer(minLength: 4)
                circleButton(showVolume ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                             fill: showVolume ? Theme.accentA : Color.white.opacity(0.12)) {
                    withAnimation(.easeOut(duration: 0.2)) { showVolume.toggle() }
                }
                circleButton(call.muted ? "mic.slash.fill" : "mic.fill",
                             fill: call.muted ? Theme.danger : (call.meTalking ? Theme.good : Color.white.opacity(0.12))) {
                    call.muted.toggle()
                }
                circleButton("phone.down.fill", fill: Theme.danger) { app.endCall() }
            }
            if showVolume {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundColor(Theme.muted)
                    Slider(value: $volume, in: 0...2).tint(Theme.accentB)
                        .onChange(of: volume) { v in call.setVolume(v) }
                    Text("\(Int(volume * 100))%").font(.caption.monospacedDigit().weight(.bold)).frame(width: 42)
                }
            }
        }
        .foregroundColor(Theme.text)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(hex: 0x0F2018).opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.good.opacity(0.5))))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }

    private func circleButton(_ icon: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); action() }) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 38, height: 38)
                .background(Circle().fill(fill))
                .foregroundColor(.white)
        }
    }
}

// MARK: - قائمة اللاعبين المتصلين

struct PlayersSheet: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var lobby: Lobby
    @Environment(\.dismiss) private var dismiss
    let romFile: String

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Circle().fill(lobby.connected ? Theme.good : Theme.muted).frame(width: 9, height: 9)
                            Text(lobby.connected ? "\(lobby.onlinePS2) متصل الآن على PS2 Online" : "جارِ الاتصال بالسيرفر...")
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(lobby.connected ? Theme.good : Theme.muted)
                        }
                        .padding(.bottom, 4)
                        if lobby.others.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "person.2.slash").font(.system(size: 34)).foregroundColor(Theme.muted)
                                Text("لا يوجد لاعبون آخرون الآن").foregroundColor(Theme.muted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                        ForEach(lobby.others) { p in row(p) }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("اللاعبون المتصلون")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
        .overlay(InvitesOverlay(), alignment: .top)
    }

    private func row(_ p: LobbyPlayer) -> some View {
        HStack(spacing: 12) {
            AvatarView(id: p.id, av: p.av, name: p.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.subheadline.weight(.heavy)).foregroundColor(Theme.text).lineLimit(1)
                Text([(p.platform.hasPrefix("iOS") ? "📱 " : "💻 ") + p.platform, p.game]
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundColor(Theme.muted).lineLimit(1)
                Text(p.playing ? "● يلعب الآن" : "● متاح")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(p.playing ? Theme.warn : Theme.good)
            }
            Spacer(minLength: 4)
            NavigationLink(destination: DMView(peer: p)) {
                iconCircle("bubble.left.fill", fill: Theme.surface2)
                    .overlay(alignment: .topTrailing) {
                        if let n = lobby.unread[p.id], n > 0 {
                            Text("\(n)").font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.danger)).offset(x: 5, y: -5)
                        }
                    }
            }
            Button { Haptics.tap(); app.startCall(p) } label: {
                iconCircle("phone.fill", fill: Theme.good.opacity(app.activeCall == nil ? 0.9 : 0.3))
            }
            .disabled(app.activeCall != nil)
            Button { Haptics.tap(); app.challenge(p, romFile: romFile) } label: {
                iconCircle("bolt.fill", fill: p.playing ? Theme.surface2 : Theme.accentA)
            }
            .disabled(p.playing)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border)))
    }

    private func iconCircle(_ name: String, fill: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(fill))
    }
}

// MARK: - محادثة خاصة

struct DMView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var lobby: Lobby
    let peer: LobbyPlayer
    @State private var text = ""
    @FocusState private var focused: Bool

    private var messages: [DMMessage] { lobby.dms[peer.id] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if messages.isEmpty {
                            Text("لا توجد رسائل بعد — ابدأ المحادثة 👋")
                                .font(.subheadline).foregroundColor(Theme.muted)
                                .padding(.top, 40)
                        }
                        ForEach(messages) { m in
                            bubble(m).id(m.id)
                        }
                    }
                    .padding(14)
                }
                .onAppear {
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: messages.count) { _ in
                    lobby.markRead(peer.id)
                    if let last = messages.last {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("اكتب رسالة…", text: $text)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Capsule().fill(Color(hex: 0x0D1017)))
                    .overlay(Capsule().stroke(Theme.border))
                    .foregroundColor(Theme.text)
                Button(action: send) {
                    Image(systemName: "paperplane.fill").font(.system(size: 15, weight: .bold))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Theme.accent))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(peer.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { app.startCall(peer) } label: { Image(systemName: "phone.fill") }
                    .disabled(app.activeCall != nil)
            }
        }
        .onAppear {
            lobby.openChat = peer.id
            lobby.markRead(peer.id)
        }
        .onDisappear {
            if lobby.openChat == peer.id { lobby.openChat = nil }
        }
    }

    private func send() {
        if lobby.sendDM(to: peer.id, text: text) { text = "" }
    }

    private func bubble(_ m: DMMessage) -> some View {
        HStack {
            if !m.mine { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 3) {
                Text(m.text).font(.body).foregroundColor(.white)
                Text(m.time, style: .time).font(.caption2).foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(m.mine ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface2)))
            if m.mine { Spacer(minLength: 50) }
        }
    }
}
