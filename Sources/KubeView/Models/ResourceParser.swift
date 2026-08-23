import Foundation

// MARK: - Resource parsing

enum ResourceParser {
    /// Convert CPU quantity ("500m", "1", "100u", "100n") to millicores.
    static func cpuToMillicores(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        if s.hasSuffix("n") { return (Double(s.dropLast()) ?? 0) / 1_000_000 }
        if s.hasSuffix("u") { return (Double(s.dropLast()) ?? 0) / 1_000 }
        if s.hasSuffix("m") { return Double(s.dropLast()) ?? 0 }
        return (Double(s) ?? 0) * 1000
    }

    /// Convert memory quantity ("128Mi", "1Gi", "500M", "1024") to bytes.
    static func memoryToBytes(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        let units: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1024*1024), ("Gi", pow(1024,3)), ("Ti", pow(1024,4)), ("Pi", pow(1024,5)),
            ("K", 1000), ("M", 1_000_000), ("G", 1_000_000_000), ("T", 1e12), ("P", 1e15)
        ]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            if let n = Double(s.dropLast(suffix.count)) { return n * mult }
        }
        return Double(s) ?? 0
    }

    static func formatMillicores(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.2f", m / 1000) }
        return "\(Int(m))m"
    }

    static func formatBytes(_ b: Double) -> String {
        let g = 1024.0 * 1024 * 1024
        let mi = 1024.0 * 1024
        if b >= g { return String(format: "%.1f Gi", b / g) }
        if b >= mi { return String(format: "%.0f Mi", b / mi) }
        return String(format: "%.0f", b)
    }
}
