// PS2 Online (Cruyfford) — online screens laid over ARMSX2's UI.
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

// MARK: - State shared by the online screens

@MainActor
final class NPCenter: ObservableObject {
    static let shared = NPCenter()

    @Published var showHome = false
    @Published private(set) var session: NPSession?
    @Published var games: [NPGame] = []
    @Published var selected: String = UserDefaults.standard.string(forKey: "np.game") ?? "" {
        didSet { UserDefaults.standard.set(selected, forKey: "np.game") }
    }
    @Published var delay: Int = max(1, UserDefaults.standard.integer(forKey: "np.delay") == 0 ? 3
                                    : UserDefaults.standard.integer(forKey: "np.delay")) {
        didSet { UserDefaults.standard.set(delay, forKey: "np.delay") }
    }
    @Published var busyText: String?
    @Published var alert: String?
    @Published var needsJIT = false

    let lobby = NPLobby()
    private var pendingTo: String?

    private init() {
        lobby.isBusy = { [weak self] in self?.session != nil }
        lobby.onAnswer = { [weak self] from, accept, reason in self?.answered(from: from, accept: accept, reason: reason) }
    }

    var selectedGame: NPGame? { games.first { $0.name == selected } }

    func reloadGames() {
        games = NPGame.library()
        if selectedGame == nil { selected = games.first?.name ?? "" }
    }

    func connectLobby() {
        if NPAccount.shared.isLoggedIn { lobby.connect() } else { lobby.disconnect() }
    }

    static func newCode() -> String {
        String((0..<5).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! })
    }

    /// The disc fingerprint, read in the background the first time (a few seconds for a big ISO).
    private func fingerprint(_ g: NPGame) async -> UInt32? {
        if let c = NPDisc.cached(g.path) { return c }
        busyText = "جارِ فحص ملف اللعبة (مرة واحدة فقط)..."
        let path = g.path
        let c = await Task.detached(priority: .userInitiated) { NPDisc.crc(path) }.value
        busyText = nil
        return c
    }

    private func ready() -> Bool {
        guard ARMSX2Bridge.isJITAvailable() else {
            needsJIT = true
            return false
        }
        guard AppState.shared.runningGameName == nil else {
            alert = "أغلق اللعبة المفتوحة أولاً ثم ابدأ اللعب أونلاين"
            return false
        }
        return true
    }

    func host(room: String? = nil) async -> Bool {
        guard ready(), let g = selectedGame else {
            if selectedGame == nil { alert = "اختر اللعبة أولاً" }
            return false
        }
        guard let crc = await fingerprint(g) else { alert = "تعذّر قراءة ملف اللعبة"; return false }
        let s = NPSession(mode: .host, game: g, room: room ?? NPCenter.newCode(), delay: delay, crc: crc)
        begin(s)
        return session != nil
    }

    func join(room: String, game: NPGame? = nil) async {
        let code = room.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { alert = "اكتب كود الغرفة"; return }
        guard ready(), let g = game ?? selectedGame else {
            if selectedGame == nil { alert = "اختر اللعبة أولاً" }
            return
        }
        guard let crc = await fingerprint(g) else { alert = "تعذّر قراءة ملف اللعبة"; return }
        begin(NPSession(mode: .join, game: g, room: code, delay: delay, crc: crc))
    }

    private func begin(_ s: NPSession) {
        session = s
        showHome = false
        s.start()
        lobby.setStatus("playing", game: s.game.title)
    }

    func leave() {
        if let to = pendingTo { lobby.cancel(to: to) }
        pendingTo = nil
        session?.stop()
        session = nil
        lobby.setStatus("idle", game: "")
    }

    // MARK: challenges

    func challenge(_ p: NPPlayer) async {
        guard let g = selectedGame else { alert = "اختر اللعبة أولاً"; return }
        let room = NPCenter.newCode() + "X"
        guard await host(room: room), let s = session, let crc = Optional(s.crc) else { return }
        pendingTo = p.id
        s.waitingHint = "⚔  بانتظار رد \(p.name) على التحدي..."
        lobby.challenge(to: p.id, game: g.title, crc: crc, room: room)
    }

    private func answered(from: String, accept: Bool, reason: String) {
        guard from == pendingTo else { return }
        pendingTo = nil
        if accept {
            session?.waitingHint = ""
        } else {
            let why = ["busy": "مشغول الآن", "no_rom": "لا يملك هذه اللعبة", "offline": "غير متصل"][reason] ?? "رفض التحدي"
            leave()
            alert = why
        }
    }

    func accept(_ c: NPChallenge) async {
        lobby.incoming = nil
        reloadGames()
        var match: NPGame?
        for g in games where NPDisc.cached(g.path) == c.crc { match = g; break }
        if match == nil {
            busyText = "جارِ البحث عن نفس ملف اللعبة..."
            let list = games
            match = await Task.detached(priority: .userInitiated) {
                list.first { NPDisc.crc($0.path) == c.crc }
            }.value
            busyText = nil
        }
        guard let g = match else {
            lobby.answer(to: c.fromId, accept: false, room: c.room, reason: "no_rom")
            alert = "لا تملك نفس ملف اللعبة:\n\(c.game)"
            return
        }
        guard ready() else {
            lobby.answer(to: c.fromId, accept: false, room: c.room, reason: "busy")
            return
        }
        lobby.answer(to: c.fromId, accept: true, room: c.room)
        await join(room: c.room, game: g)
    }

    func decline(_ c: NPChallenge) {
        lobby.answer(to: c.fromId, accept: false, room: c.room, reason: "declined")
        lobby.incoming = nil
    }
}

