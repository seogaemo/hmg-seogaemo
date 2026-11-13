#!/bin/sh
# Reproducible build of the wired ADB payload for Gen5W head units (Android 4.4.2,
# ARMv7):
#   cable-link   Go service: Apple USB NCM over usbfs, private TAP, adbd supervisor
#   cable-adbd   AOSP 4.4.4 adbd with adbd/cable-adbd.patch, NDK r21e, API 19
#
#   sh modules/wired-adb/payload/build.sh   run on the host; builds the Docker images,
#                                           runs the two build stages inside them and
#                                           copies the results to modules/wired-adb/files/
#
# The toolchains are the ones behind the contributor's car-verified binaries
# (Go 1.26.4, NDK r21 clang 9.0.9). Every download is checked against a pinned hash.
# The NDK stage runs in a linux/amd64 container; the Go stage runs on the host's own
# architecture, because the x86-64 Go toolchain crashes under emulation.
set -eu

GO_VERSION=1.26.4
GO_URL=https://go.dev/dl
# From https://go.dev/dl/?mode=json&include=all. Go runs on the host's own
# architecture; its cross-compiled output does not depend on it.
GO_SHA256_amd64=1153d3d50e0ac764b447adfe05c2bcf08e889d42a02e0fe0259bd47f6733ad7f
GO_SHA256_arm64=ef758ae7c6cf9267c9c0ef080b8965f453d89ab2d25d9eb22de4405925238768

NDK_VERSION=r21e
NDK_URL=https://dl.google.com/android/repository/android-ndk-$NDK_VERSION-linux-x86_64.zip
# SHA-1 as published on the NDK downloads page.
NDK_SHA1=c3ebc83c96a4d7f539bd72c241b2be9dcd29bda9

# Gitiles regenerates archives on every request, so the sources are pinned by tag
# and by the SHA-256 of every file the build uses (adbd/sources.sha256).
AOSP_TAG=android-4.4.4_r1
AOSP_URL=https://android.googlesource.com/platform/system/core/+archive/refs/tags/$AOSP_TAG

IMAGE=hmg-seogaemo-wired-adb
WORK_VOLUME=hmg-seogaemo-wired-adb-work

die() { echo "build.sh: $*" >&2; exit 1; }
log() { echo "== $*"; }

here=$(cd "$(dirname "$0")" && pwd)

STAGE=${HMG_SEOGAEMO_WIRED_ADB_STAGE:-}
if [ -z "$STAGE" ]; then
	command -v docker >/dev/null 2>&1 || die "docker is required"
	# The Docker VM must be able to mount this directory (Colima shares only the home directory).
	docker build --platform linux/amd64 -t "$IMAGE-ndk" "$here"
	docker build -t "$IMAGE-go" "$here"
	mkdir -p "$here/out"
	docker run --rm --platform linux/amd64 -e HMG_SEOGAEMO_WIRED_ADB_STAGE=adbd \
		-v "$here:/wired-adb:ro" -v "$here/out:/out" -v "$WORK_VOLUME:/work" \
		"$IMAGE-ndk" sh /wired-adb/build.sh
	docker run --rm -e HMG_SEOGAEMO_WIRED_ADB_STAGE=link \
		-v "$here:/wired-adb:ro" -v "$here/out:/out" -v "$WORK_VOLUME:/work" \
		"$IMAGE-go" sh /wired-adb/build.sh
	files=$here/../files
	mkdir -p "$files"
	for name in cable-link cable-adbd NOTICE.txt SHA256SUMS; do
		cp "$here/out/$name" "$files/$name"
	done
	log "copied to modules/wired-adb/files/"
	cat "$files/SHA256SUMS"
	exit 0
fi

SRC=/wired-adb
OUT=/out
CACHE=$OUT/cache
WORK=/work
mkdir -p "$CACHE" "$WORK"

fetch() {
	[ -f "$2" ] && return 0
	curl -fsSL --retry 3 -o "$2.part" "$1"
	mv "$2.part" "$2"
}

[ -f "$SRC/adbd/cable-adbd.patch" ] || die "the build directory is not visible in the container (share it with the Docker VM)"

if [ "$STAGE" = adbd ]; then
log "NDK $NDK_VERSION"
fetch "$NDK_URL" "$CACHE/android-ndk-$NDK_VERSION-linux-x86_64.zip"
echo "$NDK_SHA1  $CACHE/android-ndk-$NDK_VERSION-linux-x86_64.zip" | sha1sum -c - >/dev/null ||
	die "NDK archive hash mismatch"
TC=$WORK/android-ndk-$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/bin
if [ ! -x "$TC/armv7a-linux-androideabi19-clang" ]; then
	rm -rf "$WORK/android-ndk-$NDK_VERSION"
	(cd "$WORK" && unzip -q "$CACHE/android-ndk-$NDK_VERSION-linux-x86_64.zip" \
		"android-ndk-$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/*")
