SWIFT_PATHS := Package.swift $(shell find Sources Tests Fixtures -type f -name '*.swift' -not -path '*/Generated/*' -not -path '*/.build/*')
SWIFTPM_MODULECACHE_OVERRIDE := $(CURDIR)/.build/ModuleCache
CLANG_MODULE_CACHE_PATH := $(SWIFTPM_MODULECACHE_OVERRIDE)
PROTOC_GEN_SWIFT := $(CURDIR)/.build/protobuf-tools/release/protoc-gen-swift
SWIFT_PROTOBUF_CHECKOUT := $(CURDIR)/.build/checkouts/swift-protobuf
PROTOC_GEN_GRPC_SWIFT := $(CURDIR)/.build/grpc-protobuf-tools/release/protoc-gen-grpc-swift-2
GRPC_PROTOBUF_CHECKOUT := $(CURDIR)/.build/checkouts/grpc-swift-protobuf

export SWIFTPM_MODULECACHE_OVERRIDE
export CLANG_MODULE_CACHE_PATH

.PHONY: format lint build test consumer check protobuf-tools generate-protocol

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

consumer:
	swift build --package-path Fixtures/CallerOnlyConsumer -Xswiftc -warnings-as-errors

check: lint build test consumer

protobuf-tools:
	swift package resolve
	swift build --package-path $(SWIFT_PROTOBUF_CHECKOUT) --scratch-path $(CURDIR)/.build/protobuf-tools --configuration release --product protoc-gen-swift
	swift build --package-path $(GRPC_PROTOBUF_CHECKOUT) --scratch-path $(CURDIR)/.build/grpc-protobuf-tools --configuration release --product protoc-gen-grpc-swift-2

generate-protocol: protobuf-tools
	buf generate
