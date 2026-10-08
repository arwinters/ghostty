# Validation of the native status plugin prototype

Environment: Apple Silicon macOS, Xcode 27.0 (27A266a), Zig 0.16.0.
Base revision: `7ec9e26`.

Completed:

- Ghostty core/XCFramework build: `zig build -Demit-macos-app=false`.
- Full macOS application build: `macos/build.nu --configuration ReleaseLocal`.
  The identical macOS sources, generated XCFramework and resources were copied
  to a temporary directory to avoid Finder metadata breaking ad-hoc signing
  under Documents. No build-setting or application-code workaround was applied.
- New config accepted by the built app's `+validate-config` action.
- Targeted Zig config test: `zig build test
  -Dtest-filter='native status plugin manifest configuration'`.
- Ten Swift tests passed in an isolated Swift Package using the actual host,
  protocol sources and `StatusPluginTests.swift` from this branch. This isolates
  the plugin tests from the app's existing test suite and signing requirements.
  Cases include partial records, latest snapshot replacement, invalid fields,
  duplicate IDs, oversized output, manifest validation, disabled operation,
  exited plugins, valid updates/disable, flooding and silent-plugin timeout.
- Example Swift plugin compiled with optimization and produced three live CPU,
  RAM, receive and transmit samples. All graph values were checked to lie in
  0...1 and all four widgets were present.
- Strict SwiftLint passed for all four new app/test Swift files.
- Zig format and Git whitespace checks passed.

- Full macOS unit-test run: `macos/build.nu --action test` succeeded, including
  all ten plugin tests inside the actual Ghostty app test target. The upstream
  build script excludes GhosttyUITests by design.

Remaining: manual visual/accessibility checks, quick-terminal behavior,
multi-window lifecycle, sleep/wake, and interactive application compatibility.
Do not interpret compilation and unit tests as visual or accessibility QA.
