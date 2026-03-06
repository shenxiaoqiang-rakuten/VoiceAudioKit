//
//  SpectrumView.swift
//  MasterAudioKit
//
//  Optimized voiceprint visualization with smooth animation and gradient.
//

import SwiftUI

/// View that displays real-time spectrum from PCMVisualizationPlugin.
public struct SpectrumView: View {
    public let spectrum: [Float]
    public var color: Color = .orange

    public init(spectrum: [Float], color: Color = .orange) {
        self.spectrum = spectrum
        self.color = color
    }

    public var body: some View {
        ZStack {
            SpectrumShape(magnitudes: spectrum)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(0.4),
                            color.opacity(0.75),
                            color
                        ],
                        startPoint: .center,
                        endPoint: .top
                    )
                )
                .animation(.easeOut(duration: 0.08), value: spectrum)
        }
        .drawingGroup()
    }
}
