import Foundation
import Testing
@testable import ForgeFit

@Suite("iOS performance configuration")
struct PerformanceConfigurationTests {
    @Test("The shipped app opts into adaptive ProMotion frame rates")
    func promotionOptInRemainsEnabled() throws {
        let appBundle = try #require(Bundle(identifier: "org.xpetsllc.ForgeFit"))
        #expect(
            appBundle.object(
                forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone"
            ) as? Bool == true
        )
    }
}
