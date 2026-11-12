// PS2 Online (Cruyfford) — game-modding window floating over the running game:
// EE RAM viewer/editor, value search, freezes, RAM dumps and R5900 disassembly.
// Opened from the in-game quick menu ("أدوات التعديل"); the game keeps running behind it.
// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

// MARK: - State

@MainActor
final class NPModCenter: ObservableObject {
    static let shared = NPModCenter()

    @Published var visible = false
    @Published var minimized = false
    @Published var offset: CGSize = .zero
    @Published var opacity: Double = UserDefaults.standard.object(forKey: "np.mod.opacity") as? Double ?? 0.92 {
        didSet { UserDefaults.standard.set(opacity, forKey: "np.mod.opacity") }
    }
    @Published var tab = 0

    // memory view
    @Published var viewAddress: UInt32 = 0x0010_0000
    @Published var memory = Data()
    @Published var live = true

    // search
    @Published var width = 4
    @Published var aligned = true
    @Published var searching = false
    @Published var busy = false
    @Published var count: UInt32 = 0
    @Published var results: [PS2ModResult] = []

    @Published var frozen: [PS2ModFrozen] = []
    @Published var message: String?

    private var timer: Timer?

    func show() {
        visible = true
        minimized = false
        startTimer()
        refresh()
    }

    func close() {
        visible = false
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in NPModCenter.shared.tick() }
        }
    }

    private func tick() {
        guard visible, !minimized else { return }
        if AppState.shared.runningGameName == nil { return }
        if live { refresh() }
    }

    func refresh() {
        guard PS2ModTools.isAvailable() else { memory = Data(); return }
        memory = PS2ModTools.read(viewAddress, length: 256)
        frozen = PS2ModTools.frozen()
        if searching && !busy && count <= 500 { results = PS2ModTools.searchResults(200) }
    }

    func go(_ text: String) {
        guard let a = NPModCenter.parse(text) else { message = "عنوان غير صحيح"; return }
        viewAddress = (a & 0x01FF_FFFF) & ~0xF
        refresh()
    }

    func page(_ delta: Int) {
        let next = Int64(viewAddress) + Int64(delta) * 256
        viewAddress = UInt32(max(0, min(Int64(PS2ModTools.ramSize()) - 256, next)))
        refresh()
    }

    var paused = false
    func togglePause() {
        paused.toggle()
        ARMSX2Bridge.setVMPaused(paused)
        objectWillChange.send()
    }

    // MARK: search

    func newSearch() {
        busy = true
        let w = width, al = aligned
        Task.detached(priority: .userInitiated) {
            PS2ModTools.searchBeginWidth(w, aligned: al)
            let c = PS2ModTools.searchCount()
            await MainActor.run {
                let m = NPModCenter.shared
                m.count = c
                m.searching = true
                m.results = []
                m.busy = false
            }
        }
    }

    func filter(_ op: Int, value text: String) {
        guard searching else { return }
        var raw: UInt32 = 0
        if op <= 3 {
            guard let v = NPModCenter.value(text, width: width) else { message = "اكتب قيمة صحيحة"; return }
            raw = v
        }
        busy = true
        Task.detached(priority: .userInitiated) {
            let c = PS2ModTools.searchFilter(op, value: raw)
            await MainActor.run {
                let m = NPModCenter.shared
                m.count = c
                m.results = c <= 500 ? PS2ModTools.searchResults(200) : []
                m.busy = false
            }
        }
    }

    func resetSearch() {
        PS2ModTools.searchReset()
        searching = false
        count = 0
        results = []
    }

    // MARK: edits

    func write(_ addr: UInt32, _ text: String, width w: Int, freeze: Bool) {
        guard let v = NPModCenter.value(text, width: w) else { message = "قيمة غير صحيحة"; return }
        if NPCenter.shared.session != nil {
            message = "التعديل متوقف أثناء اللعب أونلاين حتى لا يحدث عدم تطابق"
            return
        }
        if freeze { PS2ModTools.freeze(addr, width: w, value: v) } else { PS2ModTools.write(addr, width: w, value: v) }
        message = freeze ? "تم التجميد" : "تمت الكتابة"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NPModCenter.shared.refresh() }
    }

    func dump() {
        let dir = URL.documentsDirectory.appendingPathComponent("PS2 Online Dumps", isDirectory: true).path
        if let p = PS2ModTools.dump(toDirectory: dir) {
            message = "تم الحفظ في الملفات ← PS2 Online ← PS2 Online Dumps\n" + (p as NSString).lastPathComponent
        } else {
            message = "تعذّر حفظ الذاكرة"
        }
    }

    // MARK: parsing / formatting

    /// "0x1234", "1234h" or plain hex for addresses
    static func parse(_ text: String) -> UInt32? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        if t.hasSuffix("h") { t.removeLast() }
        guard !t.isEmpty, let v = UInt32(t, radix: 16) else { return nil }
        return v
    }

    /// Decimal, "0x" hex, or a float for the float width
    static func value(_ text: String, width: Int) -> UInt32? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if width == 0x14 {
            guard let f = Float(t) else { return nil }
            return f.bitPattern
        }
        let lower = t.lowercased()
        var v: UInt64?
        if lower.hasPrefix("0x") {
            v = UInt64(lower.dropFirst(2), radix: 16)
        } else if let i = Int64(t) {
            v = UInt64(bitPattern: i)
        }
        guard let x = v else { return nil }
        switch width {
        case 1: return UInt32(x & 0xFF)
        case 2: return UInt32(x & 0xFFFF)
        default: return UInt32(x & 0xFFFF_FFFF)
        }
    }

    static func show(_ raw: UInt32, width: Int) -> String {
        switch width {
        case 0x14: return String(Float(bitPattern: raw))
        case 1: return "\(raw & 0xFF)  (0x\(String(format: "%02X", raw & 0xFF)))"
        case 2: return "\(raw & 0xFFFF)  (0x\(String(format: "%04X", raw & 0xFFFF)))"
        default: return "\(Int32(bitPattern: raw))  (0x\(String(format: "%08X", raw)))"
        }
    }

    static func hex(_ a: UInt32) -> String { String(format: "%08X", a) }
}

