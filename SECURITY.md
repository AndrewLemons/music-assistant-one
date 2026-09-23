# Security policy

Security fixes target the current main branch and latest release. Older development snapshots are not supported.

Use the repository's **Security → Report a vulnerability** private reporting feature. Do not open public issues containing credentials, exploit details, or private server information. If private reporting is unavailable, open a minimal issue asking maintainers to enable a private reporting channel, without disclosing the vulnerability.

Include the affected revision, platform, reproduction steps, and impact. Use synthetic credentials and loopback fixtures. Never attach Keychain exports, signing assets, server backups, access tokens, pairing records, or unredacted network logs.

The app uses system TLS validation and stores credentials/pairing data in Keychain. Explicit HTTP and local address defaults support local Music Assistant installations; use HTTPS on untrusted networks. Sendspin encryption does not protect the separate Music Assistant login/control connection when HTTP is selected.

Before making a repository public, run `make secrets`, review the files being committed, and enable GitHub private vulnerability reporting and secret scanning/push protection. Automated scans reduce risk but do not prove the absence of secrets. If a real credential is exposed, revoke it before considering history cleanup.
