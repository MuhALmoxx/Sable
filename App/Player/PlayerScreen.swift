import SwiftUI
import UIKit
import SubtitleKit
import LibraryKit

// OWNER: playback agent.
struct PlayerScreen: View {
    let itemID: UUID
    @Environment(AppServices.self) private var services
    @State private var session: PlayerSession?
    @State private var missingItem = false

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if let session {
                PlayerContentView(session: session, onClose: close)
            } else if missingItem {
                VStack(spacing: Spacing.md) {
                    PixelMessage(glyph: .warning, title: "Video not found",
                                 message: "This video is no longer in your library.")
                        .accessibilityIdentifier(AX.Player.errorMessage)
                    Button("Close") { services.playingItemID = nil }
                        .buttonStyle(PixelButtonStyle(kind: .secondary))
                        .accessibilityIdentifier(AX.Player.close)
                }
                .padding(Spacing.lg)
            } else {
                PixelSpinner(size: 32).accessibilityIdentifier(AX.Player.loading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AX.Player.screen)
        .task {
            guard session == nil else { return }
            guard let item = services.library.item(id: itemID) else {
                missingItem = true
                return
            }
            let newSession = PlayerSession(item: item, services: services)
            session = newSession
            await newSession.start()
        }
        .onDisappear {
            session?.tearDown()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func close() {
        session?.tearDown()
        UIApplication.shared.isIdleTimerDisabled = false
        if DeviceControls.isLandscape { DeviceControls.toggleOrientation() }
        services.playingItemID = nil
    }
}

enum PlayerSheet: String, Identifiable {
    case tracks, audio, speed, aspect, translate, timing, sync
    var id: String { rawValue }
}

/// Everything on screen once a session exists.
struct PlayerContentView: View {
    let session: PlayerSession
    let onClose: () -> Void

    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase

    @State private var controlsVisible = true
    @State private var isLocked = false
    @State private var activeSheet: PlayerSheet?
    @State private var hideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var seekBadge: SeekBadge?
    @State private var badgeTask: Task<Void, Never>?
    @State private var pan: PanState?
    @State private var hudTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            Group {
                if landscape {
                    stage(size: geo.size, landscape: true)
                } else {
                    portraitLayout(size: geo.size)
                }
            }
            .statusBarHidden(landscape)
            .persistentSystemOverlays(landscape ? .hidden : .automatic)
        }
        .background(Palette.background.ignoresSafeArea())
        .sheet(item: $activeSheet, onDismiss: { scheduleHide() }) { sheet in
            sheetContent(sheet)
                .environment(services)
                .presentationBackground(Palette.background)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(6)
                .preferredColorScheme(.dark)
        }
        .onChange(of: session.isPlaying) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
            if playing { scheduleHide() } else { revealControls(autoHide: false) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.persistNow() }
        }
        .onAppear { scheduleHide() }
    }

    // MARK: Layouts

    private func portraitLayout(size: CGSize) -> some View {
        let ratio = Self.pictureRatio(session)
        let videoHeight = min((size.width / ratio).rounded(), size.height * 0.6)
        return VStack(spacing: 0) {
            stage(size: CGSize(width: size.width, height: videoHeight), landscape: false)
                .frame(width: size.width, height: videoHeight)
                .clipped()
            PortraitPanel(session: session, onTool: open)
            Spacer(minLength: 0)
        }
    }

    /// Video, subtitles, gestures and the overlaid controls. In landscape the picture runs
    /// edge to edge (ignoring the safe area) while the controls stay inside it.
    private func stage(size: CGSize, landscape: Bool) -> some View {
        ZStack {
            if landscape {
                videoLayers(size: size, landscape: true).ignoresSafeArea()
            } else {
                videoLayers(size: size, landscape: false)
            }
            chromeLayers(landscape: landscape)
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
    }

    private func videoLayers(size: CGSize, landscape: Bool) -> some View {
        let reserved: CGFloat = controlsVisible && !isLocked ? (landscape ? 150 : 56) : 0
        return ZStack {
            Color.black
            EngineSurface(engineView: session.engineView)
                .accessibilityHidden(true)
            SubtitleOverlay(session: session, reservedBottom: reserved)
            gestureLayer(size: size)
        }
    }

    @ViewBuilder
    private func chromeLayers(landscape: Bool) -> some View {
        ZStack {
            if controlsVisible && !isLocked && session.isLoaded {
                ControlsOverlay(session: session, landscape: landscape,
                                onClose: onClose,
                                onTool: open,
                                onLock: lock,
                                onInteraction: { scheduleHide() },
                                onScrubbingChanged: scrubbingChanged)
                    .transition(.opacity)
            }
            if isLocked {
                lockedOverlay
            }
            hud
            statusOverlay(landscape: landscape)
        }
    }

    // MARK: Gestures

    private func gestureLayer(size: CGSize) -> some View {
        let taps = SpatialTapGesture(count: 2)
            .onEnded { value in doubleTap(at: value.location, width: size.width) }
            .exclusively(before: SpatialTapGesture(count: 1).onEnded { _ in toggleControls() })
        let drag = DragGesture(minimumDistance: 16)
            .onChanged { value in panChanged(value, size: size) }
            .onEnded { value in panEnded(value, size: size) }
        let pinch = MagnifyGesture()
            .onEnded { value in
                if value.magnification > 1.12, session.aspectMode != .fill {
                    session.setAspectMode(.fill)
                    showBadge(SeekBadge(text: "FILL", side: .center))
                } else if value.magnification < 0.9, session.aspectMode != .fit {
                    session.setAspectMode(.fit)
                    showBadge(SeekBadge(text: "FIT", side: .center))
                }
            }
        return Color.clear
            .contentShape(Rectangle())
            .gesture(taps)
            .simultaneousGesture(drag)
            .simultaneousGesture(pinch)
            .allowsHitTesting(!isLocked && session.isLoaded)
            .accessibilityElement()
            .accessibilityLabel("Video")
            .accessibilityHint(controlsVisible ? "Double-tap to hide the controls" : "Double-tap to show the controls")
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityAction { toggleControls() }
            .accessibilityIdentifier(AX.Player.surface)
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            controlsVisible = false
        } else {
            revealControls(autoHide: true)
        }
    }

    private func doubleTap(at location: CGPoint, width: CGFloat) {
        let step = services.settings.doubleTapSeekSeconds
        let label = Int(step.rounded())
        if location.x < width / 3 {
            session.skip(by: -step)
            accumulateBadge(side: .leading, step: label)
        } else if location.x > width * 2 / 3 {
            session.skip(by: step)
            accumulateBadge(side: .trailing, step: label)
        } else {
            session.togglePlayPause()
        }
    }

    private func panChanged(_ value: DragGesture.Value, size: CGSize) {
        if pan == nil {
            let dx = value.translation.width
            let dy = value.translation.height
            if abs(dx) > abs(dy) {
                pan = .scrub(start: session.currentTime, target: session.currentTime)
            } else if value.startLocation.x < size.width / 2 {
                pan = .brightness(start: DeviceControls.brightness, level: DeviceControls.brightness)
            } else {
                pan = .ignored
            }
            hudTask?.cancel()
        }
        switch pan {
        case let .scrub(start, _):
            let span = session.duration > 0 ? min(session.duration, 120) : 120
            var target = start + Double(value.translation.width / max(size.width, 1)) * span
            if session.duration > 0 { target = min(max(0, target), session.duration) } else { target = max(0, target) }
            pan = .scrub(start: start, target: target)
            session.scrub(to: target)
        case let .brightness(start, _):
            let level = min(1, max(0, start - value.translation.height / max(size.height * 0.8, 1)))
            DeviceControls.brightness = level
            pan = .brightness(start: start, level: level)
        case .ignored, .none:
            break
        }
    }

    private func panEnded(_ value: DragGesture.Value, size: CGSize) {
        guard let current = pan else { return }
        if case let .scrub(_, target) = current {
            Task { await session.endScrub(at: target) }
        }
        // Keep the HUD a moment so the final value is readable.
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            pan = nil
        }
        if case .ignored = current { pan = nil }
        scheduleHide()
    }

    // MARK: Controls visibility

    private var autoHideEnabled: Bool {
        if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning { return false }
        #if DEBUG
        if UITestSupport.isUITesting { return false }
        #endif
        return true
    }

    private func revealControls(autoHide: Bool) {
        controlsVisible = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard autoHideEnabled, session.isPlaying, activeSheet == nil, !isScrubbing, !isLocked else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, session.isPlaying, activeSheet == nil, !isScrubbing else { return }
            controlsVisible = false
        }
    }

    private func scrubbingChanged(_ scrubbing: Bool) {
        isScrubbing = scrubbing
        if scrubbing { hideTask?.cancel() } else { scheduleHide() }
    }

    private func open(_ sheet: PlayerSheet) {
        hideTask?.cancel()
        activeSheet = sheet
    }

    private func lock() {
        hideTask?.cancel()
        isLocked = true
        controlsVisible = false
    }

    private var lockedOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    isLocked = false
                    revealControls(autoHide: true)
                } label: {
                    HStack(spacing: Spacing.xs) {
                        PixelIcon(.unlock, size: 16, color: Palette.textPrimary)
                        Text("Unlock").font(Typo.callout).foregroundStyle(Palette.textPrimary)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .frame(minHeight: Spacing.touch)
                    .background(Rectangle().fill(Palette.scrim))
                    .overlay(Rectangle().stroke(Palette.border, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unlock controls")
                .accessibilityIdentifier(AX.Player.unlock)
            }
            Spacer()
        }
        .padding(Spacing.md)
    }

    // MARK: HUD (seek badges, pan feedback)

    private func accumulateBadge(side: SeekBadge.Side, step: Int) {
        var amount = step
        if let current = seekBadge, current.side == side, let value = current.seconds { amount += value }
        let sign = side == .leading ? "\u{2212}" : "+"
        showBadge(SeekBadge(text: "\(sign)\(amount)", side: side, seconds: amount))
    }

    private func showBadge(_ badge: SeekBadge) {
        seekBadge = badge
        badgeTask?.cancel()
        badgeTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            seekBadge = nil
        }
    }

    @ViewBuilder
    private var hud: some View {
        if let seekBadge {
            HStack {
                if seekBadge.side != .leading { Spacer() }
                Text(seekBadge.text)
                    .font(Typo.title)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .background(Rectangle().fill(Palette.scrim))
                    .overlay(Rectangle().stroke(Palette.accent, lineWidth: 1))
                    .accessibilityIdentifier(AX.Player.seekBadge)
                if seekBadge.side != .trailing { Spacer() }
            }
            .padding(.horizontal, Spacing.xl)
            .allowsHitTesting(false)
        }
        switch pan {
        case let .scrub(start, target):
            VStack(spacing: Spacing.xxs) {
                Text(TimecodeFormatter.precise(target)).font(Typo.monoLarge).foregroundStyle(Palette.textPrimary)
                Text(TimecodeFormatter.signedOffset(target - start)).font(Typo.mono).foregroundStyle(Palette.accent)
            }
            .padding(Spacing.md)
            .background(Rectangle().fill(Palette.scrim))
            .overlay(Rectangle().stroke(Palette.border, lineWidth: 1))
            .allowsHitTesting(false)
        case let .brightness(_, level):
            VStack(spacing: Spacing.xs) {
                Text("BRIGHTNESS").font(Typo.micro).foregroundStyle(Palette.textSecondary)
                PixelProgressBar(value: Double(level), height: 6).frame(width: 120)
            }
            .padding(Spacing.md)
            .background(Rectangle().fill(Palette.scrim))
            .overlay(Rectangle().stroke(Palette.border, lineWidth: 1))
            .allowsHitTesting(false)
        case .ignored, .none:
            EmptyView()
        }
    }

    // MARK: Loading / failure / notices

    @ViewBuilder
    private func statusOverlay(landscape: Bool) -> some View {
        switch session.status {
        case .idle, .loading:
            VStack(spacing: Spacing.sm) {
                PixelSpinner(size: 32)
                Text(session.loadingMessage).font(Typo.body).foregroundStyle(Palette.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(session.loadingMessage)
            .accessibilityIdentifier(AX.Player.loading)
            closeOnlyBar
        case let .failed(message):
            failureView(message)
        case .ready, .ended:
            VStack(spacing: Spacing.xs) {
                subtitleStatusPill
                if let notice = session.notice {
                    Button { session.dismissNotice() } label: {
                        InlineMessage(glyph: .info, text: notice, tint: Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Dismiss")
                    .accessibilityIdentifier(AX.Player.notice)
                }
                Spacer()
            }
            .frame(maxWidth: 520)
            .padding(.top, landscape ? 64 : 52)
            .padding(.horizontal, Spacing.md)
            if session.isBuffering && session.isPlaying {
                PixelSpinner(size: 28).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var subtitleStatusPill: some View {
        switch session.subtitleLoadState {
        case let .loading(progress):
            let text = progress.map { "Extracting subtitles \(Int(($0 * 100).rounded()))%" } ?? "Loading subtitles…"
            HStack(spacing: Spacing.xs) {
                PixelSpinner(size: 14)
                Text(text).font(Typo.callout).foregroundStyle(Palette.textPrimary)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: 32)
            .background(Rectangle().fill(Palette.scrim))
            .overlay(Rectangle().stroke(Palette.border, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
            .accessibilityIdentifier(AX.Player.subtitleStatus)
            .allowsHitTesting(false)
        case let .failed(message):
            InlineMessage(glyph: .warning, text: message, tint: Palette.danger)
                .accessibilityIdentifier(AX.Player.subtitleStatus)
        case .idle:
            EmptyView()
        }
    }

    private var closeOnlyBar: some View {
        VStack {
            HStack {
                PixelIconButton(.close, label: "Close player", action: onClose)
                    .accessibilityIdentifier(AX.Player.close)
                Spacer()
            }
            Spacer()
        }
        .padding(Spacing.xs)
    }

    private func failureView(_ message: String) -> some View {
        ZStack {
            Palette.background.opacity(0.92)
            ScrollView {
                VStack(spacing: Spacing.md) {
                    PixelMessage(glyph: .warning, title: "Can't play this video", message: message)
                        .accessibilityIdentifier(AX.Player.errorMessage)
                    VStack(spacing: Spacing.xs) {
                        Button("Retry") { Task { await session.retry() } }
                            .buttonStyle(PixelButtonStyle(kind: .primary))
                            .accessibilityIdentifier(AX.Player.retry)
                        if session.lastAttemptedEngine != .vlc {
                            Button("Try VLC engine") { Task { await session.retryWithVLC() } }
                                .buttonStyle(PixelButtonStyle(kind: .secondary))
                                .accessibilityIdentifier(AX.Player.tryVLC)
                        }
                        Button("Close", action: onClose)
                            .buttonStyle(PixelButtonStyle(kind: .ghost))
                            .accessibilityIdentifier(AX.Player.close)
                    }
                }
                .frame(maxWidth: 420)
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .tracks:
            TrackSheet(session: session, onClose: { activeSheet = nil })
                .presentationDetents([.medium, .large])
        case .audio:
            AudioTrackSheet(session: session, onClose: { activeSheet = nil })
                .presentationDetents([.height(320), .medium])
        case .speed:
            SpeedSheet(session: session, onClose: { activeSheet = nil })
                .presentationDetents([.height(300)])
        case .aspect:
            AspectSheet(session: session, onClose: { activeSheet = nil })
                .presentationDetents([.height(320)])
        case .translate:
            TranslationSheet(session: session)
                .presentationDetents([.medium, .large])
        case .timing:
            TimingPanel(session: session, onClose: { activeSheet = nil })
                .presentationDetents([.height(340)])
                .presentationBackgroundInteraction(.enabled)
        case .sync:
            GuidedSyncView(session: session, onClose: { activeSheet = nil })
                .presentationDetents([.fraction(0.62), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.62)))
        }
    }

    /// Picture width / height for the portrait stage (16:9 until the size is known).
    static func pictureRatio(_ session: PlayerSession) -> CGFloat {
        if let ratio = VideoGeometry.forcedRatio(for: session.aspectMode) { return ratio }
        if let size = session.videoSize, size.width > 0, size.height > 0 {
            return min(max(size.width / size.height, 0.5), 3)
        }
        return 16.0 / 9.0
    }
}

struct SeekBadge: Equatable {
    enum Side { case leading, center, trailing }
    var text: String
    var side: Side
    var seconds: Int? = nil
}

enum PanState: Equatable {
    case scrub(start: TimeInterval, target: TimeInterval)
    case brightness(start: CGFloat, level: CGFloat)
    case ignored
}
