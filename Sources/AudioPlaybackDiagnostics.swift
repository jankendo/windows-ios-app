import SwiftUI
import UIKit

@MainActor
final class AudioPlaybackDiagnostics: ObservableObject {
    static let shared = AudioPlaybackDiagnostics()

    @Published private(set) var entries: [String] = []

    var text: String {
        entries.joined(separator: "\n")
    }

    func record(_ message: String, category: String = "audio") {
        let stamped = "[\(Self.timestampFormatter.string(from: .now))] [\(category.uppercased())] \(message)"
        entries.append(stamped)
        if entries.count > 160 {
            entries.removeFirst(entries.count - 160)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func copyToPasteboard() {
        UIPasteboard.general.string = text
        record("diagnostics copied to clipboard", category: "diagnostics")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

struct AudioDiagnosticsPanel: View {
    let palette: ResonancePalette

    @ObservedObject private var diagnostics = AudioPlaybackDiagnostics.shared
    @State private var copied = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text(diagnostics.entries.isEmpty ? "まだログはありません。" : diagnostics.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(palette.surfaceSecondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        diagnostics.copyToPasteboard()
                        copied = true
                    } label: {
                        Label("診断をコピー", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.accent)

                    Button {
                        diagnostics.clear()
                        copied = false
                    } label: {
                        Label("クリア", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.secondaryText.opacity(0.7))

                    Spacer()

                    if copied {
                        Text("コピーしました")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Label("診断ログ", systemImage: "stethoscope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
        }
    }
}
