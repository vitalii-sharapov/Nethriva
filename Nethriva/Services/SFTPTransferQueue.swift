import AppKit
import SwiftUI

enum SFTPTransferState: Equatable {
    case queued, running, completed, cancelled, skipped, interrupted, conflict, failed(String)
    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Transferring"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .interrupted: "Interrupted — retry when ready"
        case .conflict: "Destination exists — choose an action"
        case .failed(let message): message
        }
    }
    var retryable: Bool {
        switch self { case .cancelled, .interrupted, .failed: true; default: false }
    }
}

struct SFTPTransferJob: Identifiable {
    enum Operation { case upload(URL, String), download(SFTPFileItem, URL) }
    let id = UUID()
    let operation: Operation
    let name: String
    var state: SFTPTransferState = .queued
    var policy: SFTPConflictPolicy = .ask
    var bytes: Int64 = 0
    var total: Int64?
    var bytesPerSecond: Double = 0
    var updated = Date()
}

@MainActor
final class SFTPTransferQueue: ObservableObject {
    @Published private(set) var jobs: [SFTPTransferJob] = []
    private let connection: RemoteConnection
    private let service: any SFTPTransferring
    private var password: String?
    private var worker: Task<Void, Never>?
    private var activeID: UUID?
    private var suspended = false
    var onUploadFinished: (() async -> Void)?
    init(connection: RemoteConnection, service: any SFTPTransferring = SFTPService()) { self.connection = connection; self.service = service }
    func configure(password: String?) { self.password = password }
    func upload(_ urls: [URL], to directory: String) {
        for url in urls where url.isFileURL { jobs.append(.init(operation: .upload(url, directory), name: url.lastPathComponent)) }
        start()
    }
    func download(_ item: SFTPFileItem, to url: URL) { jobs.append(.init(operation: .download(item, url), name: item.name)); start() }
    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[index].state == .queued || jobs[index].state == .running || jobs[index].state == .conflict else { return }
        jobs[index].state = .cancelled
        if activeID == id { worker?.cancel(); service.close() }
    }
    func retry(_ id: UUID, policy: SFTPConflictPolicy? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.retryable || jobs[index].state == .conflict else { return }
        if let policy { jobs[index].policy = policy }
        jobs[index].bytes = 0; jobs[index].total = nil; jobs[index].bytesPerSecond = 0
        jobs[index].state = .queued
        start()
    }
    func skip(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .conflict else { return }
        jobs[index].state = .skipped
    }
    func clearFinished() { jobs.removeAll { $0.state == .completed || $0.state == .cancelled || $0.state == .skipped } }
    func suspend() {
        suspended = true
        for index in jobs.indices where jobs[index].state == .queued || jobs[index].state == .running { jobs[index].state = .interrupted }
        worker?.cancel(); service.close()
    }
    func resume() { suspended = false } // Never silently replay remote writes.
    func close() { suspend(); onUploadFinished = nil; password = nil }
    private func update(_ progress: SFTPTransferProgress, id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        let elapsed = max(0.1, Date().timeIntervalSince(jobs[index].updated))
        jobs[index].bytesPerSecond = Double(max(0, progress.bytes - jobs[index].bytes)) / elapsed
        jobs[index].bytes = progress.bytes; jobs[index].total = progress.total; jobs[index].updated = Date()
    }
    private func start() {
        guard worker == nil, !suspended, jobs.contains(where: { $0.state == .queued }) else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { worker = nil; activeID = nil; if !suspended { start() } }
            while !Task.isCancelled, !suspended, let index = jobs.firstIndex(where: { $0.state == .queued }) {
                let job = jobs[index]
                activeID = job.id; jobs[index].state = .running; jobs[index].updated = Date()
                do {
                    let progress: @Sendable (SFTPTransferProgress) -> Void = { [weak self] value in
                        Task { @MainActor in self?.update(value, id: job.id) }
                    }
                    switch job.operation {
                    case .upload(let url, let directory):
                        try await service.upload(localURLs: [url], to: directory, connection: connection, password: password, policy: job.policy, progress: progress)
                    case .download(let item, let url):
                        try await service.download(item: item, to: url, connection: connection, password: password, policy: job.policy, progress: progress)
                    }
                    if let index = jobs.firstIndex(where: { $0.id == job.id }), jobs[index].state == .running { jobs[index].state = .completed }
                    if case .upload = job.operation { await onUploadFinished?() }
                } catch {
                    guard let index = jobs.firstIndex(where: { $0.id == job.id }), jobs[index].state == .running else { continue }
                    if error is CancellationError { jobs[index].state = .cancelled }
                    else if case SFTPServiceError.conflict = error { jobs[index].state = .conflict }
                    else { jobs[index].state = .failed(Self.safeFailure(error)) }
                }
            }
        }
    }
    private static func safeFailure(_ error: Error) -> String {
        if let error = error as? SFTPServiceError { return error.localizedDescription }
        return "The transfer failed. Check local access, free space, and the remote connection, then retry."
    }
}

struct SFTPTransferQueueView: View {
    @ObservedObject var queue: SFTPTransferQueue
    @State private var expanded = true
    var body: some View {
        if !queue.jobs.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(queue.jobs) { job in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(job.name).lineLimit(1)
                                    Spacer()
                                    if job.state.retryable { Button("Retry") { queue.retry(job.id) } }
                                    if job.state == .conflict {
                                        Menu("Resolve") {
                                            Button("Skip") { queue.skip(job.id) }
                                            Button("Rename automatically") { queue.retry(job.id, policy: .rename) }
                                            Button("Overwrite / merge folders", role: .destructive) { queue.retry(job.id, policy: .overwrite) }
                                        }
                                    }
                                    if job.state == .running || job.state == .queued { Button("Cancel") { queue.cancel(job.id) } }
                                }
                                if job.state == .running {
                                    ProgressView(value: Double(job.bytes), total: Double(max(1, job.total ?? max(1, job.bytes))))
                                    Text("\(ByteCountFormatter.string(fromByteCount: job.bytes, countStyle: .file)) · \(ByteCountFormatter.string(fromByteCount: Int64(job.bytesPerSecond), countStyle: .file))/s (current file)")
                                        .foregroundStyle(.secondary)
                                } else { Text(job.state.label).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            } label: {
                HStack {
                    Label("Transfers (\(queue.jobs.count))", systemImage: "arrow.up.arrow.down")
                    Spacer()
                    Button("Clear finished") { queue.clearFinished() }
                }
            }
            .font(.caption)
            .controlSize(.small)
            .padding(8)
            .background(.bar)
        }
    }
}
