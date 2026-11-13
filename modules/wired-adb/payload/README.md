# Wired ADB payload

Sources and reproducible build of the two programs the `wired-adb` module ships in `files/`:

| Program | Source | Built with |
| --- | --- | --- |
| `cable-link` | `cable-link/` (Go, our code) | Go 1.26.4, `GOOS=linux GOARCH=arm GOARM=7`, static, `-trimpath` |
| `cable-adbd` | AOSP `android-4.4.4_r1` `platform/system/core` (`adb`, `libcutils`, `libmincrypt`, Apache-2.0) plus `adbd/cable-adbd.patch` | NDK r21e, `armv7a-linux-androideabi19-clang` |

## Build

Needs Docker with amd64 emulation on Apple Silicon (Colima, OrbStack or Docker Desktop) and
network access. The Docker VM must be able to mount this directory: Colima shares only the home
directory by default, so build from a checkout (or a copy of `modules/wired-adb`) below it.

```sh
sh modules/wired-adb/payload/build.sh
```

The script downloads the NDK (about 1.2 GB), Go and four AOSP source archives into `out/cache/`
(gitignored) and checks each against a pinned hash. The adbd stage runs in a linux/amd64
container; the Go stage runs in a container of the host's own architecture, runs `go vet` and
`go test`, and cross-compiles. Both programs, `NOTICE.txt` and `SHA256SUMS` are copied to
`modules/wired-adb/files/`. Toolchains live in the Docker volume `hmg-seogaemo-wired-adb-work`.

`adbd/sources.sha256` lists every AOSP file the build uses. Files not listed never enter the
build tree, and a listed file with another hash stops the build.

Design and behaviour: `.agents/wired-adb.md`.
