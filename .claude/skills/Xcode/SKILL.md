---
name: Xcode
description: Configure Xcode projects with XcodeGen, SPM, and explicit build flags. Use when setting up builds, adding dependencies, or configuring build settings. Never use #if DEBUG. (project)
---

# Xcode

## Use XcodeGen

Generate `.xcodeproj` from `project.yml`. Never commit `.xcodeproj` to git.

```bash
brew install xcodegen
xcodegen generate  # Run after any project.yml change
```

**Why:**
- No merge conflicts
- Readable project structure
- Reproducible builds

## Use SPM

Swift Package Manager over CocoaPods/Carthage.

In `project.yml`:

```yaml
packages:
  MyLibrary:
    url: https://github.com/example/MyLibrary
    from: 1.0.0

targets:
  MyApp:
    dependencies:
      - package: MyLibrary
```

## Explicit Build Flags

Don't rely on implicit `DEBUG`. Define explicit flags per configuration:

```yaml
settings:
  configs:
    Debug:
      SWIFT_ACTIVE_COMPILATION_CONDITIONS: USE_LOCAL_API VERBOSE_LOGGING
    Staging:
      SWIFT_ACTIVE_COMPILATION_CONDITIONS: USE_STAGING_API
    Release:
      SWIFT_ACTIVE_COMPILATION_CONDITIONS: USE_PRODUCTION_API
```

```swift
#if USE_LOCAL_API
let apiURL = "http://localhost:3000"
#elseif USE_STAGING_API
let apiURL = "https://staging.api.com"
#else
let apiURL = "https://api.com"
#endif
```

**Why:**
- Clear what each config enables
- Searchable in codebase
- No implicit "DEBUG means X, Y, Z"

## Don't

- Commit `.xcodeproj` when using XcodeGen
- Use CocoaPods for new projects
- Use `#if DEBUG` for behavior changes (use explicit flags)
- Skip `xcodegen generate` after `project.yml` changes
