import MapKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

@MainActor
final class MapBrowserModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case building(scanned: Int, total: Int?)
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var groups: [MapClusterGroup] = []
    @Published private(set) var locatedCount = 0
    @Published var camera: MapCameraPosition = .automatic
    @Published private(set) var records: [MapPhotoRecord] = []
    @Published private(set) var thumbnailsByID: [Int64: ThumbnailInfo] = [:]

    /// Minimum on-screen distance between pins, in points.
    private static let pinPitch: CGFloat = 52

    private var repository: CachedPhotosRepository?
    private var indexTask: Task<Void, Never>?
    private var reclusterTask: Task<Void, Never>?
    private var recordIndices: [Int64: Int] = [:]
    private var currentRegion: MKCoordinateRegion?
    private var currentCamera: MapCamera?
    private var viewSize: CGSize = .zero
    private var hasFitInitialCamera = false

    /// Subscribes to the shared location index once. Later calls are ignored unless
    /// `retry()` reset the subscription after a failure.
    func start(repository: CachedPhotosRepository?) {
        if let repository { self.repository = repository }
        guard indexTask == nil, let repository = self.repository else { return }
        indexTask = Task { [weak self] in
            for await event in await repository.locationIndex() {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    func retry() {
        indexTask?.cancel()
        indexTask = nil
        status = .idle
        start(repository: repository)
    }

    /// Debounced recluster for a user-driven camera change. The full camera is kept
    /// so the map reopens at the same position, zoom, rotation, and pitch after a
    /// filtered collection closes.
    func cameraChanged(to region: MKCoordinateRegion, camera mapCamera: MapCamera, viewSize: CGSize) {
        guard region.center.latitude.isFinite, region.center.longitude.isFinite,
              region.span.latitudeDelta.isFinite, region.span.longitudeDelta.isFinite,
              region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else { return }
        self.viewSize = viewSize
        currentRegion = region
        if !Self.isApproximatelyEqual(mapCamera, currentCamera) {
            currentCamera = mapCamera
            camera = .camera(mapCamera)
        }
        scheduleRecluster(region: Self.mapRegion(from: region),
                          minimumCellSpan: minimumCellSpan(for: region),
                          delay: .milliseconds(120))
    }

    /// A window resize changes the on-screen radius without a camera change.
    func viewSizeChanged(to size: CGSize) {
        viewSize = size
        guard let region = currentRegion else { return }
        scheduleRecluster(region: Self.mapRegion(from: region),
                          minimumCellSpan: minimumCellSpan(for: region),
                          delay: .milliseconds(120))
    }

    /// The records behind a pin's member IDs, preserving the requested order.
    func records(for ids: [Int64]) -> [MapPhotoRecord] {
        ids.compactMap { id in recordIndices[id].map { records[$0] } }
    }

    func thumbnail(for record: MapPhotoRecord) -> ThumbnailInfo? {
        thumbnailsByID[record.id]
    }

    private func receive(_ event: LocationIndexEvent) {
        switch event {
        case .cached(let locationRecords):
            apply(locationRecords)
            status = .ready
        case .progress(let scanned, let total):
            status = .building(scanned: scanned, total: total)
        case .completed(let locationRecords, _):
            apply(locationRecords)
            status = .ready
        case .failure(let message):
            status = .failed(message)
        }
    }

    private func apply(_ locationRecords: [PhotoLocationRecord]) {
        let mapped = locationRecords.map {
            MapPhotoRecord(id: $0.id, time: $0.time, coordinate: $0.coordinate)
        }
        records = mapped
        locatedCount = mapped.count
        thumbnailsByID = Dictionary(locationRecords.compactMap { record in
            record.thumbnail.map { (record.id, $0) }
        }, uniquingKeysWith: { _, last in last })
        recordIndices = Dictionary(mapped.enumerated().map {
            ($0.element.id, $0.offset)
        }, uniquingKeysWith: { _, last in last })
        guard !mapped.isEmpty else {
            groups = []
            return
        }
        if !hasFitInitialCamera {
            hasFitInitialCamera = true
            let region = Self.boundingRegion(for: mapped)
            currentRegion = region
            camera = .region(region)
            scheduleRecluster(region: Self.mapRegion(from: region),
                              minimumCellSpan: minimumCellSpan(for: region), delay: .zero)
        } else if let currentRegion {
            scheduleRecluster(region: Self.mapRegion(from: currentRegion),
                              minimumCellSpan: minimumCellSpan(for: currentRegion), delay: .zero)
        }
    }

    private func scheduleRecluster(region: MapRegion, minimumCellSpan: MapCellSpan?,
                                   delay: Duration) {
        reclusterTask?.cancel()
        let snapshot = records
        guard !snapshot.isEmpty else {
            groups = []
            return
        }
        reclusterTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let computed = await Task.detached(priority: .userInitiated) {
                MapClusterBuilder.groups(records: snapshot, in: region, maxAnnotations: 256,
                                         minimumCellSpan: minimumCellSpan)
            }.value
            guard !Task.isCancelled else { return }
            self?.groups = computed
        }
    }

    /// The cluster radius that keeps pins roughly one pin-width apart on screen.
    private func minimumCellSpan(for region: MKCoordinateRegion) -> MapCellSpan? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        return MapCellSpan(
            latitude: region.span.latitudeDelta * Double(Self.pinPitch) / Double(viewSize.height),
            longitude: region.span.longitudeDelta * Double(Self.pinPitch) / Double(viewSize.width))
    }

    private static func boundingRegion(for records: [MapPhotoRecord]) -> MKCoordinateRegion {
        var minimumLatitude = 90.0
        var maximumLatitude = -90.0
        var minimumLongitude = 180.0
        var maximumLongitude = -180.0
        for record in records {
            minimumLatitude = min(minimumLatitude, record.coordinate.latitude)
            maximumLatitude = max(maximumLatitude, record.coordinate.latitude)
            minimumLongitude = min(minimumLongitude, record.coordinate.longitude)
            maximumLongitude = max(maximumLongitude, record.coordinate.longitude)
        }
        let latitudeDelta = max((maximumLatitude - minimumLatitude) * 1.2, 0.01)
        let longitudeDelta = max((maximumLongitude - minimumLongitude) * 1.2, 0.01)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minimumLatitude + maximumLatitude) / 2,
                                           longitude: (minimumLongitude + maximumLongitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta))
    }

    private static func mapRegion(from region: MKCoordinateRegion) -> MapRegion {
        MapRegion(center: PhotoCoordinate(latitude: region.center.latitude,
                                          longitude: region.center.longitude),
                  latitudeDelta: region.span.latitudeDelta,
                  longitudeDelta: region.span.longitudeDelta)
    }

    private static func isApproximatelyEqual(_ lhs: MapCamera, _ rhs: MapCamera?) -> Bool {
        guard let rhs else { return false }
        return abs(lhs.centerCoordinate.latitude - rhs.centerCoordinate.latitude) < 1e-9
            && abs(lhs.centerCoordinate.longitude - rhs.centerCoordinate.longitude) < 1e-9
            && abs(lhs.distance - rhs.distance) < 0.5
            && abs(lhs.heading - rhs.heading) < 0.1
            && abs(lhs.pitch - rhs.pitch) < 0.1
    }
}
