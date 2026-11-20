import Foundation
import Observation
import SwiftUI
import Translation
import SubtitleKit
import TranslationKit

// OWNER: translation agent.
//
// Apple's Translation framework (iOS 18) only hands out a `TranslationSession` inside SwiftUI's
// `.translationTask(_:action:)` modifier, for as long as the view is on screen. The broker below
// bridges that view-scoped session to the engine's async provider protocol: the provider
// enqueues batches, and the host modifier (attached to the Translate sheet) serves them with the
// session. Closing the sheet ends the session; queued batches fail and the engine keeps its
// checkpoint, so the job can be resumed.

enum AppleTranslationAvailability: Equatable {
    case unknown
    /// Languages are on the device.
    case installed
    /// Supported; iOS asks to download the languages on first use.
    case needsDownload
    case unsupported

    var label: String {
        switch self {
        case .unknown: return "Checking availability…"
        case .installed: return "English and Arabic are installed on this iPhone."
        case .needsDownload: return "Supported. iOS will ask to download English and Arabic the first time."
        case .unsupported: return "Not supported on this iPhone."
        }
    }
}

@Observable
@MainActor
final class AppleTranslationBroker {
    /// Read by the host modifier; setting/invalidating it (re)starts the session.
    var configuration: TranslationSession.Configuration? = nil {
        didSet { configurationGeneration &+= 1 }
    }
    /// Bumped on every (re)configuration so a finished session only clears its own configuration.
    @ObservationIgnored private var configurationGeneration = 0
    private(set) var isServing = false
    /// True while iOS prepares the languages (it may show a download prompt).
    private(set) var isPreparing = false

    private struct PendingBatch {
        let id: UUID
        let requests: [TranslationSession.Request]
        let continuation: CheckedContinuation<[TranslationSession.Response], Error>
    }

    @ObservationIgnored private var queue: [PendingBatch] = []
    @ObservationIgnored private var watchdogs: [UUID: Task<Void, Never>] = [:]

    /// How long a batch may wait for a session before it fails (the sheet must be open).
    private let startTimeout: TimeInterval = 20
    /// The serving loop ends after this long without work; the next job restarts it.
    private let idleTimeout: TimeInterval = 30

    static func availability(source: LanguageCode = .english, target: LanguageCode = .arabic) async -> AppleTranslationAvailability {
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: source.rawValue),
                                                         to: Locale.Language(identifier: target.rawValue))
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Translates `parts` (client id -> text) and returns client id -> translated text.
    func translate(_ parts: [(id: String, text: String)], source: LanguageCode, target: LanguageCode) async throws -> [String: String] {
        let sourceLanguage = Locale.Language(identifier: source.rawValue)
        let targetLanguage = Locale.Language(identifier: target.rawValue)
        if configuration?.source != sourceLanguage || configuration?.target != targetLanguage {
            configuration = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
        } else if !isServing {
            configuration?.invalidate()
            configurationGeneration &+= 1
        }
        let requests = parts.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
        let batchID = UUID()
        let responses: [TranslationSession.Response] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TranslationSession.Response], Error>) in
                self.enqueue(PendingBatch(id: batchID, requests: requests, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.failQueued(batchID, with: CancellationError()) }
        }
        var out: [String: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier { out[id] = response.targetText }
        }
        return out
    }

    private func enqueue(_ batch: PendingBatch) {
        queue.append(batch)
        let id = batch.id
        let timeout = startTimeout
        watchdogs[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isServing else { return }
            self.failQueued(id, with: TranslationKit.TranslationError.providerUnavailable(
                "On-device translation did not start. Keep the Translate sheet open while it runs."))
        }
    }

    private func failQueued(_ id: UUID, with error: Error) {
        watchdogs.removeValue(forKey: id)?.cancel()
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let batch = queue.remove(at: index)
        batch.continuation.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let pending = queue
        queue.removeAll()
        for batch in pending {
            watchdogs.removeValue(forKey: batch.id)?.cancel()
            batch.continuation.resume(throwing: error)
        }
    }

    /// Runs inside `.translationTask` for as long as the host view is visible.
    func serve(_ session: TranslationSession) async {
        isServing = true
        let servedGeneration = configurationGeneration
        defer {
            isServing = false
            isPreparing = false
            failAll(TranslationKit.TranslationError.providerUnavailable(
                "On-device translation stopped because the Translate sheet was closed. Open it and tap Resume."))
            // Without this, `.translationTask` would start a new session (and iOS could show the
            // language-download prompt) every time the sheet reappears, even with no job queued.
            if configurationGeneration == servedGeneration { configuration = nil }
        }
        isPreparing = true
        do {
            try await session.prepareTranslation()
        } catch {
            isPreparing = false
            failAll(Self.map(error))
            return
        }
        isPreparing = false
        var idleSince = Date()
        while !Task.isCancelled {
            guard !queue.isEmpty else {
                if Date().timeIntervalSince(idleSince) > idleTimeout { return }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                continue
            }
            let batch = queue.removeFirst()
            watchdogs.removeValue(forKey: batch.id)?.cancel()
            do {
                let responses = try await session.translations(from: batch.requests)
                batch.continuation.resume(returning: responses)
            } catch {
                batch.continuation.resume(throwing: Task.isCancelled ? CancellationError() : Self.map(error))
            }
            idleSince = Date()
        }
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError { return error }
        return TranslationKit.TranslationError.providerUnavailable("On-device translation failed: \(error.localizedDescription)")
    }
}

