import Foundation
import CoreLocation
import MapKit

// MARK: - Errors

struct ToolError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

// MARK: - Retry helper (MapKit throttling: MKError.loadingThrottled etc.)

func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch {
        // One retry after a 2s backoff — covers transient throttling
        // (MKError.loadingThrottled, CLGeocoder rate limiting).
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return try await operation()
    }
}

// MARK: - Formatting helpers

func formatAddress(_ placemark: CLPlacemark) -> String {
    var parts: [String] = []
    let street = [placemark.subThoroughfare, placemark.thoroughfare]
        .compactMap { $0 }.joined(separator: " ")
    if !street.isEmpty { parts.append(street) }
    if let locality = placemark.locality { parts.append(locality) }
    let stateZip = [placemark.administrativeArea, placemark.postalCode]
        .compactMap { $0 }.joined(separator: " ")
    if !stateZip.isEmpty { parts.append(stateZip) }
    if let country = placemark.country { parts.append(country) }
    if parts.isEmpty, let name = placemark.name { parts.append(name) }
    return parts.joined(separator: ", ")
}

func formatDistance(_ meters: CLLocationDistance) -> String {
    let km = meters / 1000.0
    let mi = meters / 1609.344
    return String(format: "%.1f km (%.1f mi)", km, mi)
}

func formatCoordinate(_ coordinate: CLLocationCoordinate2D) -> String {
    String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
}

// MARK: - Geocoding

/// Forward-geocode an address string to its best-match placemark.
/// Note: CLGeocoder is rate-limited (~1 request/second); callers that need
/// multiple geocodes should issue them sequentially, which all call sites do.
func geocodeAddress(_ query: String) async throws -> CLPlacemark {
    let placemarks = try await withRetry {
        try await CLGeocoder().geocodeAddressString(query)
    }
    guard let placemark = placemarks.first, placemark.location != nil else {
        throw ToolError("No geocoding result for \"\(query)\"")
    }
    return placemark
}

func reverseGeocode(lat: Double, lon: Double) async throws -> CLPlacemark {
    let location = CLLocation(latitude: lat, longitude: lon)
    let placemarks = try await withRetry {
        try await CLGeocoder().reverseGeocodeLocation(location)
    }
    guard let placemark = placemarks.first else {
        throw ToolError("No reverse-geocoding result for \(lat), \(lon)")
    }
    return placemark
}

func geocodeText(query: String?, lat: Double?, lon: Double?) async throws -> String {
    if let query, !query.isEmpty {
        let pm = try await geocodeAddress(query)
        let coord = pm.location!.coordinate
        return """
        Address: \(formatAddress(pm))
        Coordinates: \(formatCoordinate(coord))
        """
    } else if let lat, let lon {
        let pm = try await reverseGeocode(lat: lat, lon: lon)
        var lines = ["Address: \(formatAddress(pm))"]
        if let name = pm.name { lines.append("Name: \(name)") }
        lines.append("Coordinates: \(formatCoordinate(CLLocationCoordinate2D(latitude: lat, longitude: lon)))")
        return lines.joined(separator: "\n")
    } else {
        throw ToolError("map_geocode requires either \"query\" (address string) or both \"lat\" and \"lon\"")
    }
}

// MARK: - POI search

func searchText(query: String, near: String?, limit: Int) async throws -> String {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.resultTypes = [.pointOfInterest, .address]

    var biasLocation: CLLocation? = nil
    if let near, !near.isEmpty {
        let biasPlacemark = try await geocodeAddress(near)
        let location = biasPlacemark.location!
        biasLocation = location
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 20_000,
            longitudinalMeters: 20_000
        )
    }

    let response = try await withRetry {
        try await MKLocalSearch(request: request).start()
    }

    var items = response.mapItems
    if items.isEmpty {
        throw ToolError("No results for \"\(query)\"")
    }
    if let biasLocation {
        items.sort {
            guard let a = $0.placemark.location, let b = $1.placemark.location else { return false }
            return a.distance(from: biasLocation) < b.distance(from: biasLocation)
        }
    }
    items = Array(items.prefix(max(1, limit)))

    var lines: [String] = []
    for (index, item) in items.enumerated() {
        let name = item.name ?? "(unnamed)"
        lines.append("\(index + 1). \(name)")
        lines.append("   Address: \(formatAddress(item.placemark))")
        lines.append("   Coordinates: \(formatCoordinate(item.placemark.coordinate))")
        if let phone = item.phoneNumber {
            lines.append("   Phone: \(phone)")
        }
        if let url = item.url {
            lines.append("   URL: \(url.absoluteString)")
        }
        if let biasLocation, let location = item.placemark.location {
            lines.append("   Distance: \(formatDistance(location.distance(from: biasLocation))) from \"\(near!)\"")
        }
    }
    return lines.joined(separator: "\n")
}

