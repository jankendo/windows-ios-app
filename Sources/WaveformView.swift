import AVFoundation
import SwiftUI

struct AudioWaveformView: View {
    let samples: [CGFloat]
    let progress: Double
    var activeColor: Color = .indigo
    var inactiveColor: Color = Color.indigo.opacity(0.2)
    var minimumBarHeight: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let barWidth = max(3, geometry.size.width / CGFloat(max(samples.count * 2, 1)))

            HStack(alignment: .center, spacing: barWidth / 2) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(indexFraction(index) <= progress ? activeColor : inactiveColor)
                        .frame(width: barWidth, height: max(minimumBarHeight, sample * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 64)
    }

    private func indexFraction(_ index: Int) -> Double {
        guard !samples.isEmpty else { return 0 }
        return Double(index + 1) / Double(samples.count)
    }
}

struct SeekableAudioWaveformView: View {
    let samples: [CGFloat]
    let progress: Double
    let duration: TimeInterval
    var activeColor: Color = .indigo
    var inactiveColor: Color = Color.indigo.opacity(0.2)
    var minimumBarHeight: CGFloat = 14
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            AudioWaveformView(
                samples: samples,
                progress: progress,
                activeColor: activeColor,
                inactiveColor: inactiveColor,
                minimumBarHeight: minimumBarHeight
            )
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / max(geometry.size.width, 1)))
                        onSeek(TimeInterval(fraction) * max(duration, 0.1))
                    }
            )
        }
    }
}

enum WaveformExtractor {
    static func samples(from url: URL?, sampleCount: Int = 40) -> [CGFloat] {
        guard
            let url,
            let file = try? AVAudioFile(forReading: url),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            return Array(repeating: 0.25, count: sampleCount)
        }

        do {
            try file.read(into: buffer)
        } catch {
            return Array(repeating: 0.25, count: sampleCount)
        }

        guard
            let channelData = buffer.floatChannelData?.pointee
        else {
            return Array(repeating: 0.25, count: sampleCount)
        }

        let frameLength = Int(buffer.frameLength)
        let bucketSize = max(1, frameLength / sampleCount)
        var values: [CGFloat] = []
        values.reserveCapacity(sampleCount)

        for bucket in 0..<sampleCount {
            let start = bucket * bucketSize
            let end = min(frameLength, start + bucketSize)

            guard start < end else {
                values.append(0.05)
                continue
            }

            var sum: Float = 0
            for frame in start..<end {
                sum += abs(channelData[frame])
            }

            let average = sum / Float(end - start)
            values.append(max(0.05, min(1, CGFloat(average * 8))))
        }

        return values
    }
}
