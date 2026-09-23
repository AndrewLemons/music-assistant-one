# Release maintenance

[Andrew Lemons (@AndrewLemons)](https://github.com/AndrewLemons) maintains the repository and coordinates releases. App Store signing and publication use the Lemony Click, LLC account.

`release-please.yml` runs on main and on manual dispatch. It proposes a release PR from Conventional Commits, updating `version.txt`, `.release-please-manifest.json`, `CHANGELOG.md`, and the annotated marketing version in `Config/Version.xcconfig`. A small API-only step reserves the next integer build number in that PR; reruns do not increment it repeatedly or lower a manually reserved number.

When a release PR merges into main, Release Please creates the corresponding `vX.Y.Z` tag and publishes a GitHub release with changelog-based release notes. It also updates the release PR lifecycle labels. The release workflow does not build, sign, or upload app binaries. CI builds disposable unsigned binaries for validation only.

## GitHub setup

After creating the repository:

- Enable Actions and **Allow GitHub Actions to create and approve pull requests**. The workflow uses only `GITHUB_TOKEN`; no personal access token or Apple signing secret is required.
- Enable private vulnerability reporting, secret scanning, and push protection where available.
- Protect main with reviewed PRs and required CI checks (`quality`, `apple`), and disallow force pushes. Use squash merges with Conventional Commit titles.
- The Apple CI job uses GitHub's `xcode-27` preview runner because the extension needs the iOS 27 SDK. Monitor runner availability and update the label/toolchain when stable images become available.

PRs created or updated with `GITHUB_TOKEN` can require approval before CI runs. Use **Approve workflows to run** on the release PR when offered, or run CI manually from that PR's branch in the Actions UI. Ensure the tested SHA is still the PR head and do not bypass required checks. Tags and releases created using `GITHUB_TOKEN` do not trigger downstream release workflows; this setup has no automated binary distribution workflow.

## Release process

1. Review and test the release PR, including version, build number, and changelog. Merge it when ready to publish the GitHub release.
2. The push to main runs Release Please, which tags the release commit and publishes the GitHub release notes. Verify the tag and release in GitHub. If the run fails, fix the reported issue and rerun the workflow; do not create a competing tag manually.
3. Follow [distribution instructions](DISTRIBUTION.md) for manual signed archives, device checks, export, and notarization/submission. Build from the published tag, and attach any intended downloadable binaries to that GitHub release manually.

Once this workflow change reaches main, it can also publish a previously merged release PR still labeled `autorelease: pending`.

## Recovering a blocked historical release

If release creation fails with `Resource not accessible by integration` even though the job has `contents: write`, check the release PR's merge commit against main. GitHub can reject tag creation with `GITHUB_TOKEN` when workflow files differ between that historical commit and the default branch. The built-in token cannot receive the additional Workflows permission.

For this case, the maintainer can create the missing `vX.Y.Z` tag at the **exact merged release PR commit** and publish the GitHub release using an authorized personal account. Verify the version in that commit's manifest first and use its committed changelog for release notes; never move an existing tag or tag the current main commit as a substitute. Creating the tag alone may not resolve the release endpoint restriction. After publication, replace the release PR's `autorelease: pending` label with `autorelease: tagged`, then rerun the failed workflow. No repository secret is needed for this one-time recovery.

This was the recovery for `v0.1.1`: release PR #3 merged before GitHub release publishing was enabled. Routine releases continue using `GITHUB_TOKEN`.

Reference: [GitHub's release creation permissions](https://docs.github.com/en/rest/releases/releases#create-a-release).

For another upload of the same marketing version, manually increment `CURRENT_PROJECT_VERSION` and commit with `chore(release): increment build number`. Never reuse an uploaded build number. Marketing version changes must stay synchronized across the xcconfig, version file, and manifest; `make check` validates them.

References: [Release Please action](https://github.com/googleapis/release-please-action), [generic version updates](https://github.com/googleapis/release-please/blob/main/docs/customizing.md), [Xcode 27 runner](https://github.com/actions/runner-images/issues/14404).
