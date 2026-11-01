import XCTest
@testable import EdgeJournalLogic

final class TodoScanTests: XCTestCase {
    private func scan(_ text: String) -> [Todo] {
        TodoScan.todos(in: text, path: "n.md")
    }

    func testFindsOpenAndDoneLines() {
        let todos = scan("# Note\n- [ ] one\n  * [x] two\n+ [X] three\n- not a task\n- [] no\n- [ ]no space\n")
        XCTAssertEqual(todos.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(todos.map(\.done), [false, true, true])
        XCTAssertEqual(todos.map(\.line), [1, 2, 3])
    }

    func testSkipsCodeFences() {
        XCTAssertEqual(scan("```\n- [ ] code\n```\n- [ ] real\n~~~\n- [ ] more\n").map(\.text), ["real"])
    }

    func testReadsTheDueTag() {
        let todo = scan("- [ ] call the bank due:2026-11-02\n")[0]
        XCTAssertEqual(todo.text, "call the bank")
        XCTAssertEqual(todo.due, "2026-11-02")
        XCTAssertNil(scan("- [ ] pay due:soon\n")[0].due)
    }

    func testGroupsAndOrder() {
        let todos = scan("- [ ] u\n- [ ] later due:2026-12-01\n- [ ] soon due:2026-11-05\n- [ ] now due:2026-10-31\n- [ ] late due:2026-10-01\n")
        XCTAssertEqual(TodoScan.sorted(todos, today: "2026-10-31").map(\.text), ["late", "now", "soon", "later", "u"])
        XCTAssertEqual(todos.map { TodoScan.group($0, today: "2026-10-31") }, [.undated, .dated, .dated, .today, .overdue])
    }

    func testToggleFlipsOnlyThatLine() throws {
        let text = "- [ ] a\n- [ ] a [ ] b\n- [x] c\n"
        let todos = scan(text)
        XCTAssertEqual(TodoScan.toggled(todos[1], in: text), "- [ ] a\n- [x] a [ ] b\n- [x] c\n")
        XCTAssertEqual(TodoScan.toggled(todos[2], in: text), "- [ ] a\n- [ ] a [ ] b\n- [ ] c\n")
    }

    func testToggleRefusesAChangedLine() {
        let todo = scan("- [ ] a\n")[0]
        XCTAssertNil(TodoScan.toggled(todo, in: "- [ ] edited\n"))
        XCTAssertNil(TodoScan.toggled(todo, in: ""))
    }

    func testSettingDue() {
        let text = "- [ ] a due:2026-01-01\n"
        let todo = scan(text)[0]
        XCTAssertEqual(TodoScan.settingDue("2026-02-02", on: todo, in: text), "- [ ] a due:2026-02-02\n")
        XCTAssertEqual(TodoScan.settingDue(nil, on: todo, in: text), "- [ ] a\n")
    }

    func testMeetingTitleParsing() throws {
        let parsed = try XCTUnwrap(Meeting.parse(title: "2026-11-03 Felipe y Ana"))
        XCTAssertEqual(parsed.day, "2026-11-03")
        XCTAssertEqual(parsed.name, "Felipe y Ana")
        XCTAssertNil(Meeting.parse(title: "Felipe 2026-11-03"))
    }

    func testMeetingRowsJoinEventsAndNotes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        let start = Date(timeIntervalSince1970: 1_793_467_800) // 2026-10-31 12:30 in Bogota
        let rows = Meeting.rows(
            events: [Meeting.Event(name: "Felipe", start: start)],
            notes: [
                (path: "Meetings/2026-10-31-Felipe.md", title: "2026-10-31 Felipe", time: nil, place: nil),
                (path: "Meetings/2026-11-03-Ana.md", title: "2026-11-03 Ana", time: "15:30", place: "Juan Valdez"),
                (path: "Meetings/2026-01-01-Old.md", title: "2026-01-01 Old", time: nil, place: nil),
                (path: "Meetings/Notes.md", title: "Notes", time: nil, place: nil),
            ],
            today: "2026-10-31",
            calendar: calendar,
        )
        XCTAssertEqual(rows.map(\.title), ["2026-10-31 Felipe", "2026-11-03 Ana"])
        XCTAssertEqual(rows[0].path, "Meetings/2026-10-31-Felipe.md")
        XCTAssertEqual(rows[0].start, start)
        XCTAssertEqual(rows[1].start, start.addingTimeInterval(3 * 86400 + 3 * 3600))
        XCTAssertEqual(rows[1].place, "Juan Valdez")
    }

