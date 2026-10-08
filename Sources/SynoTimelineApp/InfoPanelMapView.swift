import MapKit
import SwiftUI
import TimelineCore

/// A small non-interactive pin map for the info panel.
struct InfoPanelMapView: View {
    let pins: [InfoPanelPin]

    var body: some View {
        if !pins.isEmpty {
            Map(initialPosition: .region(region), interactionModes: []) {
                ForEach(pins, id: \.id) { pin in
                    Marker("", coordinate: CLLocationCoordinate2D(latitude: pin.coordinate.latitude,
                                                                  longitude: pin.coordinate.longitude))
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Map with \(pins.count) location\(pins.count == 1 ? "" : "s")")
        }
    }

    private var region: MKCoordinateRegion {
        if pins.count == 1, let pin = pins.first {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: pin.coordinate.latitude,
                                               longitude: pin.coordinate.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        }
        var minimumLatitude = 90.0
        var maximumLatitude = -90.0
        var minimumLongitude = 180.0
        var maximumLongitude = -180.0
        for pin in pins {
            minimumLatitude = min(minimumLatitude, pin.coordinate.latitude)
            maximumLatitude = max(maximumLatitude, pin.coordinate.latitude)
            minimumLongitude = min(minimumLongitude, pin.coordinate.longitude)
            maximumLongitude = max(maximumLongitude, pin.coordinate.longitude)
        }
        let latitudeDelta = max((maximumLatitude - minimumLatitude) * 1.4, 0.01)
        let longitudeDelta = max((maximumLongitude - minimumLongitude) * 1.4, 0.01)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minimumLatitude + maximumLatitude) / 2,
                                           longitude: (minimumLongitude + maximumLongitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
    }
}
