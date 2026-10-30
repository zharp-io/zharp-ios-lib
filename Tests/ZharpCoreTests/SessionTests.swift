import XCTest
@testable import ZharpCore

final class SessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var counter = 0

    private func nextId() -> String {
        counter += 1
        return "session-\(counter)"
    }

    func testIdsAreLowercaseUUIDs() {
        let id = SessionRules.newId()
        XCTAssertEqual(id, id.lowercased())
        XCTAssertNotNil(UUID(uuidString: id))
    }

    func testShortTimeInBackgroundKeepsTheSession() {
        var rules = SessionRules(id: "a")
        rules.didEnterBackground(at: start)
        XCTAssertFalse(rules.willEnterForeground(at: start.addingTimeInterval(29 * 60), newId: nextId))
        XCTAssertEqual(rules.id, "a")
        XCTAssertNil(rules.backgroundedAt)
    }

    func testThirtyMinutesInBackgroundStartsANewSession() {
        var rules = SessionRules(id: "a")
        rules.didEnterBackground(at: start)
        XCTAssertTrue(rules.willEnterForeground(at: start.addingTimeInterval(30 * 60), newId: nextId))
        XCTAssertEqual(rules.id, "session-1")
    }

    func testForegroundTimeDoesNotCount() {
        var rules = SessionRules(id: "a")
        XCTAssertFalse(rules.current(at: start.addingTimeInterval(3 * 60 * 60), newId: nextId))
        XCTAssertEqual(rules.id, "a")
    }

    func testTelemetryLongInTheBackgroundStartsANewSessionOnce() {
        var rules = SessionRules(id: "a")
        rules.didEnterBackground(at: start)
        // A background fetch 40 minutes later is a new session…
        XCTAssertTrue(rules.current(at: start.addingTimeInterval(40 * 60), newId: nextId))
        XCTAssertEqual(rules.id, "session-1")
        // …which continues when the app is opened 5 minutes after that.
        XCTAssertFalse(rules.willEnterForeground(at: start.addingTimeInterval(45 * 60), newId: nextId))
        XCTAssertEqual(rules.id, "session-1")
    }

    func testBackgroundTimeIsFromTheFirstNotification() {
        var rules = SessionRules(id: "a")
        rules.didEnterBackground(at: start)
        rules.didEnterBackground(at: start.addingTimeInterval(20 * 60))
        XCTAssertTrue(rules.willEnterForeground(at: start.addingTimeInterval(31 * 60), newId: nextId))
    }

    func testRestartForClearUser() {
        var rules = SessionRules(id: "a")
        rules.restart(newId: nextId)
        XCTAssertEqual(rules.id, "session-1")
    }

    func testSnapshotAttributes() {
        let snapshot = ContextSnapshot(sessionId: "s1",
                                       user: UserInfo(id: "u1", email: "ada@example.com", name: nil),
                                       screen: "Checkout",
                                       tags: ["plan": "pro", "session.id": "not-this"],
                                       release: "1.0")
        let attributes = snapshot.attributes()
        XCTAssertEqual(attributes["session.id"], .string("s1"))
        XCTAssertEqual(attributes["enduser.id"], .string("u1"))
        XCTAssertEqual(attributes["enduser.email"], .string("ada@example.com"))
        XCTAssertNil(attributes["enduser.name"])
        XCTAssertEqual(attributes["app.screen.name"], .string("Checkout"))
        XCTAssertEqual(attributes["plan"], .string("pro"))
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let snapshot = ContextSnapshot(sessionId: "s1", user: UserInfo(id: "u1"), screen: "Home",
                                       tags: ["a": "b"], release: "2.0 (3)")
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(ContextSnapshot.self, from: data), snapshot)
    }

    func testScreenNames() {
        XCTAssertEqual(ScreenNaming.name(fromClassName: "MyApp.CheckoutViewController"), "CheckoutViewController")
        XCTAssertEqual(ScreenNaming.name(fromClassName: "CheckoutViewController"), "CheckoutViewController")
        XCTAssertEqual(ScreenNaming.name(fromClassName: "RootHostingController<MyApp.RootView>"), "RootHostingController")
        XCTAssertEqual(ScreenNaming.spanName("Checkout"), "screen Checkout")
    }

    func testRepeatedAppearancesAreOneScreenView() {
        XCTAssertTrue(ScreenNaming.isRepeat(previous: "Home", previousAt: start, name: "Home",
                                            now: start.addingTimeInterval(0.2)))
        XCTAssertFalse(ScreenNaming.isRepeat(previous: "Home", previousAt: start, name: "Home",
                                             now: start.addingTimeInterval(5)))
        XCTAssertFalse(ScreenNaming.isRepeat(previous: "Home", previousAt: start, name: "Cart",
                                             now: start.addingTimeInterval(0.2)))
        XCTAssertFalse(ScreenNaming.isRepeat(previous: nil, previousAt: nil, name: "Home", now: start))
    }
}
