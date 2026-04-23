import SwiftUI
import UIKit
import Vision

struct AtmosphericImmersiveOverlay: View {
    let atmosphere: AtmosphereStyle
    let snapshot: CaptureEnvironmentSnapshot?
    let audioReactiveLevel: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ResonancePreferenceKey.immersiveParticlesEnabled) private var immersiveParticlesEnabled = true
    @AppStorage(ResonancePreferenceKey.immersiveAudioReactiveLightEnabled) private var immersiveAudioReactiveLightEnabled = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                drawBaseGlow(in: &context, size: size)

                if immersiveAudioReactiveLightEnabled {
                    drawAudioReactiveLight(in: &context, size: size)
                }

                guard immersiveParticlesEnabled, !reduceMotion else { return }
                drawParticles(in: &context, size: size, date: timeline.date)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawBaseGlow(in context: inout GraphicsContext, size: CGSize) {
        let colors: [Color]
        switch atmosphere {
        case .dawn:
            colors = [Color.pink.opacity(0.18), Color.orange.opacity(0.12), .clear]
        case .day:
            colors = [Color.white.opacity(0.08), Color.yellow.opacity(0.08), .clear]
        case .dusk:
            colors = [Color.orange.opacity(0.18), Color.purple.opacity(0.12), .clear]
        case .night:
            colors = [Color.blue.opacity(0.16), Color.indigo.opacity(0.14), .clear]
        }

        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: colors),
                startPoint: CGPoint(x: size.width * 0.5, y: 0),
                endPoint: CGPoint(x: size.width * 0.5, y: size.height)
            )
        )
    }

    private func drawAudioReactiveLight(in context: inout GraphicsContext, size: CGSize) {
        let clampedLevel = max(0.08, min(audioReactiveLevel, 1))
        let radius = max(size.width, size.height) * CGFloat(0.18 + (clampedLevel * 0.18))
        let color: Color

        switch atmosphere {
        case .dawn:
            color = .orange.opacity(0.08 + (clampedLevel * 0.16))
        case .day:
            color = .white.opacity(0.06 + (clampedLevel * 0.12))
        case .dusk:
            color = .orange.opacity(0.08 + (clampedLevel * 0.18))
        case .night:
            color = .blue.opacity(0.08 + (clampedLevel * 0.16))
        }

        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.42)
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [color, .clear]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private func drawParticles(in context: inout GraphicsContext, size: CGSize, date: Date) {
        let seed = date.timeIntervalSinceReferenceDate
        let particleCount = baseParticleCount
        let drift = windDrift

        for index in 0..<particleCount {
            let phase = seed * (0.12 + (Double(index % 5) * 0.04))
            let normalizedX = fractionalSine(Double(index) * 4.2 + phase)
            let normalizedY = fractionalSine(Double(index) * 7.7 + (phase * 0.82))

            var x = normalizedX * size.width
            var y = normalizedY * size.height
            x += drift.width * CGFloat(sin(phase + Double(index)))
            y += drift.height * CGFloat(cos((phase * 0.9) + Double(index)))

            let radius = CGFloat(1.4) + (CGFloat(index % 4) * CGFloat(0.8))
            let opacity = 0.08 + (Double(index % 3) * 0.04)
            let color = particleColor.opacity(opacity)
            let rect = CGRect(x: x, y: y, width: radius, height: radius)
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }

        if shouldShowMist {
            let mistRect = CGRect(x: -size.width * 0.1, y: size.height * 0.58, width: size.width * 1.2, height: size.height * 0.26)
            context.fill(
                Path(ellipseIn: mistRect),
                with: .linearGradient(
                    Gradient(colors: [Color.white.opacity(colorScheme == .dark ? 0.06 : 0.08), .clear]),
                    startPoint: CGPoint(x: mistRect.minX, y: mistRect.midY),
                    endPoint: CGPoint(x: mistRect.maxX, y: mistRect.midY)
                )
            )
        }
    }

    private var baseParticleCount: Int {
        switch atmosphere {
        case .dawn:
            return 22
        case .day:
            return 18
        case .dusk:
            return 24
        case .night:
            return 28
        }
    }

    private var particleColor: Color {
        switch atmosphere {
        case .dawn:
            return .orange
        case .day:
            return .white
        case .dusk:
            return .orange
        case .night:
            return .blue
        }
    }

    private var windDrift: CGSize {
        guard let speed = snapshot?.speed else { return .zero }
        let normalizedSpeed = max(0, min(speed / 8.0, 1.0))
        return CGSize(width: normalizedSpeed * 18, height: normalizedSpeed * 4)
    }

    private var shouldShowMist: Bool {
        if let pressure = snapshot?.pressureKilopascals, pressure < 100.5 {
            return true
        }

        guard let snapshot else { return false }
        let month = Calendar.current.component(.month, from: .now)
        let altitude = snapshot.altitude ?? 0
        let hour = Calendar.current.component(.hour, from: .now)
        let coldEstimate = (month <= 2 || month == 12) || altitude > 800 || hour < 7 || hour >= 20
        return coldEstimate
    }

    private func fractionalSine(_ value: Double) -> CGFloat {
        let raw = (sin(value) + 1) * 0.5
        return CGFloat(raw)
    }
}

enum SaliencyFocusResolver {
    static func focusPoint(for image: UIImage) async -> CGPoint {
        guard let cgImage = image.cgImage else { return CGPoint(x: 0.5, y: 0.5) }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNGenerateAttentionBasedSaliencyImageRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage)

                do {
                    try handler.perform([request])
                    guard
                        let observation = request.results?.first as? VNSaliencyImageObservation,
                        let salientObject = observation.salientObjects?.first
                    else {
                        continuation.resume(returning: CGPoint(x: 0.5, y: 0.5))
                        return
                    }

                    let box = salientObject.boundingBox
                    continuation.resume(returning: CGPoint(x: box.midX, y: 1 - box.midY))
                } catch {
                    continuation.resume(returning: CGPoint(x: 0.5, y: 0.5))
                }
            }
        }
    }
}
