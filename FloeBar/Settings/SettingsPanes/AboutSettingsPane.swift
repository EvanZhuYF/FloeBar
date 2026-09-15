//
//  AboutSettingsPane.swift
//  FloeBar
//

import SwiftUI

struct AboutSettingsPane: View {
    @Environment(\.openURL) private var openURL
    @State private var frame = CGRect.zero

    private var acknowledgementsURL: URL {
        // swiftlint:disable:next force_unwrapping
        Bundle.main.url(forResource: "Acknowledgements", withExtension: "pdf")!
    }

    /// The upstream project FloeBar is derived from.
    private var upstreamURL: URL {
        URL(string: "https://github.com/jordanbaird/Ice")!
    }

    private var minFrameDimension: CGFloat {
        min(frame.width, frame.height)
    }

    var body: some View {
        HStack {
            if let nsImage = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsImage)
                    .resizable().scaledToFit()
                    .frame(width: minFrameDimension / 1.5)
            }

            VStack(alignment: .leading) {
                Text("FloeBar")
                    .font(.system(size: minFrameDimension / 7))
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text("Version")
                    Text(Constants.appVersion)
                }
                .font(.system(size: minFrameDimension / 30))
                .foregroundStyle(.secondary)

                Text(Constants.copyright)
                    .font(.system(size: minFrameDimension / 37))
                    .foregroundStyle(.tertiary)

                Button {
                    openURL(upstreamURL)
                } label: {
                    Text("Based on Ice by Jordan Baird")
                        .font(.system(size: minFrameDimension / 37))
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
            .fontWeight(.medium)
            .padding([.vertical, .trailing])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onFrameChange(update: $frame)
        .bottomBar {
            HStack {
                Button("Quit FloeBar") {
                    NSApp.terminate(nil)
                }
                Spacer()
                Button("Acknowledgements") {
                    NSWorkspace.shared.open(acknowledgementsURL)
                }
            }
            .padding()
        }
    }
}
