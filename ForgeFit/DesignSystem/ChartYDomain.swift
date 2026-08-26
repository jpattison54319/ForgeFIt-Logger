import Foundation

/// Rounded, padded bounds for continuous measurements. Line charts should
/// reveal change within the observed range; zero belongs only to metrics whose
/// meaning actually has a zero baseline, such as counts and aggregate bars.
nonisolated enum ChartYDomain {
    static func padded(
        values: [Double],
        lowerLimit: Double? = nil,
        upperLimit: Double? = nil,
        desiredTickCount: Int = 4
    ) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard var lower = finite.min(), var upper = finite.max() else {
            return 0...1
        }

        if lower == upper {
            let flatPadding = max(abs(lower) * 0.1, 1)
            lower -= flatPadding
            upper += flatPadding
        }

        let observedSpan = upper - lower
        lower -= observedSpan * 0.1
        upper += observedSpan * 0.1

        let step = niceStep(
            for: (upper - lower) / Double(max(2, desiredTickCount))
        )
        lower = floor(lower / step) * step
        upper = ceil(upper / step) * step

        if let lowerLimit { lower = max(lower, lowerLimit) }
        if let upperLimit { upper = min(upper, upperLimit) }
        if lower >= upper {
            upper = lower + step
        }
        return lower...upper
    }

    private static func niceStep(for rawStep: Double) -> Double {
        guard rawStep.isFinite, rawStep > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let multiplier: Double
        if normalized <= 1 {
            multiplier = 1
        } else if normalized <= 2 {
            multiplier = 2
        } else if normalized <= 5 {
            multiplier = 5
        } else {
            multiplier = 10
        }
        return multiplier * magnitude
    }
}
