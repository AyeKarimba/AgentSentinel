import Foundation

/// How loudly the app is allowed to interrupt, and in which ways.
///
/// Separate from the rest of `Config` because these are the knobs the settings window exposes,
/// and because every one of them is a matter of taste — the right level of interruption depends
/// on whether you are staring at the menu bar or three desktops away with headphones on.
///
/// Decoded leniently, like `Config`, so a settings file written by an older build still loads.
public struct AlertSettings: Codable, Equatable, Sendable {
    public enum BannerSize: String, Codable, CaseIterable, Sendable {
        case small, medium, large

        /// Width in points. Height follows the content.
        public var width: Double {
            switch self {
            case .small: return 300
            case .medium: return 380
            case .large: return 460
            }
        }

        public var titleSize: Double {
            switch self {
            case .small: return 12
            case .medium: return 14
            case .large: return 16
            }
        }

        public var bodySize: Double {
            switch self {
            case .small: return 11
            case .medium: return 12
            case .large: return 14
            }
        }

        public var label: String { rawValue.capitalized }
    }

    /// Show a banner when a tab starts waiting.
    public var bannerEnabled: Bool
    public var bannerSize: BannerSize
    /// Seconds a banner stays on screen before fading out.
    public var bannerSeconds: Double
    /// Let the banner appear over fullscreen apps.
    ///
    /// Only possible because the banner is the app's own window rather than a system
    /// notification: macOS decides that for system notifications from your Focus settings, and
    /// gives an app no say. Off by default — overriding fullscreen is exactly the interruption
    /// some people go fullscreen to avoid.
    public var bannerOverFullscreen: Bool

    public var soundEnabled: Bool
    /// 0...1.
    public var soundVolume: Double
    /// A name from `NSSound(named:)` — the system sounds in /System/Library/Sounds.
    public var soundName: String
    /// Played instead of `soundName` for a blocking request, so the two are distinguishable
    /// without looking.
    public var urgentSoundName: String

    public var pulseEnabled: Bool
    /// How far the menu bar item fades at the bottom of a pulse: 1 is no fade at all, lower is
    /// a deeper dip and a more obvious pulse.
    public var pulseDepth: Double
    /// Pulse for any unread row, not just blocking requests.
    public var pulseForAllUnread: Bool

    public init(bannerEnabled: Bool = true,
                bannerSize: BannerSize = .medium,
                bannerSeconds: Double = 6,
                bannerOverFullscreen: Bool = false,
                soundEnabled: Bool = true,
                soundVolume: Double = 0.7,
                soundName: String = "Submarine",
                urgentSoundName: String = "Sosumi",
                pulseEnabled: Bool = true,
                pulseDepth: Double = 0.45,
                pulseForAllUnread: Bool = false) {
        self.bannerEnabled = bannerEnabled
        self.bannerSize = bannerSize
        self.bannerSeconds = bannerSeconds
        self.bannerOverFullscreen = bannerOverFullscreen
        self.soundEnabled = soundEnabled
        self.soundVolume = soundVolume
        self.soundName = soundName
        self.urgentSoundName = urgentSoundName
        self.pulseEnabled = pulseEnabled
        self.pulseDepth = pulseDepth
        self.pulseForAllUnread = pulseForAllUnread
    }

    /// Every value that comes from a slider is clamped on the way in. A settings file can be
    /// hand-edited, and a negative volume or a pulse depth above 1 would otherwise produce a
    /// silently broken alert rather than an obviously wrong number.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AlertSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) as? T ?? fallback
        }
        bannerEnabled = value(.bannerEnabled, defaults.bannerEnabled)
        bannerSize = value(.bannerSize, defaults.bannerSize)
        bannerSeconds = min(30, max(1, value(.bannerSeconds, defaults.bannerSeconds)))
        bannerOverFullscreen = value(.bannerOverFullscreen, defaults.bannerOverFullscreen)
        soundEnabled = value(.soundEnabled, defaults.soundEnabled)
        soundVolume = min(1, max(0, value(.soundVolume, defaults.soundVolume)))
        soundName = value(.soundName, defaults.soundName)
        urgentSoundName = value(.urgentSoundName, defaults.urgentSoundName)
        pulseEnabled = value(.pulseEnabled, defaults.pulseEnabled)
        pulseDepth = min(1, max(0.1, value(.pulseDepth, defaults.pulseDepth)))
        pulseForAllUnread = value(.pulseForAllUnread, defaults.pulseForAllUnread)
    }

    /// The sounds offered in the settings window. Every one ships with macOS.
    public static let availableSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
}