// MARK: - Floating window

struct NPModWindow: View {
    @ObservedObject private var m = NPModCenter.shared
    @State private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width - 16, 560)
            let h = min(geo.size.height - 40, 520)
            Group {
                if m.minimized {
                    Button { m.minimized = false; m.refresh() } label: {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(NPTheme.a))
                            .shadow(color: .black.opacity(0.5), radius: 8)
                    }
                    .offset(x: m.offset.width + drag.width, y: m.offset.height + drag.height)
                    .gesture(dragGesture)
                    .position(x: geo.size.width - 40, y: geo.size.height / 2)
                } else {
                    VStack(spacing: 0) {
                        titleBar
                        NPModContent()
                    }
                    .frame(width: w, height: h)
                    .background(RoundedRectangle(cornerRadius: 18).fill(NPTheme.bg.opacity(m.opacity)))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12)))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.5), radius: 16)
                    .offset(x: m.offset.width + drag.width, y: m.offset.height + drag.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
        .alert("أدوات التعديل", isPresented: Binding(get: { m.message != nil }, set: { if !$0 { m.message = nil } })) {
            Button("حسناً", role: .cancel) {}
        } message: { Text(m.message ?? "") }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded {
                m.offset.width += $0.translation.width
                m.offset.height += $0.translation.height
                drag = .zero
            }
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundColor(.secondary)
            Text("أدوات التعديل").font(.system(size: 15, weight: .heavy))
            Text(PS2ModTools.serial()).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            Spacer()
            Button { m.togglePause() } label: {
                Image(systemName: m.paused ? "play.fill" : "pause.fill")
            }
            Button { m.minimized = true } label: { Image(systemName: "minus.circle.fill") }
            Button { m.close() } label: { Image(systemName: "xmark.circle.fill").foregroundColor(NPTheme.bad) }
        }
        .font(.system(size: 18))
        .foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }
}

// MARK: - Window content

struct NPModContent: View {
    @ObservedObject private var m = NPModCenter.shared

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $m.tab) {
                Text("الذاكرة").tag(0)
                Text("بحث").tag(1)
                Text("المجمّد").tag(2)
                Text("أدوات").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.top, 8)
            switch m.tab {
            case 0: NPMemoryTab()
            case 1: NPSearchTab()
            case 2: NPFrozenTab()
            default: NPToolsTab()
            }
        }
        .foregroundColor(.white)
    }
}

