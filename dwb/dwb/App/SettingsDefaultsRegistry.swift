import Foundation

enum SettingsDefaultsRegistry {
    enum Keys {
        static let autoHideTransportWindowed = "autoHideTransportWindowed"
        static let persistedVolume = "lastEffectiveVolume"
        static let skipDurationSeconds = "skipDurationSeconds"
        static let autoHideTitlebar = "autoHideTitlebar"
        static let completeVideoWindowMode = "completeVideoWindowMode"
        static let imageDurationSeconds = "imageDurationSeconds"
        static let gifLoopCount = "gifLoopCount"
        static let acceptVideoMedia = "acceptVideoMedia"
        static let acceptImageMedia = "acceptImageMedia"
        static let acceptGIFMedia = "acceptGIFMedia"
        static let showTitleOverlay = "showTitleOverlay"
        static let deletePrefixRenameEnabled = "deletePrefixRenameEnabled"
        static let videoPageDButtonEnabled = "videoPageDButtonEnabled"
        static let customPrefixValue = "customPrefixValue"
        static let customPrefixQueuePageEnabled = "customPrefixQueuePageEnabled"
        static let customPrefixVideoPageEnabled = "customPrefixVideoPageEnabled"
        static let customPrefixSecondaryValue = "customPrefixValue2"
        static let debugConsoleEnabled = "debugConsoleEnabled"
        static let verboseAutoplayTrace = "verboseAutoplayTrace"
        static let chromeAutohideThreshold = "chromeAutohideThreshold"
        static let chromeReducedMotion = "chromeReducedMotion"
        static let queuePanelOpenAtLaunch = "queuePanelOpenAtLaunch"
        static let bottomRailShowXButton = "bottomRailShowXButton"
        static let bottomRailShowShuffleButton = "bottomRailShowShuffleButton"
        static let bottomRailShowReplayButton = "bottomRailShowReplayButton"
        static let bottomRailShowVolumeButton = "bottomRailShowVolumeButton"
        static let bottomRailShowBookmarkButton = "bottomRailShowBookmarkButton"
        static let playerWindowOpacity = "playerWindowOpacity"
        static let xtremeModeEnabled = "xtremeModeEnabled"
        static let xtremeModeGIFBookmarkData = "xtremeModeGIFBookmarkData"
        static let xtremeModeOpacity = "xtremeModeOpacity"
        static let xtremeAudioEnabled = "xtremeAudioEnabled"
        static let xtremeAudioMP3BookmarkData = "xtremeAudioMP3BookmarkData"
        static let xtremeAudioVolume = "xtremeAudioVolume"
        static let xtremeAudioMuteMedia = "xtremeAudioMuteMedia"

        enum OptionalTransportControl: CaseIterable {
            case stop, volume, shuffle, repeatOne

            var defaultsKey: String {
                switch self {
                case .stop:      return "showStopButton"
                case .volume:    return "showVolumeButton"
                case .shuffle:   return "showShuffleButton"
                case .repeatOne: return "showRepeatButton"
                }
            }
        }

        enum QueueColumn {
            static let durationVisible = "com.dwb.queueColumnDurationVisible"
            static let sizeVisible = "com.dwb.queueColumnSizeVisible"
            static let durationWidth = "com.dwb.queueColumnDurationWidth"
            static let sizeWidth = "com.dwb.queueColumnSizeWidth"
        }
    }

    enum Defaults {
        static let skipDurationSeconds = 10
        static let imageDurationSeconds = 3
        static let gifLoopCount = 1
        static let chromeAutohideThreshold = 3.0
        static let queueDurationColumnWidth = 92.0
        static let queueSizeColumnWidth = 104.0
        static let playerWindowOpacityMin = 0.35
        static let playerWindowOpacityMax = 1.0
        static let playerWindowOpacity = 1.0
        static let xtremeModeOpacityMin = 0.05
        static let xtremeModeOpacityMax = 0.50
        static let xtremeModeOpacity = 0.15
        static let xtremeAudioVolumeMin = 0.0
        static let xtremeAudioVolumeMax = 1.0
        static let xtremeAudioVolume = 0.50
    }

    static func defaultValues(reduceMotionDefault: Bool) -> [String: Any] {
        var defaults: [String: Any] = [
            Keys.autoHideTransportWindowed: false,
            Keys.skipDurationSeconds: Defaults.skipDurationSeconds,
            Keys.imageDurationSeconds: Defaults.imageDurationSeconds,
            Keys.gifLoopCount: Defaults.gifLoopCount,
            Keys.acceptVideoMedia: true,
            Keys.acceptImageMedia: true,
            Keys.acceptGIFMedia: true,
            Keys.autoHideTitlebar: false,
            Keys.completeVideoWindowMode: false,
            Keys.showTitleOverlay: true,
            Keys.deletePrefixRenameEnabled: false,
            Keys.videoPageDButtonEnabled: false,
            Keys.customPrefixValue: "",
            Keys.customPrefixSecondaryValue: "",
            Keys.debugConsoleEnabled: false,
            Keys.verboseAutoplayTrace: false,
            Keys.chromeAutohideThreshold: Defaults.chromeAutohideThreshold,
            Keys.chromeReducedMotion: reduceMotionDefault,
            Keys.queuePanelOpenAtLaunch: false,
            Keys.bottomRailShowXButton: true,
            Keys.bottomRailShowShuffleButton: true,
            Keys.bottomRailShowReplayButton: true,
            Keys.bottomRailShowVolumeButton: true,
            Keys.bottomRailShowBookmarkButton: true,
            Keys.playerWindowOpacity: Defaults.playerWindowOpacity,
            Keys.xtremeModeEnabled: false,
            Keys.xtremeModeOpacity: Defaults.xtremeModeOpacity,
            Keys.xtremeAudioEnabled: false,
            Keys.xtremeAudioVolume: Defaults.xtremeAudioVolume,
            Keys.xtremeAudioMuteMedia: false,
        ]

        for control in Keys.OptionalTransportControl.allCases {
            defaults[control.defaultsKey] = false
        }

        defaults[Keys.QueueColumn.durationVisible] = true
        defaults[Keys.QueueColumn.sizeVisible] = true
        defaults[Keys.QueueColumn.durationWidth] = Defaults.queueDurationColumnWidth
        defaults[Keys.QueueColumn.sizeWidth] = Defaults.queueSizeColumnWidth

        return defaults
    }

    static func register(defaults: UserDefaults = .standard, reduceMotionDefault: Bool) {
        defaults.register(defaults: defaultValues(reduceMotionDefault: reduceMotionDefault))
    }
}
