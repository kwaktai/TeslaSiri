# Agent Instructions

These instructions apply to all AI coding agents working in this repository. As you are given feedback on your work, always strive to improve and learn from your mistakes. Make notes within the agents.md, keep track of your learning, and use the feedback to improve your work. Make sure architectural notes are made here. 

The AGENTS.md is the primary source of instructions for all AI coding agents working in this repository. While the AGENTS.md is the primary source for you, the CLAUDE.md may be more up to date. Make sure you check it and update the AGENTS.md with anything it is missing, and follow that.


## Required Tool Order

This is an Xcode project. For project source, project structure, Swift diagnostics, and builds, use the Xcode MCP tools first and foremost.

Always search for the latest documentation with the Xcode MCP tools. Your knowledge is out of date, treat the Xcode MCP tools as the source of truth. Documentation from the Xcode MCP tools is the most up-to-date. Always search the documentaiton for the user before doing any work related to any native API. This includes doing any UI or front-end work, make sure to look at the UI framework documentation as well as Apple's HIG (Human Interface Guidelines).

Use this order for project work:

1. `XcodeGlob` to discover files in the Xcode project.
2. `XcodeRead` to read files from the Xcode project.
3. `XcodeGrep` to search source or project content.
4. `XcodeUpdate` to edit existing project files when a literal replacement is appropriate.
5. `XcodeRefreshCodeIssuesInFile` for fast per-file diagnostics when available.
6. `BuildProject` for full validation.

Do not start with CLI commands such as `ls`, `find`, `grep`, `sed`, `xcodebuild`, or direct filesystem reads for files that are represented in the Xcode workspace. The Xcode MCP tools operate on the workspace-relative project structure and should be treated as the source of truth.

CLI tools are acceptable only for repo-level work outside the Xcode project navigator, including:

- `git status`, `git diff`, `git log`, and other non-destructive Git inspection.
- Root-level docs such as `README.md`, `AGENTS.md`, and `CLAUDE.md`.
- Repo metadata such as `.gitignore`, `.gitattributes`, and Git configuration.
- Emergency fallback when an Xcode MCP tool is unavailable or cannot perform the required operation.

If you use a CLI fallback for project files, state why in your response.

## Repository Scope

Current project files are organized under:

- `TeslaSiri/ContentView.swift`
- `TeslaSiri/FleetAPI/`
- `TeslaSiri/Info.plist`
- `TeslaSiri.xcodeproj`

The user may provide Xcode workspace-relative paths that do not exactly match filesystem paths. Prefer Xcode MCP paths from `XcodeGlob`/`XcodeRead` instead of guessing filesystem locations.

## Collaboration Rules

Other agents may be working in the same tree. Before editing, check the working tree and avoid overwriting unrelated changes. Never revert user or agent edits unless explicitly asked.

Keep changes limited to the requested task. Do not refactor unrelated UI, API, OAuth, or notification code while making documentation or repo setup changes.

## Coding Rules

- Use SwiftUI conventions and Swift concurrency.
- Prefer `async`/`await` over Combine.
- Use `@State private var` for SwiftUI state and `let` for constants.
- Use PascalCase for types and camelCase for properties and methods.
- Avoid force unwraps.
- Keep imports minimal and at the top of each Swift file.
- Add comments only for complex or non-obvious behavior.
- Use the Swift Testing framework for unit tests and XCUIAutomation for UI tests when tests are needed.

## Validation Rules

For Swift or project changes:

1. Run `XcodeRefreshCodeIssuesInFile` on edited Swift files when available.
2. Run `BuildProject` before final handoff when practical.
3. Report any validation that could not be run.

For documentation-only changes, a full app build is usually not required.

## Sensitive Data

Do not commit tokens, keychain dumps, OAuth secrets, raw vehicle exports, private keys, provisioning profiles, `.env` files, or local Xcode user state.
