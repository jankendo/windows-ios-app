import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

struct AudioAssetProfile {
    let audioTrackChannelCounts: [Int]
    let layoutTags: [AudioChannelLayoutTag]
    let metadataTrackCount: Int

    var hasFOATrack: Bool {
        layoutTags.contains(Self.foaLayoutTag) || audioTrackChannelCounts.contains(4)
    }

    var hasStereoFallbackTrack: Bool {
        layoutTags.contains(kAudioChannelLayoutTag_Stereo) || audioTrackChannelCounts.contains(2)
    }

    var isTrueSpatialAudio: Bool {
        hasFOATrack && hasStereoFallbackTrack && metadataTrackCount > 0
    }

    var diagnosticSummary: String {
        let channels = audioTrackChannelCounts.isEmpty
            ? "none"
            : audioTrackChannelCounts.map(String.init).joined(separator: ",")
        let tags = layoutTags.isEmpty
            ? "none"
            : layoutTags.map { String($0) }.joined(separator: ",")
        return "tracks=\(audioTrackChannelCounts.count) channels=[\(channels)] layoutTags=[\(tags)] metadata=\(metadataTrackCount) spatial=\(isTrueSpatialAudio)"
    }

    static let empty = AudioAssetProfile(audioTrackChannelCounts: [], layoutTags: [], metadataTrackCount: 0)
    static let foaLayoutTag: AudioChannelLayoutTag = kAudioChannelLayoutTag_HOA_ACN_SN3D | 4

    static func inspect(url: URL) -> AudioAssetProfile {
        let asset = AVURLAsset(url: url)
        let audioTracks = asset.tracks(withMediaType: .audio)
        let metadataTrackCount = asset.tracks(withMediaType: .metadata).count

        let descriptions = audioTracks.flatMap { $0.formatDescriptions }
        let channelCounts = descriptions.compactMap(Self.channelCount(from:))
        let layoutTags = descriptions.compactMap(Self.layoutTag(from:))

        return AudioAssetProfile(
            audioTrackChannelCounts: channelCounts,
            layoutTags: layoutTags,
            metadataTrackCount: metadataTrackCount
        )
    }

    static func firstStereoTrack(in asset: AVAsset) -> AVAssetTrack? {
        asset.tracks(withMediaType: .audio).first { track in
            track.formatDescriptions.contains { description in
                channelCount(from: description) == 2 || layoutTag(from: description) == kAudioChannelLayoutTag_Stereo
            }
        }
    }

    private static func channelCount(from description: Any) -> Int? {
        guard
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description as! CMAudioFormatDescription)
        else {
            return nil
        }

        return Int(streamDescription.pointee.mChannelsPerFrame)
    }

    private static func layoutTag(from description: Any) -> AudioChannelLayoutTag? {
        var layoutSize: Int = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(description as! CMAudioFormatDescription, sizeOut: &layoutSize) else {
            return nil
        }

        return layout.pointee.mChannelLayoutTag
    }
}
