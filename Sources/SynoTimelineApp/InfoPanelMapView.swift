import MapKit
import SwiftUI
import TimelineCore

/// A small interactive pin map for the info panel.
struct InfoPanelMapView: View {
    let pins: [InfoPanelPin]

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        if !pins.isEmpty {
            Map(position: $position, interactionModes: .all) {
                ForEach(pins, id: \.id) { pin in
                    Marker("", coordinate: CLLocationCoordinate2D(latitude: pin.coordinate.latitude,
                                                                  longitude: pin.coordinate.longitude))
                }
            }
            .onChange(of: pins, initial: true) { _, pins in
                // A user pan changes the binding. A new selection must frame its
                // own annotations again, even when the pin count stays the same.
                if let first = pins.first,
                   pins.allSatisfy({ $0.coordinate == first.coordinate }) {
                    position = .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: first.coordinate.latitude,
                                                       longitude: first.coordinate.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))
                } else {
                    // MapKit fits annotation content to the actual viewport,
                    // including marker height and widely separated locations.
                    position = .automatic
                }
            }
            // Keeps automatically framed markers clear of the edges and the Legal label.
            .safeAreaPadding(.horizontal, 18)
            .safeAreaPadding(.vertical, 14)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Map with \(pins.count) location\(pins.count == 1 ? "" : "s")")
        }
    }
}
