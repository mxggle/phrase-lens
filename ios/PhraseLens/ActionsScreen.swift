import SwiftUI

/// The actions the Share sheet and the lookup screen offer, in their order.
/// The first-listed default is what a lookup starts with.
struct ActionsScreen: View {
  @EnvironmentObject private var store: MobileSettingsStore
  @State private var editing: TranslationAction?

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(store.settings.actions) { action in
            Button {
              editing = action
            } label: {
              HStack(spacing: 12) {
                Image(systemName: action.mobileSymbol)
                  .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                  Text(action.mobileTitle)
                  if action.id == store.settings.defaultActionID {
                    Text(L10n.isChinese ? "默认" : "Default")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.footnote)
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .leading) {
              Button(L10n.isChinese ? "设为默认" : "Default", systemImage: "star") {
                store.settings.defaultActionID = action.id
              }
              .tint(.yellow)
            }
          }
          .onMove { store.settings.actions.move(fromOffsets: $0, toOffset: $1) }
          .onDelete { store.settings.actions.remove(atOffsets: $0) }
        } footer: {
          Text(
            L10n.isChinese
              ? "左滑删除，右滑设为默认。点“编辑”可以拖动排序。"
              : "Swipe left to delete, right to make default. Tap Edit to reorder."
          )
        }
      }
      .navigationTitle(L10n.isChinese ? "动作" : "Actions")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { EditButton() }
        ToolbarItem(placement: .primaryAction) { addMenu }
      }
      .sheet(item: $editing) { action in
        ActionEditor(action: action) { saved in
          if let index = store.settings.actions.firstIndex(where: { $0.id == saved.id }) {
            store.settings.actions[index] = saved
          } else {
            store.settings.actions.append(saved)
          }
        }
        .environmentObject(store)
        .mobilePalette()
      }
    }
  }

  private var addMenu: some View {
    Menu {
      Button(L10n.isChinese ? "新建自定义动作" : "New Custom Action", systemImage: "plus") {
        editing = MobileActions.blank()
      }
      let installed = Set(store.settings.actions.map(\.id))
      let missing = MobileActions.templates.filter { !installed.contains($0.id) }
      if !missing.isEmpty {
        Section(L10n.isChinese ? "添加内置动作" : "Add a Built-in") {
          ForEach(missing) { template in
            Button(template.mobileTitle, systemImage: template.mobileSymbol) {
              store.settings.actions.append(template)
            }
          }
        }
      }
    } label: {
      Image(systemName: "plus")
    }
    .accessibilityLabel(L10n.isChinese ? "添加动作" : "Add Action")
  }
}

/// Edits one action's name and prompts. Saving writes it back in place, or
/// appends it when it is new.
private struct ActionEditor: View {
  @State var action: TranslationAction
  let onSave: (TranslationAction) -> Void

  @EnvironmentObject private var store: MobileSettingsStore
  @Environment(\.dismiss) private var dismiss
  @State private var model = ""

  private var factory: TranslationAction? {
    if let builtIn = TranslationAction.factoryBuiltIn(for: action.id) { return builtIn }
    return action.id == MobileActions.nativeSpeakerID ? MobileActions.nativeSpeaker : nil
  }

  var body: some View {
    NavigationStack {
      Form {
        Section(L10n.isChinese ? "名称" : "Name") {
          if action.isBuiltIn {
            // Built-in names follow the interface language, so they are not
            // edited here.
            Text(action.mobileTitle).foregroundStyle(.secondary)
          } else {
            TextField(L10n.isChinese ? "名称" : "Name", text: $action.name)
          }
        }
        Section {
          TextEditor(text: $action.rolePrompt)
            .frame(minHeight: 120)
            .font(.callout.monospaced())
            .textInputAutocapitalization(.never)
        } header: {
          Text(L10n.isChinese ? "角色（System Prompt）" : "Role (System Prompt)")
        }
        Section {
          TextEditor(text: $action.commandPrompt)
            .frame(minHeight: 160)
            .font(.callout.monospaced())
            .textInputAutocapitalization(.never)
        } header: {
          Text(L10n.isChinese ? "指令" : "Command")
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(MobileActions.variables, id: \.0) { variable, meaning in
              Text("\(variable)  \(meaning)")
            }
          }
          .font(.caption.monospaced())
        }
        Section {
          Toggle(L10n.isChinese ? "按 Markdown 显示结果" : "Render result as Markdown", isOn: $action.outputMarkdown)
          LabeledContent(L10n.isChinese ? "模型" : "Model") {
            TextField(store.settings.provider.model, text: $model)
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }
        } footer: {
          Text(
            L10n.isChinese
              ? "模型留空就用“设置”里的默认模型。"
              : "Leave the model empty to use the one in Settings."
          )
        }
        if let factory, factory != action {
          Section {
            Button(L10n.isChinese ? "恢复默认 prompt" : "Restore Default Prompts", role: .destructive) {
              action.rolePrompt = factory.rolePrompt
              action.commandPrompt = factory.commandPrompt
              action.outputMarkdown = factory.outputMarkdown
            }
          }
        }
      }
      .navigationTitle(action.mobileTitle.isEmpty ? (L10n.isChinese ? "动作" : "Action") : action.mobileTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(L10n.isChinese ? "取消" : "Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(L10n.isChinese ? "保存" : "Save") {
            action.setModelOverride(model, for: store.settings.provider)
            if action.name.trimmingCharacters(in: .whitespaces).isEmpty {
              action.name = L10n.isChinese ? "新动作" : "New Action"
            }
            onSave(action)
            dismiss()
          }
        }
      }
      .onAppear {
        model = action.modelOverride(for: store.settings.provider) ?? ""
      }
    }
  }
}
