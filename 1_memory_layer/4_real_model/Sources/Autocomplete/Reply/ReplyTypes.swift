import Foundation

/// A single short-form reply suggestion (Stage 1 output).
struct ReplyIntent: Equatable {
    let text: String
}

/// What the reply card is currently showing.
enum ReplyCardPhase: Equatable {
    case chips          // three intents, one highlighted
    case preview        // expanded full reply for the highlighted intent
}
