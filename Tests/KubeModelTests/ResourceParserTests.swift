import Foundation
import XCTest
@testable import KubeModel

/// `ResourceParser` is real logic worth testing directly: parsing kubectl's
/// Kubernetes-quantity strings (CPU millicores, memory bytes) including the
/// unit suffixes and malformed input, plus the reverse formatting.
final class ResourceParserTests: XCTestCase {
    // MARK: - cpuToMillicores

    func test_cpuToMillicores_nanoAndMicroAndMilliSuffixes() {
        XCTAssertEqual(ResourceParser.cpuToMillicores("100n"), 0.0001, accuracy: 0.00001)
        XCTAssertEqual(ResourceParser.cpuToMillicores("100u"), 0.1, accuracy: 0.0001)
        XCTAssertEqual(ResourceParser.cpuToMillicores("500m"), 500)
    }

    func test_cpuToMillicores_bareCoresMultipliesBy1000() {
        XCTAssertEqual(ResourceParser.cpuToMillicores("1"), 1000)
        XCTAssertEqual(ResourceParser.cpuToMillicores("2.5"), 2500)
    }

    func test_cpuToMillicores_emptyAndMalformedReturnZero() {
        XCTAssertEqual(ResourceParser.cpuToMillicores(""), 0)
        XCTAssertEqual(ResourceParser.cpuToMillicores("not-a-number"), 0)
    }

    // MARK: - memoryToBytes

    func test_memoryToBytes_binarySuffixes() {
        XCTAssertEqual(ResourceParser.memoryToBytes("128Ki"), 128 * 1024)
        XCTAssertEqual(ResourceParser.memoryToBytes("128Mi"), 128 * 1024 * 1024)
        XCTAssertEqual(ResourceParser.memoryToBytes("1Gi"), pow(1024, 3), accuracy: 1)
    }

    func test_memoryToBytes_decimalSuffixes() {
        XCTAssertEqual(ResourceParser.memoryToBytes("500M"), 500_000_000)
        XCTAssertEqual(ResourceParser.memoryToBytes("2K"), 2000)
    }

    func test_memoryToBytes_bareNumberAndMalformed() {
        XCTAssertEqual(ResourceParser.memoryToBytes("1024"), 1024)
        XCTAssertEqual(ResourceParser.memoryToBytes(""), 0)
        XCTAssertEqual(ResourceParser.memoryToBytes("nonsense"), 0)
    }

    // MARK: - formatting

    func test_formatMillicores_belowOneCoreShowsMilliSuffix() {
        XCTAssertEqual(ResourceParser.formatMillicores(500), "500m")
    }

    func test_formatMillicores_atOrAboveOneCoreShowsCores() {
        XCTAssertEqual(ResourceParser.formatMillicores(1500), "1.50")
    }

    func test_formatBytes_bucketsByMagnitude() {
        XCTAssertEqual(ResourceParser.formatBytes(2 * pow(1024, 3)), "2.0 Gi")
        XCTAssertEqual(ResourceParser.formatBytes(5 * 1024 * 1024), "5 Mi")
        XCTAssertEqual(ResourceParser.formatBytes(500), "500")
    }
}
