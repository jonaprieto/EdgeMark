@testable import EdgeReminderLogic
import XCTest

final class ReminderLogicTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testTonightIsOfferedUntilSeven() {
        XCTAssertTrue(ReminderOption.available(now: date(2026, 10, 16, 18, 59), calendar: calendar).contains(.tonight))
        XCTAssertFalse(ReminderOption.available(now: date(2026, 10, 16, 19, 0), calendar: calendar).contains(.tonight))
    }

    func testOneShotTimes() {
        let friday = date(2026, 10, 16, 10, 15)
        XCTAssertEqual(ReminderOption.in3h.triggers(now: friday, calendar: calendar).first?.hour, 13)
        XCTAssertEqual(ReminderOption.tonight.triggers(now: friday, calendar: calendar).first?.hour, 20)
        let morning = ReminderOption.tomorrowMorning.triggers(now: friday, calendar: calendar).first
        XCTAssertEqual([morning?.day, morning?.hour], [17, 9])
    }

    func testOneHourAcrossTheSpringForwardChange() {
        // 2026-03-29 02:00 does not exist in Madrid, so 01:30 plus an hour is 03:30.
        let trigger = ReminderOption.in1h.triggers(now: date(2026, 3, 29, 1, 30), calendar: calendar).first
        XCTAssertEqual([trigger?.hour, trigger?.minute], [3, 30])
    }

    func testWeekdaysRepeatMondayToFriday() {
        let triggers = ReminderOption.everyWeekday.triggers(now: date(2026, 10, 16, 10, 0), calendar: calendar)
        XCTAssertEqual(triggers.map(\.weekday), [2, 3, 4, 5, 6])
        XCTAssertEqual(Set(triggers.map(\.hour)), [9])
        XCTAssertTrue(ReminderOption.everyWeekday.repeats)
        XCTAssertFalse(ReminderOption.in1h.repeats)
    }

    func testCustomDateKeepsItsLocalTime() {
        let trigger = ReminderOption.trigger(at: date(2026, 12, 24, 18, 45), calendar: calendar)
        XCTAssertEqual([trigger.year, trigger.month, trigger.day, trigger.hour, trigger.minute], [2026, 12, 24, 18, 45])
    }

    func testRequestOffersOnlyShownOptionsPlusNone() throws {
        let body = try ReminderSuggestion.requestBody(
            title: "Visa", text: String(repeating: "a", count: 5000), now: "Friday 18:40", options: [.in1h, .tomorrowMorning],
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let question = try XCTUnwrap((root["questions"] as? [String: Any])?["reminder"] as? [String: Any])
        XCTAssertEqual(question["type"] as? String, "choice")
        let criteria = try XCTUnwrap(question["criteria"] as? [String: Any])
        XCTAssertEqual(Set(criteria.keys), ["in1h", "tomorrowMorning", "none"])
        let note = try XCTUnwrap((root["state"] as? [String: Any])?["note"] as? [String: Any])
        XCTAssertEqual((note["text"] as? String)?.count, 4000)
    }

    private func answer(_ choice: String, _ probability: Double) -> Data {
        Data(#"{"answers":{"reminder":{"type":"choice","choice":"\#(choice)","confidence":0.5,"probabilities":{"\#(choice)":\#(probability)}}}}"#.utf8)
    }

    func testParseNeedsAnOfferedConfidentChoice() {
        XCTAssertEqual(ReminderSuggestion.parse(answer("tonight", 0.7), options: [.tonight]), .tonight)
        XCTAssertNil(ReminderSuggestion.parse(answer("tonight", 0.4), options: [.tonight]))
        XCTAssertNil(ReminderSuggestion.parse(answer("none", 0.9), options: [.tonight]))
        XCTAssertNil(ReminderSuggestion.parse(answer("tonight", 0.9), options: [.in1h]))
        XCTAssertNil(ReminderSuggestion.parse(Data("{}".utf8), options: [.in1h]))
    }
}
