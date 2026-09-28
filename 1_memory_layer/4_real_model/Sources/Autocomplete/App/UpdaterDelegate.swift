import AppKit
import Sparkle

@MainActor
final class UpdaterDelegate: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    private let dockPresence: DockPresence
    private var raisedForUpdate = false

    init(dockPresence: DockPresence) {
        self.dockPresence = dockPresence
        super.init()
    }

    // Update-found alert: Sparkle shows it as a regular window, not a modal.
    // Bump policy when the alert appears, drop it when the update cycle ends.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            guard handleShowingUpdate, !raisedForUpdate else { return }
            raisedForUpdate = true
            dockPresence.windowAppeared()
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard raisedForUpdate else { return }
            raisedForUpdate = false
            dockPresence.windowDisappeared()
        }
    }

    // Modal Sparkle alerts (errors, "no update available" on manual check)
    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated {
            dockPresence.windowAppeared()
        }
    }

    nonisolated func standardUserDriverDidShowModalAlert() {
        MainActor.assumeIsolated {
            dockPresence.windowDisappeared()
        }
    }
}
