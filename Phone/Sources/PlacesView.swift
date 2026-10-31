import CoreLocation
import EdgeJournalLogic
import MapKit
import SwiftUI

/// Where notes were finished, newest first.
struct PlacesView: View {
    private var model: PhoneModel { .shared }
    private var places: [PlaceLine] { model.places.reversed() }

    var body: some View {
        VStack(spacing: 0) {
            Map {
                ForEach(places) { place in
                    Marker(place.place ?? place.path, coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon))
                }
            }
            .frame(minHeight: 280)
            List(places) { place in
                NavigationLink(value: Route.note(place.path)) {
                    VStack(alignment: .leading) {
                        Text(model.note(place.path)?.title ?? place.path).lineLimit(1)
                        Text("\(place.at.prefix(16).replacingOccurrences(of: "T", with: " ")) \(place.place ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
    }
}