    func testMeetingDayReadsBack() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        let date = try XCTUnwrap(Meeting.date(day: "2026-11-03", calendar: calendar))
        XCTAssertEqual(Journal.day(date, calendar: calendar), "2026-11-03")
        XCTAssertEqual(calendar.component(.weekday, from: date), 3) // Tuesday
    }

    func testMeetingNoteKeepsItsPlaceAndNote() {
        let body = Meeting.body(time: "15:30", place: "Juan Valdez", note: " traer el borrador ")
        XCTAssertEqual(body, "Time: 15:30\nPlace: Juan Valdez\n\ntraer el borrador\n\n## Ideas\n\n")
        let note = "# 2026-11-03 Ana\n\n" + body
        XCTAssertEqual(Meeting.time(inNote: note), "15:30")
        XCTAssertEqual(Meeting.place(inNote: note), "Juan Valdez")
        XCTAssertEqual(Meeting.body(time: nil, place: "", note: ""), "## Ideas\n\n")
    }

    func testMeetingNoteKeepsItsTime() {
        XCTAssertEqual(Meeting.time(inNote: "# 2026-11-03 Ana\n\n" + Meeting.body(time: "15:30")), "15:30")
        XCTAssertNil(Meeting.time(inNote: "# 2026-11-03 Ana\n\n" + Meeting.body(time: nil)))
        XCTAssertNil(Meeting.time(inNote: "# A\n\nTime: soon\n"))
    }

    func testSegmentsCutTheNoteAroundItsTasks() {
        let text = "# Note\n\nintro\n\n- [ ] one\n  - [x] two\n\nafter\n\n```\n- [ ] in code\n```\n"
        let segments = TodoScan.segments(of: text, path: "n.md")
        XCTAssertEqual(segments.count, 4)
        guard case let .text(first) = segments[0], case let .task(one) = segments[1], case let .task(two) = segments[2], case let .text(last) = segments[3] else {
            return XCTFail("unexpected shape")
        }
        XCTAssertEqual(first, "# Note\n\nintro\n")
        XCTAssertEqual(one.text, "one")
        XCTAssertEqual(two.line, 5)
        XCTAssertTrue(two.done)
        XCTAssertTrue(last.contains("- [ ] in code"))
    }

    func testANoteWithoutTasksIsOneSegment() {
        XCTAssertEqual(TodoScan.segments(of: "# Note\n\nbody\n", path: "n.md"), [.text("# Note\n\nbody\n")])
    }

    func testMeetingBuckets() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        calendar.firstWeekday = 2 // Monday
        // Wednesday 2026-11-04 at noon in Bogota.
        let now = Date(timeIntervalSince1970: 1_793_811_600)
        XCTAssertEqual(Journal.day(now, calendar: calendar), "2026-11-04")
        let expected: [(String, Meeting.Bucket)] = [
            ("2026-11-03", .today), ("2026-11-04", .today), ("2026-11-05", .tomorrow), ("2026-11-06", .thisWeek), ("2026-11-08", .thisWeek),
            ("2026-11-09", .nextWeek), ("2026-11-15", .nextWeek), ("2026-11-16", .later), ("2026-12-01", .later),
        ]
        for (day, bucket) in expected {
            XCTAssertEqual(Meeting.bucket(day: day, now: now, calendar: calendar), bucket, day)
        }
    }

    func testTomorrowWinsAtTheEndOfTheWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        calendar.firstWeekday = 2
        // Sunday 2026-11-08 at noon: tomorrow is already next week.
        let now = Date(timeIntervalSince1970: 1_794_157_200)
        XCTAssertEqual(Journal.day(now, calendar: calendar), "2026-11-08")
        XCTAssertEqual(Meeting.bucket(day: "2026-11-09", now: now, calendar: calendar), .tomorrow)
        XCTAssertEqual(Meeting.bucket(day: "2026-11-10", now: now, calendar: calendar), .nextWeek)
    }
}
