import XCTest
@testable import EdgeJournalLogic

final class JournalTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Bogota")!
        return c
    }()

    /// 2026-10-31 12:30 in Bogota.
    private let date = Date(timeIntervalSince1970: 1_793_467_800)

    func testDayAndPathUseTheLocalDay() {
        XCTAssertEqual(Journal.day(date, calendar: calendar), "2026-10-31")
        XCTAssertEqual(Journal.path(for: date, calendar: calendar), "Journal/2026-10-31.md")
        XCTAssertEqual(Journal.emptyDay(for: date, calendar: calendar), "# 2026-10-31\n")
    }

    func testEntries() {
        XCTAssertEqual(Journal.entry("arepa", kind: .meal, at: date, calendar: calendar), "- 12:30 arepa")
        XCTAssertEqual(Journal.entry(" one\n  two ", kind: .idea, at: date, calendar: calendar), "- 12:30 one two")
        XCTAssertEqual(Journal.entry("call", kind: .todo, at: date, calendar: calendar), "- [ ] call")
        XCTAssertEqual(Journal.entry("call", kind: .todo, at: date, due: date, calendar: calendar), "- [ ] call due:2026-10-31")
    }

    func testFirstEntryAddsItsSection() {
        XCTAssertEqual(Journal.appending("- a", under: .meal, to: "# Day\n"), "# Day\n\n## Meals\n\n- a\n")
    }

    func testSectionsKeepTheirOrder() {
        var text = "# Day\n"
        text = Journal.appending("- t", under: .todo, to: text)
        text = Journal.appending("- m", under: .meal, to: text)
        text = Journal.appending("- i", under: .idea, to: text)
        XCTAssertEqual(text, "# Day\n\n## Meals\n\n- m\n\n## Ideas\n\n- i\n\n## Todos\n\n- t\n")
    }

    func testEntriesStayTogetherAtTheEndOfTheSection() {
        let text = "# Day\n\n## Meals\n\n- a\n\n## Ideas\n\n- b\n"
        XCTAssertEqual(
            Journal.appending("- c", under: .meal, to: text),
            "# Day\n\n## Meals\n\n- a\n- c\n\n## Ideas\n\n- b\n",
        )
    }

    func testEmptySectionGetsItsBlankLine() {
        XCTAssertEqual(Journal.appending("- a", under: .idea, to: "# Day\n\n## Ideas\n"), "# Day\n\n## Ideas\n\n- a\n")
    }

    func testPlaceRoundsToThreeDecimals() {
        let line = PlaceLine(date: date, path: "Journal/2026-10-31.md", latitude: 4.70249, longitude: -74.04251, place: "Usaquen", timeZone: calendar.timeZone)
        XCTAssertEqual(line.lat, 4.702)
        XCTAssertEqual(line.lon, -74.043)
        XCTAssertEqual(line.at, "2026-10-31T12:30:00-05:00")
    }

    func testPlaceLogRoundTripsAndSkipsBadLines() {
        let line = PlaceLine(date: date, path: "a/b.md", latitude: 1, longitude: 2, place: nil)
        XCTAssertFalse(line.text.contains("\n"))
        XCTAssertEqual(PlaceLine.all(in: "\(line.text)\nnot json\n\(line.text)\n"), [line, line])
    }
}
