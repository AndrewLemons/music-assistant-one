# Release maintenance

[Andrew Lemons (@AndrewLemons)](https://github.com/AndrewLemons) maintains the repository and coordinates releases. App Store signing and publication use the Lemony Click, LLC account.

Releases are automatic once the release PR is merged. App Store review submission is the one step that stays manual.

## How it works

| Workflow | Trigger | Does |
| --- | --- | --- |
| `ci.yml` | PRs, pushes to main | Lint, secrets, dependency review, Core, both Release builds, playback engine tests on macOS, and the server and review images. PRs run only the suites their files affect. The simulator suite (every playback test, including iOS-only remote media, plus UI tests; about 12 minutes) runs on every push to main and on the release PR, so it gates releases. A failure on main opens an issue. The `CI` job is the single required check. |
| `pr-title.yml` | PR opened or edited | Requires a Conventional Commit title, because the squash commit drives the changelog. |
| `release.yml` | Pushes to main, manual | Runs Release Please, then delivers the app (see below). |
| `server-image.yml` | Called by release, manual | Publishes the server image and the App Review image. |
| `tools-update.yml` | Weekly | Opens a PR updating the tools pinned in `mise.toml`. |
| `certificates.yml` | Weekly | Opens an issue 30 days before a stored signing certificate expires. |

Every push to main runs `release.yml`:

1. **Release Please** opens or updates the release PR. That PR bumps `version.txt`, `.release-please-manifest.json`, `CHANGELOG.md`, and `MARKETING_VERSION` in `Config/Version.xcconfig`. When the release PR itself merges, Release Please tags `vX.Y.Z` and publishes the GitHub release. It runs as the repository's GitHub App, so the release PR runs CI like any other PR.
2. **Delivery** depends on what was pushed:
   - **An ordinary merge that changes the app** goes to TestFlight for **internal testers**. Its version is the open release PR's version (or the next patch), because Apple closes a version to new builds once it ships on the App Store. What to Test lists the commits since the previous build. Docs-only or CI-only merges are not uploaded.
   - **A release** goes to TestFlight for internal and **public** testers, using the tag. It's submitted for Beta App Review, with the changelog as What to Test. The release also gets a Developer ID-signed, notarized Mac app attached as `MusicAssistantOne-X.Y.Z-macOS.zip` (with a build provenance attestation). The server image is published, and the [App Review server](#app-review-server) is redeployed.

Debug symbols for every delivery are kept as workflow artifacts for 90 days. App Store Connect also receives the iOS symbols.

### Build numbers

CI assigns `CFBundleVersion` at upload; the committed `CURRENT_PROJECT_VERSION = 1` is only for local builds. Each delivery takes `max(highest build in App Store Connect, highest builds/<n> tag) + 1` and reserves it by creating the tag `builds/<n>` at the commit being built. Creating a tag is atomic, so concurrent runs can never share a number. The tags also record which commit produced each build. A failed run leaves a gap, which is harmless; numbers only ever increase.

### Releasing

1. Review the release PR: version, changelog, and CI. Merge it when ready. Nothing else is required.
2. Watch the **Release** run. TestFlight processing and Beta App Review take minutes to a day; the run waits for processing, not for review.
3. When Beta App Review approves the build, public testers get it automatically. Submitting for App Store review is still done by hand in App Store Connect.

**Retrying.** If delivery fails after the tag exists, for example during an Apple outage, rerun the failed jobs. If the build number was already uploaded, run **Release** from the Actions tab with the tag (such as `v0.2.0`) to rebuild under a new build number. Never move or recreate a release tag. Running **Release** with no tag uploads an internal build of main.

**Concurrency.** Internal builds of newer commits replace pending ones. Release deliveries are grouped by tag and are never cancelled by later pushes.

## One-time setup

Repository settings live outside the code, so they are listed here.

### GitHub App (release identity)

Pull requests created with `GITHUB_TOKEN` don't run workflows. A private GitHub App lets Release Please and the tools-update job open PRs that run CI.

1. **Settings → Developer settings → GitHub Apps → New GitHub App.** Name it something like `music-assistant-one-release`, set the homepage to this repository, and turn off webhooks.
2. Repository permissions: **Contents** read and write, **Pull requests** read and write, **Issues** read and write (for Release Please labels). Nothing else. Allow installation **only on this account**.
3. Install it on this repository only. Note the **Client ID** and generate a **private key**.

### App Store Connect and signing

1. **API key.** In App Store Connect → Users and Access → Integrations → Team Keys, create a key with **Admin** access. Admin is what Apple requires for cloud-managed distribution signing. Download the `.p8` (it can be downloaded only once) and note the Key ID and Issuer ID.
2. **Apple Development certificate.** The archive step needs a development identity; without one, Xcode creates a new certificate on every run until the team limit is reached. In Keychain Access, export `Apple Development: …` together with its private key as a `.p12` with a strong password. It is reused by every run and expires after a year.
3. **Developer ID Application certificate.** Export it the same way. Apple has no API for creating these. Use the newest certificate if there are several. Its provisioning profile is created or reused through the API on each release, so there is nothing else to store.
4. **TestFlight groups.** Use an internal group (for example "Internal") and the public beta group behind the public link. Turn on **automatic distribution** for the internal group: Apple's API can't add builds to internal groups, so that setting is how each upload reaches internal testers. External groups get builds through the API.

### Environments, secrets, and variables

Create two environments under **Settings → Environments**, each limited to the `main` branch:

| Environment | Secrets | Variables |
| --- | --- | --- |
| `release` | `RELEASE_APP_PRIVATE_KEY` | `RELEASE_APP_CLIENT_ID` |
| `app-store` | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the file's contents), `APPLE_DEVELOPMENT_P12` and `DEVELOPER_ID_P12` (base64, `base64 -i cert.p12`), `APPLE_DEVELOPMENT_P12_PASSWORD`, `DEVELOPER_ID_P12_PASSWORD` | `APPLE_TEAM_ID`, `TESTFLIGHT_INTERNAL_GROUP`, `TESTFLIGHT_PUBLIC_GROUP` |

Pull request and Dependabot runs never reach these environments. Only workflows running on main can use them.

### Repository settings

- **Actions → General:** default workflow permissions **Read repository contents**. Turn off "Allow GitHub Actions to create and approve pull requests"; the GitHub App opens PRs now.
- **Rules → Rulesets** for `main`: require a pull request (no approval required, because the maintainer can't approve their own PRs), require the `CI` and `PR title` status checks, require linear history, and block force pushes and deletion. Leave "require branches to be up to date" off: the release PR is rebuilt from main on every push, so its CI always tests current main.
- Squash merging only, with the PR title as the commit message. Enable private vulnerability reporting, secret scanning, and push protection.
- After the server image's first publication, set the package's visibility to **Public** and link it to this repository.

## Signing certificates

`certificates.yml` checks the stored certificates weekly and opens an issue 30 days before expiry; delivery jobs also warn. To renew: create a new certificate (Xcode → Settings → Accounts → Manage Certificates for Apple Development; the developer portal for Developer ID), export it with its private key as a `.p12`, and replace the secret and password in the `app-store` environment. Revoke the old certificate only after a successful delivery with the new one.

If the App Store Connect key is revoked, create a new Admin key and update `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8`.

## App Review server

The review server (`https://music-demo.lemonyclick.com`, Railway project `music-assistant-review`) runs the stateless App Review image; see [the review handoff](APP_STORE_REVIEW.md). Each release publishes `<server>-<release>-review`, plus a moving `review` tag for the newest release. The `review-server` job then:

1. Skips the deploy unless the tag is the newest release, so re-delivering an older release never rolls the server back.
2. Commits one Railway environment patch: the image, the reviewer credentials (copied from GitHub, the single source of truth), an `/info` health check, and an always-restart policy.
3. Follows that deployment to `SUCCESS`, then checks the live URL: the expected Music Assistant version, reviewer sign-in, the regular-user role, the sample album, and the playlists.

The `review-server` environment (limited to `main`) holds the `RAILWAY_TOKEN` secret (a project token scoped to `music-assistant-review` / `production`) and `REVIEW_PASSWORD`, plus the variables `RAILWAY_SERVICE_ID`, `RAILWAY_ENVIRONMENT_ID`, `REVIEW_SERVER_URL`, and `REVIEW_USERNAME`. Create project tokens in Railway under Project → Settings → Tokens.

## Server image

`server-image.yml` builds `ServerCompanion/` for `linux/amd64` and `linux/arm64` and pushes `ghcr.io/andrewlemons/music-assistant-one-server` with `GITHUB_TOKEN`. It first builds and tests the image from the release tag with `make test-server-image`. For the newest release it publishes the tags users already know from the official image (`latest`, `stable`, the Music Assistant minor such as `2.10`, and the full version such as `2.10.9`), plus a pinned `<server>-<release>` tag such as `2.10.9-0.2.0`. The image includes an SBOM and a GitHub build provenance attestation.

To republish a release, for example after a registry outage, run **Server image** from the Actions tab with its `vX.Y.Z` tag. Republishing an older release updates only its pinned tag, never `latest` or the other shared tags.

## Updating Music Assistant

`ServerCompanion/Dockerfile` pins the supported Music Assistant release by tag and digest. It is the single source of the image version. Dependabot opens a weekly `fix(deps)` PR, three days after a new stable Music Assistant release. Merging it leads to a patch release that republishes the image. Before merging:

1. Let CI run. The server image job checks the provider against the new server's internals, FFmpeg, and setup API on both architectures.
2. Read the upstream release notes. Check the bundled `aiosendspin` version in that release's `requirements_all.txt`. If it changed, update the pin in `scripts/check-interop.py` and run `make interop`; see [dependency maintenance](DEPENDENCIES.md).
3. Update the supported version in `README.md`, `ServerCompanion/README.md`, and `App/Services/LocalPlayer.swift`. `make lint-repository` fails until they match the Dockerfile.
4. Run the image against a copy of real server data, then confirm playback and a download from the app.

To try another version locally, change the `FROM` line and run `make test-server-image`. Use `docker buildx imagetools inspect ghcr.io/music-assistant/server:<version>` to find the index digest.

## Updating tools

Tool versions are pinned in `mise.toml` and verified by checksum in `mise.lock`. `tools-update.yml` proposes upgrades weekly, each at least seven days after its release. It runs `make format` with any new SwiftFormat, so formatting changes are reviewed in the same PR. To upgrade by hand, run `mise upgrade --bump --pin` then `mise lock --platform macos-arm64,linux-x64`. Dependabot updates GitHub Actions, grouped weekly, also with a seven-day cooldown.

CI runs the app jobs on GitHub's `xcode-27` image because the remote media extension needs the iOS 27 SDK, and Core on the stable `macos-26` image. When Xcode 27 becomes the default on a standard image, change the `xcode-27` labels and remove the label from `.github/actionlint.yaml`.

## Recovering a blocked historical release

If release creation fails with `Resource not accessible by integration`, check the release PR's merge commit against main. GitHub rejects tag creation by an integration token when workflow files differ between that commit and the default branch. This can happen if a workflow change merges before Release Please has tagged an earlier release PR.

The maintainer can create the missing `vX.Y.Z` tag at the **exact merged release PR commit** and publish the GitHub release from an authorized personal account. Verify the version in that commit's manifest first and use its committed changelog for the release notes; never move an existing tag or tag the current main commit instead. Then replace the release PR's `autorelease: pending` label with `autorelease: tagged`, and run **Release** with the tag to deliver it. This was the recovery for `v0.1.1`.

References: [Release Please action](https://github.com/googleapis/release-please-action), [GitHub App tokens in Actions](https://github.com/actions/create-github-app-token), [App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi), [notarytool](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [publishing images to GitHub Packages](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images), [artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations), [mise lockfiles](https://mise.jdx.dev/dev-tools/mise-lock.html), [Xcode 27 runner](https://github.com/actions/runner-images/issues/14404).
