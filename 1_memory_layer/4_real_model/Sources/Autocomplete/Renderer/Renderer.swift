import AppKit

@MainActor
final class Renderer {
    private let suggestionPanel = SuggestionPanel()
    let toolbarPanel = ToolbarPanel()

    func showSuggestion(_ text: String, at caretRect: CGRect, elementFrame: CGRect = .zero, font: NSFont?, currentLinePrefix: String = "", textAreaLeftEdge: CGFloat? = nil, focusedAppBundleId: String? = nil) {
        suggestionPanel.show(text: text, at: caretRect, elementFrame: elementFrame, font: font, currentLinePrefix: currentLinePrefix, textAreaLeftEdge: textAreaLeftEdge, focusedAppBundleId: focusedAppBundleId)
    }

    func updateSuggestion(_ text: String) {
        suggestionPanel.update(text: text)
    }

    func updateSuggestionAfterPartialAccept(remainingText: String, acceptedText: String) {
        suggestionPanel.updateAfterPartialAccept(remainingText: remainingText, acceptedText: acceptedText)
    }

    func hideSuggestion() {
        suggestionPanel.hide()
    }

    var isSuggestionVisible: Bool {
        suggestionPanel.isVisible
    }

    func showToolbar(near caretRect: CGRect, elementFrame: CGRect, appName: String, appBundleId: String, isAppEnabled: Bool, isGloballyEnabled: Bool) {
        toolbarPanel.show(near: caretRect, elementFrame: elementFrame, appName: appName, appBundleId: appBundleId, isAppEnabled: isAppEnabled, isGloballyEnabled: isGloballyEnabled)
    }

    func hideToolbar() {
        toolbarPanel.hide()
    }
}
