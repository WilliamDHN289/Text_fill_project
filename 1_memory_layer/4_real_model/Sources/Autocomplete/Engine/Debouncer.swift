import Foundation

@MainActor
final class Debouncer {
    private var workItem: DispatchWorkItem?
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.3) {
        self.interval = interval
    }

    func debounce(interval: TimeInterval? = nil, action: @escaping @MainActor () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard self != nil else { return }
            Task { @MainActor in
                action()
            }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (interval ?? self.interval), execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
