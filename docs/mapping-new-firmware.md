# Mapping a new Gen5W firmware

The core mapper uses the full `core/hookpoints/` catalogue. Stable point IDs match HMG-API; the rules and mapper code here are independently maintained. A map is accepted only for the exact `ro.build.product`, onebin, Android release, and every stock file MD5 recorded in `car.json`. Hashes identify the firmware; structural DEX matching finds names. The on-car verifier resolves the mapped classes and member signatures with the device framework. A module stays off unless every ID in its `hookpoints.required` is verified.

## Prepare the head unit

Park safely, keep power stable, and ensure full-root adb recovery through NEMESIS is available. Do not enable projection hooks during the first mapping pass. Record these facts:

```sh
adb shell getprop ro.build.product
adb shell getprop ro.mobis.onebindir
adb shell getprop ro.build.version.release
```

The exact stock file list comes from the catalogue:

```sh
python3 tools/hmg-seogaemo-list-stock-files.py
python3 tools/hmg-seogaemo-list-stock-files.py --adb-pull > /tmp/pull-hmg-seogaemo-stock.sh
sh /tmp/pull-hmg-seogaemo-stock.sh
```

This pulls the current 18 catalogue files into `stock/system/{app,framework}/`. Re-run the generator after catalogue changes. If adb shell cannot read a stock file, use NEMESIS full root to copy that exact file to a shell-readable temporary location, then `adb pull` it. Keep stock binaries out of git and out of the PR.

## Map on the host (macOS or Linux)

