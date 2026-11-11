import CoreGraphics

/// إطار الصورة الحالي من النواة
struct FrameInfo {
    let ptr: UnsafePointer<UInt8>
    let w: Int
    let h: Int
    let pitch: Int
    let fmt: Int          // 0=0RGB1555، 1=XRGB8888، 2=RGB565

    /// لون البكسل بصيغة 0xRRGGBB (نفس تحويل Qt في نسخة الكمبيوتر) — الإحداثيات بنظام 256×224
    func rgb(_ x: Int, _ y: Int) -> UInt32 {
        let sx = x * w / 256, sy = y * h / 224
        guard sx >= 0, sy >= 0, sx < w, sy < h else { return 0 }
        return FrameInfo.convert(ptr + sy * pitch, sx, fmt) & 0xFFFFFF
    }

    @inline(__always)
    static func convert(_ row: UnsafePointer<UInt8>, _ x: Int, _ fmt: Int) -> UInt32 {
        if fmt == 1 {
            let o = x * 4
            return UInt32(row[o]) | UInt32(row[o + 1]) << 8 | UInt32(row[o + 2]) << 16
        }
        let v = UInt32(row[x * 2]) | UInt32(row[x * 2 + 1]) << 8
        let r5: UInt32, g: UInt32, b5: UInt32
        if fmt == 2 {
            r5 = (v >> 11) & 31
            let g6 = (v >> 5) & 63
            g = (g6 << 2) | (g6 >> 4)
            b5 = v & 31
        } else {
            r5 = (v >> 10) & 31
            let g5 = (v >> 5) & 31
            g = (g5 << 3) | (g5 >> 2)
            b5 = v & 31
        }
        let r = (r5 << 3) | (r5 >> 2), b = (b5 << 3) | (b5 >> 2)
        return (r << 16) | (g << 8) | b
    }
}

struct Cover: Equatable {
    var full: Bool
    var rect: CGRect      // بإحداثيات space عندما full = false
    var text: String
    /// شارة ملوّنة (إطار + «أنت») بدل غطاء يخفي المحتوى
    var badge: Bool = false
    var color: UInt32 = 0x7C5CFF
    /// مساحة الإحداثيات (PS1 = 320×240)
    var space: CGSize = CGSize(width: 320, height: 240)
}

/// إضافات العرض — الأسماء مطابقة لنسخة الكمبيوتر حرفياً
enum ViewPlugin: String, CaseIterable, Identifiable {
    case none = "بدون (نفس الشاشة للجميع)"
    case tomba2P = "Tomba! — وضع اللاعبَين (علامة «أنت»)"

    var id: String { rawValue }
    var name: String { rawValue }

    private static func u32(_ m: UnsafeMutableBufferPointer<UInt8>, _ addr: Int) -> UInt32 {
        let o = addr - 0x8000_0000
        return UInt32(m[o]) | UInt32(m[o + 1]) << 8 | UInt32(m[o + 2]) << 16 | UInt32(m[o + 3]) << 24
    }

    func cover(player: Int, wram: UnsafeMutableBufferPointer<UInt8>?, frame: FrameInfo) -> Cover? {
        switch self {
        case .none:
            return nil
        case .tomba2P:
            // باتش Tomba_2Player: الكنترول الأول = الأحمر (عدّاده يسار)، الثاني = الأزرق (عدّاده يمين)
            guard let ram = wram, ram.count >= 0x200000 else { return nil }
            let j = ViewPlugin.u32(ram, 0x8001_B6B0)
            let target = 0x8000_0000 | ((j & 0x03FF_FFFF) << 2)
            guard j >> 26 == 3, target >= 0x8006_1BBC, target < 0x8006_2ED4 else { return nil }
            let blue: UInt32 = 0x3C96FF, red: UInt32 = 0xFF5046
            guard ViewPlugin.u32(ram, 0x8006_1D34) == 1 else {
                return player == 1
                    ? Cover(full: false, rect: CGRect(x: 110, y: 200, width: 100, height: 22),
                            text: "اضغط START للدخول", badge: true, color: blue)
                    : nil
            }
            return player == 0
                ? Cover(full: false, rect: CGRect(x: 13, y: 5, width: 38, height: 48), text: "أنت", badge: true, color: red)
                : Cover(full: false, rect: CGRect(x: 264, y: 57, width: 38, height: 48), text: "أنت", badge: true, color: blue)
        }
    }
}
