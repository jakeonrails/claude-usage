import Foundation

/// Drives `BreakdownView`. Wraps the `UsageBreakdownService` actor: all scans
/// happen off-main inside the actor, this type only marshals results back to
/// the main actor for SwiftUI. `responseProvider` is read fresh on `onAppear`
/// and on each `select` — there's no polling here, the breakdown window shows
/// a snapshot of whatever `UsageStore` last fetched when it was opened/switched.
@MainActor
final class BreakdownViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(BreakdownResult)
        case empty
    }

    @Published private(set) var windows: [WindowDescriptor] = []
    @Published private(set) var selected: WindowDescriptor?
    @Published private(set) var state: State = .idle
    @Published var expandedProjectIDs: Set<String> = []

    private let service: UsageBreakdownService
    private let responseProvider: @MainActor () -> UsageResponse?

    init(service: UsageBreakdownService, responseProvider: @MainActor @escaping () -> UsageResponse?) {
        self.service = service
        self.responseProvider = responseProvider
    }

    /// Loads the available timescales for the current response, selects the
    /// first one (if any), and loads its breakdown. Call each time the window
    /// is shown so data refreshes on reopen.
    func onAppear() async {
        guard let response = responseProvider() else {
            windows = []
            selected = nil
            state = .empty
            return
        }
        let now = Date()
        let descriptors = await service.availableWindows(response: response, now: now)
        windows = descriptors
        guard let first = descriptors.first else {
            selected = nil
            state = .empty
            return
        }
        selected = first
        await reload(for: first, response: response, now: now)
    }

    /// Switches the selected timescale and reloads its breakdown. Uses a
    /// fresh snapshot of the response so the picker and its breakdown stay
    /// consistent even if `UsageStore` refreshed in between.
    func select(_ descriptor: WindowDescriptor) async {
        selected = descriptor
        expandedProjectIDs = []
        guard let response = responseProvider() else {
            state = .empty
            return
        }
        await reload(for: descriptor, response: response, now: Date())
    }

    func toggleExpanded(_ projectID: String) {
        if expandedProjectIDs.contains(projectID) {
            expandedProjectIDs.remove(projectID)
        } else {
            expandedProjectIDs.insert(projectID)
        }
    }

    private func reload(for descriptor: WindowDescriptor, response: UsageResponse, now: Date) async {
        state = .loading
        let result = await service.breakdown(for: descriptor, response: response, now: now)
        state = .loaded(result)
    }
}
