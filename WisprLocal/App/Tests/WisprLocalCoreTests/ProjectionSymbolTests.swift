import Testing
@testable import WisprLocalCore

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite struct ProjectionSymbolTests {
    @Test(arguments: ["$", "€", "£", "¥", "₹", "+", "=", "<", ">", "#", "%", "&", "@", "*", "/", "^", "~", "|", "\\"])
    func contentSymbolsSurvive(_ symbol: String) {
        let input = "a \(symbol) b"
        #expect(projectionKeys(input, "A b.") == PlanTokens(input).keys)
    }
    @Test func attachedNumbersSurvive() {
        #expect(PlanTokens("-500 .5 +44 10-20 12.5% 1990s 7:45 1,250").keys == ["-500", ".5", "+44", "10-20", "12.5%", "1990s", "7:45", "1,250"])
    }
}
