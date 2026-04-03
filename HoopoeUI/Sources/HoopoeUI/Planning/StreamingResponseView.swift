import SwiftUI

/// Displays a streaming LLM response with progressive text rendering,
/// auto-scroll, status indicators, and token/cost tracking.
///
/// Designed to be reusable across plan generation, refinement, and synthesis views.
public struct StreamingResponseView: View {
    @State private var viewModel: StreamingResponseViewModel

    public init(stream: AsyncThrowingStream<LLMEvent, Error>) {
        _viewModel = State(initialValue: StreamingResponseViewModel(stream: stream))
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Response content
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(LocalizedStringKey(viewModel.accumulatedText))
                            .textSelection(.enabled)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()

                        // Invisible anchor for auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                }
                .onChange(of: viewModel.accumulatedText) {
                    if viewModel.shouldAutoScroll {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Status bar
            statusBar
        }
        .task {
            await viewModel.startStreaming()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Status indicator
            statusIndicator

            Spacer()

            // Token count
            if let usage = viewModel.tokenUsage {
                Label(
                    "\(usage.inputTokens + usage.outputTokens) tokens",
                    systemImage: "number"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Cost estimate
            if let cost = viewModel.costEstimate, cost > 0 {
                Text(String(format: "$%.4f", cost))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Action buttons
            if viewModel.state == .streaming {
                Button("Cancel", systemImage: "xmark.circle") {
                    viewModel.cancel()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
            }

            if viewModel.state == .complete {
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

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.streaming, .streaming),
                 (.complete, .complete), (.cancelled, .cancelled):
                true
            case (.error(let a), .error(let b)):
                a == b
            default:
                false
            }
        }
    }

    private(set) var accumulatedText = ""
    private(set) var state: State = .idle
    private(set) var tokenUsage: TokenUsage?
    private(set) var costEstimate: Double?
    var shouldAutoScroll = true

    private let stream: AsyncThrowingStream<LLMEvent, Error>
    private var streamTask: Task<Void, Never>?

    init(stream: AsyncThrowingStream<LLMEvent, Error>) {
        self.stream = stream
    }

    func startStreaming() async {
        state = .streaming

        do {
            for try await event in stream {
                switch event {
                case .text(let chunk):
                    accumulatedText += chunk

                case .done(let response):
                    accumulatedText = response.fullText
                    tokenUsage = response.tokenUsage
                    costEstimate = response.costEstimate
                    state = .complete
                    return

                case .error(let llmError):
                    state = .error(llmError.localizedDescription)
                    return
                }
            }
            // Stream ended without a .done event
            if state == .streaming {
                state = .complete
            }
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func cancel() {
        streamTask?.cancel()
        state = .cancelled
    }
}
