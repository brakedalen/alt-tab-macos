# WindowCaptureEvents — Specs

## Scope

AltTab dev requires macOS 26. Its thumbnail and Preview captures are one-shot ScreenCaptureKit
requests. There is no persistent capture stream. The old private screenshot backend and the
commented-out video-stream experiment are removed from this build.

## API and image lifetime

- Non-fullscreen windows use `SCScreenshotManager.captureScreenshot` with `SCScreenshotConfiguration`,
  introduced in macOS 26. The output is SDR with explicit pixel dimensions and no pointer.
- Fullscreen windows retain `captureSampleBuffer`. Upstream reported that `captureScreenshot` fails
  with error -3811 for fullscreen windows on an inactive Space; changing that route requires device
  testing. There is no automatic fallback or retry from the newer API to the stream-backed API.
- Window thumbnails are downscaled to the existing maximum thumbnail dimensions. Full-resolution
  Preview frames are fetched only when Preview is enabled, for the selected window and its two
  neighbors in each cycling direction. The existing session cache retains at most ten frames.
  Pending Preview captures become invalid when a frame is cached or the window leaves the current
  neighborhood, preventing duplicate captures and obsolete work during fast cycling.
- A request holds a weak Window reference and a weak original session reference. Delivery requires
  that the window is still the same tracked object and that the original session is still current.
  A capture from a dismissed invocation cannot populate a later invocation's Preview cache.
- Size, backing scale, maximum thumbnail dimensions, fullscreen state, and session scope are
  snapshotted on main. Capture-queue work reads immutable pixel dimensions, not mutable screen/UI data.

## Work admitted to the system

- `WindowCaptureScheduler` permits at most **two unfinished screenshot requests**, across thumbnails
  and full-resolution Preview captures. The slot remains occupied until the OS callback is processed.
  Two is an initial tuning choice, not a measured optimum or a promised resource reduction.
- `OperationQueue.maxConcurrentOperationCount` alone cannot impose this bound: the old BlockOperation
  returned immediately after submitting the asynchronous API request. Its eight-operation limit did
  not limit the number of outstanding ScreenCaptureKit requests.
- Each window/resolution key has at most one active request and one latest pending request. Visible
  viewport/selected requests take precedence, followed by other session requests, then background work.
  Equal-priority pending requests keep FIFO order. An in-flight OS call is never falsely counted as
  canceled just because the UI has closed.
- The 200 ms per-key rate limiter receives a callback that fetches the latest request. This avoids
  its first retained trailing closure using stale geometry or suppressing a later session's request.
  Each session owns a separate rate limiter and buffer key namespace.
- Cache misses merge into one outstanding `SCShareableContent` query, with one latest waiting request
  per window/resolution. A missing request that arrived or changed after the query began gets one
  fresh query containing that request; an unchanged request already included in the query does not
  retry itself. Invalid requests and query failures do not start automatic retries. Discovery already
  submitted to Apple cannot be canceled; queued discovery whose session
  scopes are all canceled is discarded before calling Apple.
- Immediately before admission, requests recheck app termination, screen lock, screen-recording
  permission, capture preferences, original session, and tracked window identity. Background dispatch
  checks a synchronized cancellation token as well as termination and lock state before calling Apple.
  There remains an unavoidable narrow cancellation race with an already-submitting OS call. At most
  the two admitted captures and one discovery query can remain unfinished; their results are discarded
  if no longer valid. There is no blocking wait, polling loop, or timeout that would falsely free a slot
  while Apple's uncancelable operation is still running.

## When captures occur

- The initial switcher pass captures only windows currently admitted by the user's switcher filters.
  Queued initial-show requests recheck visibility and whether the current shortcut uses thumbnails
  or Preview, so a filter/shortcut change within the same session can discard unnecessary captures.
  Fullscreen, minimized, hidden, and other-Space windows can still be captured when those filters
  actually show them.
- External-event refresh retains the existing event-driven selection of changed windows. Visibility
  flags may not yet have been recomputed when that callback runs, so it does not filter on stale flags.
- “Capture windows in the background” applies to **all** idle thumbnail paths, including the focused
  window/tab-preservation capture. Turning it off means focused-window events no longer bypass it.
  Thumbnails can consequently be stale or absent until the next switcher invocation; this is the
  intended resource/thumbnail-freshness trade-off. Dev's default is off.
- An idle background request becomes invalid when a switcher session opens, so an old delayed event
  cannot replace a newer session request or lower its priority.
- Closing the switcher cancels its pending/throttled requests and invalidates its in-flight delivery.
  Only a later event can request background work, when that preference is enabled.
- Restore-animation deferral and bounded partial-frame retries remain in place. A retry also obeys
  the current background-capture preference. Per-window rate-limit, restore, retry, and pending-capture
  entries are removed when the tracked window leaves. Delayed callbacks check object identity before
  changing per-window state, protecting a new window that reuses the numeric window ID.

## Evidence and limitations

The code at upstream commit `941d841e` (11.5.0) already used macOS 26's screenshot API for ordinary
windows, downscaled thumbnails, and lazy Preview captures. These are not new optimizations introduced
by this fork. Supporting older deployment targets did not cause macOS 26 to run the old backend.

Upstream's [#5786](https://github.com/lwouis/alt-tab-macos/issues/5786),
[#5845](https://github.com/lwouis/alt-tab-macos/pull/5845), and
[#5861](https://github.com/lwouis/alt-tab-macos/issues/5861) motivate reducing request count and avoiding
unnecessary stream-backed captures. Their observations are reports on other workloads; they do not
establish the cause of this user's WindowServer CPU or RAM growth.

Apple documents the [macOS 26 screenshot API](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/capturescreenshot(contentfilter:configuration:completionhandler:))
and [pixel-based output configuration](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration).
The [sample-buffer API](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/capturesamplebuffer(contentfilter:configuration:completionhandler:))
returns a frame from streaming content. Foundation's
[operation limit](https://developer.apple.com/documentation/foundation/operationqueue/maxconcurrentoperationcount)
applies to executing operations; asynchronous work must retain its execution lifetime until completion,
as explained in [Operation](https://developer.apple.com/documentation/foundation/operation).

## Verification

`WindowCaptureSchedulerTests` exercises outstanding callback bounds, latest-request coalescing,
per-window serialization, priority/FIFO ordering, cached-Preview invalidation, cancellation before dispatch, duplicate completion,
error completion, off-main completion, weak session retention, session identity, the background
preference, stale throttler tails, rapid session replacement, release of discarded requests, and
bounded discovery follow-ups for late requests (including query failures and canceled sessions).
These tests use controlled callbacks and no real screen-recording permission or WindowServer workload.

Required device comparison: official app, dev with background capture off, then dev with it on;
run one switcher at a time with the same display, windows, and actions. Compare idle and repeated
switching separately. Include rapid dismiss/reopen, switching filters/shortcuts, window resizing,
minimize/restore, Spaces/fullscreen, lock/unlock, and display reconnect. Measure both the app and
WindowServer/replayd/systemstatusd, with capture counts and thumbnail/Preview latency. Debug builds
expose `WindowCaptureScreenshots.debugSnapshot()` on main and log its cumulative submitted/completed,
active/pending, and discovery-waiting counts on dismissal. Final captures may finish after that log;
the next snapshot should show their completion. This adds no timer or graph to idle operation.
