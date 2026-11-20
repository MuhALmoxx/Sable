import SwiftUI
import UIKit
import UniformTypeIdentifiers

// OWNER: playback agent. Files picker for SRT/VTT/ASS/SSA subtitle files (copied into Sable).
struct SubtitleDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    /// Subtitle types by extension (resolves to the app's declared types), with plain-text
    /// fallbacks so files with unusual type metadata can still be picked.
    static var contentTypes: [UTType] {
        var types: [UTType] = []
        for ext in ["srt", "vtt", "ass", "ssa"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        for identifier in ["com.murisixz.sable.subrip", "com.murisixz.sable.webvtt", "com.murisixz.sable.ass"] {
            if let type = UTType(identifier), !types.contains(type) { types.append(type) }
        }
        if types.count < 4 {
            types.append(.plainText)
            types.append(.text)
        }
        return types
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
