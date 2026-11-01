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

    func testPlacesShowBesideEntriesOnly() {
        let path = "Journal/2026-10-31.md"
        let text = "# 2026-10-31\n\n## Meals\n\n- 12:30 arroz\n- 12:30 arroz con pollo\n- 19:00 sopa\n\n## Todos\n\n- [ ] 12:30 pan\n"
        let there = PlaceLine(date: date, path: path, latitude: 4.6, longitude: -74.1, place: "Chapinero", timeZone: calendar.timeZone)
        let shown = PlaceLine.annotated(text, path: path, lines: [there])
        XCTAssertEqual(shown, "# 2026-10-31\n\n## Meals\n\n- 12:30 arroz · Chapinero\n- 12:30 arroz con pollo · Chapinero\n- 19:00 sopa\n\n## Todos\n\n- [ ] 12:30 pan\n")
        // The checkboxes read back from the same lines, so line numbers must not move.
        XCTAssertEqual(TodoScan.todos(in: shown, path: path).map(\.line), TodoScan.todos(in: text, path: path).map(\.line))
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

    func testEntriesReadTimedLinesAndSkipTasks() {
        let text = "# Day\n\n## Meals\n\n- 08:00 arepa\n\n## Ideas\n\n- 09:15 a note: with colon\n- no time\n\n## Todos\n\n- [ ] task\n- 10:00 not an entry\n"
        let entries = Journal.entries(in: text, path: "Journal/2026-10-31.md")
        XCTAssertEqual(entries.map(\.text), ["arepa", "a note: with colon"])
        XCTAssertEqual(entries.map(\.kind), [.meal, .idea])
        XCTAssertEqual(entries[1].day, "2026-10-31")
        XCTAssertEqual(entries[1].time, "09:15")
    }

    func testAnEntryFindsThePlaceLoggedJustAfterIt() throws {
        let path = "Journal/2026-10-31.md"
        let entry = try XCTUnwrap(Journal.entries(in: "## Ideas\n\n- 12:30 idea\n", path: path).first)
        let at = date
        let line = PlaceLine(date: at.addingTimeInterval(60), path: path, latitude: 1, longitude: 2, place: "Usaquen", timeZone: calendar.timeZone)
        let late = PlaceLine(date: at.addingTimeInterval(600), path: path, latitude: 1, longitude: 2, place: "Far", timeZone: calendar.timeZone)
        let other = PlaceLine(date: at, path: "Other.md", latitude: 1, longitude: 2, place: "Other", timeZone: calendar.timeZone)
        XCTAssertEqual(PlaceLine.place(of: entry, in: [other, late, line])?.place, "Usaquen")
        XCTAssertNil(PlaceLine.place(of: entry, in: [other, late]))
    }

    func testEntriesSeparateWordsFromPhotos() throws {
        let line = "## Ideas\n\n- 12:30 la pizarra ![](.2026-10-31/IMG-1.jpg) ![foto](.2026-10-31/IMG-2.jpg)\n"
        let entry = try XCTUnwrap(Journal.entries(in: line, path: "Journal/2026-10-31.md").first)
        XCTAssertEqual(entry.images, [".2026-10-31/IMG-1.jpg", ".2026-10-31/IMG-2.jpg"])
        XCTAssertEqual(entry.words, "la pizarra")
    }

    func testAPhotoAloneMakesAnEntry() throws {
        let entry = try XCTUnwrap(Journal.entries(in: "## Ideas\n\n- 12:30 ![](.d/IMG.jpg)\n", path: "Journal/2026-10-31.md").first)
        XCTAssertEqual(entry.images, [".d/IMG.jpg"])
        XCTAssertEqual(entry.words, "")
    }

    func testPrivateEntriesReadTheirFileName() throws {
        let entry = try XCTUnwrap(Journal.privateEntry(path: "Journal/2026-10-31-22-14-idea.md.age"))
        XCTAssertEqual(entry.day, "2026-10-31")
        XCTAssertEqual(entry.time, "22:14")
        XCTAssertEqual(entry.kind, "idea")
        XCTAssertNil(Journal.privateEntry(path: "Journal/2026-10-31.md"))
        XCTAssertNil(Journal.privateEntry(path: "Journal/Diary.md.age"))
        XCTAssertNil(Journal.privateEntry(path: "Other/2026-10-31-22-14-idea.md.age"))
    }
}
