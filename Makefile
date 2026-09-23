SWIFT_PATHS = App Core/Package.swift Core/Sources Core/Tests Integration/Package.swift Integration/Sources RemoteMedia Shared PlaybackTests UITests scripts
PROJECT = MusicAssistantOne.xcodeproj
SCHEME = MusicAssistantOne

.PHONY: bootstrap generate format lint test check build-macos build-ios secrets
bootstrap:
	python3 scripts/bootstrap.py

generate: bootstrap
	xcodegen generate

format:
	swiftformat $(SWIFT_PATHS)

lint:
	swiftformat $(SWIFT_PATHS) --lint
	swiftlint lint --strict --quiet
	actionlint
	python3 scripts/check-repository.py

test:
	swift test --package-path Core
	python3 -m unittest discover -s scripts/tests

check: lint test

build-macos: bootstrap
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination 'generic/platform=macOS' -derivedDataPath DerivedData-ci CODE_SIGNING_ALLOWED=NO build

build-ios: bootstrap
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData-ci CODE_SIGNING_ALLOWED=NO build

secrets:
	gitleaks git --redact --log-opts='--branches --remotes --tags HEAD' .
	python3 scripts/scan-files.py