// MARK: - Root overlay (added over ARMSX2's RootView)

struct NetplayRootOverlay: View {
    @ObservedObject private var center = NPCenter.shared

    var body: some View {
        ZStack {
            if let s = center.session {
                NetplaySessionOverlay(session: s)
            } else if AppState.shared.runningGameName == nil {
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            center.showHome = true
                        } label: {
                            Label("أونلاين", systemImage: "globe")
                                .font(.system(size: 15, weight: .heavy))
                                .padding(.horizontal, 16).padding(.vertical, 11)
                                .background(Capsule().fill(LinearGradient(colors: [NPTheme.a, NPTheme.b],
                                                                          startPoint: .leading, endPoint: .trailing)))
                                .foregroundColor(.white)
                                .shadow(color: NPTheme.a.opacity(0.5), radius: 12)
                        }
                        .overlay(alignment: .topTrailing) {
                            if center.lobby.incoming != nil {
                                Circle().fill(Color.red).frame(width: 12, height: 12).offset(x: 2, y: -2)
                            }
                        }
                        Spacer()
                    }
                    .padding(.leading, 18)
                    .padding(.bottom, 96)
                }
            }
        }
        .sheet(isPresented: $center.showHome) {
            NetplayHomeView()
                .environment(\.layoutDirection, .rightToLeft)
                .preferredColorScheme(.dark)
        }
        .alert("تحدٍ جديد ⚔️", isPresented: Binding(get: { center.lobby.incoming != nil && center.session == nil },
                                                    set: { if !$0, let c = center.lobby.incoming { center.decline(c) } }),
               presenting: center.lobby.incoming) { c in
            Button("قبول") { Task { await center.accept(c) } }
            Button("رفض", role: .cancel) { center.decline(c) }
        } message: { c in
            Text("\(c.fromName) يتحداك في:\n\(c.game)")
        }
        .onAppear { center.connectLobby() }
    }
}

