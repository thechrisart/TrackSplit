import SwiftUI

/// Colours taken from the logo: deep purple ground, neon cyan and violet.
enum Theme {
    static let backgroundTop = Color(red: 0.10, green: 0.03, blue: 0.20)
    static let backgroundBottom = Color(red: 0.20, green: 0.05, blue: 0.36)
    static let panel = Color.white.opacity(0.06)
    static let panelStroke = Color.white.opacity(0.10)
    static let cyan = Color(red: 0.36, green: 0.92, blue: 1.0)
    static let violet = Color(red: 0.80, green: 0.45, blue: 1.0)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.65)
    static let success = Color(red: 0.45, green: 0.95, blue: 0.70)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.60)

    static let neon = LinearGradient(colors: [cyan, violet], startPoint: .leading, endPoint: .trailing)
    static let background = LinearGradient(colors: [backgroundTop, backgroundBottom], startPoint: .top, endPoint: .bottom)
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.panelStroke))
    }
}

struct NeonProgressBar: View {
    var value: Double
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Theme.neon)
                    .frame(width: max(height, geometry.size.width * min(max(value, 0), 1)))
                    .shadow(color: Theme.cyan.opacity(0.7), radius: 8)
                    .animation(.easeOut(duration: 0.4), value: value)
            }
        }
        .frame(height: height)
    }
}

struct NeonButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(enabled ? Theme.backgroundTop : Theme.secondary)
            .padding(.horizontal, 34).padding(.vertical, 12)
            .background(Capsule().fill(enabled ? AnyShapeStyle(Theme.neon) : AnyShapeStyle(Color.white.opacity(0.1))))
            .shadow(color: enabled ? Theme.violet.opacity(0.6) : .clear, radius: configuration.isPressed ? 4 : 12)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.secondary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 20).padding(.vertical, 9)
            .overlay(Capsule().stroke(tint.opacity(0.6)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
