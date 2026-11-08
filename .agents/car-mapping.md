Status: current — core mapping implemented off-car; on-car timing/reflection for the v1.0.1 and stock-guidance additions unverified.

# Car mapping: NEEV.KOR.260902

The private Car Report is never committed. Operator workflow:
`docs/mapping-new-firmware.md`; provenance and stable IDs: `UPSTREAM.md`; AGENTS.md has the mapping summary.

## Implemented core mapping

- The repo is GNU AGPL-3.0 with an independent core mapper (copying HMG-API's Java mapper would extend AGPL obligations to the shared runtime). `core/hookpoints/` re-authors the full HMG-API
  catalogue in our schema with stable IDs. `maps/hyundai/ioniq5/kor/260902/` has the bundled names and all 18 stock MD5s.
  `modules/wireless-carplay-and-aa/hookpoints.required` declares 120 direct and supporting points, none unresolved.
- `core/map/`: standalone Java 7/API 19 DEX index, shape resolver and reflection verifier run in a root `app_process`. The
  full catalogue is scanned only on confirmed `map run`; `map status` matches product, onebin, Android release and stock
  MD5s. A known map is verified once per boot from an app worker (`map verify` via adb). Every resolved point is reflected
  against its stock classloader; failed optional points are removed from the published map, failed required points block
  publication. The package API publishes immutable files and an atomic active pointer under `car-maps/`, with ledger and PR
  export. The wireless module consumes that pointer. Settings → Car
  mapping shows status, source, counts, IDs and confirmed map/export actions.
- `tools/map-car.py`: independent baksmali host mapper. `tools/verify-map` validates schema and compares host/on-car maps. CI
  validates every bundled map, catalogue coverage, module requirements, forbidden fields. `UPSTREAM.md` and
  `tools/upstream-diff.sh` track HMG-API commit `4fab437` without copying source.
- Design decisions kept: the cheap status check runs automatically and, on unknown firmware, the app offers the confirmed
  "Map this car" itself once per start (the scan is never run without that confirmation); a map
  generated on the car activates after on-car verification plus explicit module enable; mapper runs on a background worker
  outside zygote and the UI process; every required point needs exactly one candidate and passing reflection, else the whole
  projection hook set stays off with point and reason reported; native-recipe checks stay independent.
- Host synthetic DEX/smali and fake-root tests do not prove mapping time, Dalvik reflection, memory, verified points, zygote
  loading or projection on the Ioniq 5. Open: time/memory budget from a parked-car measurement; retention of generated maps
  and redacted report fields.

## v1.0.1 additions

- The 18 IDs listed in UPSTREAM.md were translated from HMG-API v1.0.1 definitions into our schema (no upstream mapper code).
  All 18 resolve uniquely in the owner's read-only KOR stock dump with our DEX index/scanner; no US/EV6 names
  or hashes used. No new stock files needed: the 18 existing `car.json` MD5s match; `car.json` is byte-identical.
- 6 iAP2 points in `/system/app/Iap2ServerApp.odex` (`a672fd0e0070414f2eb70a2807117a6f`); 12 framework points in
  `/system/framework/automotive.odex` (`c76b8209ef171739b177eb14e8df61dd`). Per-ID signatures in the bundled `evidence.json`.
  Keep the stock `iAP2UsedVehicelInformation` spelling. No module requires a new ID.
- Bundle maps 348/349; `themesettings.split_item.type` stays missing. Only the original 324 points have owner-reported
  on-car reflection (324/324, 2026-11-03); the 24 additions need it. The sidecar and generated `docs/hookpoints.md` distinguish these claims; the host validator checks
  consistency and optional exact-stock MD5s, not that a physical observation happened.

## Stock-guidance additions (2026-11-07)

Six independently authored IDs are listed with exact signatures in UPSTREAM.md and
the bundled evidence sidecar. Our DEX index/scanner uniquely resolved all six without
reference-map fallback against the read-only dump at
`tmp/car-sessions/2026-11-04-devdump/system/` in the main checkout. All 18 existing
stock MD5s match; every new point is in `/system/framework/automotive.odex`
(`c76b8209ef171739b177eb14e8df61dd`). No stock hashes or module requirements changed.

Smali cross-checks under `analysis/api-inventory/smali/automotive/com/hkmc/cluster/`:
`NavigationCluster.smali:1504` (five-int junction view), `:7728` (17-int trap info,
`:7741` names argument 12 barGraphLevel), `:8186` (NaviTbtTrapInfo object);
`NavigationCluster$NaviTbtTrapInfo.smali:34` (instance int barGraphLevel), `:94`
(public no-argument constructor). The stock class implements Parcelable and has
CREATOR, a Parcel constructor and writeToParcel; a consumer can preserve its other
fields via a Parcelable round trip rather than mapping every camera/speed field.
`wireless-carplay-and-aa` uses them as optional points (not in `hookpoints.required`):
a failed reflection turns off only the approach bar or the junction view, never CarPlay.
The six additions still need on-car reflection; physical view observations in
cluster-ar-view.md and hud-junction-view.md do not establish that verification.

## Verification seal

The verification seal carries a map/car/catalogue/required-manifest digest; old three-line seals and changed inputs report off until reverified, including same-boot OTA reconciliation (so a same-boot update cannot reuse a stale seal). Normative format, zygote gate and map-ID rules: [module-runtime-contract.md](module-runtime-contract.md), "Core car mapping". On-car validation of the seal is still open.

## Catalogue and mapper shape

`core/hookpoints/*.json` defines stable IDs, app package, stock files, and per-point `kind`, owning class (`of`) and `find` shape (package/class name, superclass, constructor signatures, field/method names and types, static flags, parameter/return types, code string constants). Named regex patterns capture obfuscated names from smali call patterns; `@point` references depend on earlier resolution (`core/hookpoints/README.md`). Zero or multiple candidates leave a point missing (`--strict` fails). The on-unit mapper parses dex in `.odex`/`.jar` directly (no baksmali) and cannot evaluate smali-only regex/`code` rules; the host mapper uses baksmali. Equal point names across cars do not prove binary compatibility. Host mapping uses hundreds of MB of temp smali and is unsuitable for the head unit.
