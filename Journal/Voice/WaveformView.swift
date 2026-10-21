import SwiftUI

/// Bars for recent input levels (0…1), newest on the right.
struct WaveformView: View {
    let levels: [Float]
    var barCount = AudioRecorder.levelCount

    var body: some View {
        Canvas { context, size in
            let slot = size.width / CGFloat(barCount)
            let barWidth = max(1, slot * 0.6)
            let padded = Array(repeating: Float(0), count: max(0, barCount - levels.count)) + levels.suffix(barCount)
            for (index, level) in padded.enumerated() {
                let height = max(2, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * slot + (slot - barWidth) / 2,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.accentColor))
            }
        }
        .accessibilityHidden(true)
    }
}
