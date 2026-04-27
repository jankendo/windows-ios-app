import Accelerate
import AVFoundation
import Foundation

struct DirectionalAudioHotspot: Codable, Hashable, Identifiable {
    let timeFraction: Double
    let angleRadians: Double
    let intensity: Double

    var id: String {
        "\(timeFraction)-\(angleRadians)-\(intensity)"
    }
}

struct ImmersiveAudioAnalysis {
    let waveformFingerprint: [Double]
    let audioFeatureVector: [Float]
    let seamlessLoopStartPoint: TimeInterval?
    let seamlessLoopEndPoint: TimeInterval?
    let directionalHotspots: [DirectionalAudioHotspot]
}

enum ImmersiveAudioIntelligence {
    static func analyze(url: URL?, waveformSamples: Int = 28) -> ImmersiveAudioAnalysis {
        guard let signal = readSignal(from: url) else {
            return ImmersiveAudioAnalysis(
                waveformFingerprint: WaveformExtractor.samples(from: url, sampleCount: waveformSamples).map(Double.init),
                audioFeatureVector: [],
                seamlessLoopStartPoint: nil,
                seamlessLoopEndPoint: nil,
                directionalHotspots: []
            )
        }

        let waveform = WaveformExtractor.samples(from: url, sampleCount: waveformSamples).map(Double.init)
        let loopPoints = analyzeLoopPoints(from: signal)
        let featureVector = makeFeatureVector(from: signal)
        let hotspots = detectHotspots(from: signal)

        return ImmersiveAudioAnalysis(
            waveformFingerprint: waveform,
            audioFeatureVector: featureVector,
            seamlessLoopStartPoint: loopPoints?.start,
            seamlessLoopEndPoint: loopPoints?.end,
            directionalHotspots: hotspots
        )
    }
}

private extension ImmersiveAudioIntelligence {
    struct Signal {
        let sampleRate: Double
        let channels: [[Float]]

        var frameCount: Int {
            channels.first?.count ?? 0
        }

        var mono: [Float] {
            guard let first = channels.first else { return [] }
            guard channels.count > 1 else { return first }

            var mixed = Array(repeating: Float.zero, count: first.count)
            let divisor = Float(channels.count)
            for channel in channels {
                for index in channel.indices {
                    mixed[index] += channel[index] / divisor
                }
            }
            return mixed
        }
    }

    struct LoopPoints {
        let start: TimeInterval
        let end: TimeInterval
    }

