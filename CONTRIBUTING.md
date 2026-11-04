# Contributing

[Andrew Lemons (@AndrewLemons)](https://github.com/AndrewLemons) maintains this repository and reviews contributions. Use GitHub issues for bugs and feature requests, and pull requests for proposed changes. For vulnerabilities, follow [SECURITY.md](SECURITY.md).

Use Xcode 27. Install [mise](https://mise.jdx.dev) (`brew bundle` installs it), activate it in your shell, and run `make tools bootstrap`. mise installs the exact tool versions CI uses. Start with the [architecture](docs/ARCHITECTURE.md) and [dependency notes](docs/DEPENDENCIES.md).

Keep changes focused. Put protocol models and transport-independent behavior in `Core`, app coordination in `App/AppModel.swift`, platform services in `App/Services`, and presentation in `App/Views`. Keep credentials in Keychain and preserve Swift concurrency isolation. Do not log passwords, access tokens, pairing secrets, or complete server responses.

Before submitting:

1. Run `make format check secrets`. `make lint` includes SwiftFormat, SwiftLint, actionlint, zizmor (workflow security), and repository checks.
2. Run `make generate` when files, targets, or project settings change; include the generated project.
3. Build affected platforms (`make build-macos build-ios`). Run `make test-unit` and `make test-ui` for app changes. For playback/dependency changes, also run `make interop`.
4. For `ServerCompanion/` changes, run `make test-server-image` (Docker with Buildx). It builds the server image and tests the provider inside it.
5. Add behavior tests for bugs and new logic; explain any device checks you could not run. UI tests use synthetic data, never a real account.

SwiftFormat owns formatting; SwiftLint checks selected correctness rules. Tool versions are pinned in `mise.toml` and checksum-verified by `mise.lock`, so local results match CI. A weekly automated PR proposes upgrades, and formatter output changes are reviewed in that PR.

CI runs only the suites a PR affects and reports them through one required `CI` check. UI tests are slow on CI runners, so they run after merge and on the release PR rather than on every PR. Run `make test-ui` yourself when you change UI. Failing UI or unit tests are retried once; a test that passes only on retry is flagged as flaky in the run summary, so please fix it rather than ignore it. Failed runs upload logs and `.xcresult` bundles as artifacts.

Use Conventional Commits and a conventional PR title, such as `fix(playback): reconnect after network loss`, `feat(library): add album details`, or `docs: clarify setup`. Use `!` and a `BREAKING CHANGE:` footer for breaking changes. Prefer squash merging so the PR title becomes the release-relevant commit. Keep generated formatting changes separate from behavioral changes when practical.

Describe the problem, resulting behavior, and validation in your PR. Be respectful, assume good intent, and keep review focused on the work. Contributions are provided under the repository's Apache-2.0 license.
