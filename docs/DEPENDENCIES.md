# Dependency maintenance

SendspinKit is locked in `patches/sendspinkit.json` to upstream revision `accbc9ebde17b8af1925fd3f84da2955b801a33e`, the revision tested against Music Assistant 2.10.1 / aiosendspin 9.1.1. `make bootstrap` fetches that exact commit into the ignored `.dependencies/SendspinKit` directory and applies `patches/sendspinkit-release.patch`.

The patch adds a Release-only computed property returning nil for `pairingScalarBOverride`. Upstream declares the property only in DEBUG but references it from two production pairing paths. Nil preserves fresh random production scalars. Never define DEBUG in Release to work around this compiler error.

The setup script validates the patch SHA-256, upstream commit, origin, and entire tracked tree against the expected patch. It fails on unexpected edits rather than resetting user work. It is safe to rerun and never modifies SwiftPM checkout caches. The app and Integration executable use the same local package. Upstream source, tests, licenses, and provenance remain in the downloaded checkout; only the small patch and lock are committed here.

The next upstream commit (`d5f354a`) changes protocol messages and removes management/persistence APIs used by this integration; current upstream also changes device setup. A blind upgrade would require both app migration and interoperability validation. This compatibility patch is temporary, not a claim that the older dependency contains every later upstream fix. Review upstream security and protocol changes regularly.

To update:

1. Review upstream changes and verify the target Music Assistant/aiosendspin versions.
2. Update the locked revision. Rebase or remove the patch and update its checksum. Move the existing `.dependencies/SendspinKit` aside, then run `make bootstrap`.
3. Resolve the app and Integration packages and commit both `Package.resolved` files. Xcode additionally resolves DocC plugins; runtime pins must match.
4. Run core tests, both Release builds, and `python3 scripts/check-interop.py`. Validate live pairing persistence, reconnect, and audible playback on real devices before releasing.
5. When a compatible upstream revision needs no patch, switch both consumers to the same remote SwiftPM revision and remove the bootstrap exception.

The old `Vendor/` snapshot is ignored and no longer referenced. Existing local copies may be retained as backups. Do not commit dependency sources or update dependencies by modifying build caches.
