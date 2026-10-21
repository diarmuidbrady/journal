import SwiftUI

/// Diverging mood colours: muted red (negative) through neutral grey to teal-green
/// (positive), four steps per side. Teal rather than pure green keeps the two ends
/// apart for red–green colour blindness (validated: deutan ΔE ≈ 10; a plain
/// red/green pair scores 3.4). Steps are interpolated in OKLab; dark mode has its own.
enum MoodScale {
    private static let light: [UInt32] = [
        0xC4553A, 0xCE7862, 0xD59988, 0xDABAAE, 0xDCDAD5, 0xB3C9BF, 0x89B7AA, 0x5AA694, 0x0F9480,
    ]
    private static let dark: [UInt32] = [
        0xD4664C, 0xB1604C, 0x8E5A4B, 0x6C5248, 0x4A4945, 0x4A5F56, 0x467567, 0x3B8B79, 0x22A28C,
    ]

    static let stepCount = 9

    /// 0 (most negative) … 4 (neutral) … 8 (most positive).
    static func step(for score: Double) -> Int {
        let clamped = min(1, max(-1, score))
        return min(stepCount - 1, Int(((clamped + 1) / 2 * Double(stepCount)).rounded(.down)))
    }

    static func color(for score: Double) -> Color {
        color(step: step(for: score))
    }

    static func color(step: Int) -> Color {
        Color(UIColor { traits in
            let hex = (traits.userInterfaceStyle == .dark ? dark : light)[step]
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    /// Day numbers sit on the fill; use white on the darkest light-mode steps.
    static func textColor(step: Int, scheme: ColorScheme) -> Color {
        scheme == .light && abs(step - 4) >= 3 ? .white : .primary
    }

    static func describe(_ score: Double) -> String {
        let value = score.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)))
        switch step(for: score) {
        case 0...1: return "very negative (\(value))"
        case 2...3: return "negative (\(value))"
        case 4: return "neutral (\(value))"
        case 5...6: return "positive (\(value))"
        default: return "very positive (\(value))"
        }
    }
}

/// The small legend under the calendar: the nine steps with end labels.
struct MoodLegend: View {
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<MoodScale.stepCount, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(MoodScale.color(step: step))
                        .frame(height: 10)
                }
            }
            HStack {
                Text("Negative")
                Spacer()
                Text("Neutral")
                Spacer()
                Text("Positive")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mood colours range from red for negative, through grey for neutral, to green for positive.")
    }
}

/// A small coloured dot for an entry's mood, or a hollow one if it isn't scored yet.
struct MoodDot: View {
    let score: Double?
    var size: CGFloat = 10

    var body: some View {
        Group {
            if let score {
                Circle().fill(MoodScale.color(for: score))
            } else {
                Circle().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
