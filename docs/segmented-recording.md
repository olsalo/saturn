# Segmented recording

Pause finalizes a source clip; Continue records a new clip in the same project.
Stop also works while paused. Paused wall time is excluded from the duration.
The macOS status bar exposes directly clickable Pause / Continue and Stop buttons.
Control + Option + Command + P pauses or continues globally; the R combination
starts or stops. Saturn appears while paused with the source picker disabled,
then hides before capture resumes. The 3-second countdown option remains editable
while paused and applies to Continue from the panel, global shortcut or status bar.
Escape cancels a pending countdown.
The export preview remains a still image from the first clip.

New recordings use `.saturn` manifest version 2. `clips` holds independent source
video, system/microphone audio with local offsets, and local cursor metadata.
`sequence` holds ordered clip references. The top-level media fields summarize
the sequence for existing UI consumers. Version 1 projects remain supported.

Exports render each clip with the current project settings, concatenate the
rendered intermediates with straight cuts, then encode the complete sequence.
Original clips remain untouched, so the project can be reopened and re-exported.
Transitions and trims can extend the sequence model in a later change; transition
controls are not included here.

Completed clips are checkpointed before Pause is acknowledged. A native journal
also preserves the clip list if manifest checkpointing fails. A failed Continue
keeps earlier clips. Recovery of an unfinished first clip is best-effort and may
lack separately recorded audio when its timing metadata was not finalized.

Verification: `npm run build`, `npm test`, `npm run test:rust`, and
`npm run test:native`. Native tests exercise the status bar through its actual
button actions and verify paused window visibility with synthetic capture, plus multi-clip rendering, duration, audio
continuity and temporary-file cleanup. Actual ScreenCaptureKit capture still
requires a permission-enabled macOS session.