enum NPTheme {
    static let a = Color(red: 0.49, green: 0.36, blue: 1.0)
    static let b = Color(red: 0.0, green: 0.76, blue: 1.0)
    static let bg = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let card = Color(red: 0.08, green: 0.09, blue: 0.13)
    static let good = Color(red: 0.17, green: 0.84, blue: 0.48)
    static let warn = Color(red: 1.0, green: 0.69, blue: 0.13)
    static let bad = Color(red: 1.0, green: 0.30, blue: 0.43)
}

// MARK: - Home sheet

struct NetplayHomeView: View {
    @ObservedObject private var center = NPCenter.shared
    @ObservedObject private var account = NPAccount.shared
    @ObservedObject private var lobby = NPCenter.shared.lobby
    @State private var code = ""

    var body: some View {
        NavigationStack {
            ZStack {
                NPTheme.bg.ignoresSafeArea()
                if account.isLoggedIn { main } else { NPAuthView() }
                if let t = center.busyText {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(NPTheme.a).scaleEffect(1.4)
                        Text(t).font(.headline).multilineTextAlignment(.center)
                    }.padding(30)
                }
            }
            .navigationTitle("PS2 Online")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { center.showHome = false }
                }
            }
        }
        .onAppear {
            center.reloadGames()
            center.connectLobby()
            Task { await account.refresh() }
        }
        .onChange(of: account.isLoggedIn) { _, _ in center.connectLobby() }
        .alert("PS2 Online", isPresented: Binding(get: { center.alert != nil }, set: { if !$0 { center.alert = nil } })) {
            Button("حسناً", role: .cancel) {}
        } message: { Text(center.alert ?? "") }
        .alert("JIT غير مفعّل", isPresented: $center.needsJIT) {
            Button("فتح StikDebug") { StikDebugLauncher.open(reason: "netplay") }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("اللعب أونلاين يحتاج JIT. فعّله من StikDebug ثم ارجع للتطبيق وحاول مرة أخرى.")
        }
    }

    private var main: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                gameCard
                roomCard
                playersCard
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.user?.username ?? "").font(.title3.weight(.heavy))
                Text(lobby.connected ? "🟢 \(lobby.onlinePS2) متصل الآن في PS2 Online" : "جارِ الاتصال بالسيرفر...")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Spacer()
            Button("خروج") { lobby.disconnect(); account.logout() }
                .font(.footnote.weight(.semibold)).foregroundColor(NPTheme.bad)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(NPTheme.card))
    }

    private var gameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("اللعبة").font(.caption.weight(.bold)).foregroundColor(.secondary)
            if center.games.isEmpty {
                Text("لا توجد ألعاب في المكتبة — أضف ملف ISO من مكتبة التطبيق أولاً")
                    .font(.subheadline).foregroundColor(.secondary)
            } else {
                Picker("اللعبة", selection: $center.selected) {
                    ForEach(center.games) { g in Text(g.title).tag(g.name) }
                }
                .pickerStyle(.menu)
                .tint(.white)
            }
            Stepper("تأخير المدخلات: \(center.delay) إطار", value: $center.delay, in: 1...10)
                .font(.subheadline)
            Text("يجب أن يملك صديقك نفس ملف اللعبة ونفس البايوس ونفس إصدار التطبيق.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(NPTheme.card))
    }

    private var roomCard: some View {
        VStack(spacing: 12) {
            Button {
                Task { _ = await center.host() }
            } label: {
                Text("إنشاء غرفة").font(.headline.weight(.heavy)).frame(maxWidth: .infinity).padding(15)
                    .background(RoundedRectangle(cornerRadius: 15).fill(LinearGradient(colors: [NPTheme.a, NPTheme.b],
                                                                                       startPoint: .leading, endPoint: .trailing)))
                    .foregroundColor(.white)
            }
            HStack(spacing: 10) {
                TextField("كود الغرفة", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.4)))
                    .environment(\.layoutDirection, .leftToRight)
                Button("انضمام") { Task { await center.join(room: code) } }
                    .font(.headline.weight(.bold)).padding(.horizontal, 18).padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 12).stroke(NPTheme.a, lineWidth: 1.5))
                    .foregroundColor(.white)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18).fill(NPTheme.card))
    }

    private var playersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("اللاعبون المتصلون").font(.caption.weight(.bold)).foregroundColor(.secondary)
            if lobby.others.isEmpty {
                Text("لا يوجد لاعبون متصلون الآن").font(.subheadline).foregroundColor(.secondary)
            }
            ForEach(lobby.others) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.headline)
                        Text((p.isIOS ? "📱 آيفون" : "💻 كمبيوتر") + (p.playing ? " · يلعب \(p.game)" : ""))
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if p.isIOS && !p.playing {
                        Button("تحدَّ ⚔️") { Task { await center.challenge(p) } }
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(NPTheme.a))
                            .foregroundColor(.white)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(NPTheme.card))
    }
}

