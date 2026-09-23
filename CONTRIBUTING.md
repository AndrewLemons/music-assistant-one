# Contributing

[Andrew Lemons (@AndrewLemons)](https://github.com/AndrewLemons) maintains this repository and reviews contributions. Use GitHub issues for bugs and feature requests, and pull requests for proposed changes. For vulnerabilities, follow [SECURITY.md](SECURITY.md).

Use Xcode 27 and run `brew bundle`, then `make bootstrap`. Start with the [architecture](docs/ARCHITECTURE.md) and [dependency notes](docs/DEPENDENCIES.md).

Keep changes focused. Put protocol models and transport-independent behavior in `Core`, app coordination in `App/AppModel.swift`, platform services in `App/Services`, and presentation in `App/Views`. Keep credentials in Keychain and preserve Swift concurrency isolation. Do not log passwords, access tokens, pairing secrets, or complete server responses.

Before submitting:

1. Run `make format check secrets`.
2. Run `make generate` when files, targets, or project settings change; include the generated project.
3. Build affected platforms. For playback/dependency changes, run both Release builds and `python3 scripts/check-interop.py`.
4. Add behavior tests for bugs and new logic; explain any device checks you could not run. UI tests use synthetic data, never a real account.

SwiftFormat owns formatting; SwiftLint checks selected correctness rules. Tested tool versions: XcodeGen 2.46.0, SwiftFormat 0.63.0, SwiftLint 0.62.2, Gitleaks 8.30.1, actionlint 1.7.12. CI installs Homebrew tools; review formatter/tool upgrades together if their output changes.

Use Conventional Commits and a conventional PR title, such as `fix(playback): reconnect after network loss`, `feat(library): add album details`, or `docs: clarify setup`. Use `!` and a `BREAKING CHANGE:` footer for breaking changes. Prefer squash merging so the PR title becomes the release-relevant commit. Keep generated formatting changes separate from behavioral changes when practical.

Describe the problem, resulting behavior, and validation in your PR. Be respectful, assume good intent, and keep review focused on the work. Contributions are provided under the repository's Apache-2.0 license.
