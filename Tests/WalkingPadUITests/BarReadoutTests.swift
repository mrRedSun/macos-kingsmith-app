import AppKit
import SwiftUI
import Testing
import WalkingPadCore
@testable import WalkingPadApp

@MainActor
struct BarReadoutTests {
    private let all: [BarReadout.Reading] = [
        .init(metric: .speed, value: "3.0"), .init(metric: .steps, value: "3007"),
        .init(metric: .distance, value: "1.87"), .init(metric: .duration, value: "37:32"),
    ]

    @Test func stackedReadoutFitsTheMenuBarAndSavesWidth() throws {
        let pair = Array(all[1...2])
        let stacked = try #require(BarReadout.image(pair, stacked: true))
        let inline = try #require(BarReadout.image(pair, stacked: false))
        #expect(stacked.isTemplate)
        #expect(stacked.size.height <= 22 && inline.size.height <= 22)
        #expect(stacked.size.width < inline.size.width * 0.7)
        let four = try #require(BarReadout.image(all, stacked: true))
        #expect(four.size.width < 110)
    }

    /// Visual review: `WALKINGPAD_SNAPSHOTS=1 swift test --filter BarReadout`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WALKINGPAD_SNAPSHOTS"] != nil))
    func savesMenuBarSnapshots() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/design-checks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let variants: [([BarReadout.Reading], Bool)] = [
            (Array(all[1...2]), true), (all, true), (Array(all[1...2]), false), (Array(all[0...2]), true),
        ]
        for dark in [false, true] {
            let bar = VStack(alignment: .trailing, spacing: 8) {
                ForEach(variants.indices, id: \.self) { index in
                    HStack(spacing: 14) {
                        Image(systemName: "wifi"); Image(systemName: "battery.75percent")
                        BarReadout(readings: variants[index].0, stacked: variants[index].1).frame(height: 22)
                        Image(systemName: "magnifyingglass"); Text("Tue 12:55")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(dark ? Color(white: 0.16) : Color(white: 0.93))
                }
            }
            .foregroundStyle(dark ? .white : .black)
            .padding(10)
            .background(dark ? Color.black : Color.white)
            let renderer = ImageRenderer(content: bar)
            renderer.scale = 4
            let image = try #require(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("menubar-\(dark ? "dark" : "light").png"))
        }
    }
}
