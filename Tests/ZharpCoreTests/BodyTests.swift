import XCTest
@testable import ZharpCore

/// The same rules as the JavaScript SDKs' `bodies.ts`: field names stay, secret values are
/// filtered, files and inline images are described, text is capped, URLs lose their secrets.
final class BodyTests: XCTestCase {
    private let errors = BodySettings(mode: .errors)
    private let all = BodySettings(mode: .all, maxSize: 1000, redactKeys: ["dateOfBirth"])

    private func object(_ text: String?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = try XCTUnwrap(text?.data(using: .utf8), file: file, line: line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
    }

    private func string(_ value: AttrValue?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }

    // MARK: Settings

    func testDefaultsAndLimits() {
        XCTAssertEqual(BodySettings(mode: .errors).maxSize, 32 * 1024)
        XCTAssertEqual(BodySettings(mode: .errors, maxSize: 1_000_000).maxSize, 128 * 1024)
        XCTAssertEqual(BodySettings(mode: .errors, maxSize: 0).maxSize, 32 * 1024)
        XCTAssertEqual(BodySettings(mode: .errors).rawLimit, 64 * 1024)
        XCTAssertEqual(BodySettings(mode: .errors, maxSize: 100_000).rawLimit, 200_000)
    }

    func testWanted() {
        XCTAssertFalse(errors.wanted(status: 200))
        XCTAssertTrue(errors.wanted(status: 400))
        XCTAssertTrue(errors.wanted(status: 503))
        XCTAssertTrue(errors.wanted(status: 0), "no response counts as failed")
        XCTAssertTrue(all.wanted(status: 200))
    }

    // MARK: Content types and labels

    func testTextualTypes() {
        XCTAssertTrue(BodyAttributes.isTextual(nil))
        XCTAssertTrue(BodyAttributes.isTextual("application/json; charset=utf-8"))
        XCTAssertTrue(BodyAttributes.isTextual("application/problem+json"))
        XCTAssertTrue(BodyAttributes.isTextual("text/plain"))
        XCTAssertTrue(BodyAttributes.isTextual("application/x-www-form-urlencoded"))
        XCTAssertFalse(BodyAttributes.isTextual("text/event-stream"))
        XCTAssertFalse(BodyAttributes.isTextual("image/png"))
        XCTAssertFalse(BodyAttributes.isTextual("multipart/form-data; boundary=x"))
    }

    func testSizesAndLabels() {
        XCTAssertEqual(BodyAttributes.formatSize(500), "500 B")
        XCTAssertEqual(BodyAttributes.formatSize(2048), "2 KB")
        XCTAssertEqual(BodyAttributes.formatSize(1536 * 1024), "1.5 MB")
        XCTAssertEqual(BodyAttributes.fileLabel(name: "photo.png", type: "image/png", size: 2048), "[file photo.png · image/png · 2 KB]")
        XCTAssertEqual(BodyAttributes.fileLabel(name: nil, type: nil, size: 10, partial: true), "[file blob · 10 B+]")
        XCTAssertEqual(BodyAttributes.describe(contentType: "image/png", size: 3000), "[binary · image/png · 3 KB]")
        XCTAssertEqual(BodyAttributes.describe(contentType: "image/png"), "[binary · image/png]")
        XCTAssertEqual(BodyAttributes.describe(contentType: "text/event-stream"), "[event stream]")
    }

    // MARK: Redaction

    func testSecretKeys() {
        for key in ["password", "newPassword", "api_key", "X-Auth-Token", "authorization", "cookie", "cardNumber", "cvv", "pin", "card"] {
            XCTAssertTrue(BodyAttributes.isSecretKey(key), key)
        }
        for key in ["email", "name", "pinned", "key", "author"] {
            XCTAssertFalse(BodyAttributes.isSecretKey(key), key)
        }
        XCTAssertTrue(BodyAttributes.isSecretKey("date_of_birth", settings: all), "redactKeys ignore case, - and _")
        let pattern = BodySettings(mode: .all, redactPatterns: [try! NSRegularExpression(pattern: "^acct")])
        XCTAssertTrue(BodyAttributes.isSecretKey("acctNo", settings: pattern))
    }

    func testJSONSecretsFilteredFieldNamesKept() throws {
        let body = #"{"email":"a@b.test","password":"hunter2","dateOfBirth":"1990-01-01","remember":true,"empty":"","none":null}"#
        let out = try object(BodyAttributes.format(body, contentType: "application/json", settings: all)?.value)
        XCTAssertEqual(out["email"] as? String, "a@b.test")
        XCTAssertEqual(out["password"] as? String, "[Filtered]")
        XCTAssertEqual(out["dateOfBirth"] as? String, "[Filtered]")
        XCTAssertEqual(out["remember"] as? Bool, true)
        XCTAssertEqual(out["empty"] as? String, "")
        XCTAssertTrue(out["none"] is NSNull)
    }

    func testSecretObjectKeepsItsKeys() throws {
        let body = #"{"card":{"brand":"visa","last4":"4242","meta":{"exp":12}},"items":[{"token":"t"}]}"#
        let out = try object(BodyAttributes.format(body, contentType: "application/json", settings: errors)?.value)
        let card = try XCTUnwrap(out["card"] as? [String: Any])
        XCTAssertEqual(card["brand"] as? String, "[Filtered]")
        XCTAssertEqual(card["last4"] as? String, "[Filtered]")
        XCTAssertEqual((card["meta"] as? [String: Any])?["exp"] as? String, "[Filtered]")
        XCTAssertEqual(((out["items"] as? [[String: Any]])?.first)?["token"] as? String, "[Filtered]")
    }

    func testNoEscapedSlashes() {
        let out = BodyAttributes.format(#"{"url":"https://example.com/a"}"#, contentType: "application/json", settings: errors)?.value
        XCTAssertEqual(out, #"{"url":"https://example.com/a"}"#)
    }

    func testForm() {
        let out = BodyAttributes.format("user=ada&password=p4ss&x", contentType: "application/x-www-form-urlencoded", settings: all)?.value
        XCTAssertEqual(out, "user=ada&password=[Filtered]&x")
    }

    func testInlineImagesAndBase64() throws {
        let pixel = "data:image/png;base64," + String(repeating: "iVBORw0KGgo", count: 4000)
        let blob = String(repeating: "QUJD", count: 500) + "1"
        let body = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: ["avatar": pixel, "blob": blob, "name": "Ada"]), encoding: .utf8))
        let out = try object(BodyAttributes.format(body, contentType: "application/json", settings: errors)?.value)
        XCTAssertEqual(out["avatar"] as? String, "[image/png · 32 KB]")
        XCTAssertEqual(out["blob"] as? String, "[base64 · 1 KB]")
        XCTAssertEqual(out["name"] as? String, "Ada")
        XCTAssertEqual(BodyAttributes.shorten(String(repeating: "abcdefgh", count: 40)), String(repeating: "abcdefgh", count: 40),
                       "long text without digits or +/ is not base64")
    }

