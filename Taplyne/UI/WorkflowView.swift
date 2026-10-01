import SwiftUI

struct WorkflowView: View {
    @ObservedObject var chat: AgentChat
    @Binding var draft: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var selected: ConversationStore.Workflow?
    @State private var values: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved workflows").font(.title2.bold())
            Text("Use {{recipient}} or {{topic}} for details that change each run. Review the filled instructions before starting.").foregroundStyle(.secondary)
            List {
                ForEach(chat.workflows) { workflow in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(workflow.name).font(.headline)
                            Text(workflow.prompt).font(.caption).lineLimit(2)
                        }
                        Spacer()
                        Button("Use") { selected = workflow; values = [:]; error = nil }
                        Button(role: .destructive) { chat.deleteWorkflow(workflow.id); if selected?.id == workflow.id { selected = nil } } label: { Image(systemName: "trash") }
                    }
                }
            }.frame(height: 130)
            if let selected {
                Text(selected.name).font(.headline)
                ForEach(selected.inputs, id: \.self) { key in
                    TextField(key, text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }))
                }
                Text((try? selected.rendered(values)) ?? selected.prompt).font(.caption).lineLimit(5).textSelection(.enabled)
                HStack {
                    Button("Load into draft") {
                        do { draft = try selected.rendered(values); dismiss() } catch { self.error = error.localizedDescription }
                    }
                    Button("Run workflow") {
                        do { try chat.runWorkflow(selected, values: values); dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(chat.running || chat.paused)
                }
            }
            Divider()
            TextField("Workflow name", text: $name)
            TextField("Instructions", text: $prompt, axis: .vertical).lineLimit(2...4)
            HStack {
                Button("Use current draft") { prompt = draft }
                Spacer()
                Button("Save") { chat.saveWorkflow(name: name, prompt: prompt); name = ""; prompt = "" }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !chat.workflowRuns.isEmpty {
                Text("Recent runs").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(chat.workflowRuns.suffix(10).reversed()) { run in
                            Text("\(run.name) · \(run.status) · \(run.startedAt.formatted())").font(.caption.bold())
                            Text(run.result).font(.caption).lineLimit(3).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 130)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560).frame(minHeight: 470, maxHeight: 800)
    }
}
