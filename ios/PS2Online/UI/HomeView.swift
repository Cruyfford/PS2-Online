import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AppDefaults {
    static let server = "wss://snes-online-relay.cruyfford4488.workers.dev"
}

struct PlaySettings {
    let server: String, name: String, delay: Int, plugin: ViewPlugin
    static var current: PlaySettings {
        let d = UserDefaults.standard
        var server = d.string(forKey: "server") ?? AppDefaults.server
        if server.isEmpty || server.contains("YOUR-NAME") { server = AppDefaults.server }
        let delay = d.object(forKey: "delay") as? Int ?? 3
        return PlaySettings(server: server, name: Account.shared.user?.username ?? "Player", delay: delay,
                            plugin: ViewPlugin(rawValue: d.string(forKey: "plugin") ?? "") ?? .none)
    }
}

final class AppModel: ObservableObject {
    @Published var runner: GameRunner?
    @Published var errorText: String?
    let lobby = Lobby()
    @Published var activeCall: VoiceCall?
    @Published var playersOpen = false
    @Published var notice: String?
    private var pendingTo: String?
    private var pendingName = ""

    init() {
        lobby.isBusy = { [weak self] in self?.runner != nil }
        lobby.isInCall = { [weak self] in self?.activeCall != nil }
        lobby.onAnswer = { [weak self] from, accept, reason in self?.answered(from: from, accept: accept, reason: reason) }
        lobby.onNotice = { [weak self] n in self?.show(n) }
        lobby.onCallAnswer = { [weak self] from, accept, reason in
            guard let self = self, let c = self.activeCall, c.peerId == from, !accept else { return }
            let why = ["busy": "مشغول الآن", "offline": "غير متصل"][reason] ?? "رفض المكالمة"
            self.endCall(notify: false)
            self.show("📞 \(c.peerName): \(why)")
        }
        lobby.onCallEnd = { [weak self] from in
            guard let self = self, let c = self.activeCall, c.peerId == from else { return }
            self.endCall(notify: false)
            self.show("📞 \(c.peerName) أنهى المكالمة")
        }
    }

    func show(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }

    // MARK: - calls

    private func attach(_ c: VoiceCall) {
        c.onEnded = { [weak self, weak c] reason in
            guard let self = self, let c = c, self.activeCall === c else { return }
            self.activeCall = nil
            self.show("📞 \(reason)")
        }
        activeCall = c
    }

    func startCall(_ p: LobbyPlayer) {
        guard runner == nil, activeCall == nil else { return }
        let s = PlaySettings.current
        let room = "C" + AppModel.newCode() + "Q"
        attach(VoiceCall(peerId: p.id, peerName: p.name, isCaller: true, room: room, server: s.server, myName: s.name))
        lobby.call(to: p.id, room: room)
    }

    func acceptCall(_ i: CallInvite) {
        lobby.incomingCall = nil
        if activeCall != nil { endCall() }
        let s = PlaySettings.current
        attach(VoiceCall(peerId: i.fromId, peerName: i.fromName, isCaller: false, room: i.room, server: s.server, myName: s.name))
        lobby.callAnswer(to: i.fromId, accept: true, room: i.room)
    }

    func declineCall(_ i: CallInvite) {
        lobby.incomingCall = nil
        lobby.callAnswer(to: i.fromId, accept: false, room: i.room, reason: "declined")
    }

    func endCall(notify: Bool = true) {
        guard let c = activeCall else { return }
        activeCall = nil
        if notify { lobby.callEnd(to: c.peerId) }
        c.onEnded = nil
        c.finish("انتهت المكالمة")
    }

    func logoutCleanup() {
        stop()
        endCall()
        lobby.disconnect()
    }

    func connectLobby() {
        let s = PlaySettings.current
        lobby.connect(server: s.server, name: s.name)
    }

    private func crcOf(_ url: URL) -> UInt32? { Disc.crc(url) }

