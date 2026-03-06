//
//  SpectrumShape.swift
//  MasterAudioKit
//
//  Shape for rendering spectrum/waveform. Bars grow from center (vertical center).
//  Single Path, minimal allocations, optimized for animation.
//

import SwiftUI

/// Shape that renders magnitudes as vertical bars centered vertically (mirror layout).
public struct SpectrumShape: Shape {
    public var magnitudes: [Float]

    public init(magnitudes: [Float]) {
        self.magnitudes = magnitudes
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !magnitudes.isEmpty else { return path }

        let barCount = magnitudes.count
        let totalWidth = rect.width
        let barWidth = totalWidth / CGFloat(barCount) * 0.58
        let gap = totalWidth / CGFloat(barCount) * 0.42
        let halfHeight = rect.height * 0.48
        let chartWidth = CGFloat(barCount) * (barWidth + gap) - gap
        let offsetX = (totalWidth - chartWidth) / 2
        let minHeight: CGFloat = 1.5

        for i in 0..<barCount {
            let mag = CGFloat(magnitudes[i])
            let x = offsetX + CGFloat(i) * (barWidth + gap)
            let halfBarHeight = max(minHeight, mag * halfHeight)
            let barHeight = halfBarHeight * 2
            let y = rect.midY - halfBarHeight
            let corner = min(barWidth / 2, 4)
            path.addRoundedRect(in: CGRect(x: x, y: y, width: barWidth, height: barHeight), cornerSize: CGSize(width: corner, height: corner))
        }
        return path
    }
}