    static func readSignal(from url: URL?) -> Signal? {
        guard
            let url,
            let file = try? AVAudioFile(forReading: url),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            return nil
        }

        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }

        guard
            let floatChannelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let channels = (0..<channelCount).map { channelIndex in
            Array(UnsafeBufferPointer(start: floatChannelData[channelIndex], count: frameCount))
        }

        return Signal(sampleRate: buffer.format.sampleRate, channels: channels)
    }

    static func analyzeLoopPoints(from signal: Signal) -> LoopPoints? {
        let mono = signal.mono
        let frameCount = mono.count
        guard frameCount > 16_384, signal.sampleRate > 0 else { return nil }

        let windowSize = min(max(Int(signal.sampleRate * 0.24), 4_096), max(frameCount / 5, 4_096))
        let stride = max(windowSize / 3, 1_024)
        let startLowerBound = Int(signal.sampleRate * 0.18)
        let startUpperBound = min(Int(signal.sampleRate * 1.4), max(frameCount / 3, startLowerBound + stride))
        let endLowerBound = max(frameCount - Int(signal.sampleRate * 2.2) - windowSize, startUpperBound + stride)
        let endUpperBound = max(frameCount - Int(signal.sampleRate * 0.18) - windowSize, endLowerBound)

        guard startUpperBound > startLowerBound, endUpperBound > endLowerBound else { return nil }

        var bestScore = Float(-1)
        var bestPair: (Int, Int)?

        var startIndex = startLowerBound
        while startIndex < startUpperBound {
            let adjustedStart = nearestZeroCrossing(around: startIndex, in: mono)
            guard adjustedStart + windowSize < frameCount else { break }
            let startWindow = Array(mono[adjustedStart..<(adjustedStart + windowSize)])
            let startRMS = max(vDSP.rootMeanSquare(startWindow), 0.0001)

            var endIndex = endLowerBound
            while endIndex < endUpperBound {
                let adjustedEnd = nearestZeroCrossing(around: endIndex, in: mono)
                guard adjustedEnd + windowSize < frameCount, adjustedEnd > adjustedStart + windowSize else {
                    endIndex += stride
                    continue
                }

                let endWindow = Array(mono[adjustedEnd..<(adjustedEnd + windowSize)])
                let endRMS = max(vDSP.rootMeanSquare(endWindow), 0.0001)
                let similarity = vDSP.dot(startWindow, endWindow) / Float(windowSize) / (startRMS * endRMS)
                let edgePenalty = min(abs(mono[adjustedStart] - mono[adjustedEnd]), 0.4)
                let score = similarity - edgePenalty

                if score > bestScore {
                    bestScore = score
                    bestPair = (adjustedStart, adjustedEnd)
                }

                endIndex += stride
            }

            startIndex += stride
        }

        guard let bestPair, bestScore > 0.74 else { return nil }
        let startSeconds = Double(bestPair.0) / signal.sampleRate
        let endSeconds = Double(bestPair.1) / signal.sampleRate
        guard endSeconds - startSeconds > 1.4 else { return nil }
        return LoopPoints(start: startSeconds, end: endSeconds)
    }

    static func makeFeatureVector(from signal: Signal) -> [Float] {
        let mono = signal.mono
        guard mono.count > 32, signal.sampleRate > 0 else { return [] }

        let rms = vDSP.rootMeanSquare(mono)
        let mean = mono.reduce(Float.zero, +) / Float(mono.count)
        let variance = mono.reduce(Float.zero) { partial, sample in
            let centered = sample - mean
            return partial + (centered * centered)
        } / Float(mono.count)

        let dynamicRange = (mono.max() ?? 0) - (mono.min() ?? 0)

        var zeroCrossings = 0
        var diffEnergy: Float = 0
        var quietFrames = 0
        var peakFrames = 0
        for index in 1..<mono.count {
            let previous = mono[index - 1]
            let current = mono[index]
            if (previous >= 0 && current < 0) || (previous < 0 && current >= 0) {
                zeroCrossings += 1
            }
            let delta = current - previous
            diffEnergy += abs(delta)
            if abs(current) < 0.01 {
                quietFrames += 1
            }
            if abs(current) > 0.1 {
                peakFrames += 1
            }
        }

        let zeroCrossRate = Float(zeroCrossings) / Float(max(mono.count - 1, 1))
        let transientDensity = diffEnergy / Float(max(mono.count - 1, 1))
        let quietRatio = Float(quietFrames) / Float(mono.count)
        let peakRatio = Float(peakFrames) / Float(mono.count)

        let channelSpread: Float
        if signal.channels.count >= 2 {
            let left = vDSP.rootMeanSquare(signal.channels[0])
            let right = vDSP.rootMeanSquare(signal.channels[1])
            channelSpread = abs(left - right)
        } else {
            channelSpread = 0
        }

        return [
            rms,
            variance,
            dynamicRange,
            zeroCrossRate,
            transientDensity,
            quietRatio,
            peakRatio,
            channelSpread
        ]
    }

    static func detectHotspots(from signal: Signal) -> [DirectionalAudioHotspot] {
        let mono = signal.mono
        guard mono.count > 2_048 else { return [] }

        let channelCount = signal.channels.count
        let bucketCount = 12
        let bucketSize = max(mono.count / bucketCount, 1)
        var hotspots: [DirectionalAudioHotspot] = []

        for bucket in 0..<bucketCount {
            let start = bucket * bucketSize
            let end = min(mono.count, start + bucketSize)
            guard end - start > 256 else { continue }

            let monoSegment = Array(mono[start..<end])
            let intensity = Double(vDSP.rootMeanSquare(monoSegment))
            guard intensity > 0.018 else { continue }

            let angle: Double
            if channelCount >= 3 {
                let xSegment = Array(signal.channels[1][start..<end])
                let ySegment = Array(signal.channels[2][start..<end])
                let xBalance = signedBalance(xSegment)
                let yBalance = signedBalance(ySegment)
                angle = atan2(Double(yBalance), Double(xBalance == 0 && yBalance == 0 ? 0.0001 : xBalance))
            } else if channelCount >= 2 {
                let leftSegment = Array(signal.channels[0][start..<end])
                let rightSegment = Array(signal.channels[1][start..<end])
                let leftEnergy = vDSP.rootMeanSquare(leftSegment)
                let rightEnergy = vDSP.rootMeanSquare(rightSegment)
                let balance = max(-1, min(1, rightEnergy - leftEnergy))
                angle = Double(balance) * (.pi / 2.0)
            } else {
                angle = 0
            }

            hotspots.append(
                DirectionalAudioHotspot(
                    timeFraction: Double(start) / Double(max(mono.count - 1, 1)),
                    angleRadians: angle,
                    intensity: intensity
                )
            )
        }

        let peakIntensity = hotspots.map(\.intensity).max() ?? 1
        return hotspots
            .sorted { $0.intensity > $1.intensity }
            .prefix(6)
            .map {
                DirectionalAudioHotspot(
                    timeFraction: $0.timeFraction,
                    angleRadians: $0.angleRadians,
                    intensity: min(max($0.intensity / peakIntensity, 0.22), 1)
                )
            }
    }

    static func nearestZeroCrossing(around index: Int, in samples: [Float], searchRadius: Int = 512) -> Int {
        guard samples.indices.contains(index) else { return max(0, min(index, samples.count - 1)) }

        let lowerBound = max(1, index - searchRadius)
        let upperBound = min(samples.count - 1, index + searchRadius)
        var bestIndex = index
        var bestDistance = Int.max

        for candidate in lowerBound..<upperBound {
            let lhs = samples[candidate - 1]
            let rhs = samples[candidate]
            let isCrossing = (lhs >= 0 && rhs < 0) || (lhs < 0 && rhs >= 0)
            guard isCrossing else { continue }

            let distance = abs(candidate - index)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = candidate
            }
        }

        return bestIndex
    }

    static func signedBalance(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(Float.zero) { partial, sample in
            partial + (sample * abs(sample))
        } / Float(samples.count)
    }
}
