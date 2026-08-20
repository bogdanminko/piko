import SwiftUI

/// The shortcut list. A menu rather than a bare `/` hint: naming what each
/// command does is the difference between a shortcut and a secret.
extension WorkspaceChatView {
    // MARK: - Slash panel

    var slashPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleCommands) { command in
                Button {
                    chat.draft = ""
                    showsSlashPanel = false
                    onCommand(command)
                } label: {
                    HStack(spacing: 12) {
                        Text(command.name)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.accent)
                            .frame(width: 84, alignment: .leading)
                        Text(command.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.text)
                        Spacer()
                    }
                    .padding(EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .cardSurface(theme, radius: 9)
    }

    var visibleCommands: [ChatCommand] {
        chat.commandSuggestions.isEmpty ? ChatCommand.all : chat.commandSuggestions
    }

}
