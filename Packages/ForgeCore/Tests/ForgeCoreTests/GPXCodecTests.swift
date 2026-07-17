import Foundation
import Testing
@testable import ForgeCore

struct GPXCodecTests {

    /// Fixed ISO8601 calendar in UTC so date construction never drifts with
    /// the runner's locale or local timezone.
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int, _ second: Int
    ) -> Date {
        Self.calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    // MARK: - Encoding

    @Test func encodeGoldenShape() {
        let track = GPXCodec.Track(name: "Morning Run", points: [
            .init(
                time: date(2026, 7, 10, 6, 0, 0),
                latitude: 51.5007,
                longitude: -0.1246,
                elevationMeters: 11.5,
                heartRate: 142
            )
        ])
        let xml = GPXCodec.encode(track: track)

        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(xml.contains("version=\"1.1\""))
        #expect(xml.contains("creator=\"ForgeFit\""))
        #expect(xml.contains("xmlns=\"http://www.topografix.com/GPX/1/1\""))
        #expect(xml.contains("xmlns:gpxtpx=\"http://www.garmin.com/xmlschemas/TrackPointExtension/v1\""))
        #expect(xml.contains("<trk>"))
        #expect(xml.contains("<name>Morning Run</name>"))
        #expect(xml.contains("<trkseg>"))
        #expect(xml.contains("<trkpt lat=\"51.5007\" lon=\"-0.1246\">"))
        #expect(xml.contains("<ele>11.5</ele>"))
        #expect(xml.contains("<time>2026-07-10T06:00:00Z</time>"))
        #expect(xml.contains("<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>142</gpxtpx:hr></gpxtpx:TrackPointExtension></extensions>"))
        // One track, one segment.
        #expect(xml.components(separatedBy: "<trkseg>").count == 2)
        #expect(xml.hasSuffix("</gpx>\n"))
    }

    @Test func encodeEscapesTrackName() {
        let track = GPXCodec.Track(name: "Morning <Run> & Coffee", points: [
            .init(latitude: 1.0, longitude: 2.0)
        ])
        let xml = GPXCodec.encode(track: track)
        #expect(xml.contains("<name>Morning &lt;Run&gt; &amp; Coffee</name>"))
        #expect(!xml.contains("<name>Morning <Run>"))

        // And the decoder must hand the original name back.
        #expect(GPXCodec.decode(xml)?.name == "Morning <Run> & Coffee")
    }

    @Test func encodeOmitsNilOptionals() {
        let track = GPXCodec.Track(name: nil, points: [
            .init(latitude: 40.0, longitude: -105.0)
        ])
        let xml = GPXCodec.encode(track: track)
        #expect(!xml.contains("<name>"))
        #expect(!xml.contains("<ele>"))
        #expect(!xml.contains("<time>"))
        #expect(!xml.contains("<extensions>"))
        #expect(!xml.contains("gpxtpx:hr"))
        #expect(xml.contains("<trkpt lat=\"40\" lon=\"-105\">"))
    }

    @Test func encodeCustomCreator() {
        let xml = GPXCodec.encode(
            track: .init(points: [.init(latitude: 0.5, longitude: 0.5)]),
            creator: "Someone \"Else\""
        )
        #expect(xml.contains("creator=\"Someone &quot;Else&quot;\""))
    }

    // MARK: - Decoding

    @Test func decodeStravaStyleFile() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx creator="StravaGPX" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
        xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd \
        http://www.garmin.com/xmlschemas/TrackPointExtension/v1 \
        http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd" version="1.1" \
        xmlns="http://www.topografix.com/GPX/1/1" \
        xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
         <metadata>
          <time>2026-07-10T06:00:00Z</time>
          <name>should not become the track name</name>
         </metadata>
         <trk>
          <name>Lunch Run</name>
          <type>running</type>
          <trkseg>
           <trkpt lat="52.5200066" lon="13.4049540">
            <ele>34.2</ele>
            <time>2026-07-10T06:00:00Z</time>
            <extensions>
             <gpxtpx:TrackPointExtension>
              <gpxtpx:hr>128</gpxtpx:hr>
             </gpxtpx:TrackPointExtension>
            </extensions>
           </trkpt>
           <trkpt lat="52.5200500" lon="13.4050100">
            <ele>34.6</ele>
            <time>2026-07-10T06:00:05Z</time>
            <extensions>
             <gpxtpx:TrackPointExtension>
              <gpxtpx:hr>131</gpxtpx:hr>
             </gpxtpx:TrackPointExtension>
            </extensions>
           </trkpt>
          </trkseg>
         </trk>
        </gpx>
        """
        let track = GPXCodec.decode(xml)
        #expect(track != nil)
        #expect(track?.name == "Lunch Run")
        #expect(track?.points.count == 2)

        let first = track?.points.first
        #expect(abs((first?.latitude ?? 0) - 52.5200066) < 1e-9)
        #expect(abs((first?.longitude ?? 0) - 13.4049540) < 1e-9)
        #expect(first?.elevationMeters == 34.2)
        #expect(first?.heartRate == 128)
        #expect(first?.time == date(2026, 7, 10, 6, 0, 0))
        #expect(track?.points.last?.heartRate == 131)
        #expect(track?.points.last?.time == date(2026, 7, 10, 6, 0, 5))
    }

    @Test func decodeGarminPrefixedHeartRate() {
        // Garmin Connect exports use ns3: instead of gpxtpx: — the decoder
        // must match by local name.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Garmin Connect" \
        xmlns="http://www.topografix.com/GPX/1/1" \
        xmlns:ns3="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
         <trk><trkseg>
          <trkpt lat="45.0" lon="7.0">
           <extensions><ns3:TrackPointExtension><ns3:hr>155</ns3:hr></ns3:TrackPointExtension></extensions>
          </trkpt>
         </trkseg></trk>
        </gpx>
        """
        let track = GPXCodec.decode(xml)
        #expect(track?.points.count == 1)
        #expect(track?.points.first?.heartRate == 155)
        #expect(track?.points.first?.time == nil)
        #expect(track?.points.first?.elevationMeters == nil)
    }

    @Test func decodeConcatenatesMultipleSegments() {
        let xml = """
        <gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
         <trk>
          <trkseg>
           <trkpt lat="1.0" lon="1.0"/>
           <trkpt lat="2.0" lon="2.0"/>
          </trkseg>
          <trkseg>
           <trkpt lat="3.0" lon="3.0"/>
          </trkseg>
         </trk>
        </gpx>
        """
        let track = GPXCodec.decode(xml)
        #expect(track?.points.count == 3)
        #expect(track?.points.map(\.latitude) == [1.0, 2.0, 3.0])
    }

    @Test func decodeRouteFallbackWhenNoTrack() {
        let xml = """
        <gpx version="1.1" creator="planner" xmlns="http://www.topografix.com/GPX/1/1">
         <rte>
          <name>Planned Loop</name>
          <rtept lat="10.5" lon="-20.25"><ele>100</ele></rtept>
          <rtept lat="10.6" lon="-20.35"/>
         </rte>
        </gpx>
        """
        let track = GPXCodec.decode(xml)
        #expect(track?.name == "Planned Loop")
        #expect(track?.points.count == 2)
        #expect(track?.points.first?.elevationMeters == 100)
        #expect(track?.points.last?.longitude == -20.35)
    }

    @Test func decodePrefersTrackOverRoute() {
        let xml = """
        <gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
         <rte><rtept lat="9.0" lon="9.0"/></rte>
         <trk><trkseg><trkpt lat="1.0" lon="1.0"/></trkseg></trk>
        </gpx>
        """
        let track = GPXCodec.decode(xml)
        #expect(track?.points.count == 1)
        #expect(track?.points.first?.latitude == 1.0)
    }

    @Test func decodeMalformedReturnsNil() {
        #expect(GPXCodec.decode("<gpx><trk><trkseg><trkpt lat=\"1.0\"") == nil)
        #expect(GPXCodec.decode("not xml at all") == nil)
        #expect(GPXCodec.decode("") == nil)
    }

    @Test func decodeZeroPointsReturnsNil() {
        let emptySegment = """
        <gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
         <trk><name>Empty</name><trkseg></trkseg></trk>
        </gpx>
        """
        #expect(GPXCodec.decode(emptySegment) == nil)

        // Points without a usable coordinate don't count either.
        let noCoords = """
        <gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
         <trk><trkseg><trkpt><ele>5</ele></trkpt><trkpt lat="oops" lon="1.0"/></trkseg></trk>
        </gpx>
        """
        #expect(GPXCodec.decode(noCoords) == nil)
    }

    @Test func decodeSkipsCoordinatelessPointsButKeepsValidOnes() {
        let xml = """
        <gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
         <trk><trkseg>
          <trkpt><ele>5</ele></trkpt>
          <trkpt lat="3.0" lon="4.0"/>
         </trkseg></trk>
        </gpx>
        """
        let track = GPXCodec.decode(xml)
        #expect(track?.points.count == 1)
        #expect(track?.points.first?.latitude == 3.0)
    }

    @Test func decodeFractionalSecondTimestamps() {
        let xml = """
        <gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1">
         <trk><trkseg>
          <trkpt lat="1.0" lon="1.0"><time>2026-07-10T06:00:00.250Z</time></trkpt>
          <trkpt lat="2.0" lon="2.0"><time>2026-07-10T06:00:05Z</time></trkpt>
         </trkseg></trk>
        </gpx>
        """
        let track = GPXCodec.decode(xml)
        let base = date(2026, 7, 10, 6, 0, 0)
        let t0 = track?.points.first?.time
        #expect(t0 != nil)
        #expect(abs((t0?.timeIntervalSince(base) ?? -1) - 0.25) < 0.001)
        #expect(track?.points.last?.time == date(2026, 7, 10, 6, 0, 5))
    }

    // MARK: - Round trip

    @Test func roundTripPreservesData() {
        let start = date(2026, 7, 10, 6, 30, 0)
        let original = GPXCodec.Track(name: "Tempo Intervals", points: (0..<25).map { (i: Int) -> GPXCodec.Point in
            let d = Double(i)
            let ele: Double? = (i % 3 == 0) ? nil : 11.0 + d * 0.25
            let hr: Int? = (i % 4 == 0) ? nil : 120 + i
            return GPXCodec.Point(
                time: start.addingTimeInterval(d * 5.0),
                latitude: 51.5007 + d * 0.0001,
                longitude: -0.1246 - d * 0.0002,
                elevationMeters: ele,
                heartRate: hr
            )
        })

        let decoded = GPXCodec.decode(GPXCodec.encode(track: original))
        #expect(decoded != nil)
        #expect(decoded?.name == original.name)
        #expect(decoded?.points.count == original.points.count)

        for (a, b) in zip(original.points, decoded?.points ?? []) {
            #expect(abs(a.latitude - b.latitude) < 1e-6)
            #expect(abs(a.longitude - b.longitude) < 1e-6)
            #expect(a.heartRate == b.heartRate)
            #expect((a.elevationMeters == nil) == (b.elevationMeters == nil))
            if let ea = a.elevationMeters, let eb = b.elevationMeters {
                #expect(abs(ea - eb) < 0.01)
            }
            #expect((a.time == nil) == (b.time == nil))
            if let ta = a.time, let tb = b.time {
                #expect(abs(ta.timeIntervalSince(tb)) < 1.0)
            }
        }
    }

    @Test func roundTripNegativeCoordinates() {
        let original = GPXCodec.Track(name: "Southern Hemisphere", points: [
            .init(latitude: -33.8688197, longitude: 151.2092955),
            .init(latitude: -54.801912, longitude: -68.302951),
        ])
        let decoded = GPXCodec.decode(GPXCodec.encode(track: original))
        #expect(decoded?.points.count == 2)
        for (a, b) in zip(original.points, decoded?.points ?? []) {
            #expect(abs(a.latitude - b.latitude) < 1e-6)
            #expect(abs(a.longitude - b.longitude) < 1e-6)
        }
    }

    @Test func largeTrackRoundTripStaysFast() {
        let start = date(2026, 7, 10, 7, 0, 0)
        let big = GPXCodec.Track(name: "Long Ride", points: (0..<5000).map { i in
            GPXCodec.Point(
                time: start.addingTimeInterval(Double(i)),
                latitude: 47.0 + Double(i) * 1e-5,
                longitude: 8.0 + Double(i) * 1e-5,
                elevationMeters: 400 + Double(i % 100),
                heartRate: 110 + i % 60
            )
        })

        let clock = ContinuousClock()
        var decoded: GPXCodec.Track?
        let elapsed = clock.measure {
            decoded = GPXCodec.decode(GPXCodec.encode(track: big))
        }

        #expect(decoded?.points.count == 5000)
        #expect(decoded?.points.first?.heartRate == 110)
        #expect(decoded?.points.last?.time == start.addingTimeInterval(4999))
        #expect(abs((decoded?.points.last?.latitude ?? 0) - (47.0 + 4999 * 1e-5)) < 1e-6)
        // Sanity bound, deliberately generous so CI load never flakes it;
        // in practice this runs in well under a second.
        #expect(elapsed < .seconds(10))
    }
}
