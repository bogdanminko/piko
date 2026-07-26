import SwiftUI

/// Which language the summary is written in.
///
/// "Same as the recording" is the default and lets the backend detect it, so
/// nothing has to be chosen before the first run. Choosing explicitly is not
/// only a fallback for a failed guess: a Russian call can be summarized in
/// English for a report, which detection can never offer.
struct SummaryLanguagePicker: View {
    @Bindable var summarizer: SummarizerVM
    var disabled = false

    var body: some View {
        if !summarizer.languages.isEmpty {
            Picker("", selection: $summarizer.outputLanguage) {
                ForEach(summarizer.languages) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 190)
            .disabled(disabled)
            .help("Language the summary is written in")
        }
    }
}
