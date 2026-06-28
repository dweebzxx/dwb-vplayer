import Foundation

enum PlaybackCompletionAction: String {
    case repeatCurrent
    case playNext
    case endlessShuffleNext
    case stopLastItem
    case ignoredUserStop
}

struct PlaybackCompletionPolicy {
    let isRepeatOne: Bool
    let currentDisplayIndex: Int
    let displayOrderCount: Int
    let isEndlessShuffleOn: Bool
    let queueIsEmpty: Bool

    var action: PlaybackCompletionAction {
        if isRepeatOne { return .repeatCurrent }
        if currentDisplayIndex < displayOrderCount - 1 { return .playNext }
        if isEndlessShuffleOn && !queueIsEmpty { return .endlessShuffleNext }
        return .stopLastItem
    }
}
