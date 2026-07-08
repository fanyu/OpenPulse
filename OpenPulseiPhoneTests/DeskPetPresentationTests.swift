import Testing
@testable import OpenPulseiPhone

struct DeskPetPresentationTests {
    @MainActor
    @Test
    func appStoreStartsInWaitingStateWithoutSnapshot() async throws {
        let store = DeskModeAppStore(client: .init(fetchCurrent: { nil }))
        await store.refresh()

        #expect(store.snapshot == nil)
        #expect(store.statusText == "Waiting for Mac")
    }
}
