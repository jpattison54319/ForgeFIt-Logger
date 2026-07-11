import Foundation

/// GPX 1.1 encoder/decoder for cardio workouts — the interchange format behind
/// "export to Strava" and GPX import.
///
/// Encoding targets what Strava's importer actually requires rather than the
/// full GPX schema: a single `<trk>`/`<trkseg>`, ISO8601 UTC timestamps, and
/// heart rate carried in the Garmin TrackPointExtension v1 namespace, because
/// that is the only HR encoding Strava (and most other platforms) read from
/// GPX. Decoding is deliberately tolerant — real-world exports differ in
/// namespace prefixes (Garmin uses `ns3:`, Strava uses `gpxtpx:`), split
/// tracks across multiple `<trkseg>` elements, omit time/elevation/HR, or
/// ship routes (`<rte>`) instead of tracks — so the parser matches extension
/// elements by local name and degrades gracefully instead of rejecting files.
public enum GPXCodec: Sendable {

    /// A single recorded track: what one cardio session exports to / imports from.
    public struct Track: Equatable, Sendable {
        public var name: String?
        public var points: [Point]

        public init(name: String? = nil, points: [Point]) {
            self.name = name
            self.points = points
        }
    }

    /// One trackpoint. Everything except the coordinate is optional because
    /// treadmill-style sessions have no elevation, imported files often lack
    /// HR, and some route files carry no timestamps at all.
    public struct Point: Equatable, Sendable {
        public var time: Date?
        public var latitude: Double
        public var longitude: Double
        public var elevationMeters: Double?
        public var heartRate: Int?

        public init(
            time: Date? = nil,
            latitude: Double,
            longitude: Double,
            elevationMeters: Double? = nil,
            heartRate: Int? = nil
        ) {
            self.time = time
            self.latitude = latitude
            self.longitude = longitude
            self.elevationMeters = elevationMeters
            self.heartRate = heartRate
        }
    }

    // MARK: - Encode

    /// Serializes a track as GPX 1.1. The `gpxtpx` namespace is declared on
    /// the root unconditionally (even when no point has HR) so the output is
    /// schema-valid regardless of content, and optional child elements are
    /// omitted rather than emitted empty — several importers choke on empty
    /// `<time/>`/`<ele/>` elements.
    public static func encode(track: Track, creator: String = "ForgeFit") -> String {
        var out = String()
        // ~140 bytes per point with all fields present; over-reserving is cheap.
        out.reserveCapacity(512 + track.points.count * 160)

        out += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<gpx version=\"1.1\" creator=\"\(xmlEscaped(creator))\""
        out += " xmlns=\"http://www.topografix.com/GPX/1/1\""
        out += " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
        out += " xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\""
        out += " xsi:schemaLocation=\"http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd\">\n"
        out += "  <trk>\n"
        if let name = track.name {
            out += "    <name>\(xmlEscaped(name))</name>\n"
        }
        out += "    <trkseg>\n"
        for point in track.points {
            out += "      <trkpt lat=\"\(decimal(point.latitude, maxFractionDigits: 7))\""
            out += " lon=\"\(decimal(point.longitude, maxFractionDigits: 7))\">\n"
            if let ele = point.elevationMeters {
                out += "        <ele>\(decimal(ele, maxFractionDigits: 2))</ele>\n"
            }
            if let time = point.time {
                out += "        <time>\(time.formatted(timeStyle))</time>\n"
            }
            if let hr = point.heartRate {
                out += "        <extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>\(hr)</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>\n"
            }
            out += "      </trkpt>\n"
        }
        out += "    </trkseg>\n"
        out += "  </trk>\n"
        out += "</gpx>\n"
        return out
    }

    // MARK: - Decode

