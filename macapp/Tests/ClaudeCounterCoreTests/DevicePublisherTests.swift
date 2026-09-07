import XCTest
@testable import ClaudeCounterCore

final class DevicePublisherTests: XCTestCase {

    private let url = URL(string: "https://example.workers.dev/state")!

    private func payload(day: Double) -> DevicePayload {
        var t = Totals()
        let k = SeriesKey(source: "claude/claude", vendor: "claude", model: "claude-opus-5")
        t.day[k] = ModelDay(usd: day, tokens: .zero)
        t.month[k] = ModelDay(usd: 100, tokens: .zero)
        return DevicePayload.build(totals: t, statuses: [], gauges: [], sessions: [], warnPct: 80,
                                   now: Date(timeIntervalSince1970: 0))
    }

    func test_publish_sendsPutWithBearerAndJSON() async throws {
        let mock = RecordingSession(status: 204)
        let pub = DevicePublisher()
        let out = await pub.publish(payload(day: 1), to: url, token: "w-secret", session: mock)
        XCTAssertEqual(out, .sent)
        let reqs = await mock.requests
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].httpMethod, "PUT")
        XCTAssertEqual(reqs[0].url, url)
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "Authorization"), "Bearer w-secret")
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(reqs[0].httpBody, try payload(day: 1).encoded())
        XCTAssertEqual(reqs[0].timeoutInterval, 10)
    }

    func test_publish_skipsIdenticalBody() async {
        let mock = RecordingSession(status: 204)
        let pub = DevicePublisher()
        _ = await pub.publish(payload(day: 1), to: url, token: "t", session: mock)
        let second = await pub.publish(payload(day: 1), to: url, token: "t", session: mock)
        XCTAssertEqual(second, .unchanged)
        let count = await mock.requests.count
        XCTAssertEqual(count, 1)
    }

    func test_publish_sendsAgainWhenBodyChanges() async {
        let mock = RecordingSession(status: 204)
        let pub = DevicePublisher()
        _ = await pub.publish(payload(day: 1), to: url, token: "t", session: mock)
        let out = await pub.publish(payload(day: 2), to: url, token: "t", session: mock)
        XCTAssertEqual(out, .sent)
        let count = await mock.requests.count
        XCTAssertEqual(count, 2)
    }

    func test_publish_httpErrorReportsAndRetriesNextTime() async {
        let mock = RecordingSession(status: 401)
        let pub = DevicePublisher()
        let first = await pub.publish(payload(day: 1), to: url, token: "bad", session: mock)
        XCTAssertEqual(first, .failed("HTTP 401"))
        await mock.setStatus(204)
        let second = await pub.publish(payload(day: 1), to: url, token: "bad", session: mock)
        XCTAssertEqual(second, .sent, "a failed send must not be remembered as sent")
    }

    func test_publish_transportErrorReportsMessage() async {
        let mock = RecordingSession(status: 204, error: URLError(.notConnectedToInternet))
        let pub = DevicePublisher()
        let out = await pub.publish(payload(day: 1), to: url, token: "t", session: mock)
        guard case .failed(let msg) = out else { return XCTFail("expected .failed") }
        XCTAssertFalse(msg.isEmpty)
    }
}

/// Records every request; answers with a fixed status or throws.
actor RecordingSession: URLSessionProtocol {
    private(set) var requests: [URLRequest] = []
    private var status: Int
    private let error: Error?

    init(status: Int, error: Error? = nil) {
        self.status = status
        self.error = error
    }

    func setStatus(_ s: Int) { status = s }

    func dataReturning(from url: URL) async throws -> (Data, URLResponse) {
        try await dataReturning(for: URLRequest(url: url))
    }

    func dataReturning(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let error { throw error }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(), resp)
    }
}
