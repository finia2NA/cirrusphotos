import MapKit
import PhotoCache
import SwiftUI
import SynologyAPI
import TimelineCore

/// Full-screen Apple Map of geotagged photos in the selected space.
struct MapBrowserView: View {
    @ObservedObject var model: MapBrowserModel
    @EnvironmentObject private var library: LibraryModel
    var contentTopInset: CGFloat = 0
    var space: PhotoSpace
    let onOpenPhoto: (Int64) -> Void
    let onOpenGroup: ([Int64]) -> Void

    var body: some View {
        GeometryReader { proxy in
            Map(position: $model.camera) {
            ForEach(model.groups, id: \.representative.id) { group in
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: group.coordinate.latitude,
                                                                  longitude: group.coordinate.longitude)) {
                    MapClusterPin(group: group,
                                  thumbnail: model.thumbnail(for: group.representative),
                                  repository: library.repository,
                                  collection: PhotoCollectionDescriptor.library(space),
                                  allowNetwork: model.status == .ready) {
                        if group.isSingle {
                            onOpenPhoto(group.representative.id)
                        } else {
                            onOpenGroup(group.memberIDs)
                        }
                    }
                }
            }
        }
            .mapStyle(.standard)
            .onMapCameraChange(frequency: .onEnd) { context in
                model.cameraChanged(to: context.region, camera: context.camera,
                                    viewSize: proxy.size)
            }
            .onChange(of: proxy.size) { _, size in
                model.viewSizeChanged(to: size)
            }
            .overlay { overlays }
            .ignoresSafeArea(.container, edges: .top)
        }
        .task(id: "\(library.repository.map(ObjectIdentifier.init).map(String.init(describing:)) ?? "none"):\(space.rawValue)") {
            model.start(repository: library.repository, space: space)
        }
        .onDisappear { model.stopObservingProjection() }
    }

    @ViewBuilder
    private var overlays: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                statusOverlay
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, contentTopInset + 12)
            .padding(.horizontal, 16)

            if model.records.isEmpty, model.status == .ready {
                ContentUnavailableView("No located photos", systemImage: "mappin.slash",
                                       description: Text("No photos in this space have location data."))
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.status {
        case .idle, .ready:
            EmptyView()
        case .cachedUnverified:
            HStack(spacing: 10) {
                Label("Showing cached locations; changes are not verified.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                Button("Retry") { model.retry() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 4)
        case .building(let scanned, let total):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(total.map { "Scanning locations… \(scanned) of \($0)" } ?? "Scanning locations…")
                    .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4)
            .accessibilityLabel("Scanning photo locations")
        case .failed(let message):
            HStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .lineLimit(2)
                Button("Retry") { model.retry() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 4)
        }
    }
}

private struct MapClusterPin: View {
    let group: MapClusterGroup
    let thumbnail: ThumbnailInfo?
    let repository: CachedPhotosRepository?
    let collection: PhotoCollectionDescriptor
    let allowNetwork: Bool
    let onTap: () -> Void
    @State private var image: NSImage?

    private var identity: String {
        guard let thumbnail else { return "missing" }
        return "\(collection.rawValue):\(thumbnail.unitID):\(thumbnail.cacheKey):\(allowNetwork)"
    }

    private var clipShape: AnyShape {
        group.isSingle ? AnyShape(RoundedRectangle(cornerRadius: 8)) : AnyShape(Circle())
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .frame(width: 40, height: 40)
                .clipShape(clipShape)
                .overlay(clipShape.stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            if !group.isSingle {
                Text("\(group.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .offset(x: 6, y: 6)
            }
        }
        .overlay(MapPinClickCatcher(isCircular: !group.isSingle) { onTap() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .task(id: identity) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipped()
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var accessibilityLabel: String {
        if group.isSingle {
            return "Photo, \(InfoPanelFormatting.singleDate(group.representative.time))"
        }
        return "\(group.count) photos at this location"
    }

    private func load() async {
        image = nil
        guard let thumbnail, let repository else { return }
        for await event in await repository.thumbnailWithFallback(
            thumbnail, size: .sm, allowNetwork: allowNetwork, collection: collection, priority: .visible
        ) {
            guard !Task.isCancelled else { return }
            guard case .value(let value, _) = event else { continue }
            if let decoded = await DecodedImages.shared.image(from: value.data, maxPixel: 200) {
                guard !Task.isCancelled else { return }
                image = decoded
            }
        }
    }
}
