SWIFT_PATHS := Package.swift $(shell find Sources Tests -name '*.swift' -not -path '*/Generated/*')
SWIFTPM_MODULECACHE_OVERRIDE := $(CURDIR)/.build/ModuleCache
CLANG_MODULE_CACHE_PATH := $(SWIFTPM_MODULECACHE_OVERRIDE)
PROTOC_GEN_SWIFT := $(CURDIR)/.build/protobuf-tools/release/protoc-gen-swift
SWIFT_PROTOBUF_CHECKOUT := $(CURDIR)/.build/checkouts/swift-protobuf

export SWIFTPM_MODULECACHE_OVERRIDE
export CLANG_MODULE_CACHE_PATH

.PHONY: format lint build test check protobuf-tools generate-protocol

format:
	swift-format format --configuration .swift-format --parallel --in-place $(SWIFT_PATHS)
	buf format --write Protos

lint:
	swift-format lint --configuration .swift-format --parallel --strict $(SWIFT_PATHS)
	swiftlint lint --config .swiftlint.yml --strict --quiet --no-cache
	buf format --diff --exit-code Protos
	buf lint Protos

build:
	swift build -Xswiftc -warnings-as-errors

test:
	swift test -Xswiftc -warnings-as-errors

check: lint build test

protobuf-tools:
	swift package resolve
	swift build --package-path $(SWIFT_PROTOBUF_CHECKOUT) --scratch-path $(CURDIR)/.build/protobuf-tools --configuration release --product protoc-gen-swift

generate-protocol: protobuf-tools
	buf generate
