# Rack design rules

Every rack (Duplicate Finder, Media Organizer, Convert & Compress, Transcribe, Second Screen) follows these rules so the app feels like one product. Shared pieces live in `FileFoundryApp/Views/Shared/RackKit.swift`.

## Language and copy

- All interface text is US English. No Portuguese anywhere in the UI, alerts, notifications, export headings or error messages. Do not force a locale (`.environment(\.locale, …)`); dates and numbers follow the system.
- Title Case for buttons, menu items, toolbar labels and window titles ("Import Files", "Move to Trash"). Sentence case for descriptions, help tags and messages.
- Say what happens, not how. No implementation jargon in the UI: no "byte-for-byte", "SHA-256", "APFS clone", "two-pass", "HEVC" unless it is a choice the person makes. Example: "Only files with identical content are matched."
- Short: a label is 1–3 words, a message is one sentence, an error says what went wrong and what to do next.
- Destructive actions name the object and say whether it can be undone ("Move 3 Files to Trash").

## Structure

- `navigationTitle` is the rack name. Toolbar: up to three icon buttons in `.primaryAction`, then one "More" menu (`ellipsis.circle`) for everything else. Rack options open in a sheet from a gear button (`gearshape`, label "<Rack> Options"), never in the app Settings window.
- A rack that needs a list or configuration column uses `HSplitView` with `RackLayout.paneMin/paneIdeal/paneMax` for the pane and `RackLayout.contentMin` for the content. Never `NavigationSplitView` (the app root already is one).
- Empty screens use `RackEmptyState`: one symbol, a title, one sentence, one primary action, optionally one secondary action and a short footnote.
- Every rack ends with a `RackStatusBar` (32 pt): what is happening now on the leading side, counts on the trailing side.
- Long work shows determinate progress when possible, can be cancelled, and never blocks the rest of the app.

## Behavior

- File and save panels use `panel.presentAsSheet { ok in … }` (attached to the window). Never `runModal()`, which freezes every rack. Alerts use `beginSheetModal(for:)` as well.
- Drag and drop works wherever files are accepted.
- Keyboard: Return triggers the primary action, Delete removes the selected item, Escape cancels sheets.

## Visual

- Spacing only from `RackLayout` (4, 8, 12, 16, 24, 32). Corner radius 12. Grouped surfaces use `.foundryCard()`.
- System fonts and semantic colors only (`.secondary`, `.tint`, `.red` for destructive). Numbers that change use `.monospacedDigit()`.
- Motion: only for state changes the person caused. Springs `response 0.3, dampingFraction 1`, or ease-out 0.15–0.2 s. Respect `accessibilityReduceMotion`. No decorative or looping animation.
