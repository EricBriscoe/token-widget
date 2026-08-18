import Foundation
import TokenWidgetCore

// A small command-line front end over the same engine the app and widget use.
// Handy for verifying totals against the raw transcripts without launching the
// GUI, and for a quick look at usage from a terminal.

func formatTokens(_ value: Int) -> String {
    let number = Double(value)
    switch number {
    case 1_000_000_000...: return String(format: "%.2fB", number / 1_000_000_000)
    case 1_000_000...: return String(format: "%.1fM", number / 1_000_000)
    case 1_000...: return String(format: "%.1fK", number / 1_000)
    default: return String(value)
    }
}

func formatMoney(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

let arguments = CommandLine.arguments
let rangeName = arguments.count > 1 ? arguments[1] : "week"
guard let range = RangeKind(rawValue: rangeName) else {
    print("usage: tokenusage [week|month|quarter|year] [offset]")
    exit(2)
}
let offset = arguments.count > 2 ? Int(arguments[2]) ?? 0 : 0

let storeDirectory = SharedContainer.directory
print("store: \(storeDirectory.path)")

// Published rates, refreshed at most once a day and cached beside the history.
let catalog = await OpenRouterPriceService().refreshIfNeeded()
let priceBook = PriceBook.builtIn.withCatalog(catalog)
if let catalog {
    print("rates: \(catalog.models.count) models from OpenRouter, fetched \(UsageFormat.relativeAge(of: catalog.fetchedAt))")
} else {
    print("rates: built-in only (OpenRouter unreachable)")
}

let scanner = UsageScanner(priceBook: priceBook)
var lastReported = Date.distantPast
let started = Date()

let snapshot = try scanner.scan { progress in
    guard Date().timeIntervalSince(lastReported) > 0.25 || progress.filesProcessed == progress.filesTotal else { return }
    lastReported = Date()
    let percent = Int(progress.fraction * 100)
    let megabytes = Double(progress.bytesRead) / 1_048_576
    FileHandle.standardError.write(Data(
        "\rscanning \(percent)%  \(progress.filesProcessed)/\(progress.filesTotal) files  \(String(format: "%.0f", megabytes)) MB  +\(progress.newRecords) msgs".utf8
    ))
}
FileHandle.standardError.write(Data("\n".utf8))

print("""
scanned \(snapshot.filesScanned) files in \(String(format: "%.1f", Date().timeIntervalSince(started)))s
messages: \(snapshot.totalMessages)
days with activity: \(snapshot.days.count)
range: \(snapshot.firstDay.map { "\($0.rawValue)" } ?? "-") to \(snapshot.lastDay.map { "\($0.rawValue)" } ?? "-")
""")

if !snapshot.unpricedModels.isEmpty {
    print("unpriced (cost reported as 0): \(snapshot.unpricedModels.joined(separator: ", "))")
}
if !snapshot.localModels.isEmpty {
    print("local (no per-token cost): \(snapshot.localModels.joined(separator: ", "))")
}

let query = UsageQuery(snapshot: snapshot, priceBook: priceBook)
let breakdown = query.breakdown(range, offset: offset)

print("\n\(breakdown.window.title)   \(formatMoney(breakdown.cost))   \(formatTokens(breakdown.totals.output)) generated   \(breakdown.totals.messages) msgs")
print(String(repeating: "-", count: 64))

let peak = breakdown.peak(for: .cost)
for point in breakdown.points {
    let width = peak > 0 ? Int((point.cost / peak) * 34) : 0
    let bar = String(repeating: "#", count: width)
    print(String(format: "%-8@ %8@  %@", point.shortLabel as NSString, formatMoney(point.cost) as NSString, bar))
}

print(String(repeating: "-", count: 64))
for model in breakdown.models {
    let share = breakdown.cost > 0 ? model.cost / breakdown.cost * 100 : 0
    var note = ""
    if model.isUnpriced { note = "  (no published rate)" }
    if model.isLocal { note = "  (local)" }
    if model.isApproximate { note = "  (estimated)" }
    print(String(
        format: "%-22@ %9@  %5.1f%%  in %@  cache-w %@  cache-r %@  out %@%@",
        model.displayName as NSString,
        formatMoney(model.cost) as NSString,
        share,
        formatTokens(model.counts.input) as NSString,
        formatTokens(model.counts.cacheWrite5m + model.counts.cacheWrite1h) as NSString,
        formatTokens(model.counts.cacheRead) as NSString,
        formatTokens(model.counts.output) as NSString,
        note as NSString
    ))
}
