import Foundation

/// Quantized sRGB colours are persisted, so algorithm changes, newly discovered
/// models, history imports, and process restarts cannot repaint existing models.
public struct ModelColor: Codable, Hashable, Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    var isUsable: Bool {
        light <= 0xffffff && dark <= 0xffffff
            && ColorScience.contrast(light, 0xfcfcfb) >= 3
            && ColorScience.contrast(dark, 0x1a1a19) >= 3
    }
}

/// Farthest-point sampling in OKLab, with a secondary separation score under
/// protanopia, deuteranopia, and tritanopia simulation. Colour alone still cannot
/// distinguish arbitrarily many series; every chart also supplies a text legend.
enum ModelColorAllocator {
    private struct Candidate {
        let color: ModelColor
        let appearances: [SIMD3<Double>]

        init(_ color: ModelColor) {
            self.color = color
            appearances = [color.light, color.dark].flatMap { hex in
                let linear = ColorScience.linearRGB(hex)
                return [ColorScience.lab(linear)] + ColorScience.deficiencies.map {
                    ColorScience.lab(ColorScience.simulate(linear, matrix: $0))
                }
            }
        }

        func distance(to other: Candidate) -> Double {
            let distances = zip(appearances, other.appearances).map { lhs, rhs in
                let delta = lhs - rhs
                return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
            }
            let normal = min(distances[0], distances[4])
            let simulated = [1, 2, 3, 5, 6, 7].map { distances[$0] }.min()!
            return normal * 0.75 + simulated * 0.25
        }
    }

    // No model names or vendor palette to maintain. Each hue has several
    // chroma/lightness pairs; gamut mapping reduces chroma rather than clipping.
    private static let candidates: [Candidate] = {
        var result: [Candidate] = []
        var seen = Set<ModelColor>()
        for hue in stride(from: 0.0, to: 360.0, by: 5) {
            for lightness in [0.44, 0.53, 0.62] {
                for chroma in [0.10, 0.16, 0.22] {
                    let color = makeColor(hue: hue, lightness: lightness, chroma: chroma)
                    if color.isUsable, seen.insert(color).inserted { result.append(Candidate(color)) }
                }
            }
        }
        return result
    }()

    static func assign(
        models: [ModelKey], preserving existing: [String: ModelColor] = [:]
    ) -> [String: ModelColor] {
        var assigned: [String: ModelColor] = [:]
        var usedLight = Set<UInt32>()
        var usedDark = Set<UInt32>()
        // Keep reservations for models absent from the current history as well.
        // Invalid/colliding imported assignments are repaired deterministically.
        for identity in existing.keys.sorted() {
            let color = existing[identity]!
            guard color.isUsable, !usedLight.contains(color.light), !usedDark.contains(color.dark) else { continue }
            assigned[identity] = color
            usedLight.insert(color.light)
            usedDark.insert(color.dark)
        }
        let unattributed = Set(models.filter(\.isUnattributed).map(\.colorIdentity))
        let missing = Set(models.map(\.colorIdentity)).subtracting(assigned.keys).sorted {
            if unattributed.contains($0) != unattributed.contains($1) {
                return !unattributed.contains($0)
            }
            return $0 < $1
        }
        guard !missing.isEmpty else { return assigned }

        var selected = assigned.keys.sorted().map { Candidate(assigned[$0]!) }
        var nearest = candidates.map { candidate in
            selected.map { candidate.distance(to: $0) }.min() ?? Double.infinity
        }
        for identity in missing {
            // Stable hashing breaks ties, not modulo a small reusable palette.
            let start = Int(fnv1a64(identity) % UInt64(candidates.count))
            var best: Candidate?
            var score = -Double.infinity
            for offset in candidates.indices {
                let index = (start + offset) % candidates.count
                let candidate = candidates[index]
                guard !usedLight.contains(candidate.color.light), !usedDark.contains(candidate.color.dark) else { continue }
                if nearest[index] > score {
                    best = candidate
                    score = nearest[index]
                }
            }
            // The sample grid is not a series limit. Generate additional unique
            // colours if it is exhausted instead of wrapping or falling to gray.
            if best == nil {
                var random = fnv1a64(identity)
                repeat {
                    for _ in 0..<64 {
                        let hue = unitRandom(&random) * 360
                        let lightness = 0.42 + unitRandom(&random) * 0.20
                        let chroma = 0.09 + unitRandom(&random) * 0.14
                        let color = makeColor(hue: hue, lightness: lightness, chroma: chroma)
                        guard color.isUsable, !usedLight.contains(color.light), !usedDark.contains(color.dark) else { continue }
                        let candidate = Candidate(color)
                        let separation = selected.map { candidate.distance(to: $0) }.min() ?? .infinity
                        if separation > score { best = candidate; score = separation }
                    }
                } while best == nil
            }
            let chosen = best!
            assigned[identity] = chosen.color
            usedLight.insert(chosen.color.light)
            usedDark.insert(chosen.color.dark)
            selected.append(chosen)
            for index in candidates.indices {
                nearest[index] = min(nearest[index], candidates[index].distance(to: chosen))
            }
        }
        return assigned
    }