struct NPAuthView: View {
    @ObservedObject private var account = NPAccount.shared
    @State private var register = false
    @State private var user = ""
    @State private var pass = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 14) {
            Text("PS2 Online").font(.system(size: 30, weight: .heavy))
            Text("نفس حساب SNES Online و PS1 Online").font(.footnote).foregroundColor(.secondary)
            Picker("", selection: $register) {
                Text("تسجيل الدخول").tag(false)
                Text("حساب جديد").tag(true)
            }
            .pickerStyle(.segmented)
            TextField("اسم المستخدم", text: $user)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(13).background(RoundedRectangle(cornerRadius: 12).fill(NPTheme.card))
            SecureField("كلمة المرور", text: $pass)
                .padding(13).background(RoundedRectangle(cornerRadius: 12).fill(NPTheme.card))
            if let e = error { Text(e).font(.footnote).foregroundColor(NPTheme.bad) }
            Button {
                busy = true
                error = nil
                Task {
                    error = await account.auth(register: register, username: user.trimmingCharacters(in: .whitespaces),
                                               password: pass)
                    busy = false
                }
            } label: {
                Group { if busy { ProgressView().tint(.white) } else { Text(register ? "إنشاء الحساب" : "دخول") } }
                    .font(.headline.weight(.heavy)).frame(maxWidth: .infinity).padding(15)
                    .background(RoundedRectangle(cornerRadius: 15).fill(NPTheme.a))
                    .foregroundColor(.white)
            }
            .disabled(busy || user.isEmpty || pass.isEmpty)
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - In-game overlay

struct NetplaySessionOverlay: View {
    @ObservedObject var session: NPSession
    @ObservedObject private var center = NPCenter.shared
    @State private var chatOpen = false
    @State private var chatText = ""
    @FocusState private var chatFocused: Bool

    var body: some View {
        ZStack {
            VStack {
                hud.padding(.top, 8)
                Spacer()
            }
            chatBubbles
            if session.desync {
                VStack {
                    Spacer()
                    Text("⚠  عدم تطابق — اخرج وادخل الغرفة من جديد للمزامنة")
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(NPTheme.bad))
                        .foregroundColor(.white)
                        .padding(.bottom, 24)
                }
                .allowsHitTesting(false)
            }
            if chatOpen { chatBar }
            if session.phase != .running { waiting }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var hud: some View {
        HStack(spacing: 10) {
            Text(session.isHost ? "P1" : "P2")
                .font(.system(size: 11, weight: .heavy))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(NPTheme.a))
            if let r = session.rtt {
                Circle().fill(r < 70 ? NPTheme.good : (r < 140 ? NPTheme.warn : NPTheme.bad)).frame(width: 7, height: 7)
                Text("\(Int(r))ms")
            }
            Text("تأخير \(session.delay)")
            if let p = session.peer {
                Text("ضد \(p)").lineLimit(1)
                if session.peerTalking {
                    Image(systemName: "speaker.wave.2.fill").foregroundColor(NPTheme.good)
                }
            }
            Button {
                if session.voiceOn { session.muted.toggle() } else { session.toggleVoice() }
            } label: {
                Image(systemName: !session.voiceOn ? "mic.slash" : (session.muted ? "mic.slash.fill" : "mic.fill"))
                    .foregroundColor(!session.voiceOn ? .gray : (session.muted ? NPTheme.bad
                                                                 : (session.meTalking ? NPTheme.good : .white)))
            }
            .contextMenu {
                if session.voiceOn {
                    Button(session.muted ? "إلغاء الكتم" : "كتم الميكروفون") { session.muted.toggle() }
                    Button("إيقاف المحادثة الصوتية", role: .destructive) { session.toggleVoice() }
                } else {
                    Button("تشغيل المحادثة الصوتية") { session.toggleVoice() }
                }
                Button("صوت الخصم: عادي") { session.voiceVolume = 1 }
                Button("صوت الخصم: عالٍ") { session.voiceVolume = 2 }
                Button("صوت الخصم: منخفض") { session.voiceVolume = 0.5 }
            }
            Button {
                chatOpen.toggle()
                chatFocused = chatOpen
            } label: { Image(systemName: "bubble.left.and.bubble.right.fill") }
            Button { center.leave() } label: { Image(systemName: "xmark.circle.fill").foregroundColor(NPTheme.bad) }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.6)).overlay(Capsule().stroke(Color.white.opacity(0.1))))
    }

    private var chatBubbles: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 6) {
                Spacer()
                ForEach(session.chat.suffix(4).filter { ctx.date.timeIntervalSince($0.time) < 10 }) { l in
                    HStack {
                        if !l.mine { Spacer(minLength: 40) }
                        Text("\(l.who): \(l.text)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(l.mine ? NPTheme.a.opacity(0.92) : Color.black.opacity(0.78)))
                        if l.mine { Spacer(minLength: 40) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, chatOpen ? 70 : 90)
        }
        .allowsHitTesting(false)
    }

    private var chatBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                TextField("اكتب رسالة…", text: $chatText)
                    .focused($chatFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(NPTheme.card))
                Button(action: send) {
                    Image(systemName: "paperplane.fill").frame(width: 40, height: 40)
                        .background(Circle().fill(NPTheme.a)).foregroundColor(.white)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.85))
        }
    }

    private func send() {
        if session.sendChat(chatText) { chatText = "" }
        chatOpen = false
        chatFocused = false
    }

    private var waiting: some View {
        let bad = session.phase == .error || session.phase == .closed
        return ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 16) {
                if bad {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 46)).foregroundColor(NPTheme.bad)
                } else {
                    ProgressView().tint(NPTheme.a).scaleEffect(1.5)
                }
                Text(!session.waitingHint.isEmpty && session.phase == .waiting ? session.waitingHint
                     : (session.status.isEmpty ? "..." : session.status))
                    .font(.system(size: 17, weight: .bold))
                    .multilineTextAlignment(.center)
                if let p = session.progress {
                    ProgressView(value: p).tint(NPTheme.b).frame(maxWidth: 260)
                }
                if session.isHost && session.phase == .waiting && session.waitingHint.isEmpty {
                    Text("كود الغرفة — أرسله لصديقك").font(.footnote).foregroundColor(.secondary)
                    Text(session.room.map { String($0) }.joined(separator: " "))
                        .font(.system(size: 40, weight: .heavy, design: .monospaced))
                        .environment(\.layoutDirection, .leftToRight)
                    Button {
                        UIPasteboard.general.string = session.room
                    } label: {
                        Label("نسخ الكود", systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(NPTheme.card))
                    }
                }
                Button { center.leave() } label: {
                    Text("خروج").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 26).padding(.vertical, 10)
                        .overlay(Capsule().stroke(Color.white.opacity(0.25)))
                }
                .padding(.top, 8)
            }
            .foregroundColor(.white)
            .padding(30)
        }
    }
}
