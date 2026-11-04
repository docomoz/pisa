# Meeting Titles Implementation Plan

> **For agentic workers:** Implement sequentially in this session; use test-driven-development and verification-before-completion.

**Goal:** Name a completed meeting from its full transcript while preserving manual names.

**Architecture:** Core owns title provenance, normalization and bounded hierarchical summarization. The app downloads verified local weights, runs MLX inference and applies the result after both transcription completion paths.

**Tech Stack:** Swift, existing model installer, pinned mlx-swift-lm, Qwen3-1.7B-4bit.

**Spec:** docs/superpowers/specs/2026-11-04-meeting-titles-design.md

## Global Constraints

- macOS 15; local processing; no transcript upload
- Preserve unrelated work; commit completed task changes
- Reuse existing interface and spacing tokens

## Review Focus

- Manual and legacy custom names survive reprocessing
- Generated names survive date refresh and JSON reload
- Empty, failed and partial transcripts retain their titles
- Long transcripts include their final part; model output is bounded
- Download/generation failure preserves successful transcription

### Task 1: Core title policy and composition

Files: Sources/PisyaCore/Models.swift, Sources/PisyaCore/MeetingTitles.swift, Tests/PisyaCoreTests/MeetingTitleTests.swift.

- [x] Add failing tests for provenance, persistence, invalid output, all chunks and provider failure
- [x] Run swift test --filter MeetingTitleTests; confirm expected failures
- [x] Implement title policy and sequential summary reduction
- [ ] Run swift test

### Task 2: Native inference and completion integration

Files: Sources/Pisya/MeetingTitleModel.swift, Sources/Pisya/MeetingTitleTests.swift, Sources/Pisya/AppState.swift, Sources/Pisya/Launcher.swift, project.yml, scripts/title-model.json, dependencies.resolved.json.

- [x] Pin a compatible MLX text runtime; add verified model manifest
- [x] Generate a title from a local model, with bounded tokens and cancellation
- [x] Integrate both full and live completion, preserving saved transcript on failure
- [x] Run isolated native checks with the real model and synthetic Russian/English conversations
- [x] Build Release; verify packaging and signature
- [ ] Inspect title display and manual rename in an isolated final build
- [x] Review task diff and commit only task changes