    private static func makeColor(hue: Double, lightness: Double, chroma: Double) -> ModelColor {
        ModelColor(
            light: ColorScience.rgb(lightness: lightness, chroma: chroma, hue: hue),
            dark: ColorScience.rgb(lightness: lightness + 0.20, chroma: chroma, hue: hue)
        )
    }

    private static func unitRandom(_ state: inout UInt64) -> Double {
        // SplitMix64: deterministic across launches (unlike Swift.Hasher).
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992
    }
}

// OKLab: https://bottosson.github.io/posts/oklab/
// Full-severity Machado et al. (2009) matrices, applied in linear sRGB:
// https://www.inf.ufrgs.br/~oliveira/pubs_files/CVD_Simulation/CVD_Simulation.html
enum ColorScience {
    static let deficiencies: [[Double]] = [
        [0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882, -0.048116, 1.051998],
        [0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820, 0.042940, 0.968881],
        [1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733, 0.691367, 0.303900]
    ]

    static func linearRGB(_ hex: UInt32) -> SIMD3<Double> {
        func linear(_ byte: UInt32) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return SIMD3(linear((hex >> 16) & 255), linear((hex >> 8) & 255), linear(hex & 255))
    }

    static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let rgb = linearRGB(hex)
            return rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func simulate(_ rgb: SIMD3<Double>, matrix m: [Double]) -> SIMD3<Double> {
        SIMD3(
            min(1, max(0, rgb.x * m[0] + rgb.y * m[1] + rgb.z * m[2])),
            min(1, max(0, rgb.x * m[3] + rgb.y * m[4] + rgb.z * m[5])),
            min(1, max(0, rgb.x * m[6] + rgb.y * m[7] + rgb.z * m[8]))
        )
    }

    static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z)
        let m = cbrt(0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z)
        let s = cbrt(0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func rgb(lightness l: Double, chroma: Double, hue: Double) -> UInt32 {
        let radians = hue * .pi / 180
        func linear(_ c: Double) -> SIMD3<Double> {
            let a = c * cos(radians), b = c * sin(radians)
            let ll = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let mm = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let ss = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            return SIMD3(4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss,
                         -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss,
                         -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss)
        }
        func inGamut(_ rgb: SIMD3<Double>) -> Bool {
            (0...1).contains(rgb.x) && (0...1).contains(rgb.y) && (0...1).contains(rgb.z)
        }
        var low = 0.0, high = chroma
        if !inGamut(linear(high)) {
            for _ in 0..<20 {
                let middle = (low + high) / 2
                if inGamut(linear(middle)) { low = middle } else { high = middle }
            }
        } else { low = high }
        let result = linear(low)
        func byte(_ linear: Double) -> UInt32 {
            let value = min(1, max(0, linear))
            let srgb = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
            return UInt32((srgb * 255).rounded())
        }
        return (byte(result.x) << 16) | (byte(result.y) << 8) | byte(result.z)
    }
}
