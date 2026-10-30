# Destination Folder Creation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show missing destination folders in the copy confirmation and create them only after the user approves copying.

**Architecture:** Add a PowerShell 5.1-compatible core helper that receives resolved destination paths and returns only directories that do not yet exist. The WinForms copy handler will show those paths in its existing confirmation prompt, then create them after approval and before the existing recursive copy loop.

**Tech Stack:** Windows PowerShell 5.1, WinForms, Pester 3.4.

**Spec:** `docs/superpowers/specs/2026-10-30-destination-folder-creation-design.md`

## Global Constraints

- Keep Japanese PowerShell files UTF-8 with BOM and parseable on Windows PowerShell 5.1.
- Preserve existing drive validation, source-descendant protection, and conflict behavior.
- Create directories only after the user accepts the copy confirmation.

## Review Focus

- A mix of existing and missing destinations lists only missing paths.
- Duplicate destination paths are shown and created once.
- An empty missing-path list does not alter the confirmation text or attempt creation.
- A missing nested path can be created with its parents after confirmation.
- A missing root drive remains an error before confirmation.

### Task 1: Detect and confirm missing destination folders

**Files:**
- Modify: `MultiDriveCopy.Core.ps1:44-58`
- Modify: `MultiDriveCopy.ps1:217-256`
- Modify: `tests/CopyProgress.Tests.ps1:4-29`

**Interfaces:**
- Produces: `Get-MissingDestinationDirectories([string[]]$Paths)`, returning unique missing directory paths.
- Consumes: resolved destination paths constructed by the copy button handler.

- [x] **Step 1: Write failing tests**

Add Pester cases with real TestDrive directories that expect the helper to return a missing nested directory, omit an existing directory, and deduplicate repeated input.

- [x] **Step 2: Run the new tests to verify they fail**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\\tests\\CopyProgress.Tests.ps1 -EnableExit"`

Expected: failure because `Get-MissingDestinationDirectories` is undefined.

- [x] **Step 3: Implement the core helper and update confirmation flow**

Add `Get-MissingDestinationDirectories` to `MultiDriveCopy.Core.ps1`. In the copy click handler, collect missing resolved roots, append a `新規作成するフォルダ` section only when nonempty, and create each directory after `Yes` before initializing and entering the copy loop.

- [x] **Step 4: Run the focused tests to verify they pass**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\\tests\\CopyProgress.Tests.ps1 -EnableExit"`

Expected: all focused tests pass.

- [x] **Step 5: Verify full compatibility and commit**

Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Path .\\tests -EnableExit"` and `git diff --check`.

Commit the production code, tests, design, and plan with `feat: confirm destination folder creation`.
