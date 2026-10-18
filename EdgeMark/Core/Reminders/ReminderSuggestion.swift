import Foundation

/// Asks Jev which of the offered reminders fits a note: one typed choice, with `none`
/// when nothing in the note says when to come back to it.
enum ReminderSuggestion {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    /// Probability the choice needs before it is marked; a starting point to tune on real notes.
    static let threshold = 0.5
    static let maxChars = 4000

    static let instructions = "The user wants a reminder to come back to the note in `note` (its `note.title` and `note.text`). It is now `now`, local time. Which reminder fits the note best?"
    static let criteria: [ReminderOption: String] = [
        .in1h: "In one hour: something to pick up again very soon, today.",
        .in3h: "In three hours: later today, still during the working day.",
        .tonight: "Tonight at 8 PM: personal or after-work things for this evening.",
        .tomorrowMorning: "Tomorrow at 9 AM: a task, errand or reading for the next day.",
        .everyWeekday: "Every weekday at 9 AM: a recurring routine, checklist, standup or habit.",
    ]
    static let none = "None: nothing in the note hints at when to come back to it."

    static func requestBody(title: String, text: String, now: String, options: [ReminderOption]) throws -> Data {
        var choices: [String: String] = ["none": none]
        for option in options {
            choices[option.rawValue] = criteria[option]
        }
        let body: [String: Any] = [
            "state": ["note": ["title": title, "text": String(text.prefix(maxChars))], "now": now],
            "model": "jev-latest",
            "questions": ["reminder": ["type": "choice", "instructions": instructions, "criteria": choices]],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The offered option Jev chose with at least `threshold` probability, else nil.
    static func parse(_ data: Data, options: [ReminderOption]) -> ReminderOption? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = (root["answers"] as? [String: Any])?["reminder"] as? [String: Any],
              let choice = answer["choice"] as? String,
              let option = ReminderOption(rawValue: choice), options.contains(option),
              let probability = (answer["probabilities"] as? [String: Any])?[choice] as? Double,
              probability >= threshold
        else { return nil }
        return option
    }

    /// "Friday 18:40".
    static func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE HH:mm"
        return formatter.string(from: date)
    }

    /// Jev's pick, or nil without a key, on any error, or when nothing fits.
    static func suggest(title: String, text: String, now: Date, options: [ReminderOption], apiKey: String?) async -> ReminderOption? {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let body = try? requestBody(title: title, text: text, now: describe(now), options: options)
        else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return parse(data, options: options)
    }
}
