// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// CREDITS.md (bundled) split into its "## " sections; each list item, paragraph or table row is one entry.
struct CreditsDocument {
    struct Section: Identifiable { let id: Int; let title: String; var items: [String] }
    let sections: [Section]

    static let bundled: CreditsDocument = {
        guard let url = Bundle.main.url(forResource: "CREDITS", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return CreditsDocument(sections: []) }
        return CreditsDocument(markdown: text)
    }()

    init(sections: [Section]) { self.sections = sections }

    init(markdown: String) {
        var out: [Section] = [Section(id: 0, title: "Credits", items: [])]
        var current: String?
        func flush() {
            if let c = current, !c.isEmpty { out[out.count - 1].items.append(c) }
            current = nil
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush(); out.append(Section(id: out.count, title: String(line.dropFirst(3)), items: []))
            } else if line.hasPrefix("# ") || line.isEmpty {
                flush()
            } else if line.hasPrefix("|") {
                flush()
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) || cells.first == "#" { continue }
                out[out.count - 1].items.append(cells.joined(separator: " · "))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); current = String(line.dropFirst(2))
            } else if raw.hasPrefix(" ") || current != nil {
                current = (current.map { $0 + " " } ?? "") + line
            } else {
                current = line
            }
        }
        flush()
        sections = out.filter { !$0.items.isEmpty }
    }
}

struct AboutView: View {
    private let credits = CreditsDocument.bundled

    var body: some View {
        ZStack {
            TriptychBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TriptychSectionHeader(title: "Provenance", accent: TriptychPalette.hinge)
                    TriptychPanelCard { ExportLogsButton() }

                    TriptychSectionHeader(title: "Triptych", accent: TriptychPalette.macLight)
                    TriptychPanelCard {
                        Text("One app for Windows, macOS, Linux and more on iPhone and iPad. Licensed GPL-3.0-or-later as a combined work; source at the project repository. Not affiliated with any upstream project.")
                            .font(.system(size: 14))
                            .foregroundStyle(TriptychPalette.textPrimary)
                    }

                    TriptychSectionHeader(title: "Notices", accent: TriptychPalette.windowsLight)
                    TriptychPanelCard {
                        VStack(alignment: .leading, spacing: 10) {
                            // Required by LICENSE-BCD.md section 4(b)2 for BCD Material.
                            Text("Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games)")
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                            Text("LinuxRunner is based on ios-linuxkit and iSH; iSH's App Store notice applies.")
                            Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                            Text("Alpine Linux minirootfs, bundled as the starter Linux system (various licences; sources at alpinelinux.org).")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(TriptychPalette.textSecondary)
                    }

                    ForEach(credits.sections) { section in
                        TriptychSectionHeader(
                            title: section.title,
                            accent: TriptychPalette.macLight,
                            identifier: "credits-\(section.title)"
                        )
                        TriptychPanelCard {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(section.items.enumerated()), id: \.offset) { idx, item in
                                    Text((try? AttributedString(markdown: item, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item))
                                        .font(.footnote)
                                        .foregroundStyle(TriptychPalette.textSecondary)
                                        .tint(TriptychPalette.windowsLight)
                                    if idx < section.items.count - 1 {
                                        Rectangle().fill(TriptychPalette.hairline).frame(height: 1)
                                    }
                                }
                            }
                        }
                    }

                    TriptychSectionHeader(title: "Not included", accent: TriptychPalette.linuxLight)
                    TriptychPanelCard {
                        Text("No macOS, Windows, Android, Apple boot ROM or Apple Metal Shader Converter is shipped. macOS is downloaded from Apple by the user's device at install time; Windows ISOs and APKs are the user's own.")
                            .font(.system(size: 13))
                            .foregroundStyle(TriptychPalette.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .triptychColumn()
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .exportLogsToolbar()
        .accessibilityIdentifier("about-list")
    }
}
