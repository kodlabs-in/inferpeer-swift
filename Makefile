SWIFT_PATHS := Package.swift Sources Tests
SWIFTPM_MODULECACHE_OVERRIDE := $(CURDIR)/.build/ModuleCache
CLANG_MODULE_CACHE_PATH := $(SWIFTPM_MODULECACHE_OVERRIDE)

export SWIFTPM_MODULECACHE_OVERRIDE
export CLANG_MODULE_CACHE_PATH

.PHONY: format lint build test check

format:
	swift-format format --configuration .swift-format --recursive --parallel --in-place $(SWIFT_PATHS)

lint:
	swift-format lint --configuration .swift-format --recursive --parallel --strict $(SWIFT_PATHS)
	swiftlint lint --config .swiftlint.yml --strict --quiet --no-cache

build:
	swift build -Xswiftc -warnings-as-errors

test:
	swift test -Xswiftc -warnings-as-errors

check: lint build test
