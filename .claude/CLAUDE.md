# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Skills

Use the `.claude/skills/` folder for detailed guidance on specific topics:

| Skill | When to Use |
|-------|-------------|
| **Application** | App architecture, file layout, VM bundle format |
| **Virtualization** | VZVirtualMachine, IPSW installation, VM lifecycle |
| **SwiftUI** | Views, navigation, window management, app lifecycle |
| **Swift** | Language patterns, closures, optionals, protocols |
| **Testing** | XCTest, mocking, async testing |
| **Xcode** | XcodeGen, project.yml, build settings |
| **gh** | GitHub CLI for issues, PRs, releases |

## Build Commands

```bash
make          # Build vmctl CLI (default)
make cli      # Build vmctl CLI
make generate # Generate Xcode project from project.yml
make app      # Build SwiftUI app (auto-generates project)
make run      # Build and launch the app
make clean    # Remove build artifacts and generated project
```

The Xcode project is generated from `project.yml` using XcodeGen.

## Requirements

- macOS 15+ on Apple Silicon (arm64)
- Xcode 15+ for building
- XcodeGen (`brew install xcodegen`)
- `com.apple.security.virtualization` entitlement required

## Agent Workflow

- Use `gh` CLI for GitHub operations (invoke gh skill)
- When done with a task, run: `terminal-notifier -title "$TITLE" -message "$MESSAGE" -sound default -sender com.apple.Terminal`
- Update `AGENTS.md` `<Agent>` section with implementation notes
