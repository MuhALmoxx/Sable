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
        // Added by the library agent:
        static let layoutToggle = "library.layoutToggle"
        static let importJob = "library.importJob"
        static let noResults = "library.noResults"
        static let clearSearch = "library.clearSearch"
        static let banner = "library.banner"
        static let rename = "library.rename"
        static let renameField = "library.renameField"
        static let addSubtitle = "library.addSubtitle"
        static let markUnwatched = "library.markUnwatched"
        static let subtitleTargetSheet = "library.subtitleTarget"
        static func subtitleTarget(_ title: String) -> String { "library.subtitleTarget.\(title)" }
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
        // Added by the library agent:
        static let back = "settings.back"
        static let defaultSpeed = "settings.defaultSpeed"
        static let resume = "settings.resume"
        static let vlcForAll = "settings.vlcForAll"
        static let subtitlePreview = "settings.subtitlePreview"
        static let subtitleSize = "settings.subtitleSize"
        static let subtitleBackground = "settings.subtitleBackground"
        static let subtitleFont = "settings.subtitleFont"
        static let showOriginal = "settings.showOriginal"
        static let storageTotal = "settings.storageTotal"
        static let clearThumbnails = "settings.clearThumbnails"
        static let clearSubtitleCache = "settings.clearSubtitleCache"
        static let version = "settings.version"
        static let licensesScreen = "settings.licensesScreen"
        static func license(_ id: String) -> String { "settings.license.\(id)" }
    }
}
