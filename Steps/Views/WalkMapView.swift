import SwiftUI
import MapKit

struct WalkMapView: View {
    let day: WalkDay
    let focus: TrackPoint?

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        let walked = day.highlightedCoordinates(upTo: focus)
        let rest = day.remainingCoordinates(after: focus)
        let path = focus == nil ? day.points.map(\.coordinate) : []

        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            if walked.count >= 2 {
                MapPolyline(Self.mkPolyline(walked))
                    .stroke(Palette.path, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            } else if path.count >= 2 {
                MapPolyline(Self.mkPolyline(path))
                    .stroke(Palette.path, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if rest.count >= 2 {
                MapPolyline(Self.mkPolyline(rest))
                    .stroke(Palette.pathRest, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
            if let focus {
                Annotation("You", coordinate: focus.coordinate, anchor: .center) {
                    PositionMarker()
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapCompass()
                .mapControlVisibility(.hidden)
        }
        .onAppear(perform: fit)
        .onChange(of: day.points.count) { _, _ in
            fit()
        }
    }

    private func fit() {
        let coords = day.points.map(\.coordinate)
        guard let region = Self.region(for: coords) else {
            camera = .automatic
            return
        }
        camera = .region(region)
    }

    private static func mkPolyline(_ coordinates: [CLLocationCoordinate2D]) -> MKPolyline {
        var copy = coordinates
        return MKPolyline(coordinates: &copy, count: copy.count)
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.55, 0.006),
            longitudeDelta: max((maxLon - minLon) * 1.55, 0.006)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

private struct PositionMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 34, height: 34)
            Circle()
                .fill(Color.white)
                .frame(width: 20, height: 20)
            Circle()
                .fill(Palette.marker)
                .frame(width: 13, height: 13)
        }
        .shadow(color: Palette.marker.opacity(0.45), radius: 6)
        .accessibilityHidden(true)
    }
}
