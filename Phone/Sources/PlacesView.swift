import CoreLocation
import EdgeJournalLogic
import MapKit
import SwiftUI

/// All that has a place, latest first: ideas and meals where they were written, meetings where
/// they happen, reminders where they were set, and any other note where it was finished.
struct PlacesView: View {
    private enum Kind {
        case idea, meal, meeting, reminder, note

        var icon: String {
            switch self {
            case .idea: "lightbulb"
            case .meal: "fork.knife"
            case .meeting: "person.2"
            case .reminder: "bell"
            case .note: "doc.text"
            }
        }

        var tint: Color {
            switch self {
            case .idea: .yellow
            case .meal: .orange
            case .meeting: .blue
            case .reminder: .red
            case .note: .gray
            }
        }
    }

    private struct Pin: Identifiable {
        let id: String
        let kind: Kind
        let title: String
        /// `2026-10-31T15:30`, which also sorts them.
        let when: String
        let place: String?
        let coordinate: CLLocationCoordinate2D
        /// Nil for a calendar event with no note yet.
        let path: String?
    }

    /// Where each meeting's place turned up, by its words.
    @State private var found: [String: CLLocationCoordinate2D] = [:]

    private var model: PhoneModel { .shared }

    private var meetingPlaces: [String] {
        Set(model.meetings.compactMap(\.place)).filter { !$0.isEmpty && !Meeting.isOnline($0) }.sorted()
    }

    private var pins: [Pin] {
        var pins: [Pin] = []
        // A line that a pin here tells more about gets no pin of its own below.
        var told = Set<String>()
        func add(_ kind: Kind, _ id: String, _ title: String, _ when: String, _ line: PlaceLine) {
            told.insert(line.id)
            pins.append(Pin(id: "\(kind) \(id)", kind: kind, title: title, when: when, place: line.place, coordinate: coordinate(of: line), path: line.path))
        }
        for (kind, journal) in [(Kind.idea, Journal.Kind.idea), (.meal, .meal)] {
            for (entry, line) in model.entries(journal) {
                guard let line else { continue }
                add(kind, entry.id, entry.words.isEmpty ? "Photo" : entry.words, "\(entry.day)T\(entry.time)", line)
            }
        }
        for reminder in model.reminders {
            guard let line = PlaceLine.place(ofTodo: reminder.raw == nil ? nil : reminder.title, path: reminder.path, in: model.places) else { continue }
            add(.reminder, reminder.id, reminder.title, Journal.stamp(reminder.date), line)
        }
        for meeting in model.meetings {
            guard let place = meeting.place, let coordinate = found[place] else { continue }
            let when = meeting.start.map { Journal.stamp($0) } ?? meeting.day
            pins.append(Pin(id: "meeting \(meeting.id)", kind: .meeting, title: meeting.name, when: when, place: place, coordinate: coordinate, path: meeting.path))
        }
        for line in model.places where !told.contains(line.id) {
            let kind: Kind = line.path.hasPrefix("\(Meeting.folder)/") ? .meeting : .note
            let title = line.todo ?? model.note(line.path)?.title ?? line.path
            pins.append(Pin(id: "note \(line.id)", kind: kind, title: title, when: String(line.at.prefix(16)), place: line.place, coordinate: coordinate(of: line), path: line.path))
        }
        return pins.sorted { $0.when > $1.when }
    }

    var body: some View {
        let pins = pins
        VStack(spacing: 0) {
            Map {
                ForEach(pins) { pin in
                    Marker(pin.title, systemImage: pin.kind.icon, coordinate: pin.coordinate).tint(pin.kind.tint)
                }
            }
            .frame(minHeight: 280)
            List(pins) { pin in
                if let path = pin.path {
                    NavigationLink(value: Route.note(path)) { row(pin) }
                } else {
                    row(pin)
                }
            }
            .themedBackground()
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: meetingPlaces) {
            let center = model.places.last.map(coordinate(of:))
            for place in meetingPlaces where found[place] == nil {
                found[place] = await PositionLog.find(place, near: center)
            }
        }
    }

    private func row(_ pin: Pin) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(pin.title).lineLimit(1)
                Text("\(pin.when.replacingOccurrences(of: "T", with: " ")) \(pin.place ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: pin.kind.icon).foregroundStyle(pin.kind.tint)
        }
    }

    private func coordinate(of line: PlaceLine) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: line.lat, longitude: line.lon)
    }
}
