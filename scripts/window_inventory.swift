import AppKit

// Metadata only: no window titles, image capture, or screen-recording permission request.
struct WindowOwner {
    let pid: pid_t
    let name: String
    var total = 0
    var normal = 0
    var onScreen = 0
    var estimatedBytes: UInt64 = 0
}

guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    fputs("Window inventory unavailable in this login session.\n", stderr)
    exit(1)
}
var owners = [pid_t: WindowOwner]()
for window in windows {
    guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName
        ?? (window[kCGWindowOwnerName as String] as? String) ?? "Unknown"
    var owner = owners[pid] ?? WindowOwner(pid: pid, name: name)
    owner.total += 1
    if (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 { owner.normal += 1 }
    if (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true { owner.onScreen += 1 }
    owner.estimatedBytes += (window[kCGWindowMemoryUsage as String] as? NSNumber)?.uint64Value ?? 0
    owners[pid] = owner
}
print("Window metadata at \(ISO8601DateFormatter().string(from: Date()))")
print("PID\tWindows\tLayer 0\tOn screen\tEstimated MiB\tApp")
for owner in owners.values.sorted(by: { $0.total == $1.total ? $0.pid < $1.pid : $0.total > $1.total }) {
    print("\(owner.pid)\t\(owner.total)\t\(owner.normal)\t\(owner.onScreen)\t\(String(format: "%.2f", Double(owner.estimatedBytes) / 1_048_576))\t\(owner.name)")
}
print("Counts include off-screen windows and auxiliary UI; they are not a CPU ranking.")
print("kCGWindowMemoryUsage is Apple's estimate for each window and its structures, not a share of WindowServer's footprint.")