    /// Parses GPX with Foundation's `XMLParser` (event-driven, no regex) so a
    /// 5000-point file stays cheap and malformed XML fails fast. Returns nil
    /// for unparseable XML or when no usable point (valid lat + lon) exists —
    /// callers treat nil as "not a GPX file worth importing".
    public static func decode(_ xml: String) -> Track? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = GPXParserDelegate()
        parser.delegate = delegate
        // Namespace processing stays off: we match by local-name suffix so
        // undeclared prefixes (common in hand-edited files) still parse.
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }

        if !delegate.trkPoints.isEmpty {
            return Track(name: delegate.trkName, points: delegate.trkPoints)
        }
        // Route fallback: some planners export <rte>/<rtept> instead of a track.
        if !delegate.rtePoints.isEmpty {
            return Track(name: delegate.trkName ?? delegate.rteName, points: delegate.rtePoints)
        }
        return nil
    }

    // MARK: - Formatting helpers

    /// Whole-second ISO8601 with a trailing "Z" — the shape every GPX consumer
    /// accepts; fractional seconds are dropped because sub-second precision is
    /// meaningless for 1 Hz cardio samples and trips up older parsers.
    private static let timeStyle = Date.ISO8601FormatStyle(timeZone: .gmt)

    /// Locale-independent decimal (POSIX "." separator) with trailing zeros
    /// trimmed. 7 fraction digits ≈ 1.1 cm of latitude — comfortably inside
    /// the round-trip tolerance without bloating large files.
    private static func decimal(_ value: Double, maxFractionDigits: Int) -> String {
        var s = String(format: "%.\(maxFractionDigits)f", value)
        guard s.contains(".") else { return s }
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func xmlEscaped(_ string: String) -> String {
        var out = String()
        out.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}

/// Streaming state machine for GPX. Kept as a plain NSObject delegate (not
/// Sendable) because parsing is synchronous and single-use inside `decode`.
private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    var trkPoints: [GPXCodec.Point] = []
    var rtePoints: [GPXCodec.Point] = []
    var trkName: String?
    var rteName: String?

    private enum PointKind { case trk, rte }

    /// Local names (prefix stripped, lowercased) of open elements.
    private var stack: [String] = []
    private var text = ""
    private var pointKind: PointKind?
    private var curLat: Double?
    private var curLon: Double?
    private var curTime: Date?
    private var curEle: Double?
    private var curHR: Int?

    // Two formatters because ISO8601DateFormatter is strict: one accepts
    // fractional seconds, one does not, and real exports use both shapes.
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// "gpxtpx:hr" → "hr"; tolerant of any (or no) namespace prefix.
    private func localName(_ qualified: String) -> String {
        let local: Substring
        if let idx = qualified.lastIndex(of: ":") {
            local = qualified[qualified.index(after: idx)...]
        } else {
            local = qualified[...]
        }
        return local.lowercased()
    }

    private func parseDate(_ raw: String) -> Date? {
        isoPlain.date(from: raw) ?? isoFractional.date(from: raw)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = localName(elementName)
        stack.append(name)
        text = ""

        switch name {
        case "trkpt", "rtept":
            pointKind = (name == "trkpt") ? .trk : .rte
            curLat = attributeDict["lat"].flatMap(Double.init)
            curLon = attributeDict["lon"].flatMap(Double.init)
            curTime = nil
            curEle = nil
            curHR = nil
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "trkpt", "rtept":
            // A coordinate is the one non-negotiable field; points without it
            // are skipped rather than failing the whole import.
            if let lat = curLat, let lon = curLon, let kind = pointKind {
                let point = GPXCodec.Point(
                    time: curTime,
                    latitude: lat,
                    longitude: lon,
                    elevationMeters: curEle,
                    heartRate: curHR
                )
                switch kind {
                case .trk: trkPoints.append(point)
                case .rte: rtePoints.append(point)
                }
            }
            pointKind = nil
        case "name":
            // Only capture a name whose direct parent is trk/rte, so
            // <metadata><name> and waypoint names don't leak into the track.
            if pointKind == nil, stack.count >= 2, !trimmed.isEmpty {
                switch stack[stack.count - 2] {
                case "trk" where trkName == nil: trkName = trimmed
                case "rte" where rteName == nil: rteName = trimmed
                default: break
                }
            }
        case "ele":
            if pointKind != nil { curEle = Double(trimmed) }
        case "time":
            if pointKind != nil { curTime = parseDate(trimmed) }
        case "hr":
            if pointKind != nil { curHR = Int(trimmed) }
        default:
            break
        }

        if !stack.isEmpty { stack.removeLast() }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }
}
