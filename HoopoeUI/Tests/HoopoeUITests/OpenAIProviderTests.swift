import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HoopoeUI

final class OpenAIProviderTests: XCTestCase {
    func testStreamingContextLimitErrorUsesResponseBodyMessage() async throws {
        let session = FakeOpenAIHTTPSession(
            streamPlans: [
                .init(
                    statusCode: 400,
                    headers: [:],
                    errorBody: try jsonData([
                        "error": [
                            "message": "This model's maximum context length was exceeded.",
                        ],
                    ])
                ),
            ]
        )
        let provider = OpenAIProvider(apiKey: "", session: session)

        let events = try await collectEvents(
            from: provider.send(
                prompt: "prompt",
                model: "gpt-4o",
                system: nil,
                stream: true
            )
        )

        XCTAssertEqual(events, [.error(.contextTooLong)])
        XCTAssertEqual(await session.streamCallCount(), 1)
    }

    func testStreamingServerErrorPreservesNestedErrorMessage() async throws {
        let session = FakeOpenAIHTTPSession(
            streamPlans: [
                .init(
                    statusCode: 500,
                    headers: [:],
                    errorBody: try jsonData([
                        "error": [
                            "message": "OpenAI upstream exploded",
                        ],
                    ])
                ),
            ]
        )
        let provider = OpenAIProvider(apiKey: "", session: session)

        let events = try await collectEvents(
            from: provider.send(
                prompt: "prompt",
                model: "gpt-4o",
                system: nil,
                stream: true
            )
        )

        XCTAssertEqual(events, [.error(.serverError(message: "OpenAI upstream exploded"))])
    }

    func testStreamingRetriesRateLimitUsingRetryAfterHeader() async throws {
        let session = FakeOpenAIHTTPSession(
            streamPlans: [
                .init(statusCode: 429, headers: ["retry-after": "3"], errorBody: Data()),
                .init(
                    statusCode: 200,
                    headers: [:],
                    lines: [
                        try sseLine([
                            "choices": [
                                [
                                    "delta": [
                                        "content": "Hi",
                                    ],
                                ],
                            ],
                        ]),
                        try sseLine([
                            "usage": [
                                "prompt_tokens": 10,
                                "completion_tokens": 1,
                            ],
                        ]),
                        "data: [DONE]",
                    ]
                ),
            ]
        )
        let sleepRecorder = SleepRecorder()
        let provider = OpenAIProvider(
            apiKey: "",
            session: session,
            sleepHandler: { seconds in
                try await sleepRecorder.sleep(seconds: seconds)
            }
        )

        let events = try await collectEvents(
            from: provider.send(
                prompt: "prompt",
                model: "gpt-4o",
                system: nil,
                stream: true
            )
        )

        XCTAssertEqual(await session.streamCallCount(), 2)
        XCTAssertEqual(await sleepRecorder.recordedSeconds(), [3])
        XCTAssertEqual(events.first, .text("Hi"))

        guard case let .done(response)? = events.last else {
            XCTFail("Expected a final done event")
            return
        }

        XCTAssertEqual(response.fullText, "Hi")
        XCTAssertEqual(response.tokenUsage, TokenUsage(inputTokens: 10, outputTokens: 1))
    }

    func testStreamingStopsProcessingAfterDoneMarker() async throws {
        let session = FakeOpenAIHTTPSession(
            streamPlans: [
                .init(
                    statusCode: 200,
                    headers: [:],
                    lines: [
                        try sseLine([
                            "choices": [
                                [
                                    "delta": [
                                        "content": "Hello",
                                    ],
                                ],
                            ],
                        ]),
                        "data: [DONE]",
                        try sseLine([
                            "choices": [
                                [
                                    "delta": [
                                        "content": " should not appear",
                                    ],
                                ],
                            ],
                        ]),
                    ]
                ),
            ]
        )
        let provider = OpenAIProvider(apiKey: "", session: session)

        let events = try await collectEvents(
            from: provider.send(
                prompt: "prompt",
                model: "gpt-4o",
                system: nil,
                stream: true
            )
        )

        XCTAssertEqual(events.first, .text("Hello"))

        guard case let .done(response)? = events.last else {
            XCTFail("Expected a final done event")
            return
        }

        XCTAssertEqual(response.fullText, "Hello")
    }

    func testNonStreamingExtractsStructuredContentParts() async throws {
        let session = FakeOpenAIHTTPSession(
            dataPlans: [
                .init(
                    statusCode: 200,
                    headers: [:],
                    body: try jsonData([
                        "choices": [
                            [
                                "message": [
                                    "content": [
                                        ["text": "Hello"],
                                        ["text": " world"],
                                    ],
                                ],
                            ],
                        ],
                        "usage": [
                            "prompt_tokens": 8,
                            "completion_tokens": 2,
                        ],
                    ])
                ),
            ]
        )
        let provider = OpenAIProvider(apiKey: "", session: session)

        let events = try await collectEvents(
            from: provider.send(
                prompt: "prompt",
                model: "gpt-4o",
                system: nil,
                stream: false
            )
        )

        guard case let .done(response)? = events.last else {
            XCTFail("Expected a final done event")
            return
        }

        XCTAssertEqual(response.fullText, "Hello world")
        XCTAssertEqual(response.tokenUsage, TokenUsage(inputTokens: 8, outputTokens: 2))
    }

