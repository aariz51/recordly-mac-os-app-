import XCTest
import CoreGraphics
@testable import Reclip

final class EditorPresetTests: XCTestCase {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("reclip-presets-\(UUID().uuidString).json")
    }

    private func project(padding: Double, frame: DeviceFrame) -> ReclipProject {
        var style = StyleOptions(); style.paddingFraction = padding; style.deviceFrame = frame
        return ReclipProject.capture(source: URL(fileURLWithPath: "/tmp/x.mp4"), style: style,
                                     zoom: ZoomTimeline(), webcam: WebcamSettings(), annotations: [],
                                     trimStart: 0, trimEnd: 0, speed: 1)
    }

    func testSaveLoadUpsertDelete() throws {
        let url = tmpURL(); defer { try? FileManager.default.removeItem(at: url) }
        let preset = EditorPreset(id: "p1", name: "My Look", createdAt: 1000,
                                  snapshot: project(padding: 0.11, frame: .macOS))
        EditorPresetStore.save(preset, to: url)

        let all = EditorPresetStore.all(from: url)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "My Look")
        // The snapshot restores the styling.
        XCTAssertEqual(all.first?.snapshot.style().paddingFraction ?? -1, 0.11, accuracy: 1e-9)
        XCTAssertEqual(all.first?.snapshot.style().deviceFrame, .macOS)

        // Upsert by id (same id replaces, not appends).
        var renamed = preset; renamed.name = "Renamed"
        EditorPresetStore.save(renamed, to: url)
        let after = EditorPresetStore.all(from: url)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.name, "Renamed")

        // A second distinct preset coexists, ordered by createdAt.
        EditorPresetStore.save(EditorPreset(id: "p2", name: "Second", createdAt: 2000,
                                            snapshot: project(padding: 0.03, frame: .none)), to: url)
        let two = EditorPresetStore.all(from: url)
        XCTAssertEqual(two.map(\.id), ["p1", "p2"])

        // Delete.
        EditorPresetStore.delete(id: "p1", from: url)
        XCTAssertEqual(EditorPresetStore.all(from: url).map(\.id), ["p2"])
    }

    func testMissingFileReturnsEmpty() {
        XCTAssertTrue(EditorPresetStore.all(from: tmpURL()).isEmpty)
    }
}
