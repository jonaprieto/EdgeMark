import XCTest
@testable import EdgeJournalLogic

final class MeetingTextTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Bogota")!
        return c
    }()

    /// Saturday 2026-10-31 12:30 in Bogota.
    private let now = Date(timeIntervalSince1970: 1_793_467_800)

    private func check(_ sentence: String, _ name: String, _ when: String?, line: UInt = #line) {
        let parsed = MeetingText.parse(sentence, now: now, calendar: calendar)
        XCTAssertEqual(parsed.name, name, sentence, line: line)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = parsed.hasTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        XCTAssertEqual(parsed.date.map(formatter.string(from:)), when, sentence, line: line)
    }

    private func checkReminder(_ sentence: String, _ text: String, _ when: String, line: UInt = #line) throws {
        let found = try XCTUnwrap(MeetingText.reminder(sentence, now: now, calendar: calendar), sentence, line: line)
        XCTAssertEqual(found.text, text, sentence, line: line)
        XCTAssertEqual(Journal.stamp(found.date, calendar: calendar), when, sentence, line: line)
    }

    func testReminders() throws {
        try checkReminder("recuérdame mañana a las 3 llamar a mamá", "Llamar a mamá", "2026-11-01T15:00")
        try checkReminder("remind me to call Ana at Google tomorrow at 10am", "Call Ana at Google", "2026-11-01T10:00")
        try checkReminder("pagar el arriendo el 15", "Pagar el arriendo", "2026-11-15T09:00")
        XCTAssertNil(MeetingText.reminder("llamar a mamá", now: now, calendar: calendar))
        XCTAssertNil(MeetingText.reminder("mañana 3pm", now: now, calendar: calendar))
    }

    func testSpanish() {
        check("Felipe martes 3pm", "Felipe", "2026-11-03 15:00")
        check("Reunion con Felipe el martes a las 3", "Reunion con Felipe", "2026-11-03 15:00")
        check("mañana a las 10 dentista", "Dentista", "2026-11-01 10:00")
        check("manana 10am dentista", "Dentista", "2026-11-01 10:00")
        check("pasado mañana 8:30 demo", "Demo", "2026-11-02 08:30")
        check("hoy 6pm llamada con Ana", "Llamada con Ana", "2026-10-31 18:00")
        check("revisión del paper el 12 a las 9 de la mañana", "Revisión del paper", "2026-11-12 09:00")
        check("comité 5 de noviembre 15:30", "Comité", "2026-11-05 15:30")
        check("Ana el viernes a las 4 y media de la tarde", "Ana", "2026-11-06 16:30")
        check("miércoles en la tarde con Juan", "Con Juan", "2026-11-04")
        check("standup el lunes que viene 9h", "Standup", "2026-11-02 09:00")
    }

    func testEnglish() {
        check("call with Ana next monday at 2pm", "Call with Ana", "2026-11-02 14:00")
        check("tomorrow 9:30am standup", "Standup", "2026-11-01 09:30")
        check("Review nov 5 at 3 pm", "Review", "2026-11-05 15:00")
    }

    func testNumericDates() {
        check("2026-11-03 14:00 comité", "Comité", "2026-11-03 14:00")
        check("5/11 3pm Ana", "Ana", "2026-11-05 15:00")
    }

    func testTodaysWeekdayMeansNextWeek() {
        check("sábado almuerzo", "Almuerzo", "2026-11-07")
    }

    func testATimeWithNoDayIsTheNextOneToCome() {
        check("Felipe 4pm", "Felipe", "2026-10-31 16:00")
        check("Felipe 10am", "Felipe", "2026-11-01 10:00")
    }

    func testAPastDateMeansNextYear() {
        check("renovar 3 de marzo", "Renovar", "2027-03-03")
    }

    func testNoDayOrTimeLeavesTheName() {
        check("planear el viaje", "Planear el viaje", nil)
    }

    func testAPlaceIsACapitalizedNameAfterEnOrAt() {
        let parse = { (text: String) in MeetingText.parse(text, now: self.now, calendar: self.calendar) }
        XCTAssertEqual(parse("Felipe martes 3pm en Juan Valdez").place, "Juan Valdez")
        XCTAssertEqual(parse("Felipe martes 3pm en Juan Valdez").name, "Felipe")
        XCTAssertEqual(parse("Coffee with Ana at Blue Bottle tomorrow 9am").place, "Blue Bottle")
        XCTAssertEqual(parse("Coffee with Ana at Blue Bottle tomorrow 9am").name, "Coffee with Ana")
        XCTAssertNil(parse("revisar en la oficina mañana").place)
        XCTAssertNil(parse("Felipe martes a las 3 en la tarde").place)
    }

    func testNumbersInANameStay() {
        check("revisar PR 708 mañana", "Revisar PR 708", "2026-11-01")
    }
}
