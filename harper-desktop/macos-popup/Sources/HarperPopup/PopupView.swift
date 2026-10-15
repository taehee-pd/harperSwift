// Added in this fork (taehee-pd/harperSwift).

import SwiftUI

/// Functional content; restyled in a later commit.
struct PopupView: View {
    let data: PopupData?
    let onAction: (PopupAction) -> Void

    var body: some View {
        if let data {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(data.kindName)
                    Spacer()
                    Button("Close") { onAction(.close) }
                }
                Text(data.message)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    ForEach(Array(data.suggestions.enumerated()), id: \.offset) { index, suggestion in
                        Button(suggestion.label) { onAction(.applySuggestion(index)) }
                    }
                }
                HStack {
                    Button("Ignore") { onAction(.ignoreLint) }
                    if data.canAddToDictionary {
                        Button("Add to dictionary") { onAction(.addToDictionary) }
                    }
                    Spacer()
                    Button("Disable rule") { onAction(.disableRule) }
                }
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
    }
}
