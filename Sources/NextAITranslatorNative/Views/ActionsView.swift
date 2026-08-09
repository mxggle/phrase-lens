import SwiftUI

struct ActionsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var draftActions: [TranslationAction] = []
  @State private var selectedID: UUID?
  @State private var saveTask: Task<Void, Never>?

  var body: some View {
    HSplitView {
      actionList
        .frame(
          minWidth: AppMetrics.actionListMinWidth,
          idealWidth: AppMetrics.actionListIdealWidth,
          maxWidth: AppMetrics.actionListMaxWidth
        )
      editor
        .frame(
          minWidth: AppMetrics.actionEditorMinWidth,
          maxWidth: .infinity,
          maxHeight: .infinity
        )
        .layoutPriority(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppDesign.canvas)
    .onAppear {
      draftActions = model.customActions
      selectedID = selectedID ?? TranslationAction.builtIns.first?.id
    }
    .onDisappear { flushPendingSave() }
    .onChange(of: draftActions) { _, actions in
      scheduleSave(actions)
    }
  }

  // MARK: - List

  /// Editing controls sit in a bar under the list, which is where macOS puts
  /// add/remove for a source list. Nothing here is a window-level command, so
  /// nothing here belongs in the toolbar.
  private var actionList: some View {
    VStack(spacing: 0) {
      List(selection: $selectedID) {
        Section("Built-in") {
          ForEach(TranslationAction.builtIns) { action in
            Label(action.name, systemImage: action.mode?.symbol ?? "sparkles")
              .tag(action.id)
          }
        }
        if !draftActions.isEmpty {
          Section("Custom") {
            ForEach(draftActions) { action in
              Label(
                action.name.isEmpty ? "Untitled Action" : action.name,
                systemImage: "sparkles"
              )
              .tag(action.id)
            }
          }
        }
      }
      .listStyle(.sidebar)

      PaneBar(.footer) {
        BarButton(title: "Add a custom action", symbol: "plus") {
          addAction()
        }
        BarButton(
          title: "Delete the selected action",
          symbol: "minus",
          isDisabled: !draftActions.contains(where: { $0.id == selectedID })
        ) {
          removeSelectedAction()
        }
        Spacer(minLength: 0)
        Text("\(draftActions.count) custom")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxHeight: .infinity)
  }

  // MARK: - Editor

  @ViewBuilder
  private var editor: some View {
    if let index = draftActions.firstIndex(where: { $0.id == selectedID }) {
      Form {
        Section {
          TextField("Name", text: $draftActions[index].name)
          Toggle("Render the result as Markdown", isOn: $draftActions[index].outputMarkdown)
        } header: {
          Text("Action")
        } footer: {
          Text("Changes are saved automatically.")
        }

        Section("System Prompt") {
          promptEditor(text: $draftActions[index].rolePrompt, minHeight: 96)
        }

        Section {
          promptEditor(text: $draftActions[index].commandPrompt, minHeight: 132)
        } header: {
          Text("Command Prompt")
        } footer: {
          Text("Available variables: ${sourceLang}, ${targetLang}, ${text}")
            .monospaced()
        }
      }
      .formStyle(.grouped)
    } else if let action = TranslationAction.builtIns.first(where: { $0.id == selectedID }) {
      builtInDetail(action)
    } else {
      ContentUnavailableView(
        "No Action Selected",
        systemImage: "slider.horizontal.3",
        description: Text("Choose an action on the left, or add a custom one.")
      )
    }
  }

  private func promptEditor(text: Binding<String>, minHeight: CGFloat) -> some View {
    TextEditor(text: text)
      .font(.system(size: 12, design: .monospaced))
      .scrollContentBackground(.hidden)
      .padding(AppSpacing.sm)
      .frame(minHeight: minHeight)
      .background(AppDesign.editorSurface, in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
      }
  }

  /// Built-in actions use the same form shape as custom ones, disabled, so
  /// switching between the two does not rearrange the pane.
  private func builtInDetail(_ action: TranslationAction) -> some View {
    Form {
      Section {
        LabeledContent("Name", value: action.name)
        LabeledContent("Result format", value: action.outputMarkdown ? "Markdown" : "Plain text")
      } header: {
        Text("Action")
      } footer: {
        Label(
          "Built-in actions use PhraseLens's default prompts and cannot be edited. "
            + "Add a custom action to write your own.",
          systemImage: "info.circle"
        )
      }

      Section {
        Button("Add a Custom Action") { addAction() }
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Editing

  private func addAction() {
    let action = TranslationAction(
      name: "Custom Action",
      rolePrompt: "You are a helpful language assistant.",
      commandPrompt: "${text}",
      outputMarkdown: false
    )
    draftActions.append(action)
    selectedID = action.id
  }

  private func removeSelectedAction() {
    guard let selectedID else { return }
    let index = draftActions.firstIndex { $0.id == selectedID }
    draftActions.removeAll { $0.id == selectedID }
    self.selectedID =
      index.flatMap { draftActions.indices.contains($0) ? draftActions[$0].id : draftActions.last?.id }
      ?? TranslationAction.builtIns.first?.id
  }

  /// Typing in a prompt should not write to disk on every keystroke, and the
  /// user should not have to remember a Save button either.
  private func scheduleSave(_ actions: [TranslationAction]) {
    // Loading the drafts on appear is not an edit.
    guard actions != model.customActions else { return }
    saveTask?.cancel()
    saveTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      model.saveCustomActions(actions)
    }
  }

  private func flushPendingSave() {
    guard saveTask != nil else { return }
    saveTask?.cancel()
    saveTask = nil
    guard draftActions != model.customActions else { return }
    model.saveCustomActions(draftActions)
  }
}
