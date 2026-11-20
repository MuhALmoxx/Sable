import Foundation
import Observation
import SubtitleKit
import LibraryKit
import TranslationKit

// OWNER: translation agent. Replace freely; AppServices constructs it with this initialiser.
@Observable
@MainActor
final class TranslationService {
    let library: LibraryStore
    let settings: AppSettings
    let keychain: KeychainStore

    init(library: LibraryStore, settings: AppSettings, keychain: KeychainStore) {
        self.library = library
        self.settings = settings
        self.keychain = keychain
    }
}
