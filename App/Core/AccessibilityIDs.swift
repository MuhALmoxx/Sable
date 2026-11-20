import Foundation

// SHARED with the UI test target (compiled into both). Add identifiers; never rename existing ones.
enum AX {
    enum Library {
        static let screen = "library.screen"
        static let importVideo = "library.importVideo"
        static let search = "library.search"
        static let sort = "library.sort"
        static let settings = "library.settings"
        static let emptyState = "library.empty"
        static func item(_ title: String) -> String { "library.item.\(title)" }
        static let itemPrefix = "library.item."
        static let remove = "library.remove"
    }
    enum Player {
        static let screen = "player.screen"
        static let surface = "player.surface"
        static let playPause = "player.playPause"
        static let close = "player.close"
        static let scrubber = "player.scrubber"
        static let currentTime = "player.currentTime"
        static let duration = "player.duration"
        static let skipBack = "player.skipBack"
        static let skipForward = "player.skipForward"
        static let subtitlesButton = "player.subtitles"
        static let audioButton = "player.audio"
        static let speedButton = "player.speed"
        static let aspectButton = "player.aspect"
        static let pipButton = "player.pip"
        static let moreButton = "player.more"
        static let translateButton = "player.translate"
        static let timingButton = "player.timing"
        static let syncButton = "player.sync"
        static let subtitleText = "player.subtitleText"
        static let errorMessage = "player.error"
        static let loading = "player.loading"
    }
    enum Tracks {
        static let sheet = "tracks.sheet"
        static func subtitle(_ id: String) -> String { "tracks.subtitle.\(id)" }
        static let subtitleOff = "tracks.subtitle.off"
        static func audio(_ id: String) -> String { "tracks.audio.\(id)" }
        static let importSubtitle = "tracks.importSubtitle"
    }
    enum Translation {
        static let sheet = "translation.sheet"
        static let sourcePicker = "translation.source"
        static let providerPicker = "translation.provider"
        static let start = "translation.start"
        static let cancel = "translation.cancel"
        static let resume = "translation.resume"
        static let progress = "translation.progress"
        static let progressLabel = "translation.progressLabel"
        static let done = "translation.done"
        static let showArabic = "translation.showArabic"
        static let export = "translation.export"
        static let exportedPath = "translation.exportedPath"
        static let confirmPaid = "translation.confirmPaid"
        // Added by the translation agent.
        static func sourceTrack(_ id: String) -> String { "translation.sourceTrack.\(id)" }
        static func provider(_ id: String) -> String { "translation.provider.\(id)" }
        static let claudeModel = "translation.claudeModel"
        static let addAPIKey = "translation.addAPIKey"
        static let estimate = "translation.estimate"
        static let cancelConfirm = "translation.cancelConfirm"
        static let useCached = "translation.useCached"
        static let translateAgain = "translation.translateAgain"
        static let discard = "translation.discard"
        static let error = "translation.error"
        static let retry = "translation.retry"
        static let showEnglish = "translation.showEnglish"
        static let preview = "translation.preview"
        static let exportApplyOffset = "translation.exportApplyOffset"
        static let exportRTLMarks = "translation.exportRTLMarks"
        static let share = "translation.share"
    }
    enum Timing {
        static let panel = "timing.panel"
        static let offsetValue = "timing.offsetValue"
        static let offsetMeaning = "timing.offsetMeaning"
        static let minusOne = "timing.minus1"
        static let minusTenth = "timing.minus0.1"
        static let plusTenth = "timing.plus0.1"
        static let plusOne = "timing.plus1"
        static let entry = "timing.entry"
        static let apply = "timing.apply"
        static let reset = "timing.reset"
        static let undo = "timing.undo"
    }
    enum Sync {
        static let flow = "sync.flow"
        static let replay = "sync.replay"
        static let mark = "sync.mark"
        static let markedTime = "sync.markedTime"
        static let nudgeBack = "sync.nudgeBack"
        static let nudgeForward = "sync.nudgeForward"
        static let next = "sync.next"
        static let question = "sync.question"
        static func candidate(_ cueID: String) -> String { "sync.candidate.\(cueID)" }
        static let widen = "sync.widen"
        static let search = "sync.search"
        static let computedOffset = "sync.computedOffset"
        static let apply = "sync.apply"
        static let preview = "sync.preview"
        static let confirm = "sync.confirm"
        static let undo = "sync.undo"
    }
    enum Settings {
        static let screen = "settings.screen"
        static let doubleTap = "settings.doubleTap"
        static let apiKeyField = "settings.apiKey"
        static let licenses = "settings.licenses"
        // Added by the translation agent.
        static let apiKeySave = "settings.apiKey.save"
        static let apiKeyTest = "settings.apiKey.test"
        static let apiKeyRemove = "settings.apiKey.remove"
        static let apiKeyStatus = "settings.apiKey.status"
        static func defaultProvider(_ id: String) -> String { "settings.translationProvider.\(id)" }
        static func claudeModel(_ id: String) -> String { "settings.claudeModel.\(id)" }
    }
}
