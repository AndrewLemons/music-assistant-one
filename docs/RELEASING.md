# Release maintenance

[Andrew Lemons (@AndrewLemons)](https://github.com/AndrewLemons) maintains the repository and coordinates releases. App Store signing and publication use the Lemony Click, LLC account.

`release-please.yml` runs on main and on manual dispatch. It proposes a release PR from Conventional Commits, updating `version.txt`, `.release-please-manifest.json`, `CHANGELOG.md`, and the annotated marketing version in `Config/Version.xcconfig`. A small API-only step reserves the next integer build number in that PR; reruns do not increment it repeatedly or lower a manually reserved number.

The workflow sets `skip-github-release: true`: it creates no tags, GitHub releases, archives, signatures, uploads, or distribution artifacts. CI builds disposable unsigned binaries for validation only.

## GitHub setup

After creating the repository:

- Enable Actions and **Allow GitHub Actions to create and approve pull requests**. The workflow uses only `GITHUB_TOKEN`; no personal access token or Apple signing secret is required.
- Enable private vulnerability reporting, secret scanning, and push protection where available.
- Protect main with reviewed PRs and required CI checks (`quality`, `apple`), and disallow force pushes. Use squash merges with Conventional Commit titles.
- The Apple CI job uses GitHub's `xcode-27` preview runner because the extension needs the iOS 27 SDK. Monitor runner availability and update the label/toolchain when stable images become available.

PRs created or updated with `GITHUB_TOKEN` do not automatically trigger other workflows. Before merging a release PR, run CI manually from that PR's branch in the Actions UI; ensure the tested SHA is still the PR head. Do not bypass required checks. A narrowly scoped GitHub App token can be introduced later if automatic bot-PR checks are needed.

## Manual release

1. Review and test the release PR, including version and build number. Merge it only when ready to prepare that release.
2. Follow [distribution instructions](DISTRIBUTION.md) for signed archives, device checks, export, and notarization/submission.
3. Manually create the matching `vX.Y.Z` tag and GitHub release against the release commit when publication is intended. Release Please uses release tags as history boundaries; complete this step before the next release cycle to avoid re-including old changes.
4. Mark the merged release PR `autorelease: tagged` and remove `autorelease: pending` after publishing, since automatic publishing is disabled.

For another upload of the same marketing version, manually increment `CURRENT_PROJECT_VERSION` and commit with `chore(release): increment build number`. Never reuse an uploaded build number. Marketing version changes must stay synchronized across the xcconfig, version file, and manifest; `make check` validates them.

References: [Release Please action](https://github.com/googleapis/release-please-action), [generic version updates](https://github.com/googleapis/release-please/blob/main/docs/customizing.md), [Xcode 27 runner](https://github.com/actions/runner-images/issues/14404).
