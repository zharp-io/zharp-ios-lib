import XCTest
@testable import ZharpCore

final class AttributeMappingTests: XCTestCase {
    func testPrimitivesKeepTheirTypes() {
        let mapped = AttributeMapping.map([
            "name": "Ada",
            "count": 3,
            "ratio": 0.5,
            "paid": true,
            "tags": ["a", "b"],
        ])
        XCTAssertEqual(mapped["name"], .string("Ada"))
        XCTAssertEqual(mapped["count"], .int(3))
        XCTAssertEqual(mapped["ratio"], .double(0.5))
        XCTAssertEqual(mapped["paid"], .bool(true))
        XCTAssertEqual(mapped["tags"], .stringArray(["a", "b"]))
    }

    func testFoundationNumbersAreToldApart() {
        XCTAssertEqual(AttributeMapping.value(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(AttributeMapping.value(NSNumber(value: 7)), .int(7))
        XCTAssertEqual(AttributeMapping.value(NSNumber(value: 1.25)), .double(1.25))
        XCTAssertEqual(AttributeMapping.value(Int64(9)), .int(9))
        XCTAssertEqual(AttributeMapping.value(Float(2.5)), .double(2.5))
    }

    func testOtherValues() {
        let uuid = UUID()
        XCTAssertEqual(AttributeMapping.value(uuid), .string(uuid.uuidString.lowercased()))
        XCTAssertEqual(AttributeMapping.value(URL(string: "https://example.com/a")!), .string("https://example.com/a"))
        XCTAssertEqual(AttributeMapping.value(Date(timeIntervalSince1970: 0)), .string("1970-01-01T00:00:00.000Z"))
        XCTAssertNil(AttributeMapping.value(NSNull()))

        struct Order: CustomStringConvertible { var description: String { "Order#1" } }
        XCTAssertEqual(AttributeMapping.value(Order()), .string("Order#1"))
    }

    func testOptionalsInsideAny() {
        let none: String? = nil
        let some: Int? = 4
        let mapped = AttributeMapping.map(["none": none as Any, "some": some as Any])
        XCTAssertNil(mapped["none"])
        XCTAssertEqual(mapped["some"], .int(4))
    }

    func testCapsAndEmptyKeys() {
        var many: [String: Any] = ["": "dropped"]
        for index in 0..<100 { many["k" + (index < 10 ? "00" : "0") + String(index)] = index }
        let mapped = AttributeMapping.map(many)
        XCTAssertEqual(mapped.count, AttributeMapping.maxAttributes)
        XCTAssertNil(mapped[""])
        XCTAssertNotNil(mapped["k000"])
        XCTAssertNil(mapped["k099"])

        let long = String(repeating: "x", count: AttributeMapping.maxStringLength + 10)
        XCTAssertEqual(AttributeMapping.value(long), .string(String(repeating: "x", count: AttributeMapping.maxStringLength)))
    }

    func testResourceAttributes() {
        let info = ResourceInfo(service: "shop-ios", release: "2.3.0 (412)", environment: "production",
                                deviceId: "dev-1", deviceModel: "iPhone15,2", osName: "iOS", osVersion: "17.4.1")
        let attributes = info.attributes()
        XCTAssertEqual(attributes["service.name"], .string("shop-ios"))
        XCTAssertEqual(attributes["service.version"], .string("2.3.0 (412)"))
        XCTAssertEqual(attributes["deployment.environment.name"], .string("production"))
        XCTAssertEqual(attributes["telemetry.sdk.name"], .string("zharp"))
        XCTAssertEqual(attributes["telemetry.sdk.language"], .string("swift"))
        XCTAssertEqual(attributes["telemetry.sdk.version"], .string(ZharpVersion.current))
        XCTAssertEqual(attributes["device.id"], .string("dev-1"))
        XCTAssertEqual(attributes["device.model.name"], .string("iPhone15,2"))
        XCTAssertEqual(attributes["os.name"], .string("iOS"))
        XCTAssertEqual(attributes["os.version"], .string("17.4.1"))

        let bare = ResourceInfo(service: "s", release: nil, environment: "", deviceId: "d",
                                deviceModel: "m", osName: "iOS", osVersion: "17.0").attributes()
        XCTAssertNil(bare["service.version"])
        XCTAssertNil(bare["deployment.environment.name"])
    }

    func testDefaults() {
        XCTAssertEqual(ResourceInfo.defaultService(explicit: " shop ", bundleIdentifier: "io.shop"), "shop")
        XCTAssertEqual(ResourceInfo.defaultService(explicit: nil, bundleIdentifier: "io.shop"), "io.shop")
        XCTAssertEqual(ResourceInfo.defaultService(explicit: "", bundleIdentifier: nil), "ios-app")

        XCTAssertEqual(ResourceInfo.defaultRelease(explicit: "web@1", shortVersion: "2.0", build: "5"), "web@1")
        XCTAssertEqual(ResourceInfo.defaultRelease(explicit: nil, shortVersion: "2.0", build: "5"), "2.0 (5)")
        XCTAssertEqual(ResourceInfo.defaultRelease(explicit: nil, shortVersion: "2.0", build: "2.0"), "2.0")
        XCTAssertEqual(ResourceInfo.defaultRelease(explicit: nil, shortVersion: nil, build: "5"), "5")
        XCTAssertNil(ResourceInfo.defaultRelease(explicit: nil, shortVersion: nil, build: nil))

        XCTAssertEqual(ResourceInfo.osVersionString(major: 17, minor: 4, patch: 1), "17.4.1")
        XCTAssertEqual(ResourceInfo.osVersionString(major: 18, minor: 0, patch: 0), "18.0")
    }

    func testEndpoint() {
        XCTAssertEqual(Endpoint.base(nil)?.absoluteString, "https://api.zharp.io/api/v1/otlp")
        XCTAssertEqual(Endpoint.base("  ")?.absoluteString, "https://api.zharp.io/api/v1/otlp")
        XCTAssertEqual(Endpoint.base("http://localhost:3000/api/v1/otlp/")?.absoluteString, "http://localhost:3000/api/v1/otlp")
        XCTAssertNil(Endpoint.base("ftp://example.com"))
        XCTAssertNil(Endpoint.base("not a url"))

        let base = Endpoint.base(nil)!
        XCTAssertEqual(Endpoint.url(base: base, kind: .traces).absoluteString, "https://api.zharp.io/api/v1/otlp/v1/traces")
        XCTAssertEqual(Endpoint.url(base: base, kind: .logs).absoluteString, "https://api.zharp.io/api/v1/otlp/v1/logs")
    }

    func testLogLevelsAreOtlpSeverityNumbers() {
        XCTAssertEqual(LogLevel.debug.rawValue, 5)
        XCTAssertEqual(LogLevel.info.rawValue, 9)
        XCTAssertEqual(LogLevel.warn.rawValue, 13)
        XCTAssertEqual(LogLevel.error.rawValue, 17)
        XCTAssertEqual(LogLevel.fatal.rawValue, 21)
    }
}
