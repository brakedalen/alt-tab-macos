import AppKit

// Lists tap metadata only. This does not install a tap or read keyboard/mouse events.
let capacity: UInt32 = 1024
var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(capacity))
var count: UInt32 = 0
let error = CGGetEventTapList(capacity, &taps, &count)
guard error == .success else {
    fputs("Event tap inventory unavailable: \(error.rawValue)\n", stderr)
    exit(1)
}
print("Event tap metadata at \(ISO8601DateFormatter().string(from: Date()))")
print("PID\tEnabled\tMode\tRaw avg microseconds\tRaw max microseconds\tApp")
for tap in taps.prefix(Int(min(count, capacity))).sorted(by: { $0.tappingProcess < $1.tappingProcess }) {
    let name = NSRunningApplication(processIdentifier: tap.tappingProcess)?.localizedName ?? "Unknown"
    let mode = tap.options == .listenOnly ? "listen-only" : "active"
    print("\(tap.tappingProcess)\t\(tap.enabled)\t\(mode)\t\(tap.avgUsecLatency)\t\(tap.maxUsecLatency)\t\(name)")
}
if count >= capacity { print("Capacity reached; inventory may be truncated.") }
print("Latency describes event delivery, not CPU attribution or capture activity.")
print("Treat implausible or stale latency values as inconclusive; rows are grouped by PID, not ranked by latency.")
print("Apple documents that this query resets each tap's minimum/maximum latency statistics to its average.")
