# Interface typography and layout

- Use the system macOS font through `Font.appFont`; use the system monospaced font for counters. Do not bundle SB Sans or reintroduce custom font registration.

- Apply the shared `typographicText` presentation rules to human-readable interface text. Use `screenText`, `screenButton`, `screenLabel`, `screenToggle`, `screenMenu` and `screenHelp` rather than adding an unformatted string label.
- Bind Russian short prepositions, conjunctions and particles to the following word with a nonbreaking space. Bind numbers to units, percentages and month names. Preserve deliberate paragraph breaks.
- Editable values and stored transcripts remain unchanged. Show copyable paths and executable configuration with `screenText(verbatim:)`.
- For every interface change, run the typography regression tests and visually inspect every affected screen, popup and state at the supported window sizes. Check wrapping, truncation, clipping, alignment, spacing and contrast after the last edit. A successful build is not a layout check.
- Preserve the two-line maximum for sidebar items and readable control sizes. Avoid fixing wrapping by shrinking text.
- Round completed sidebar durations up to minutes, then display hours and remaining minutes. Keep live counters and transcript timestamps precise.

# Repository

- Commit and push completed requested changes to `docomoz/pisya`. The public repository is the active source of truth; preserve its history and keep the separate private archive history out of public pushes.
