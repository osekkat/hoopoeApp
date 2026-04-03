import AppKit
import Observation
import SwiftUI

private enum StreamingBottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Displays a streaming LLM response with progressive text rendering,
/// auto-scroll, status indicators, and token/cost tracking.
///
/// Designed to be reusable across plan generation, refinement, and synthesis views.
public struct StreamingResponseView: View {
    @State private var viewModel: StreamingResponseViewModel
    private let bottomAnchorID = "streaming-response-bottom"

    public init(stream: AsyncThrowingStream<LLMEvent, Error>) {
        _viewModel = State(initialValue: StreamingResponseViewModel(stream: stream))
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { scrollGeometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(.init(viewModel.renderedText))
                                .textSelection(.enabled)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()

                            // Track the bottom marker so we can restore auto-scroll when the user returns.
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: StreamingBottomOffsetKey.self,
                                            value: geometry.frame(in: .named("stream-scroll")).maxY
                                        )
                                    }
                                )
                        }
                    }
                    .coordinateSpace(name: "stream-scroll")
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4).onChanged { _ in
                            viewModel.pauseAutoScroll()
                        }
                    )
                    .onPreferenceChange(StreamingBottomOffsetKey.self) { bottomMaxY in
                        viewModel.reconcileAutoScroll(
                            bottomMaxY: bottomMaxY,
                            viewportHeight: scrollGeometry.size.height
                        )
                    }
                    .onChange(of: viewModel.renderedText) {
                        guard viewModel.shouldAutoScroll else {
                            return
                        }
                        scrollToBottom(with: proxy)
                    }
                    .onChange(of: viewModel.scrollRequestID) {
                        scrollToBottom(with: proxy)
                    }
                }
            }

            Divider()

            statusBar
        }
        .task {
            await viewModel.startStreaming()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusIndicator

            Spacer()

            if let usage = viewModel.tokenUsage {
                Label("\(usage.totalTokens) tokens", systemImage: "number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let cost = viewModel.costEstimate, cost > 0 {
                Text(String(format: "$%.4f", cost))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !viewModel.shouldAutoScroll, !viewModel.renderedText.isEmpty {
                Button("Jump to Latest", systemImage: "arrow.down.to.line") {
                    viewModel.requestScrollToBottom()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if viewModel.state == .streaming {
                Button("Cancel", systemImage: "xmark.circle") {
                    viewModel.cancel()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
            }

            if viewModel.state == .complete || viewModel.state == .cancelled {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.accumulatedText, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch viewModel.state {
        case .idle:
            Label("Ready", systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .streaming:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Streaming...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .complete:
            Label("Complete", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)

        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)

        case .cancelled:
            Label("Cancelled", systemImage: "stop.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

// MARK: - View Model

@Observable
@MainActor
final class StreamingResponseViewModel {
    enum State: Equatable {
        case idle
        case streaming
        case complete
        case error(String)
        case cancelled
    }

    private(set) var accumulatedText = ""
    private(set) var renderedText = ""
    private(set) var state: State = .idle
    private(set) var tokenUsage: TokenUsage?
    private(set) var costEstimate: Double?
    private(set) var scrollRequestID = 0
    var shouldAutoScroll = true

    private let stream: AsyncThrowingStream<LLMEvent, Error>
    private var streamTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?

    init(stream: AsyncThrowingStream<LLMEvent, Error>) {
        self.stream = stream
    }

    func startStreaming() async {
        guard streamTask == nil else {
            return
        }

        let task = Task { [stream] in
            await consume(stream: stream)
        }
        streamTask = task
        await task.value
        streamTask = nil
    }

    func cancel() {
        streamTask?.cancel()
        renderTask?.cancel()
        flushRenderedText()
        state = .cancelled
    }

    func pauseAutoScroll() {
        guard shouldAutoScroll else {
            return
        }
        shouldAutoScroll = false
    }

    func requestScrollToBottom() {
        shouldAutoScroll = true
        scrollRequestID += 1
    }

    func reconcileAutoScroll(bottomMaxY: CGFloat, viewportHeight: CGFloat) {
        let isNearBottom = bottomMaxY <= viewportHeight + 24
        if !shouldAutoScroll, isNearBottom {
            shouldAutoScroll = true
        }
    }

    private func consume(stream: AsyncThrowingStream<LLMEvent, Error>) async {
        reset()
        state = .streaming

        do {
            for try await event in stream {
                switch event {
                case .text(let chunk):
                    accumulatedText += chunk
                    scheduleRenderedTextFlush()

                case .done(let response):
                    accumulatedText = response.fullText
                    tokenUsage = response.tokenUsage
                    costEstimate = response.costEstimate
                    flushRenderedText()
                    state = .complete
                    return

                case .error(let llmError):
                    flushRenderedText()
                    state = .error(llmError.localizedDescription)
                    return
                }
            }

            flushRenderedText()
            if state == .streaming {
                state = .complete
            }
        } catch is CancellationError {
            flushRenderedText()
            state = .cancelled
        } catch {
            flushRenderedText()
            state = .error(error.localizedDescription)
        }
    }

    private func reset() {
        accumulatedText = ""
        renderedText = ""
        tokenUsage = nil
        costEstimate = nil
        shouldAutoScroll = true
    }

    private func scheduleRenderedTextFlush() {
        renderTask?.cancel()
        renderTask = Task {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            renderedText = accumulatedText
        }
    }

    private func flushRenderedText() {
        renderTask?.cancel()
        renderTask = nil
        renderedText = accumulatedText
    }
}
