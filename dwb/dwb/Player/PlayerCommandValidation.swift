import Foundation

struct PlayerCommandState: Equatable {
    var hasPlayerWindow: Bool
    var queueCount: Int
    var hasCurrentMedia: Bool
    var canRenameCurrentMedia: Bool
    var shuffleEnabled: Bool
    var endlessShuffleEnabled: Bool
    var repeatOneEnabled: Bool
    var selectedPlaybackSpeedTag: Int
}

struct PlayerCommandValidationResult: Equatable {
    let isEnabled: Bool
    let isOn: Bool?
}

enum PlayerCommandValidation {
    static func result(forTag tag: Int, state: PlayerCommandState) -> PlayerCommandValidationResult? {
        switch tag {
        case 10: // Reveal in Finder
            return .init(isEnabled: state.hasCurrentMedia, isOn: nil)
        case 11: // Rename
            return .init(isEnabled: state.canRenameCurrentMedia, isOn: nil)
        case 12: // Remove Current
            return .init(isEnabled: state.hasCurrentMedia, isOn: nil)
        case 13: // Clear Queue
            return .init(isEnabled: state.queueCount > 0, isOn: nil)
        case 20: // Shuffle
            return .init(isEnabled: state.queueCount > 1, isOn: state.shuffleEnabled)
        case 21: // Endless Shuffle
            return .init(isEnabled: state.queueCount > 0, isOn: state.endlessShuffleEnabled)
        case 22: // Repeat One
            return .init(isEnabled: state.hasCurrentMedia, isOn: state.repeatOneEnabled)
        case 1000...1999: // Playback speed items
            return .init(
                isEnabled: state.hasPlayerWindow,
                isOn: tag - 1000 == state.selectedPlaybackSpeedTag
            )
        default:
            return nil
        }
    }
}