/// Edit / freeze one value
struct NPEditSheet: View {
    let address: UInt32
    @State private var width: Int
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    init(address: UInt32, width: Int) {
        self.address = address
        _width = State(initialValue: width)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("العنوان") {
                    Text("0x" + NPModCenter.hex(address)).font(.system(.body, design: .monospaced))
                        .environment(\.layoutDirection, .leftToRight)
                }
                Section("الحجم") {
                    Picker("", selection: $width) {
                        Text("8-bit").tag(1); Text("16-bit").tag(2); Text("32-bit").tag(4); Text("Float").tag(0x14)
                    }.pickerStyle(.segmented)
                }
                Section("القيمة (عدد عادي، أو 0x للـ hex)") {
                    TextField("مثال: 999 أو 0x3E7", text: $text)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Section {
                    Button("كتابة مرة واحدة") { NPModCenter.shared.write(address, text, width: width, freeze: false); dismiss() }
                    Button("تجميد (يُكتب كل إطار)") { NPModCenter.shared.write(address, text, width: width, freeze: true); dismiss() }
                }
            }
            .navigationTitle("تعديل قيمة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
        .onAppear {
            let d = PS2ModTools.read(address, length: 4)
            if d.count == 4 {
                let raw = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                switch width {
                case 1: text = String(raw & 0xFF)
                case 2: text = String(raw & 0xFFFF)
                case 0x14: text = String(Float(bitPattern: raw))
                default: text = String(raw)
                }
            }
        }
    }
}

struct NPEditTarget: Identifiable {
    let address: UInt32
    let width: Int
    var id: UInt32 { address }
}

struct NPMemoryTab: View {
    @ObservedObject private var m = NPModCenter.shared
    @State private var addr = ""
    @State private var edit: NPEditTarget?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("العنوان (hex)", text: $addr)
                    .font(.system(size: 14, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.characters)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    .environment(\.layoutDirection, .leftToRight)
                    .onSubmit { m.go(addr) }
                Button("اذهب") { m.go(addr) }.buttonStyle(.borderedProminent).tint(NPTheme.a)
                Button { m.page(-1) } label: { Image(systemName: "chevron.up") }
                Button { m.page(1) } label: { Image(systemName: "chevron.down") }
                Toggle("مباشر", isOn: $m.live).toggleStyle(.button).font(.caption)
            }
            .padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<16, id: \.self) { row in rowView(row) }
                }
                .padding(.horizontal, 10)
                .environment(\.layoutDirection, .leftToRight)
            }
            Text("اضغط على أي بايت لتعديله أو تجميده").font(.caption2).foregroundColor(.secondary).padding(.bottom, 6)
        }
        .sheet(item: $edit) { e in NPEditSheet(address: e.address, width: e.width) }
    }

    private func rowView(_ row: Int) -> some View {
        let base = m.viewAddress + UInt32(row * 16)
        let bytes = m.memory
        return HStack(spacing: 4) {
            Text(NPModCenter.hex(base)).foregroundColor(NPTheme.b)
            ForEach(0..<16, id: \.self) { i in
                let idx = row * 16 + i
                Text(idx < bytes.count ? String(format: "%02X", bytes[bytes.startIndex + idx]) : "--")
                    .foregroundColor(i % 4 == 0 ? .white : .white.opacity(0.75))
                    .onTapGesture { edit = NPEditTarget(address: base + UInt32(i), width: 1) }
            }
            Text(ascii(bytes, row)).foregroundColor(.secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func ascii(_ d: Data, _ row: Int) -> String {
        var s = ""
        for i in 0..<16 {
            let idx = row * 16 + i
            guard idx < d.count else { break }
            let b = d[d.startIndex + idx]
            s.append(b >= 0x20 && b < 0x7F ? Character(UnicodeScalar(b)) : ".")
        }
        return s
    }
}

struct NPSearchTab: View {
    @ObservedObject private var m = NPModCenter.shared
    @State private var value = ""
    @State private var edit: NPEditTarget?

    private let ops = ["=", "≠", ">", "<", "تغيّر", "لم يتغير", "زاد", "نقص"]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $m.width) {
                    Text("8").tag(1); Text("16").tag(2); Text("32").tag(4); Text("Float").tag(0x14)
                }
                .pickerStyle(.segmented)
                .disabled(m.searching)
                Toggle("محاذاة", isOn: $m.aligned).toggleStyle(.button).font(.caption).disabled(m.searching)
            }
            HStack {
                Button(m.searching ? "بحث جديد" : "ابدأ البحث") { m.newSearch() }
                    .buttonStyle(.borderedProminent).tint(NPTheme.a)
                if m.searching { Button("إنهاء") { m.resetSearch() } }
                Spacer()
                if m.busy { ProgressView().tint(.white) }
                Text(m.searching ? "النتائج: \(m.count)" : "").font(.caption.weight(.bold))
            }
            if m.searching {
                TextField("القيمة", text: $value)
                    .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    .environment(\.layoutDirection, .leftToRight)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(0..<ops.count, id: \.self) { i in
                        Button(ops[i]) { m.filter(i, value: value) }
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                            .disabled(m.busy)
                    }
                }
                if m.count > 500 {
                    Text("النتائج كثيرة — غيّر القيمة في اللعبة ثم صفِّ مرة أخرى").font(.caption).foregroundColor(.secondary)
                }
                List(m.results, id: \.address) { r in
                    HStack {
                        Text("0x" + NPModCenter.hex(r.address)).foregroundColor(NPTheme.b)
                        Spacer()
                        Text(NPModCenter.show(r.value, width: m.width))
                        Text("← " + NPModCenter.show(r.previous, width: m.width)).foregroundColor(.secondary)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .environment(\.layoutDirection, .leftToRight)
                    .contentShape(Rectangle())
                    .onTapGesture { edit = NPEditTarget(address: r.address, width: m.width) }
                    .swipeActions {
                        Button("عرض") { m.viewAddress = r.address & ~0xF; m.tab = 0; m.refresh() }.tint(NPTheme.a)
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                Text("1) اختر حجم القيمة ثم «ابدأ البحث».\n2) اكتب القيمة التي تراها في اللعبة واضغط =، أو استخدم تغيّر/زاد/نقص إذا لم تعرفها.\n3) غيّر القيمة في اللعبة وكرر حتى تبقى نتائج قليلة.")
                    .font(.footnote).foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .sheet(item: $edit) { e in NPEditSheet(address: e.address, width: e.width) }
    }
}

struct NPFrozenTab: View {
    @ObservedObject private var m = NPModCenter.shared

    var body: some View {
        VStack {
            if m.frozen.isEmpty {
                Spacer()
                Text("لا توجد قيم مجمّدة").foregroundColor(.secondary)
                Spacer()
            } else {
                List(m.frozen, id: \.address) { f in
                    HStack {
                        Text("0x" + NPModCenter.hex(f.address)).foregroundColor(NPTheme.b)
                        Spacer()
                        Text(NPModCenter.show(f.value, width: f.width))
                        Button { PS2ModTools.unfreeze(f.address); m.refresh() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(NPTheme.bad)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .environment(\.layoutDirection, .leftToRight)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                Button("إلغاء تجميد الكل", role: .destructive) { PS2ModTools.unfreezeAll(); m.refresh() }
                    .padding(.bottom, 8)
            }
        }
    }
}

struct NPToolsTab: View {
    @ObservedObject private var m = NPModCenter.shared
    @State private var disAddr = ""
    @State private var lines: [String] = []
    @State private var base: UInt32 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { m.dump() } label: {
                Label("حفظ ذاكرة EE و IOP في ملف (RAM dump)", systemImage: "square.and.arrow.down.fill")
            }
            .buttonStyle(.borderedProminent).tint(NPTheme.a)
            HStack {
                Text("الشفافية").font(.caption)
                Slider(value: $m.opacity, in: 0.4...1)
            }
            Divider()
            Text("Disassembly (R5900)").font(.caption.weight(.bold))
            HStack {
                TextField("العنوان (hex)", text: $disAddr)
                    .font(.system(size: 14, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.characters)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    .environment(\.layoutDirection, .leftToRight)
                Button("عرض") {
                    if let a = NPModCenter.parse(disAddr) {
                        base = (a & 0x01FF_FFFF) & ~3
                        lines = PS2ModTools.disassemble(base, count: 64)
                    }
                }
                .buttonStyle(.bordered)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        HStack(spacing: 10) {
                            Text(NPModCenter.hex(base + UInt32(i * 4))).foregroundColor(NPTheme.b)
                            Text(l)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}
