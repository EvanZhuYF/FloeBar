//
//  AboutSettingsPane.swift
//  FloeBar
//

import SwiftUI

struct AboutSettingsPane: View {
    @Environment(\.openURL) private var openURL

    private var acknowledgementsURL: URL {
        // swiftlint:disable:next force_unwrapping
        Bundle.main.url(forResource: "Acknowledgements", withExtension: "pdf")!
    }

    /// The upstream project FloeBar is derived from.
    private var upstreamURL: URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://github.com/jordanbaird/Ice")!
    }

    var body: some View {
        HStack(spacing: 20) {
            if let nsImage = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsImage)
                    .resizable().scaledToFit()
                    .frame(width: 128, height: 128)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("FloeBar")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text("Version")
                    Text(Constants.appVersion)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Text(Constants.copyright)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    openURL(upstreamURL)
                } label: {
                    Text("Based on Ice by Jordan Baird")
                        .font(.caption)
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
            .padding([.vertical, .trailing])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
