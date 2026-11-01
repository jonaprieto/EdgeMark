import XCTest
@testable import EdgeJournalLogic

final class SleepTextTests: XCTestCase {
    private func check(_ sentence: String, _ line: String?, file: StaticString = #filePath, at number: UInt = #line) {
        XCTAssertEqual(Sleep.parse(sentence)?.line, line, sentence, file: file, line: number)
    }

    func testSpanish() {
        check("dormí de 11 a 7, regular", "- 23:00-07:00 8h regular")
        check("dormi de 11:30 a 6:45 bien", "- 23:30-06:45 7h15 bien")
        check("me acosté a las 12 y me levanté a las 8", "- 00:00-08:00 8h")
        check("de 1 a 9 mal", "- 01:00-09:00 8h mal")
        check("8 horas", "- 8h")
        check("7 horas y media, cansado", "- 7h30 cansado")
        check("7h30 mal", "- 7h30 mal")
    }

    func testEnglish() {
        check("slept 11 to 7 good", "- 23:00-07:00 8h good")
        check("11:30pm to 6am", "- 23:30-06:00 6h30")
        check("slept 8 hours", "- 8h")
        check("6.5 hours rough night", "- 6h30 rough night")
    }

    func testTwentyFourHourClock() {
        check("23:15 07:05", "- 23:15-07:05 7h50")
    }

    func testNothingToRead() {
        XCTAssertNil(Sleep.parse("dormí fatal"))
        XCTAssertNil(Sleep.parse("de 7am a 7am"))
        XCTAssertNil(Sleep.parse("99 horas"))
    }

    func testAnEarlyBedtimeWithPMIsKept() {
        check("9pm a 5am", "- 21:00-05:00 8h")
    }

    func testEntriesReadBackWhatLinesWrote() {
        let text = "# Day\n\n## Sleep\n\n- 23:00-07:00 8h regular\n- 1h30 siesta\n\n## Ideas\n\n- 09:00 8h is not sleep\n"
        XCTAssertEqual(Sleep.entries(in: text), [
            Sleep(bed: "23:00", wake: "07:00", minutes: 480, note: "regular"),
            Sleep(bed: nil, wake: nil, minutes: 90, note: "siesta"),
        ])
    }

    func testAverage() {
        XCTAssertNil(Sleep.average([]))
        let nights = [Sleep(bed: nil, wake: nil, minutes: 480, note: ""), Sleep(bed: nil, wake: nil, minutes: 420, note: "")]
        XCTAssertEqual(Sleep.average(nights), 450)
    }

    func testSleepComesFirstInTheDay() {
        let text = Journal.appending("- 8h", under: .sleep, to: "# Day\n\n## Meals\n\n- 08:00 a\n")
        XCTAssertEqual(text, "# Day\n\n## Sleep\n\n- 8h\n\n## Meals\n\n- 08:00 a\n")
    }
}
