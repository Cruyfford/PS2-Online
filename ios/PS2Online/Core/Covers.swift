import Foundation
import UIKit

/// أغلفة الألعاب: يرسل رقم القرص (SYSTEM.CNF) واسم الملف للسيرفر فيجد الغلاف تلقائياً ويحفظه محلياً
final class Covers: ObservableObject {
    static let shared = Covers()
    @Published private(set) var images: [String: UIImage] = [:]
    private var loading = Set<String>()

    private let dir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    func image(for romFile: String) -> UIImage? {
        guard !romFile.isEmpty else { return nil }
        if let i = images[romFile] { return i }
        load(romFile)
        return nil
    }

    private func load(_ romFile: String) {
        guard !loading.contains(romFile) else { return }
        loading.insert(romFile)
        let dir = self.dir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let url = Paths.roms.appendingPathComponent(romFile)
            guard let c = Disc.crc(url) else { return }
            let file = dir.appendingPathComponent(String(format: "%08X", c) + ".png")
            if let img = UIImage(contentsOfFile: file.path) {
                DispatchQueue.main.async { self?.images[romFile] = img }
                return
            }
            var comps = URLComponents(string: Account.httpBase + "/cover")
            comps?.queryItems = [URLQueryItem(name: "system", value: "ps2"),
                                 URLQueryItem(name: "serial", value: Disc.serial(url)),
                                 URLQueryItem(name: "name", value: romFile)]
            guard let u = comps?.url else { return }
            URLSession.shared.dataTask(with: URLRequest(url: u, timeoutInterval: 25)) { data, resp, _ in
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data,
                      let img = UIImage(data: data) else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.loading.remove(romFile) }
                    return
                }
                try? data.write(to: file)
                DispatchQueue.main.async { self?.images[romFile] = img }
            }.resume()
        }
    }
}

extension Disc {
    /// رقم القرص (مثل SCUS-94236) من SYSTEM.CNF — يعمل مع .cue/.bin/.iso فقط
    static func serial(_ url: URL) -> String {
        guard let first = files(url).first(where: { !["cue", "m3u"].contains($0.pathExtension.lowercased()) }),
              ["bin", "iso", "img"].contains(first.pathExtension.lowercased()),
              let h = try? FileHandle(forReadingFrom: first) else { return "" }
        defer { try? h.close() }
        let head = [UInt8](h.readData(ofLength: 16))
        guard head.count == 16 else { return "" }
        let raw = head[0] == 0 && head[11] == 0 && head[1...10].allSatisfy { $0 == 0xFF }
        let size: UInt64 = raw ? 2352 : 2048

        func sector(_ lba: Int) -> [UInt8] {
            h.seek(toFileOffset: UInt64(lba) * size)
            let d = [UInt8](h.readData(ofLength: Int(size)))
            if !raw { return d }
            guard d.count == 2352 else { return [] }
            let off = d[15] == 2 ? 24 : 16
            return Array(d[off..<(off + 2048)])
        }
        func le32(_ b: [UInt8], _ i: Int) -> Int {
            Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
        }

        let pvd = sector(16)
        guard pvd.count == 2048, Array(pvd[1...5]) == Array("CD001".utf8) else { return "" }
        let lba = le32(pvd, 156 + 2), length = le32(pvd, 156 + 10)
        guard length > 0, length < 1 << 20 else { return "" }
        var data: [UInt8] = []
        for i in 0..<((length + 2047) / 2048) { data += sector(lba + i) }
        var i = 0
        while i + 33 < data.count {
            let n = Int(data[i])
            if n == 0 { i = (i / 2048 + 1) * 2048; continue }
            let nl = Int(data[i + 32])
            guard i + 33 + nl <= data.count else { break }
            let name = String(decoding: data[(i + 33)..<(i + 33 + nl)], as: UTF8.self).uppercased()
            if name.hasPrefix("SYSTEM.CNF") {
                let cnf = String(decoding: sector(le32(data, i + 2)), as: UTF8.self)
                let pat = #"BOOT\s*=\s*cdrom:\\?\\?([A-Za-z]{4})[_-](\d{3})\.?(\d{2})"#
                guard let re = try? NSRegularExpression(pattern: pat),
                      let m = re.firstMatch(in: cnf, range: NSRange(cnf.startIndex..., in: cnf)),
                      let a = Range(m.range(at: 1), in: cnf), let b = Range(m.range(at: 2), in: cnf),
                      let c = Range(m.range(at: 3), in: cnf) else { return "" }
                return "\(cnf[a].uppercased())-\(cnf[b])\(cnf[c])"
            }
            i += n
        }
        return ""
    }
}
