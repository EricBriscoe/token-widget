import XCTest
@testable import TokenWidgetCore

final class ModelColorTests: XCTestCase {
    private func models(_ count: Int) -> [ModelKey] {
        (0..<count).map { ModelKey(provider: .codex, model: "future-model-\($0)") }
    }

    private func snapshot(_ keys: [ModelKey], colors: [String: ModelColor]? = nil) -> UsageSnapshot {
        UsageSnapshot(days: [DaySummary(day: DayID(year: 2026, month: 9, day: 7), entries: keys.map {
            ModelEntry(provider: $0.provider, model: $0.model, fast: $0.fast, counts: TokenCounts(output: 100, messages: 1))
        })], modelColors: colors)
    }

    func testDistinctSwatchesAndSurfaceContrastBeyondEightModels() {
        let keys = models(40)
        let colors = ModelColorAllocator.assign(models: keys)
        XCTAssertEqual(colors.count, 40)
        XCTAssertEqual(Set(colors.values.map(\.light)).count, 40)
        XCTAssertEqual(Set(colors.values.map(\.dark)).count, 40)
        for color in colors.values {
            XCTAssertGreaterThanOrEqual(ColorScience.contrast(color.light, 0xfcfcfb), 3)
            XCTAssertGreaterThanOrEqual(ColorScience.contrast(color.dark, 0x1a1a19), 3)
        }
    }

    func testTypicalPaletteHasPerceptualSeparationAndMatchingThemeHues() {
        let colors = Array(ModelColorAllocator.assign(models: models(12)).values)
        for i in colors.indices {
            let light = ColorScience.lab(ColorScience.linearRGB(colors[i].light))
            let dark = ColorScience.lab(ColorScience.linearRGB(colors[i].dark))
            let hueDelta = abs(atan2(light.z, light.y) - atan2(dark.z, dark.y))
            XCTAssertLessThan(min(hueDelta, 2 * .pi - hueDelta), 3 * .pi / 180)
            for j in 0..<i {
                for pair in [(colors[i].light, colors[j].light), (colors[i].dark, colors[j].dark)] {
                    let delta = ColorScience.lab(ColorScience.linearRGB(pair.0)) - ColorScience.lab(ColorScience.linearRGB(pair.1))
                    XCTAssertGreaterThan(sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z), 0.08)
                }
            }
        }
    }

    func testModelAndInputOrderingDoNotAffectAssignments() {
        let keys = models(20)
        XCTAssertEqual(ModelColorAllocator.assign(models: keys),
                       ModelColorAllocator.assign(models: Array(keys.reversed()) + keys))
    }

    func testNewModelsNeverRepaintExistingModelsIncludingAbsentHistory() {
        let keys = models(12)
        let original = ModelColorAllocator.assign(models: keys)
        let added = ModelKey(provider: .codex, model: "aaa-released-tomorrow")
        let extended = ModelColorAllocator.assign(models: keys + [added], preserving: original)
        for key in keys { XCTAssertEqual(extended[key.colorIdentity], original[key.colorIdentity]) }
        let subset = ModelColorAllocator.assign(models: [added], preserving: extended)
        XCTAssertEqual(subset, extended, "Absent models keep their colour reservations")
    }

    func testSameModelAcrossHarnessesAndSpeedsHasOneColor() {
        let cli = ModelKey(provider: .codex, model: "gpt-6-astra")
        let pi = ModelKey(provider: .pi, model: "openai/gpt-6-astra", fast: true)
        let claude = ModelKey(provider: .claudeCode, model: "claude-opus-5")
        let piClaude = ModelKey(provider: .pi, model: "anthropic/claude-opus-5")
        let palette = ChartPalette(models: [cli, pi, claude, piClaude])
        XCTAssertEqual(palette.swatch(for: cli), palette.swatch(for: pi))
        XCTAssertEqual(palette.swatch(for: claude), palette.swatch(for: piClaude))
        XCTAssertNotEqual(palette.swatch(for: cli), palette.swatch(for: claude))
    }

    func testSnapshotsPersistAssignmentsAndLegacyHistoriesStillDecode() throws {
        let keys = models(12)
        let colors = ModelColorAllocator.assign(models: keys)
        let original = snapshot(keys, colors: colors)
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.modelColors, colors)
        for key in keys {
            XCTAssertEqual(ChartPalette(snapshot: restored).swatch(for: key), colors[key.colorIdentity])
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "modelColors")
        json["version"] = 2
        let legacy = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.modelColors)
        XCTAssertEqual(ChartPalette(snapshot: legacy).swatch(for: keys[0]), colors[keys[0].colorIdentity])
    }

    func testImportPreservesLocalColorsAndRepairsIncomingCollisions() throws {
        let local = ModelKey(provider: .codex, model: "z-local")
        let incoming = ModelKey(provider: .codex, model: "a-incoming")
        let localColors = ModelColorAllocator.assign(models: [local])
        let collision = try XCTUnwrap(localColors[local.colorIdentity])
        let merged = UsageSnapshot.merging(snapshot([local], colors: localColors),
                                          snapshot([incoming], colors: [incoming.colorIdentity: collision]))
        XCTAssertEqual(merged.modelColors?[local.colorIdentity], collision)
        let repaired = try XCTUnwrap(merged.modelColors?[incoming.colorIdentity])
        XCTAssertNotEqual(repaired.light, collision.light)
        XCTAssertNotEqual(repaired.dark, collision.dark)
    }

    func testInvalidAndDuplicateAssignmentsAreRepaired() {
        let keys = models(3)
        let swatch = ModelColorAllocator.assign(models: [keys[0]])[keys[0].colorIdentity]!
        let colors = ModelColorAllocator.assign(models: keys, preserving: [
            keys[0].colorIdentity: swatch,
            keys[1].colorIdentity: swatch,
            keys[2].colorIdentity: ModelColor(light: 0xffffff, dark: 0)
        ])
        XCTAssertEqual(colors.count, 3)
        XCTAssertTrue(colors.values.allSatisfy(\.isUsable))
        XCTAssertEqual(Set(colors.values.map(\.light)).count, 3)
        XCTAssertEqual(Set(colors.values.map(\.dark)).count, 3)
    }

    func testGeneratedPaletteExpandsBeyondTheCandidateGridWithoutRecycling() {
        let colors = ModelColorAllocator.assign(models: models(700))
        XCTAssertEqual(colors.count, 700)
        XCTAssertEqual(Set(colors.values.map(\.light)).count, 700)
        XCTAssertEqual(Set(colors.values.map(\.dark)).count, 700)
        XCTAssertTrue(colors.values.allSatisfy(\.isUsable))
    }

    func testColorScienceReferenceValues() {
        XCTAssertEqual(ColorScience.contrast(0, 0xffffff), 21, accuracy: 0.001)
        let red = ColorScience.lab(ColorScience.linearRGB(0xff0000))
        XCTAssertEqual(red.x, 0.627955, accuracy: 0.00001)
        XCTAssertEqual(red.y, 0.224863, accuracy: 0.00001)
        XCTAssertEqual(red.z, 0.125846, accuracy: 0.00001)
        let blue = ColorScience.rgb(lightness: 0.6, chroma: 0.3, hue: 260)
        let lab = ColorScience.lab(ColorScience.linearRGB(blue))
        XCTAssertEqual(lab.x, 0.6, accuracy: 0.003)
        XCTAssertEqual(atan2(lab.z, lab.y) * 180 / .pi + 360, 260, accuracy: 1)
    }
}
