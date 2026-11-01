import CoreLocation
import EdgeJournalLogic
import MapKit

/// One position fix when a note is finished. No background tracking: a fix that does not come
/// within `limit` is skipped, and saving never waits on it.
@MainActor
final class PositionLog: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let limit: Duration = .seconds(5)

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Where the phone is, with a place name when the network answers in time.
    func fix() async -> (location: CLLocation, place: String?)? {
        guard let location = await locate() else { return nil }
        return (location, await Self.placeName(of: location))
    }

    private func locate() async -> CLLocation? {
        if let last = manager.location, -last.timestamp.timeIntervalSinceNow < 120 { return last }
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        default: break
        }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            Task {
                try? await Task.sleep(for: Self.limit)
                finish(nil)
            }
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        waiting?.resume(returning: location)
        waiting = nil
    }

    /// Finds a place from its words, near `center` if given, or nil rather than somewhere else.
    /// Apple Maps gets the words. The city can pull the search to a street, so it tries without.
    static func find(_ place: String, near center: CLLocationCoordinate2D?) async -> CLLocationCoordinate2D? {
        let head = String(place.prefix { $0 != "," })
        for words in head == place ? [place] : [place, head] {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = words
            if let center { request.region = MKCoordinateRegion(center: center, latitudinalMeters: 50000, longitudinalMeters: 50000) }
            let items = try? await MKLocalSearch(request: request).start().mapItems
            if let item = items?.first(where: { Meeting.isSamePlace($0.name ?? "", as: place) }) { return item.location.coordinate }
        }
        return nil
    }

    private static func placeName(of location: CLLocation) async -> String? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task { @MainActor in
                let items = try? await MKReverseGeocodingRequest(location: location)?.mapItems
                once.resume(items?.first?.address?.shortAddress)
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waiting != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: finish(nil)
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}

/// Resumes its continuation for the first caller and ignores the rest.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }
}