Install JDK 17 and Python 3.8+. Download the standalone [baksmali 2.5.2 JAR from the original smali project](https://bitbucket.org/JesusFreke/smali/downloads/baksmali-2.5.2.jar), then check `java -jar baksmali-2.5.2.jar --help`. The original [smali project](https://github.com/JesusFreke/smali) documents its build. Point `--baksmali` at the JAR; do not commit it. The host mapper deodexes the pulled files with baksmali and applies the catalogue's shape and smali capture rules.

```sh
python3 tools/map-car.py stock/system \
  --product 'NEEV.KOR.0000.V039.001.260902' \
  --onebin neev_kr --android 4.4.2 \
  --baksmali /path/to/baksmali-2.5.2.jar \
  --output maps/hyundai/ioniq5/kor/260902
./tools/verify-map maps/hyundai/ioniq5/kor/260902
```

Use the actual facts and target layout for the new firmware. `--strict` requires all 357 current points, including optional ones, so it is usually unsuitable when an unrelated point is unresolved. The normal run records unresolved IDs in `car.json`. Review every required point and every file MD5 before opening a PR.

## Map on the head unit

HMG-Seogaemo Settings → Car mapping shows product, source, counts, failing IDs, and the confirmed **Map this car** action. For adb, use the fixed root command:

```sh
adb shell cp /system/xbin/nemesis /data/local/tmp/nemesis-d
adb shell /data/local/tmp/nemesis-d root -c '/data/nemesis/apps/hmg-seogaemo/bin/hmg-seogaemo-root map status'
adb shell /data/local/tmp/nemesis-d root -c '/data/nemesis/apps/hmg-seogaemo/bin/hmg-seogaemo-root map run'
adb shell /data/local/tmp/nemesis-d root -c '/data/nemesis/apps/hmg-seogaemo/bin/hmg-seogaemo-root map verify'
adb shell /data/local/tmp/nemesis-d root -c '/data/nemesis/apps/hmg-seogaemo/bin/hmg-seogaemo-root map export'
adb pull /data/local/tmp/hmg-seogaemo-export/
```

`map run` scans the full catalogue outside the UI and zygote, verifies all resolved points by reflection, and publishes only verified entries through the package API. `map verify` rechecks a matching bundled or generated map for this boot. `map export` chooses a mounted USB drive when available, otherwise the adb export directory; its `detail=` line gives the exact destination. The ordinary `export adb|usb` change-ledger command also includes the active PR-ready map folder. Exported files contain point names and stock MD5s, without raw DEX or personal identifiers.

Compare host and on-car results after copying the exported folder to a separate local location:

```sh
./tools/verify-map maps/hyundai/ioniq5/kor/260902 \
  --against /path/to/export/maps/hyundai/ioniq5/kor/260902
make test
```

The comparison lists differing point IDs and file hashes. Resolve differences from the stock files and catalogue; do not assume equal names imply binary compatibility. For on-car behavior, export the ledger before and after enabling one module and verify guarded revert restores exact originals. Physical-car projection and boot recovery remain separate release gates.

## Owner submission (GitHub issue)

Owners without a development setup send a map as a GitHub issue. After **Map this car**, choose **Export map** (Car tab or Settings → Developer options) and pick **GitHub issue**: the app saves the folder to USB (or the adb export directory) and then shows a QR code. The phone camera opens the `new-firmware-map.yml` issue form prefilled with product, onebin, Android release, app version and map counts/failing IDs. The owner attaches the exported `maps` folder as a `.zip`. Maintainers turn the issue into a pull request with the steps below. Support → **Report a problem** → **Export as a GitHub issue** opens `bug-car-support.yml` the same way, with a packed, redacted log (module states, failed changes, module/reconcile/watcher log tails, recent app errors) that the `Issue report log` workflow decodes into a comment; `tools/decode-issue-log.py` decodes it locally.

## Pull Request

Add a host-side `evidence.json` beside each bundled map, using the existing bundle as the schema reference. Mapping observations bind exact class/member signatures to stock paths and MD5s. Reflection observations list only the point snapshot actually checked on the car, with its date, product, onebin, Android release, stock hashes and signature digest. Keep physical feature outcomes separate, including partial or pending results. An updated map does not inherit reflection or feature claims for new points. The sidecar does not change runtime `car.json` or grant runtime verification.

Validate evidence and regenerate the coverage document:

```sh
python3 tools/hmg-seogaemo-map-evidence.py validate --stock stock/system
python3 tools/hmg-seogaemo-map-evidence.py generate
python3 tools/hmg-seogaemo-map-evidence.py check
```

The optional `--stock` argument compares every recorded MD5 with the supplied dump. Host checks validate evidence consistency, not the truth of a reported physical test. `make test` rejects stale generated coverage.

Commit only `maps/<make>/<model>/<region>/<firmware>/{map.json,car.json,README.md,evidence.json}`, regenerated `docs/hookpoints.md`, and justified implementation/catalogue changes. Device exports provide runtime map data; prepare the reviewed evidence sidecar on the host. Do not commit the Car Report, stock binaries, raw smali, VIN, serials, network details, or personal data. The PR template asks for exact product, onebin, Android version, unresolved IDs, host/on-car comparison, and verification evidence. CI runs schema, catalogue, required-point, evidence, and forbidden-field validation.

## Upstream updates

`UPSTREAM.md` pins the general HMG-API baseline at `4fab437`, records the 18 catalogue-only v1.0.1 additions, and maps each independent component and hookpoint group to its upstream source. After updating a local HMG-API clone, run `sh tools/upstream-diff.sh /path/to/HMG-API`. Review only the tracked upstream changes, translate relevant rule or behavior changes into our own schema and code, preserve stable point IDs, and repeat host and on-car checks. The diff tool never copies upstream code.

## Prompt for an AI agent with adb access

> HMG-Seogaemo의 새 Gen5W 펌웨어 매핑을 조사해 줘. 먼저 `AGENTS.md`, `.agents/module-runtime-contract.md`, `docs/mapping-new-firmware.md`, `UPSTREAM.md`를 읽어. adb에서 `ro.build.product`, `ro.mobis.onebindir`, Android 버전을 기록하고 `tools/hmg-seogaemo-list-stock-files.py`가 출력한 파일만 `stock/system/`으로 가져와. 원본 파일과 Car Report는 git에 넣지 마. `tools/map-car.py`로 host 매핑을 만들고, `hmg-seogaemo-root map run` 및 `map export`로 차량 매핑을 내보내. `tools/verify-map --against`로 이름과 MD5 차이를 설명하고, 필수 hook point가 모두 검증됐는지 확인해. 실패한 점은 추측으로 채우지 말고 ID와 근거를 보고해. PR에는 `maps/.../map.json`, `car.json`, `README.md`와 필요한 독립 구현 변경만 포함해. CarPlay, Android Auto, Wi-Fi, NEMESIS, HMG-API, HMG-Seogaemo 같은 고유명사는 그대로 써.
