import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum Theme {
    static let bg = Color(hex: 0x0B0D12)
    static let surface = Color(hex: 0x141822)
    static let surface2 = Color(hex: 0x1B2133)
    static let border = Color(hex: 0x232A3B)
    static let text = Color(hex: 0xE8EAF2)
    static let muted = Color(hex: 0x8A91A6)
    static let accentA = Color(hex: 0x7C5CFF)
    static let accentB = Color(hex: 0x00C2FF)
    static let danger = Color(hex: 0xFF4D6D)
    static let good = Color(hex: 0x2BD67B)
    static let warn = Color(hex: 0xFFB020)
    static let accent = LinearGradient(colors: [accentA, accentB], startPoint: .leading, endPoint: .trailing)
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.border, lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct LogoView: View {
    var size: CGFloat = 46
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accentA, Theme.accentB],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            ForEach(0..<4) { i in
                let off: [(CGFloat, CGFloat)] = [(0, -1), (1, 0), (0, 1), (-1, 0)]
                Circle()
                    .fill(Color.white.opacity([1, 0.8, 0.6, 0.4][i]))
                    .frame(width: size * 0.2, height: size * 0.2)
                    .offset(x: off[i].0 * size * 0.2, y: off[i].1 * size * 0.2)
            }
        }
        .frame(width: size, height: size)
        .environment(\.layoutDirection, .leftToRight)
    }
}

enum Haptics {
    private static let gen = UIImpactFeedbackGenerator(style: .light)
    static func tap() { gen.impactOccurred() }
}