    func testCutJSONIsRedactedLoosely() {
        let cut = #"{"name":"Ada","token":"abc123","photo":"data:image/png;base64,"# + String(repeating: "iVBORw0KGgo", count: 150)
        let out = BodyAttributes.format(cut, contentType: "application/json", settings: errors, cut: true)
        XCTAssertEqual(out?.truncated, true)
        XCTAssertEqual(out?.value, #"{"name":"Ada","token":"[Filtered]","photo":"[image/png · 1 KB+]""#)
    }

    func testCapAndTruncated() {
        let attrs = BodyAttributes.attributes(.response, text: String(repeating: "x", count: 20000), contentType: "text/plain", settings: all)
        XCTAssertEqual(string(attrs[BodyAttributes.response])?.count, 1000)
        XCTAssertEqual(attrs[BodyAttributes.responseTruncated], .bool(true))
        XCTAssertEqual(attrs[BodyAttributes.responseType], .string("text/plain"))
    }

    func testEmptyAndBinaryBodies() {
        XCTAssertTrue(BodyAttributes.attributes(.request, text: "  ", contentType: "application/json", settings: errors).isEmpty)
        let png = BodyAttributes.attributes(.response, data: Data(repeating: 7, count: 3000), contentType: "image/png", settings: errors)
        XCTAssertEqual(string(png[BodyAttributes.response]), "[binary · image/png · 3 KB]")
        let sse = BodyAttributes.attributes(.response, data: Data("data: 1\n\n".utf8), contentType: "text/event-stream", settings: errors)
        XCTAssertEqual(string(sse[BodyAttributes.response]), "[event stream]")
    }

    // MARK: Uploads

    func testMultipartKeepsEveryFieldInOrder() {
        let boundary = "zharpBoundary42"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nHoliday\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\nupload-secret\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"me.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(Data(repeating: 1, count: 100 * 1024))
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"after\"\r\n\r\nstill-here\r\n--\(boundary)--\r\n".utf8))
        let type = "multipart/form-data; boundary=\(boundary)"
        let attrs = BodyAttributes.attributes(.request, data: body, contentType: type, settings: errors)
        XCTAssertEqual(string(attrs[BodyAttributes.request]),
                       #"{"title":"Holiday","password":"[Filtered]","avatar":"[file me.png · image/png · 100 KB]","after":"still-here"}"#)
        XCTAssertEqual(attrs[BodyAttributes.requestType], .string(type))
        XCTAssertNil(attrs[BodyAttributes.requestTruncated])
    }

    func testMultipartCutShortMarksThePartialFile() {
        let boundary = "b"
        let body = Data("--b\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n\r\n".utf8) + Data(repeating: 0, count: 2048)
        let attrs = BodyAttributes.attributes(.request, data: body, contentType: "multipart/form-data; boundary=\(boundary)", settings: errors)
        XCTAssertEqual(string(attrs[BodyAttributes.request]), #"{"f":"[file a.bin · 2 KB+]"}"#)
        XCTAssertEqual(attrs[BodyAttributes.requestTruncated], .bool(true))
    }

    // MARK: URLs

    func testURLSecretsFiltered() {
        XCTAssertEqual(BodyAttributes.redactURL("https://api.example.com/reset?token=abc123&page=2#top"),
                       "https://api.example.com/reset?token=[Filtered]&page=2#top")
        XCTAssertEqual(BodyAttributes.redactURL("https://x.test/p?key=k1&sig=s&code=c&state=st&q=shoes"),
                       "https://x.test/p?key=[Filtered]&sig=[Filtered]&code=[Filtered]&state=[Filtered]&q=shoes")
        XCTAssertEqual(BodyAttributes.redactURL("https://user:pass@x.test/a?token="), "https://x.test/a?token=")
        XCTAssertEqual(BodyAttributes.redactURL("https://x.test/a"), "https://x.test/a")
    }
}
