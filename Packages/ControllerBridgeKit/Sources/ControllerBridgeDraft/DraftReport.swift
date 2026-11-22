/// The report a person reviews next to the draft profile (#189), in Markdown: the import check's problems, where the
/// capture and the docs disagree, what came from the docs, and every TODO with how to get it.
public enum DraftReport {
    public static func text(_ draft: ProfileDraft) -> String {
        let name = draft.profile["name"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? "?"
        let id = draft.profile["id"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? "?"
        var out = "# Draft profile: \(name) (\(id))\n\n"
        out += (draft.fromCapture
            ? "Drafted from a capture (#189). The capture wins over the docs; nothing here is guessed. "
            : "Drafted from the docs alone (#280), before any owner's capture; nothing here is guessed. The owner's capture "
                + "settles the TODOs and checks every value from the docs. ")
            + "Fix every problem, resolve or document every TODO, then review it before bundling (docs/ADDING-A-CONTROLLER.md).\n"
        if !draft.problems.isEmpty {
            out += "\n## Import check\n\n" + draft.problems.map { "- \($0)\n" }.joined()
        }
        if !draft.conflicts.isEmpty {
            out += "\n## Capture and docs disagree\n\n" + draft.conflicts.map { conflict in
                "- `\(conflict.key)`: the capture says \(conflict.capture.text()), the docs say \(conflict.docs.text())"
                    + (conflict.source.map { " (\($0))" } ?? "") + ". Kept \(conflict.capture.text()).\n"
            }.joined()
        }
        if !draft.fromDocs.isEmpty {
            out += "\n## From the docs\n\n" + draft.fromDocs.map { fact in
                "- `\(fact.key)` = \(fact.value.text())" + (fact.source.map { " (\($0))" } ?? " (no source given)") + "\n"
            }.joined()
        }
        if !draft.placeholders.isEmpty {
            // Filled so the file loads (#310); none of these was captured or documented.
            out += "\n## Placeholders from the LC6000 (check each)\n\n"
                + draft.placeholders.map { "- `\($0.key)` = \($0.value.text())\n" }.joined()
        }
        out += "\n## TODO\n\n" + (draft.todos.isEmpty ? "None.\n" : draft.todos.map { "- [ ] `\($0.key)`: \($0.how)\n" }.joined())
        return out
    }
}
