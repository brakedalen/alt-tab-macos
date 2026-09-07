import Cocoa
import ScreenCaptureKit

@available(macOS 26.0, *)
class WindowCaptureScreenshots {
    static let cachedSCWindows = ConcurrentArray<SCWindow>()
    // Two is an initial pressure/latency trade-off for the dev build, to be evaluated with real workloads.
    private static let scheduler = WindowCaptureScheduler<CaptureKey>(limit: 2)
    private static var waitingForContent = [CaptureKey: CaptureRequest]()
    private static var discoveringContent = false
    private static let latestRequests = WindowCaptureLatestRequests<String, CaptureRequest>()
    private static var sessionScope: WindowCaptureScope?
    private static var sessionThrottler: ThrottlerWithKey?
    #if DEBUG
    private static var submittedCaptures = 0
    private static var completedCaptures = 0
    #endif

    private struct CaptureKey: Hashable {
        let wid: CGWindowID
        let fullRes: Bool
    }

    private final class CaptureRequest {
        weak var window: Window?
        let key: CaptureKey
        let pixels: CGSize
        let isFullscreen: Bool
        let scope: WindowCaptureScope
        let priority: Int
        let requiresVisible: Bool

        init(_ window: Window, _ key: CaptureKey, _ pixels: CGSize, _ scope: WindowCaptureScope, _ priority: Int, _ requiresVisible: Bool) {
            self.window = window
            self.key = key
            self.pixels = pixels
            self.isFullscreen = window.isFullscreen
            self.scope = scope
            self.priority = priority
            self.requiresVisible = requiresVisible
        }

        func isValid() -> Bool {
            guard !App.isTerminating, !ScreenLockEvents.isScreenLocked,
                  ScreenRecordingPermission.status == .granted, Preferences.anyShortcutShowsWindowCaptures,
                  scope.permits(currentSession: SwitcherSession.current, backgroundCaptureEnabled: Preferences.captureWindowsInBackground),
                  let window, Windows.byWindowId[key.wid] === window else { return false }
            if requiresVisible {
                guard window.shouldShowTheUser, let session = SwitcherSession.current,
                      Preferences.effectiveAppearanceStyle(session.shortcutIndex) == .thumbnails
                        || Preferences.effectivePreviewSelectedWindow(session.shortcutIndex) else { return false }
            }
            if key.fullRes {
                guard let session = SwitcherSession.current else { return false }
                return Preferences.effectivePreviewSelectedWindow(session.shortcutIndex)
                    && !session.hasPreviewFrame(key.wid)
                    && Windows.selectedNeighborhoodIds().contains(key.wid)
            }
            return true
        }
    }

    /// All mutable window, screen, and session state is read on main. Only immutable request data crosses
    /// to screenshotsQueue; in particular, capturePixelSize reads the main-owned thumbnail size limit.
    static func oneTimeScreenshots(_ windows: [Window], _ source: RefreshCausedBy, prioritizedIds: Set<CGWindowID>? = nil, fullRes: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        let requiresSession = SwitcherSession.isActive || fullRes || source == .refreshOnlyThumbnailsAfterShowUi
        let scope: WindowCaptureScope
        if requiresSession {
            guard let session = SwitcherSession.current else { return }
            if sessionScope?.permits(currentSession: session, backgroundCaptureEnabled: false) != true {
                sessionScope?.cancel()
                sessionScope = WindowCaptureScope(session: session, requiresSession: true)
                sessionThrottler = ThrottlerWithKey(delayInMs: 200)
            }
            scope = sessionScope!
        } else {
            scope = WindowCaptureScope(session: nil, requiresSession: false)
        }
        let throttler = requiresSession ? sessionThrottler! : Applications.screenshotThrottler
        let prioritized = prioritizedIds ?? []
        let sorted = windows.sorted {
            prioritized.contains($0.cgWindowId ?? 0) && !prioritized.contains($1.cgWindowId ?? 0)
        }
        for window in sorted {
            guard let wid = window.cgWindowId, let size = window.size,
                  let pixels = WindowThumbnails.capturePixelSize(size, WindowThumbnails.captureScaleFactor(window), fullRes) else { continue }
            let key = CaptureKey(wid: wid, fullRes: fullRes)
            let priority = prioritized.contains(wid) ? 2 : (requiresSession ? 1 : 0)
            let request = CaptureRequest(window, key, pixels, scope, priority,
                !fullRes && source == .refreshOnlyThumbnailsAfterShowUi)
            let throttleKey = "\(fullRes ? "preview" : "capture")-wid-\(wid)"
            let bufferKey = "\(requiresSession ? scope.id.uuidString : "background")-\(throttleKey)"
            latestRequests.submit(bufferKey, request, schedule: { callback in
                throttler.throttleOrProceed(key: throttleKey, callback)
            }, perform: enqueue)
        }
    }

