# Build environment for the HMG-Seogaemo wired ADB payload (cable-link, cable-adbd).
# build.sh makes two images from this file: linux/amd64 for the NDK r21e toolchain
# (an x86-64 Linux build; this is the same amd64 base as kernel/usb-wifi) and the
# host's own platform for Go, whose x86-64 toolchain crashes under emulation.
FROM ubuntu:20.04@sha256:8feb4d8ca5354def3d8fce243717141ce31e2c428701f6682bd2fafe15388214

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl file patch unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /wired-adb
