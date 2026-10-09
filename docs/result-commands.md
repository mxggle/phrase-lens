# Result buttons and write-back

What an action offers under its answer, and how Replace and Insert put that
answer back into the app the text was selected in.

## Model

`ResultCommand` has three cases: `copy`, `replace` and `insert`. Each
`TranslationAction` lists the ones its answer offers, primary first.

| Action | Default buttons |
|---|---|
| Translate | Copy · Replace · Insert |
| Polish | Replace · Copy |
| Everything else, including custom actions | Copy |

The list is stored as raw strings in `resultCommandIDs`:

- nil means "the mode's defaults", so an untouched built-in is not saved as an
  override.
- Unknown values, written by a newer version, are skipped, so the action
  still loads.
- An empty or unreadable list falls back to the defaults.

Set the list through `resultCommands`, which normalizes it.

## Where the buttons appear

- **Pop-up.** The first offered command that applies is the brand pill. The
  others sit beside it as icons.
- **Main window.** Replace and Insert sit beside Copy in the result header.
- **Translation menu.** Replace and Insert items, for keyboard access.

Replace and Insert are **offered only** when the input is a selection
(`inputSource == .selection`) whose control reported itself editable.
Otherwise they are hidden, not disabled, and Copy becomes the primary. They
are **disabled** while an answer is streaming.

The pop-up's buttons have **no keyboard shortcut**. Until the reader clicks
the pop-up, keystrokes still go to the source app: Escape is caught by a
global monitor for exactly that reason. In Mail, Slack and most chat apps,
⌘↩ means Send.

A successful write closes the pop-up, even when it is pinned, and clears the
target. The captured range now holds the answer, so a second write would be
wrong. A failed write re-opens the pop-up with the error.

## Capture

Right after a selection is read, `AccessibilityService.insertionTarget`
records an `InsertionTarget`:

- the source pid and the focused element
- the selection's range and text
- whether the control is editable (`AXSelectedText` or `AXValue` is settable)
- whether it sits inside an `AXWebArea`: a browser page, or an Electron app
  such as VS Code

Secure text fields produce no target.

## Writing

`AccessibilityService.write(_:placement:into:)`:

1. Refuses a target that is not editable or whose captured selection is empty.
2. Waits for shortcut modifiers to lift, then brings the source app back to
   the front. When the main window had activated PhraseLens, it yields
   activation first.
3. **Stale guard.** In native controls, it re-reads the captured range. In web
   content, or wherever no range could be read, it reads the live
   `AXSelectedText`. If the text no longer matches the captured selection, it
   writes nothing.
4. **Native controls, with a range:** sets `AXSelectedText` over the range,
   then confirms by reading `AXValue` back. TextEdit takes this route, and ⌘Z
   undoes it.
5. **Everything else:** writes the payload to the clipboard, marked
   `org.nspasteboard.TransientType` so clipboard managers skip it. Then it
   posts ⌘V to the pid and confirms the value changed.
   - On success, the reader's clipboard is restored, unless something else
     wrote to it in the meantime.
   - On failure, the answer stays on the clipboard and the error says so.
6. ⌘V and the capture's ⌘C use whichever key types V and C in the current
   layout with Command held (`KeyboardLayoutKeys`). This covers Dvorak and
   "Dvorak – QWERTY ⌘". Non-Latin layouts fall back to the ANSI position.

### Placement

Web content is never placed by Accessibility offset. Chrome counts offsets
without its paragraph breaks and resolves an offset on a boundary to the start
of the next paragraph. There, the reader's own selection is collapsed with →
and the caret is moved by arrow keys. Native controls are placed by offset.

`WriteBackComposer` decides what is written. It's pure, and covered by
`--self-test`.

- **Replace** writes the answer wrapped in the selection's own leading and
  trailing whitespace. A triple-clicked paragraph therefore keeps its line
  break.
- **Insert** looks at what follows the selection. For web content it reads
  that from the control's value, finding the selected text from its reported
  offset onwards.

| What follows the selection | Insert writes |
|---|---|
| A line break, or the selection carries one | `answer + "\n"`, placed after the break |
| More text on the same line | `" " + answer`, right after the selected words |
| End of text, or unknown | `"\n" + answer` after a sentence, a paragraph or a multi-line answer, otherwise `" " + answer` |

Writing after the break, rather than putting a break in front of the answer,
matters in rich-text editors. They turn a pasted leading break into an empty
paragraph.

## Verified

These cases were run with the debug probe below, against the real
`AccessibilityService`:

- **TextEdit** (Accessibility route): Replace; Insert after a mid-line word,
  after a line and after the last line; ⌘Z undo.
- **Safari and Chrome `<textarea>`** (paste route): Replace, and Insert onto
  the next line.
- **Safari and Chrome `contenteditable`** (paste route): Replace in the first
  and in a later paragraph, and Insert as its own paragraph with no blank line.
- **Read-only web pages:** reported not editable, so the buttons are hidden.
- **VS Code** (paste route): Replace and Insert after a word, before
  placement moved to arrow keys.
- **End to end:** a real click on the pop-up's Replace and Insert buttons,
  writing into TextEdit.
- **Clipboard:** restored after every paste.

## Known limits

- Inserting after the **last** paragraph of a web rich-text editor leaves an
  empty paragraph above the answer. There is no following break to write
  after, and Return is never sent because it means Send in chat apps.
- In a control that reports no range and no selected text, the live selection
  can't be checked, so the write goes over whatever is selected.
- TextEdit merges consecutive Accessibility writes into one undo step.
- Answers from Markdown actions are written as Markdown source. The action
  editor says so when such an action enables Replace or Insert.
- Not yet exercised: VS Code since the arrow-key placement, Notion, Slack,
  WeChat, Telegram, Pages/Word, terminals, Java apps, remote desktops.

## Debug tooling

Debug builds only. The Bash shell on the development Mac is
Accessibility-trusted, so the raw `.build/debug/PhraseLens` can run these
without a TCC prompt.

- `--write-back-probe <pid> <replace|after> <text>` reads the live selection
  in `<pid>`, writes, and prints the route taken and the resulting value.
- `--dictionary-preview --preview-capture-from <pid> [--preview-action
  polish|translate] --preview-result <text>` shows that selection in the real
  pop-up with a canned answer, for clicking the buttons end to end.