/// Attach to a view that stays on screen while on-device jobs run (the Translate sheet).
struct AppleTranslationHost: ViewModifier {
    let broker: AppleTranslationBroker

    func body(content: Content) -> some View {
        content.translationTask(broker.configuration) { session in
            await broker.serve(session)
        }
    }
}

/// Free, private, on-device provider. Translates line by line without surrounding context.
struct AppleTranslationProvider: TranslationProvider {
    static let providerID = "apple-on-device"
    let broker: AppleTranslationBroker
    let modelID = "apple-on-device"

    var descriptor: TranslationProviderDescriptor { Self.descriptor }

    static var descriptor: TranslationProviderDescriptor {
        TranslationProviderDescriptor(
            id: providerID, displayName: "Apple on-device",
            summary: "Free and private: runs on this iPhone and nothing leaves the device. Translates each line on its own, without the surrounding dialogue, so names and gender agreement can vary.",
            isPaid: false, requiresAPIKey: false, usesContext: false, recommendedChunkSize: 20)
    }

    func translate(_ request: TranslationChunkRequest) async throws -> TranslationChunkResponse {
        // Apple's model does not keep markup, so tags are removed before translation and
        // whole-line italics are restored by the engine's post-processor. Speaker-dash lines are
        // translated separately; other multi-line cues are joined into one sentence.
        var parts: [(id: String, text: String)] = []
        var layout: [(unitID: String, partIDs: [String])] = []
        for unit in request.units {
            let plain = TextCleanup.stripInlineTags(unit.text)
            let lines = plain.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let isDialogue = lines.count > 1 && lines.allSatisfy { $0.hasPrefix("-") }
            if isDialogue {
                let ids = lines.indices.map { "\(unit.id)#\($0)" }
                for (partID, line) in zip(ids, lines) { parts.append((partID, line)) }
                layout.append((unit.id, ids))
            } else {
                parts.append((unit.id, lines.joined(separator: " ")))
                layout.append((unit.id, [unit.id]))
            }
        }
        let translated = try await broker.translate(parts, source: request.source, target: request.target.code)
        var out: [String: String] = [:]
        for entry in layout {
            let pieces = entry.partIDs.compactMap { translated[$0] }
            guard pieces.count == entry.partIDs.count else { continue }
            out[entry.unitID] = pieces.joined(separator: "\n")
        }
        return TranslationChunkResponse(translations: out)
    }
}