    static func cancelSessionRequests() {
        dispatchPrecondition(condition: .onQueue(.main))
        sessionScope?.cancel()
        sessionScope = nil
        sessionThrottler = nil
        waitingForContent = waitingForContent.filter { $0.value.isValid() }
        latestRequests.discard { !$0.isValid() }
        scheduler.discardInvalidPending()
        #if DEBUG
        Logger.debug { debugSnapshot() }
        #endif
    }

    static func removeWindowRequests(_ wid: CGWindowID) {
        dispatchPrecondition(condition: .onQueue(.main))
        for prefix in ["capture", "preview"] {
            let key = "\(prefix)-wid-\(wid)"
            Applications.screenshotThrottler.removeEntry(withKey: key)
            sessionThrottler?.removeEntry(withKey: key)
        }
        latestRequests.discard { $0.key.wid == wid }
        waitingForContent = waitingForContent.filter { $0.key.wid != wid }
        scheduler.discardInvalidPending()
    }

    #if DEBUG
    static func debugSnapshot() -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        return "captures submitted:\(submittedCaptures) completed:\(completedCaptures) active:\(scheduler.activeCount) pending:\(scheduler.pendingCount) discoveryPending:\(waitingForContent.count)"
    }
    #endif

    private static func enqueue(_ request: CaptureRequest) {
        guard request.isValid() else { return }
        let cached = cachedSCWindows.withLock { windows in windows.first { $0.windowID == request.key.wid } }
        if let cached {
            schedule(cached, request)
        } else {
            waitingForContent[request.key] = request
            discoverContentIfNeeded()
        }
    }

    /// Concurrent cache misses share one system query, and keep only the latest request per window and
    /// resolution. A missing window is retried on its next event, never in a discovery retry loop.
    private static func discoverContentIfNeeded() {
        waitingForContent = waitingForContent.filter { $0.value.isValid() }
        guard !discoveringContent, !waitingForContent.isEmpty else { return }
        discoveringContent = true
        let batch = WindowCaptureDiscoveryBatch(waitingForContent)
        let scopes = waitingForContent.values.map { $0.scope }
        BackgroundWork.screenshotsQueue.addOperation {
            guard scopes.contains(where: { !$0.isCancelled }), !App.isTerminating, !ScreenLockEvents.isScreenLocked else {
                DispatchQueue.main.async {
                    discoveringContent = false
                    discoverContentIfNeeded()
                }
                return
            }
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                DispatchQueue.main.async {
                    discoveringContent = false
                    let requests = waitingForContent
                    waitingForContent.removeAll()
                    let succeeded = content != nil && error == nil
                    let windows = Dictionary((content?.windows ?? []).map { ($0.windowID, $0) }, uniquingKeysWith: { _, latest in latest })
                    let resolved = batch.resolve(requests, querySucceeded: succeeded,
                        isAvailable: { windows[$0.wid] != nil }, isValid: { $0.isValid() })
                    waitingForContent = resolved.retry
                    guard succeeded, let content else { Logger.error { "Screen capture discovery: \(error)" }; return }
                    cachedSCWindows.withLock { $0 = content.windows }
                    for request in resolved.ready.values.sorted(by: { $0.priority > $1.priority }) {
                        guard let window = windows[request.key.wid] else { continue }
                        schedule(window, request)
                    }
                    discoverContentIfNeeded()
                }
            }
        }
    }

    private static func schedule(_ scWindow: SCWindow, _ request: CaptureRequest) {
        scheduler.submit(request.key, priority: request.priority, isValid: request.isValid) { finished in
            guard request.isValid() else { finished(); return }
            ActiveWindowCaptures.increment()
            BackgroundWork.screenshotsQueue.addOperation {
                guard !request.scope.isCancelled, !App.isTerminating, !ScreenLockEvents.isScreenLocked else {
                    ActiveWindowCaptures.decrement()
                    finished()
                    return
                }
                #if DEBUG
                DispatchQueue.main.async { submittedCaptures += 1 }
                #endif
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let completion: (CALayerContents?, Error?) -> Void = { contents, error in
                    ActiveWindowCaptures.decrement()
                    DispatchQueue.main.async {
                        defer { finished() }
                        #if DEBUG
                        completedCaptures += 1
                        #endif
                        guard request.isValid() else { return }
                        guard let contents, error == nil else { Logger.error { "wid:\(request.key.wid) capture failed: \(error)" }; return }
                        deliver(request, contents)
                    }
                }
                if !request.isFullscreen {
                    captureScreenshot(filter, request.pixels, completion)
                } else {
                    captureSampleBuffer(filter, request.pixels, completion)
                }
            }
        }
    }

    private static func captureScreenshot(_ filter: SCContentFilter, _ pixels: CGSize, _ completion: @escaping (CALayerContents?, Error?) -> Void) {
        let config = SCScreenshotConfiguration()
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.showsCursor = false
        config.dynamicRange = .sdr
        // No fallback: upstream measured inactive-Space fullscreen failures (-3811); fullscreen requests
        // have their own route. A fallback would silently restore per-call capture-stream churn (#5786).
        SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config) { output, error in
            completion(output?.sdrImage.map { CALayerContents.cgImage($0) }, error)
        }
    }

    private static func captureSampleBuffer(_ filter: SCContentFilter, _ pixels: CGSize, _ completion: @escaping (CALayerContents?, Error?) -> Void) {
        let config = SCStreamConfiguration()
        config.width = Int(pixels.width)
        config.height = Int(pixels.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) { sampleBuffer, error in
            let pixelBuffer = sampleBuffer?.pixelBuffer() ?? sampleBuffer?.imageBuffer
            completion(pixelBuffer.map { CALayerContents.pixelBuffer($0) }, error)
        }
    }

    private static func deliver(_ request: CaptureRequest, _ contents: CALayerContents) {
        guard let window = request.window else { return }
        if request.key.fullRes {
            guard let session = SwitcherSession.current,
                  !WindowThumbnails.isPartialFrame(window, contents, fullRes: true) else { return }
            session.storePreviewFrame(request.key.wid, contents)
            if let position = window.position, let size = window.size {
                PreviewPanel.updateIfShowing(request.key.wid, contents, position, size)
            }
        } else {
            window.refreshThumbnail(contents)
        }
    }
}

extension CMSampleBuffer {
    @available(macOS 12.3, *)
    func pixelBuffer() -> CVPixelBuffer? {
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first,
           let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRawValue),
           status == .complete || status == .started { // new frame was generated
            return imageBuffer
        }
        return nil
    }

    @available(macOS 12.3, *)
    func metalTexture(_ device: MTLDevice) -> MTLTexture? {
        guard let pixelBuffer = pixelBuffer(),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            mipmapped: false
        )
        return device.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
    }
}

class ActiveWindowCaptures {
    private static var _count: Int32 = 0

    static func increment() { OSAtomicIncrement32(&_count) }
    static func decrement() { OSAtomicDecrement32(&_count) }
    static func value() -> Int { Int(OSAtomicAdd32(0, &_count)) }
}
