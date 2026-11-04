SWIFT_PATHS = App Core/Package.swift Core/Sources Core/Tests Integration/Package.swift Integration/Sources RemoteMedia Shared PlaybackTests UITests scripts
ZIZMOR_FLAGS ?=

.PHONY: tools bootstrap generate format lint lint-format lint-swift lint-workflows lint-repository \
	test test-core test-scripts test-companion test-unit test-ui interop check-artwork \
	server-image test-server-image check build-macos build-ios secrets

# Pinned tool versions live in mise.toml; mise.lock verifies their checksums.
tools:
	mise install --locked

bootstrap:
	python3 scripts/bootstrap.py

generate: bootstrap
	xcodegen generate

format:
	swiftformat $(SWIFT_PATHS)

lint: lint-format lint-swift lint-workflows lint-repository

lint-format:
	swiftformat $(SWIFT_PATHS) --lint

lint-swift:
	swiftlint lint --strict --quiet

lint-workflows:
	actionlint
	zizmor $(ZIZMOR_FLAGS) .github

lint-repository:
	python3 scripts/check-repository.py

test: test-core test-scripts test-companion

test-core:
	swift test --package-path Core

test-scripts:
	python3 -m unittest discover -s scripts/tests
	python3 -m unittest discover -s scripts/playback-research -p 'test_*.py'

test-companion:
	python3 scripts/test-companion.py

# Simulator suites on an iOS 27+ iPhone, exactly as CI runs them (without retries).
test-unit:
	python3 scripts/xcode.py test --suite unit --coverage

test-ui:
	python3 scripts/xcode.py test --suite ui

interop:
	python3 scripts/check-interop.py

check-artwork:
	mkdir -p .build
	xcrun swiftc -swift-version 6 -parse-as-library App/Services/SystemMediaArtwork.swift scripts/check-system-artwork.swift -o .build/check-system-artwork
	.build/check-system-artwork

server-image:
	python3 scripts/server-image.py build

test-server-image: server-image
	python3 scripts/server-image.py test

check: lint test

build-macos: bootstrap
	python3 scripts/xcode.py build --platform macos

build-ios: bootstrap
	python3 scripts/xcode.py build --platform ios

secrets:
	gitleaks git --redact --log-opts='--branches --remotes --tags HEAD' .
	python3 scripts/scan-files.py
