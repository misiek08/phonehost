#!/bin/sh
# Cross-build the chargecap daemon for the phone (aarch64/musl) without
# touching the phone itself.
#
#   sh scripts/build-chargecap.sh [output_dir]
set -eu

OUT=${1:-.}
SRC=$(CDPATH= cd -- "$(dirname -- "$0")/../daemon/chargecap" && pwd)
OUT=$(CDPATH= cd -- "$OUT" && pwd)

docker run --rm -v "$SRC:/src" -v "$OUT:/out" -w /src golang:1.25-alpine sh -c '
	go vet ./...
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o /out/chargecap .
'
ls -l "$OUT/chargecap"