// MARK: - Place resolution (address or POI name -> MKMapItem)

/// Resolve an address or POI name to a map item. MKLocalSearch handles both
/// street addresses and POI names/abbreviations ("SEA airport"); CLGeocoder
/// only handles addresses (fails POI names with kCLErrorDomain code 8, and
/// mis-resolves abbreviations), so it is only the fallback.
func resolvePlace(_ query: String) async throws -> MKMapItem {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    if let response = try? await withRetry({
        try await MKLocalSearch(request: request).start()
    }), let item = response.mapItems.first {
        return item
    }
    guard let placemark = try? await geocodeAddress(query) else {
        throw ToolError("Could not resolve place \"\(query)\"")
    }
    return MKMapItem(placemark: MKPlacemark(placemark: placemark))
}

func describeMapItem(_ item: MKMapItem) -> String {
    let address = formatAddress(item.placemark)
    if let name = item.name, !address.hasPrefix(name), !name.isEmpty {
        return "\(name), \(address)"
    }
    return address
}

// MARK: - ETA / Directions

func transportType(from string: String) throws -> MKDirectionsTransportType {
    switch string.lowercased() {
    case "driving": return .automobile
    case "walking": return .walking
    case "transit": return .transit
    default: throw ToolError("Unknown transport \"\(string)\" — use driving, walking, or transit")
    }
}

func etaText(from: String, to: String, transport: String) async throws -> String {
    let transportType = try transportType(from: transport)

    // Sequential resolution (CLGeocoder is rate-limited ~1 req/s).
    let fromItem = try await resolvePlace(from)
    let toItem = try await resolvePlace(to)

    let request = MKDirections.Request()
    request.source = fromItem
    request.destination = toItem
    request.transportType = transportType
    request.requestsAlternateRoutes = true

    var header = """
    From: \(describeMapItem(fromItem))
    To: \(describeMapItem(toItem))
    Transport: \(transport.lowercased())
    """

    // Transit supports ETA-only (calculateETA), not full route calculation.
    if transportType == .transit {
        let eta = try await withRetry {
            try await MKDirections(request: request).calculateETA()
        }
        let minutes = Int((eta.expectedTravelTime / 60).rounded())
        header += "\nETA: \(minutes) min"
        header += "\nDistance: \(formatDistance(eta.distance))"
        header += "\n(Transit supports ETA only — no step-by-step route via MapKit.)"
        return header
    }

    let response = try await withRetry {
        try await MKDirections(request: request).calculate()
    }
    let routes = response.routes.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
    guard let best = routes.first else {
        throw ToolError("No route found from \"\(from)\" to \"\(to)\"")
    }

    let minutes = Int((best.expectedTravelTime / 60).rounded())
    var lines = [header]
    lines.append("Best route: \(best.name)")
    var etaLine = "ETA: \(minutes) min"
    if transportType == .automobile {
        etaLine += " (includes current traffic)"
    }
    lines.append(etaLine)
    lines.append("Distance: \(formatDistance(best.distance))")

    let steps = best.steps.filter { !$0.instructions.isEmpty }.prefix(4)
    if !steps.isEmpty {
        lines.append("First steps:")
        for (index, step) in steps.enumerated() {
            lines.append("  \(index + 1). \(step.instructions) (\(formatDistance(step.distance)))")
        }
    }

    let alternatives = routes.dropFirst()
    if !alternatives.isEmpty {
        lines.append("Alternatives:")
        for route in alternatives {
            let altMinutes = Int((route.expectedTravelTime / 60).rounded())
            lines.append("  - \(route.name): \(altMinutes) min, \(formatDistance(route.distance))")
        }
    }
    return lines.joined(separator: "\n")
}