    func testNonStreamingRetriesRateLimitWithExponentialBackoffWhenHeaderMissing() async throws {
        let session = FakeOpenAIHTTPSession(
            dataPlans: [
                .init(statusCode: 429, headers: [:], body: Data()),
                .init(
                    statusCode: 200,
                    headers: [:],
                    body: try jsonData([
                        "choices": [
                            [
                                "message": [
                                    "content": "Recovered response",
                                ],
                            ],
                        ],
                        "usage": [
                            "prompt_tokens": 12,
                            "completion_tokens": 3,
                        ],
                    ])
                ),
            ]
        )
        let sleepRecorder = SleepRecorder()
        let provider = OpenAIProvider(
            apiKey: "",
            session: session,
            sleepHandler: { seconds in
                try await sleepRecorder.sleep(seconds: seconds)
            }
        )

        let events = try await collectEvents(
            from: provider.send(
                prompt: "prompt",
                model: "gpt-4o",
                system: nil,
                stream: false
            )
        )

        XCTAssertEqual(await session.dataCallCount(), 2)
        XCTAssertEqual(await sleepRecorder.recordedSeconds(), [2])

        guard case let .done(response)? = events.last else {
            XCTFail("Expected a final done event")
            return
        }

        XCTAssertEqual(response.fullText, "Recovered response")
        XCTAssertEqual(response.tokenUsage, TokenUsage(inputTokens: 12, outputTokens: 3))
    }

    func testRetryLatencyIncludesBackoffAndEarlierAttempts() async throws {
        let session = FakeOpenAIHTTPSession(
            dataPlans: [
                .init(statusCode: 429, headers: [:], body: Data()),
                .init(
                    statusCode: 200,
                    headers: [:],
                    body: try jsonData([
                        "choices": [
                            [
                                "message": [
                                    "content": "Recovered response",
                                ],
                            ],
                        ],
                        "usage": [
                            "prompt_tokens": 12,
                            "completion_tokens": 3,
                        ],
                    ])
                ),
            ]
        )
        let sleepRecorder = SleepRecorder()
        let dateProvider = StepDateProvider([
            Date(timeIntervalSince1970: 1_000),
            Date(timeIntervalSince1970: 1_003),
        ])
        let provider = OpenAIProvider(
            apiKey: "",
            session: session,
            sleepHandler: { seconds in
                try await sleepRecorder.sleep(seconds: seconds)
            },
            nowProvider: {
                await dateProvider.now()
            }
        )

        let events = try await collectEvents(
            from: provider.send(
                prompt: "prompt",
                model: "gpt-4o",
                system: nil,
                stream: false
            )
        )

        guard case let .done(response)? = events.last else {
            XCTFail("Expected a final done event")
            return
        }

        XCTAssertEqual(await sleepRecorder.recordedSeconds(), [2])
        XCTAssertEqual(response.latency, 3, accuracy: 0.000_1)
    }
}

private actor FakeOpenAIHTTPSession: OpenAIHTTPSession {
    struct StreamPlan: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let errorBody: Data?
        let lines: [String]

        init(
            statusCode: Int,
            headers: [String: String],
            errorBody: Data? = nil,
            lines: [String] = []
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.errorBody = errorBody
            self.lines = lines
        }
    }

    struct DataPlan: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private var streamPlans: [StreamPlan]
    private var dataPlans: [DataPlan]
    private var streamRequests = 0
    private var dataRequests = 0

    init(
        streamPlans: [StreamPlan] = [],
        dataPlans: [DataPlan] = []
    ) {
        self.streamPlans = streamPlans
        self.dataPlans = dataPlans
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        dataRequests += 1

        guard !dataPlans.isEmpty else {
            throw TestError.unexpectedDataRequest
        }

        let plan = dataPlans.removeFirst()
        return (plan.body, try makeResponse(for: request, statusCode: plan.statusCode, headers: plan.headers))
    }

    func stream(for request: URLRequest) async throws -> OpenAIHTTPStreamResponse {
        streamRequests += 1

        guard !streamPlans.isEmpty else {
            throw TestError.unexpectedStreamRequest
        }

        let plan = streamPlans.removeFirst()
        return OpenAIHTTPStreamResponse(
            response: try makeResponse(for: request, statusCode: plan.statusCode, headers: plan.headers),
            errorBody: plan.errorBody,
            lines: AsyncThrowingStream { continuation in
                for line in plan.lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        )
    }

    func streamCallCount() -> Int {
        streamRequests
    }

    func dataCallCount() -> Int {
        dataRequests
    }

    private func makeResponse(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String]
    ) throws -> HTTPURLResponse {
        try XCTUnwrap(
            HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            ),
            "Failed to construct HTTPURLResponse for test fixture"
        )
    }
}

private actor SleepRecorder {
    private var seconds: [TimeInterval] = []

    func sleep(seconds: TimeInterval) async throws {
        self.seconds.append(seconds)
    }

    func recordedSeconds() -> [TimeInterval] {
        seconds
    }
}

private actor StepDateProvider {
    private let dates: [Date]
    private var index = 0

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func now() -> Date {
        let clampedIndex = min(index, dates.count - 1)
        let date = dates[clampedIndex]
        index += 1
        return date
    }
}

private enum TestError: Error {
    case unexpectedDataRequest
    case unexpectedStreamRequest
}

private func collectEvents(
    from stream: AsyncThrowingStream<LLMEvent, Error>
) async throws -> [LLMEvent] {
    var events: [LLMEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func sseLine(_ object: Any) throws -> String {
    let data = try jsonData(object)
    return "data: \(String(decoding: data, as: UTF8.self))"
}
