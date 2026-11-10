import Testing
@testable import WalkingPadCore

struct PadProfileTests {
    @Test func legacyServicesAreDiscoveredInsteadOfRejectedAsNonFTMS() {
        #expect(PadProfile.discoveryServices.contains("FE00"))
        #expect(PadProfile.discoveryServices.contains("FFF0"))
        #expect(PadProfile.detect(services: ["1800", "FE00"]) == .fe00)
        #expect(PadProfile.detect(services: ["1800", "FFF0"]) == .fff0)
    }
    @Test func acceptsFullAndShortUUIDsAndPrefersFTMS() {
        #expect(PadProfile.detect(services: ["0000fe00-0000-1000-8000-00805f9b34fb"]) == .fe00)
        #expect(PadProfile.detect(services: ["fff0", "1826", "FE00"]) == .ftms)
        #expect(PadProfile.detect(services: ["1800", "180A"]) == nil)
    }
    @Test func fe00RolesMatchCapturedKSBDC2() {
        // KS-BDC2 GATT: FE01 [read, notify], FE02 [writeWithoutResponse].
        #expect(PadProfile.fe00.notify == "FE01")
        #expect(PadProfile.fe00.write == "FE02")
    }
    @Test func discoveryIgnoresUnnamedUnrelatedAdvertisers() {
        #expect(!PadProfile.isCandidate(name: nil, services: []))
        #expect(!PadProfile.isCandidate(name: "AirPods", services: ["180A"]))
        #expect(PadProfile.isCandidate(name: "KS-BDC2", services: ["FE00"]))
        #expect(PadProfile.isCandidate(name: nil, services: ["0000fe00-0000-1000-8000-00805f9b34fb"]))
        #expect(PadProfile.isCandidate(name: "WalkingPad", services: []))
        #expect(PadProfile.isCandidate(name: "KS-ST-A1P", services: []))
    }
}