fi
[ -x "$TC/armv7a-linux-androideabi19-clang" ] || die "NDK toolchain missing after extraction"

log "AOSP $AOSP_TAG system/core sources"
CORE=/build/core
rm -rf /build
mkdir -p "$CORE" /build/fetched
for dir in adb include libcutils libmincrypt; do
	fetch "$AOSP_URL/$dir.tar.gz" "$CACHE/aosp-$AOSP_TAG-$dir.tar.gz"
	mkdir -p "/build/fetched/$dir"
	tar -xzf "$CACHE/aosp-$AOSP_TAG-$dir.tar.gz" -C "/build/fetched/$dir"
done
# Only the files named in the manifest enter the build tree, each with the pinned hash.
while read -r sum path; do
	[ -n "$sum" ] || continue
	[ -f "/build/fetched/$path" ] || die "AOSP file missing: $path"
	echo "$sum  /build/fetched/$path" | sha256sum -c - >/dev/null || die "AOSP file differs: $path"
	mkdir -p "$CORE/$(dirname "$path")"
	cp "/build/fetched/$path" "$CORE/$path"
done < "$SRC/adbd/sources.sha256"
(cd "$CORE" && patch -p1 -s < "$SRC/adbd/cable-adbd.patch")

log "cable-adbd"
# Flags of HMG-API's adbd build at 4fab437, which the car-verified daemon used.
(cd "$CORE" && "$TC/armv7a-linux-androideabi19-clang" -O2 -DHAVE_ANDROID_OS -DADB_HOST=0 -D_GNU_SOURCE \
	-DHAVE_PTHREADS -DHAVE_SYS_UIO_H -I"$SRC/adbd/compat" -Iinclude -Iadb -w -fPIE -pie \
	-Wl,--hash-style=sysv -Wl,--build-id=none \
	-o /build/cable-adbd adb/*.c libcutils/*.c libmincrypt/*.c -llog)
"$TC/llvm-strip" /build/cable-adbd
file /build/cable-adbd | grep -q 'ELF 32-bit LSB.*ARM.*dynamically linked' || die "cable-adbd is not an ARM PIE"
cp /build/cable-adbd "$OUT/cable-adbd"
{
	echo "cable-adbd is built from the Android Open Source Project (android-4.4.4_r1,"
	echo "platform/system/core: adb, libcutils, libmincrypt) with HMG-Seogaemo's changes in"
	echo "modules/wired-adb/payload/adbd/cable-adbd.patch. The upstream notices follow."
	for dir in adb libcutils libmincrypt; do
		echo
		echo "==== $dir/NOTICE ===="
		cat "$CORE/$dir/NOTICE"
	done
} > "$OUT/NOTICE.txt"
exit 0
fi

[ "$STAGE" = link ] || die "unknown stage $STAGE"
case $(uname -m) in
x86_64) go_arch=amd64 go_sum=$GO_SHA256_amd64 ;;
aarch64) go_arch=arm64 go_sum=$GO_SHA256_arm64 ;;
*) die "no pinned Go archive for $(uname -m)" ;;
esac
log "Go $GO_VERSION ($go_arch)"
go_archive=go$GO_VERSION.linux-$go_arch.tar.gz
fetch "$GO_URL/$go_archive" "$CACHE/$go_archive"
echo "$go_sum  $CACHE/$go_archive" | sha256sum -c - >/dev/null || die "Go archive hash mismatch"
if [ ! -x "$WORK/go-$GO_VERSION-$go_arch/go/bin/go" ]; then
	rm -rf "$WORK/go-$GO_VERSION-$go_arch"
	mkdir -p "$WORK/go-$GO_VERSION-$go_arch"
	tar -xzf "$CACHE/$go_archive" -C "$WORK/go-$GO_VERSION-$go_arch"
fi
GO=$WORK/go-$GO_VERSION-$go_arch/go/bin/go

log "cable-link"
rm -rf /build
mkdir -p /build
export GOCACHE=/build/gocache GOFLAGS=-mod=mod GOTOOLCHAIN=local HOME=/build
cp -R "$SRC/cable-link" /build/cable-link
(cd /build/cable-link && "$GO" vet . && "$GO" test . &&
	CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 "$GO" vet . &&
	CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 "$GO" build -trimpath -buildvcs=false \
		-ldflags='-s -w -buildid=' -o /build/cable-link-bin .)

log "results"
file /build/cable-link-bin | grep -q 'ELF 32-bit LSB.*ARM.*statically linked' || die "cable-link is not a static ARM program"
cp /build/cable-link-bin "$OUT/cable-link"
[ -f "$OUT/cable-adbd" ] && [ -f "$OUT/NOTICE.txt" ] || die "run the adbd stage first"
(cd "$OUT" && sha256sum cable-adbd cable-link NOTICE.txt > SHA256SUMS && cat SHA256SUMS)