    /// تحدي لاعب: نفتح غرفة كمضيف ونرسل له الطلب
    func challenge(_ p: LobbyPlayer, romFile: String) {
        if playersOpen {
            playersOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.challenge(p, romFile: romFile) }
            return
        }
        let url = Paths.roms.appendingPathComponent(romFile)
        guard !romFile.isEmpty, let crc = crcOf(url) else {
            errorText = "اختر اللعبة أولاً"
            return
        }
        let s = PlaySettings.current
        let room = AppModel.newCode() + "X"
        start(mode: .host, romFile: romFile, server: s.server, room: room, name: s.name,
              delay: s.delay, plugin: s.plugin)
        guard let r = runner else { return }
        pendingTo = p.id
        pendingName = p.name
        r.waitingHint = "⚔️ بانتظار رد \(p.name) على التحدي..."
        lobby.challenge(to: p.id, game: (romFile as NSString).deletingPathExtension, crc: crc, room: room)
    }

    private func answered(from: String, accept: Bool, reason: String) {
        guard from == pendingTo else { return }
        pendingTo = nil
        if accept {
            runner?.waitingHint = ""
        } else {
            let why = ["busy": "مشغول الآن", "no_rom": "لا يملك هذه اللعبة", "offline": "غير متصل"][reason] ?? "رفض التحدي"
            stop()
            errorText = "\(pendingName): \(why)"
        }
    }

    /// قبول تحدٍ وارد: نبحث عن نفس اللعبة ثم ننضم للغرفة
    func accept(_ c: Challenge) {
        if playersOpen {
            playersOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.accept(c) }
            return
        }
        lobby.incoming = nil
        let match = roms.first { crcOf(Paths.roms.appendingPathComponent($0)) == c.crc }
        guard let rom = match else {
            lobby.answer(to: c.fromId, accept: false, room: c.room, reason: "no_rom")
            errorText = "لا تملك نفس ملف اللعبة:\n\(c.game)\nاستورده أولاً ثم اطلب تحدياً جديداً."
            return
        }
        UserDefaults.standard.set(rom, forKey: "romFile")
        lobby.answer(to: c.fromId, accept: true, room: c.room)
        let s = PlaySettings.current
        start(mode: .join, romFile: rom, server: s.server, room: c.room, name: s.name,
              delay: s.delay, plugin: s.plugin)
    }

    func decline(_ c: Challenge) {
        lobby.incoming = nil
        lobby.answer(to: c.fromId, accept: false, room: c.room, reason: "declined")
    }

    /// ملفات الألعاب (cue/chd/pbp/m3u...) — ملفات .bin تُقرأ عن طريق ملف الـ cue
    var roms: [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: Paths.roms.path)) ?? []
        return items.filter { !$0.hasPrefix(".") && Disc.exts.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
    }

    static func newCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<5).map { _ in chars.randomElement()! })
    }

    /// ينسخ ملفات اللعبة (cue + bin...) إلى مجلد التطبيق ويرجع اسم ملف اللعبة
    /// ملف البايوس (scph*.bin) يذهب إلى مجلد bios
    @discardableResult
    func importROM(_ url: URL) -> String? { importFiles([url]) }

    @discardableResult
    func importFiles(_ urls: [URL]) -> String? {
        var game: String?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let isBios = name.lowercased().hasPrefix("scph") && name.lowercased().hasSuffix(".bin")
            let dest = (isBios ? Paths.bios : Paths.roms).appendingPathComponent(name)
            do {
                if url.standardizedFileURL != dest.standardizedFileURL {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: url, to: dest)
                }
                if !isBios && Disc.exts.contains(url.pathExtension.lowercased()) { game = name }
            } catch {
                errorText = "تعذّر نسخ الملف: \(error.localizedDescription)"
            }
        }
        if let g = game { UserDefaults.standard.set(g, forKey: "romFile") }
        return game
    }

    func start(mode: Session.Mode, romFile: String, server: String, room: String,
               name: String, delay: Int, plugin: ViewPlugin) {
        stop()
        if activeCall != nil { endCall() }
        let url = Paths.roms.appendingPathComponent(romFile)
        guard !romFile.isEmpty, FileManager.default.fileExists(atPath: url.path) else {
            errorText = "اختر ملف اللعبة (.cue) أولاً"
            return
        }
        do {
            let s = try Session(romURL: url, mode: mode, server: server, room: room,
                                name: name.isEmpty ? "Player" : name, delay: delay, plugin: plugin,
                                hleBios: UserDefaults.standard.bool(forKey: "hleBios"))
            let r = GameRunner(session: s)
            r.start()
            runner = r
            lobby.setStatus("playing", game: (romFile as NSString).deletingPathExtension)
            if mode == .host { UIPasteboard.general.string = room }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func stop() {
        if let p = pendingTo {
            lobby.cancel(to: p)
            pendingTo = nil
        }
        runner?.stop()
        runner = nil
        lobby.setStatus("idle", game: "")
    }
}

struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var lobby: Lobby
    @AppStorage("server") private var server = AppDefaults.server
    @EnvironmentObject var account: Account
    @ObservedObject private var covers = Covers.shared
    @AppStorage("room") private var room = ""
    @AppStorage("delay") private var delay = 3
    @AppStorage("plugin") private var pluginRaw = ViewPlugin.none.rawValue
    @AppStorage("romFile") private var romFile = ""
    @State private var picking = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.accentA.opacity(0.18), .clear], center: .topTrailing,
                           startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    romCard
                    roomCard
                    nameCard
                    actions
                    playersCard
                    Text("💡 استورد ملف اللعبة (.iso / .chd / .cso)، أو ضعه في تطبيق الملفات ← PS2 Online ← roms. ملف البايوس (SCPH-xxxxx.bin) يُستورد بنفس الزر أو يوضع في ← bios")
                        .font(.caption).foregroundColor(Theme.muted)
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundColor(Theme.text)
        .overlay(InvitesOverlay(), alignment: .top)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(account)
                .environment(\.layoutDirection, .rightToLeft)
                .preferredColorScheme(.dark)
        }
        .alert("تنبيه", isPresented: Binding(get: { app.errorText != nil },
                                             set: { if !$0 { app.errorText = nil } })) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(app.errorText ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            LogoView()
            VStack(alignment: .leading, spacing: 1) {
                Text("PS2 Online").font(.system(size: 20, weight: .heavy))
                Text("نسخة iOS 2026 · Cruyfford").font(.caption).foregroundColor(Theme.muted)
            }
            Spacer()
            Button { app.playersOpen = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(lobby.connected ? Theme.good : Theme.muted).frame(width: 8, height: 8)
                    Text(lobby.connected ? "\(lobby.onlinePS2)" : "—")
                        .font(.system(size: 13, weight: .heavy))
                    Image(systemName: "person.2.fill").font(.system(size: 11))
                }
                .foregroundColor(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(Theme.surface2))
                .overlay(alignment: .topTrailing) {
                    if lobby.totalUnread > 0 {
                        Text("\(lobby.totalUnread)")
                            .font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.danger))
                            .offset(x: 6, y: -6)
                    }
                }
            }
            .sheet(isPresented: $app.playersOpen) {
                PlayersSheet(romFile: romFile)
                    .environmentObject(app)
                    .environmentObject(lobby)
                    .environment(\.layoutDirection, .rightToLeft)
                    .preferredColorScheme(.dark)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.surface2))
            }
        }
    }

    private var romSubtitle: String {
        guard !romFile.isEmpty else { return "استورد ملف .cue مع ملفات .bin (أو .chd / .pbp)" }
        let url = Paths.roms.appendingPathComponent(romFile)
        var size = 0
        for f in Disc.files(url) {
            size += (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        }
        return "\(size >> 20) MB"
    }

    private var romCard: some View {
        HStack(spacing: 14) {
            if let img = covers.image(for: romFile) {
                let h: CGFloat = 84
                let w = min(120, max(48, h * img.size.width / max(1, img.size.height)))
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    .transition(.opacity)
            } else {
                Text("PS2")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(Color(hex: 0xCFC6FF))
                    .frame(width: 54, height: 54)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0x2A2150), Color(hex: 0x0E3550)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(romFile.isEmpty ? "لم يتم اختيار لعبة" : (romFile as NSString).deletingPathExtension)
                    .font(.headline).lineLimit(1)
                Text(romSubtitle).font(.caption).foregroundColor(Theme.muted)
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(app.roms, id: \.self) { f in
                    Button(f) { romFile = f }
                }
                if !app.roms.isEmpty { Divider() }
                Button { picking = true } label: { Label("استيراد من الملفات", systemImage: "folder") }
            } label: {
                Text("اختيار…")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Theme.surface2))
                    .foregroundColor(Theme.text)
            }
        }
        .card()
        .sheet(isPresented: $picking) {
            DocumentPicker { urls in
                if let f = app.importFiles(urls) { romFile = f }
            }
            .ignoresSafeArea()
        }
    }

    private var roomCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("كود الغرفة").font(.caption.weight(.bold)).foregroundColor(Theme.muted)
            HStack(spacing: 10) {
                TextField("— — — — —", text: $room)
                    .font(.system(size: 28, weight: .heavy, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x0D1017)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
                    .onChange(of: room) { v in
                        let clean = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(12))
                        if clean != v { room = clean }
                    }
                iconButton("arrow.clockwise") { room = AppModel.newCode() }
                iconButton("doc.on.clipboard") {
                    if let s = UIPasteboard.general.string { room = s }
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .card()
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
                .foregroundColor(Theme.text)
        }
    }

    private var nameCard: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 14) {
                AvatarView(id: account.user?.id ?? "", av: account.user?.av ?? 0,
                           name: account.user?.username ?? "?", size: 52, local: account.localAvatar)
                VStack(alignment: .leading, spacing: 3) {
                    Text("حسابك").font(.caption.weight(.bold)).foregroundColor(Theme.muted)
                    Text(account.user?.username ?? "").font(.headline).lineLimit(1)
                }
                Spacer()
                Label("تعديل", systemImage: "pencil")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.surface2))
            }
            .foregroundColor(Theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { start(.host) } label: {
                    Label("إنشاء غرفة", systemImage: "plus")
                        .font(.headline.weight(.heavy))
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.accent))
                        .foregroundColor(.white)
                        .shadow(color: Theme.accentA.opacity(0.45), radius: 14, y: 6)
                }
                Button { start(.join) } label: {
                    Label("انضمام", systemImage: "arrow.right.circle")
                        .font(.headline.weight(.heavy))
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                        .background(RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Theme.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(Color(hex: 0x3A4675))))
                        .foregroundColor(Theme.text)
                }
            }
            Button { start(.offline) } label: {
                Label("تجربة بدون نت", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(hex: 0x2E3650), style: StrokeStyle(lineWidth: 1, dash: [5])))
                    .foregroundColor(Theme.muted)
            }
        }
        .padding(.top, 4)
    }

    private var playersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("اللاعبون المتصلون").font(.headline)
                Spacer()
                Text(lobby.connected ? "🟢 \(lobby.onlinePS2) متصل الآن" : "جارِ الاتصال...")
                    .font(.caption.weight(.bold))
                    .foregroundColor(lobby.connected ? Theme.good : Theme.muted)
            }
            if lobby.others.isEmpty {
                Text(lobby.connected ? "لا يوجد لاعبون آخرون الآن" : "جارِ الاتصال بالسيرفر...")
                    .font(.subheadline).foregroundColor(Theme.muted)
                    .padding(.vertical, 6)
            }
            ForEach(lobby.others) { p in playerRow(p) }
        }
        .card()
    }

    private func playerRow(_ p: LobbyPlayer) -> some View {
        HStack(spacing: 12) {
            AvatarView(id: p.id, av: p.av, name: p.name, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.subheadline.weight(.bold)).lineLimit(1)
                Text([(p.platform.hasPrefix("iOS") ? "📱 " : "💻 ") + p.platform, p.game]
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundColor(Theme.muted).lineLimit(1)
                Text(p.playing ? "● يلعب الآن" : "● متاح")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(p.playing ? Theme.warn : Theme.good)
            }
            Spacer(minLength: 4)
            Button {
                Haptics.tap()
                app.challenge(p, romFile: romFile)
            } label: {
                Label("تحدي", systemImage: "bolt.fill")
                    .font(.subheadline.weight(.heavy))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(p.playing ? AnyShapeStyle(Theme.surface2) : AnyShapeStyle(Theme.accent)))
                    .foregroundColor(.white)
            }
            .disabled(p.playing)
            .opacity(p.playing ? 0.5 : 1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0x0D1017)))
    }

    private func start(_ mode: Session.Mode) {
        if mode == .host && room.isEmpty { room = AppModel.newCode() }
        if mode != .offline && room.isEmpty {
            app.errorText = "اكتب كود الغرفة الذي أرسله لك صديقك"
            return
        }
        if server.isEmpty || server.contains("YOUR-NAME") { server = AppDefaults.server }
        app.start(mode: mode, romFile: romFile, server: server, room: room,
                  name: account.user?.username ?? "Player",
                  delay: delay, plugin: ViewPlugin(rawValue: pluginRaw) ?? .none)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("server") private var server = AppDefaults.server
    @AppStorage("delay") private var delay = 3
    @AppStorage("plugin") private var pluginRaw = ViewPlugin.none.rawValue
    @AppStorage("smooth") private var smooth = false
    @AppStorage("enhance") private var enhance = false
    @AppStorage("hleBios") private var hleBios = false

    var body: some View {
        NavigationView {
            Form {
                ProfileSection()
                Section(header: Text("اللعب")) {
                    Stepper("تأخير المدخلات: \(delay) إطار", value: $delay, in: 1...15)
                    Picker("إضافة العرض", selection: $pluginRaw) {
                        ForEach(ViewPlugin.allCases) { p in Text(p.name).tag(p.rawValue) }
                    }
                    Toggle("تنعيم الصورة", isOn: $smooth)
                }
                Section(header: Text("دقة الصورة"),
                        footer: Text("اختيارك أنت فقط ولا يؤثر على خصمك. 2x أوضح للألعاب ثلاثية الأبعاد لكنه أثقل على الجهاز. تقدر تغيّرها أثناء اللعب من زر 1x/2x فوق.")) {
                    Picker("الدقة", selection: $enhance) {
                        Text("أصلية 1x").tag(false)
                        Text("مضاعفة 2x").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: enhance) { v in cb_set_enhance(v) }
                }
                Section(header: Text("البايوس"),
                        footer: Text("يجب أن يكون نفس البايوس عند اللاعبين. ضع scph1001.bin في تطبيق الملفات ← PS1 Online ← bios، أو فعّل HLE عند الاثنين.")) {
                    Toggle("HLE — بدون ملف بايوس", isOn: $hleBios)
                    HStack {
                        Text("الحالي")
                        Spacer()
                        Text(Disc.biosID(hle: hleBios)).foregroundColor(.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                Section(header: Text("النواة"),
                        footer: Text("يجب أن تطابق نسخة النواة في الكمبيوتر — استخدم ملف pcsx_rearmed_libretro.dll المبني من نفس الـ workflow.")) {
                    HStack {
                        Text("PCSX ReARMED")
                        Spacer()
                        Text(Core.libraryVersion).foregroundColor(.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            .navigationTitle("الإعدادات")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
            }
        }
    }
}

/// منتقي الملفات الأصلي في iOS — ينسخ الملف داخل التطبيق (يعمل مع أي نوع ملف)
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .data], asCopy: true)
        vc.allowsMultipleSelection = true          // cue + bin معاً
        vc.shouldShowFileExtensions = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if !urls.isEmpty { onPick(urls) }
        }
    }
}
