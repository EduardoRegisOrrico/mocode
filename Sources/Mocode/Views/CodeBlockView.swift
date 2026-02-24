import SwiftUI
import UIKit

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false
    private let diffLanguages = ["diff", "patch"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundColor(MocodeTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(.caption2))
                        .foregroundColor(copied ? MocodeTheme.accent : MocodeTheme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                if isDiffBlock {
                    diffContent
                } else {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(MocodeTheme.textBody)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    private var isDiffBlock: Bool {
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if diffLanguages.contains(lang) { return true }
        return code.contains("\n@@") || code.hasPrefix("@@")
    }

    private var diffContent: some View {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(lines.indices, id: \.self) { index in
                DiffLineView(text: String(lines[index]))
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiffLineView: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .foregroundColor(foreground)
            .padding(.vertical, 1)
            .padding(.horizontal, 6)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foreground: Color {
        if isAddedLine { return colorScheme == .dark ? Color(hex: "#CFF4DF") : Color(hex: "#1E5B3A") }
        if isRemovedLine { return colorScheme == .dark ? Color(hex: "#F8D7DA") : Color(hex: "#842029") }
        if isHunkHeader { return Color(hex: "#9AA3B2") }
        return MocodeTheme.textBody
    }

    private var background: Color {
        if isAddedLine { return colorScheme == .dark ? Color(hex: "#1E5B3A") : Color(hex: "#CFF4DF") }
        if isRemovedLine { return colorScheme == .dark ? Color(hex: "#5C2B2E") : Color(hex: "#F8D7DA") }
        if isHunkHeader { return Color(hex: "#1A1F27").opacity(0.6) }
        return Color.clear
    }

    private var trimmedLeading: Substring {
        text.drop { $0 == " " || $0 == "\t" }
    }

    private var isAddedLine: Bool {
        trimmedLeading.hasPrefix("+") && !trimmedLeading.hasPrefix("+++")
    }

    private var isRemovedLine: Bool {
        trimmedLeading.hasPrefix("-") && !trimmedLeading.hasPrefix("---")
    }

    private var isHunkHeader: Bool {
        trimmedLeading.hasPrefix("@@")
    }
}

// MARK: - Previews

#Preview("Swift Code") {
    CodeBlockView(
        language: "swift",
        code: """
        struct ContentView: View {
            @State private var count = 0
            
            var body: some View {
                Button("Count: \\(count)") {
                    count += 1
                }
            }
        }
        """
    )
    .padding()
}

#Preview("Bash Command") {
    CodeBlockView(
        language: "bash",
        code: "ls -la ~/Documents | grep swift"
    )
    .padding()
}

#Preview("JSON") {
    CodeBlockView(
        language: "json",
        code: """
        {
          "name": "Mocode",
          "version": "1.0.0",
          "dependencies": {
            "SwiftUI": "latest"
          }
        }
        """
    )
    .padding()
}

#Preview("No Language") {
    CodeBlockView(
        language: "",
        code: "Some plain text output from a command"
    )
    .padding()
}

#Preview("Diff") {
    CodeBlockView(
        language: "diff",
        code: """
        diff --git a/Mocode/Mocode/Views/MessageBubbleView.swift b/Mocode/Mocode/Views/MessageBubbleView.swift
        index 1234567..89abcde 100644
        --- a/Mocode/Mocode/Views/MessageBubbleView.swift
        +++ b/Mocode/Mocode/Views/MessageBubbleView.swift
        @@ -72,6 +72,12 @@ struct MessageBubbleView: View {
         private var assistantContent: some View {
        -    let oldValue = parseMessage(text)
        -    // Old comment to remove
        +    // New diff-aware rendering
        +    let parsed = extractInlineImages(message.text)
             return VStack(alignment: .leading, spacing: 8) {
                 ForEach(Array(parsed.enumerated()), id: \\.offset) { _, segment in
        """
    )
    .padding()
}
