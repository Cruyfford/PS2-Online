import Foundation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Paths {
    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static var roms: URL { dir("roms") }
    static var saves: URL { dir("saves") }
    static var system: URL { dir("system") }
    static var bios: URL { dir("bios") }

    private static func dir(_ name: String) -> URL {
        let u = docs.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// أرقام بتات الأزرار (نفس ترتيب libretro ونسخة الكمبيوتر)
enum Btn {
    static let b = 0, y = 1, select = 2, start = 3, up = 4, down = 5, left = 6, right = 7
    static let a = 8, x = 9, l = 10, r = 11, l2 = 12, r2 = 13, l3 = 14, r3 = 15
    // في PS1:  b = ✕   a = ○   y = □   x = △   l/r = L1/R1
    static func bit(_ n: Int) -> UInt16 { UInt16(1) << UInt16(n) }
}

/// نواة PCSX ReARMED (نسخة واحدة فقط في التطبيق)
final class Core {
    let fps: Double
    let sampleRate: Double
    let version: String
    private var isOpen = true

    static var libraryVersion: String { String(cString: cb_version()) }

    init(path: String, biosDir: String, savesDir: String, hleBios: Bool) throws {
        guard cb_init(biosDir, savesDir, hleBios) else { throw AppError("تعذّر تشغيل النواة") }
        cb_set_enhance(UserDefaults.standard.bool(forKey: "enhance"))
        guard cb_load(path) else {
            cb_unload()
            throw AppError("النواة رفضت تحميل اللعبة (تأكد من وجود ملف .cue وملفات .bin بجانبه)")
        }
        let f = cb_fps()
        fps = f > 0 ? f : 59.94
        let s = cb_sample_rate()
        sampleRate = s > 0 ? s : 44100
        version = Core.libraryVersion
    }

    func run(_ p1: UInt16, _ p2: UInt16) { cb_run(p1, p2) }

    var stateSize: Int { cb_state_size() }

    func saveState() -> Data? {
        let n = cb_state_size()
        var d = Data(count: n)
        let ok = d.withUnsafeMutableBytes { cb_save_state($0.baseAddress, n) }
        return ok ? d : nil
    }

    func loadState(_ d: Data) -> Bool {
        d.withUnsafeBytes { cb_load_state($0.baseAddress, d.count) }
    }

    /// 0 = بطاقة الذاكرة 1 (128KB)، 2 = ذاكرة PS1 (2MB)
    func memory(_ id: UInt32) -> UnsafeMutableBufferPointer<UInt8>? {
        var n = 0
        guard let p = cb_memory(id, &n), n > 0 else { return nil }
        return UnsafeMutableBufferPointer(start: p, count: n)
    }

    func wramCRC() -> UInt32 {
        guard let m = memory(2) else { return 0 }
        return Z.crc(UnsafeBufferPointer(m))
    }

    func close() {
        if isOpen { cb_unload(); isOpen = false }
    }
}

/// ملفات القرص وبصمته — نفس طريقة نسخة الكمبيوتر بالضبط (CRC32 لملفات البيانات بالترتيب)
enum Disc {
    static let exts = ["cue", "chd", "pbp", "m3u", "iso", "img", "ccd"]

    static func files(_ url: URL) -> [URL] {
        var out = [url]
        let base = url.deletingLastPathComponent()
        let ext = url.pathExtension.lowercased()
        guard ext == "cue" || ext == "m3u",
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        else { return out }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if ext == "cue" {
                guard line.uppercased().hasPrefix("FILE") else { continue }
                var rest = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                var name = ""
                if rest.hasPrefix("\"") {
                    rest.removeFirst()
                    if let q = rest.firstIndex(of: "\"") { name = String(rest[..<q]) }
                } else if let sp = rest.lastIndex(of: " ") {
                    name = String(rest[..<sp]).trimmingCharacters(in: .whitespaces)
                }
                if !name.isEmpty { out.append(base.appendingPathComponent(name)) }
            } else if !line.isEmpty && !line.hasPrefix("#") {
                out += files(base.appendingPathComponent(line))
            }
        }
        return out
    }

    static func crc(_ url: URL) -> UInt32? {
        let fm = FileManager.default
        let fs = files(url)
        var key = ""
        for f in fs {
            guard let a = try? fm.attributesOfItem(atPath: f.path) else { return nil }
            let size = (a[.size] as? NSNumber)?.int64Value ?? 0
            let mt = Int((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            key += "\(f.lastPathComponent):\(size):\(mt)|"
        }
        let cacheKey = "disc_crc:" + key
        if let v = UserDefaults.standard.object(forKey: cacheKey) as? NSNumber { return v.uint32Value }
        var c: uLong = 0
        for f in fs {
            let e = f.pathExtension.lowercased()
            if e == "cue" || e == "m3u" { continue }
            guard let h = try? FileHandle(forReadingFrom: f) else { return nil }
            defer { try? h.close() }
            while true {
                let chunk = h.readData(ofLength: 4 << 20)
                if chunk.isEmpty { break }
                c = chunk.withUnsafeBytes { raw -> uLong in
                    let b = raw.bindMemory(to: UInt8.self)
                    return crc32(c, b.baseAddress, uInt(b.count))
                }
            }
        }
        let v = UInt32(truncatingIfNeeded: c)
        UserDefaults.standard.set(NSNumber(value: v), forKey: cacheKey)
        return v
    }

    /// البايوس المستخدم: "HLE" أو "اسم:crc" — يجب أن يتطابق عند اللاعبين
    static let biosNames = ["scph101.bin", "scph7001.bin", "scph5501.bin", "scph1001.bin",
                            "SCPH101.BIN", "SCPH7001.BIN", "SCPH5501.BIN", "SCPH1001.BIN"]

    static func biosID(hle: Bool) -> String {
        if hle { return "HLE" }
        for n in biosNames {
            let u = Paths.bios.appendingPathComponent(n)
            if let d = try? Data(contentsOf: u) {
                return String(format: "%@:%08x", n.lowercased(), Z.crc(d))
            }
        }
        return "HLE"
    }
}

enum Z {
    static func crc(_ d: Data) -> UInt32 {
        d.withUnsafeBytes { raw -> UInt32 in
            let b = raw.bindMemory(to: UInt8.self)
            return UInt32(crc32(0, b.baseAddress, uInt(b.count)))
        }
    }

    static func crc(_ b: UnsafeBufferPointer<UInt8>) -> UInt32 {
        UInt32(crc32(0, b.baseAddress, uInt(b.count)))
    }

    static func compress(_ d: Data) -> Data? {
        var outLen = compressBound(uLong(d.count))
        var out = Data(count: Int(outLen))
        let r = out.withUnsafeMutableBytes { o -> Int32 in
            d.withUnsafeBytes { i -> Int32 in
                compress2(o.bindMemory(to: UInt8.self).baseAddress, &outLen,
                          i.bindMemory(to: UInt8.self).baseAddress, uLong(d.count), 6)
            }
        }
        guard r == Z_OK else { return nil }
        out.count = Int(outLen)
        return out
    }

    static func decompress(_ d: Data, capacity: Int) -> Data? {
        var outLen = uLongf(capacity)
        var out = Data(count: capacity)
        let r = out.withUnsafeMutableBytes { o -> Int32 in
            d.withUnsafeBytes { i -> Int32 in
                uncompress(o.bindMemory(to: UInt8.self).baseAddress, &outLen,
                           i.bindMemory(to: UInt8.self).baseAddress, uLong(d.count))
            }
        }
        guard r == Z_OK else { return nil }
        out.count = Int(outLen)
        return out
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var x = v
        for _ in 0..<MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: x))
            x >>= 8
        }
    }

    /// قراءة رقم little-endian من موضع نسبي (يعمل مع الـ slices أيضاً)
    func le<T: FixedWidthInteger>(_ offset: Int) -> T {
        var v: T = 0
        let start = startIndex + offset
        for i in 0..<MemoryLayout<T>.size {
            v |= T(truncatingIfNeeded: self[start + i]) << (8 * i)
        }
        return v
    }
}
