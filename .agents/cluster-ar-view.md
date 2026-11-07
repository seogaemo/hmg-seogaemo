Status: current — car-verified 2026-11-06 on NEEV KOR (stock drive, CarPlay guidance, parked probes).

# Cluster AR turn view

The instrument cluster switches from the flat turn icon to its AR turn view when it receives a
turn in the stock `Navigation.DisplayType` format. Separate from the HUD hologram
([hud-hologram.md](hud-hologram.md)) and the HUD junction view
([hud-junction-view.md](hud-junction-view.md)). Firmware reference: [navi-ar-guidance.md](navi-ar-guidance.md).

## Call

`NavigationCluster.updateTBTInfo(type, sideStreet, direction, distance, distanceErr, combiSideStreet, unit, bar, barErr)`

| Argument | Value for the AR view |
|---|---|
| type | stock `Navigation.DisplayType`: TURN 13, U_TURN 31, FORK_2 25, EXIT_RIGHT 17 / EXIT_LEFT 18, EXIT_ROUNDABOUT_TRS_RIGHT 32 / _LEFT 33, OVERPASS_* … |
| sideStreet | 0 |
| direction | degrees in 45° steps (0 straight, 90 right, 270 left) |
| distance, unit | distance text shown in the view (unit 0 = m, 1 = km) |
| bar, barErr | ignored by the view; send as stock does |

- Projection icon codes keep the flat icon. CarPlay uses them outside its approach window or
  when the maneuver geometry cannot be mapped reliably.
- Distance does not gate the view: 600 m and 0 m both draw it. Stock navigation opens its AR
  window about 150-600 m before a maneuver and leaves it after the maneuver.
- Works with stock guidance and with CarPlay guidance active.
- Types 9 CALC_ROUTE / 10 RECALC_ROUTE show "경로 탐색 중입니다" / "경로 재탐색 중입니다".

## Vertical bar

The bar beside the AR view is `updateTBTTrapInfo` (17 ints, 12th = `barGraphLevel`) /
`updateTBTTrapInfoNew`, 0..100 (100 full). The same call carries speed-camera, limit and toll
fields. CarPlay captures the latest real stock call in the navigation process and replaces
only the bar during an approach lease. Both the 17-int and object-record paths preserve the
camera, speed-limit and toll values. While the captured record reports an active camera,
trap, warning zone or toll gate (any of those fields other than 0 / -1) the stock bar passes
through unchanged. Stock navigation sends trap info only on change (often once per route), so
with no captured stock record the bar rides on a neutral record (all fields 0, overSpeedAlarm 3
as stock sends when idle), restored to bar 0 at the end. The trap points
are optional for the module: without them only the bar is off.
Leaving the window restores the latest stock bar; a 3500 ms lease also restores it if DiPO
stops renewing. Trap calls are never included in the phone-guidance suppression list.

## CarPlay policy

Stock-format output is enabled with normal TBT, independent of the developer logging toggle.
The window is 300 m for ordinary turns and 600 m for ramps and exits,
inclusive, using the raw distance in metres to the current maneuver. These fixed thresholds
approximate the observed stock urban onset of 150–375 m and highway onset of 580–600 m;
CarPlay does not expose the stock road-dependent guide-window policy. A changed current
maneuver needs a fresh distance. Unknown distance cannot open the window.

The independently implemented CpGuidance policy uses maneuver type, explicit exit angle,
other junction angles and driving handedness. Turns round to 45 degrees (the branch angle
equals the direction; 180 draws no line and is never sent). Exits send EXIT_RIGHT 17 at 90 or
EXIT_LEFT 18 at 270, or 19 at 90 / 20 at 270 (exit after a lane change toward it; the name of
20 is misleading) when CarPlay lane guidance shows the recommended lanes are not the lane on the
exit side. Keeps and highway changes keep the projection icon and the lane frame: the keep side
is only a lane recommendation (a drive showed a right then a left Y where one middle lane of
five was recommended), and FORK_2 25 is never sent. Arrival maneuvers send 2 at 270 / 90
(destination on the left / right) or ARRIVED 3; route state Arrived sends 3. Straight past one side road sends SERVICE_ROAD 23 at 270 (branch right) or 24 at 90 (branch
left), which draw the main road straight on, only with a highway road name or instruction;
otherwise TURN 13 at 0. U-turns use the Korean
left loop by default; an explicit exit angle other than 0 under 158 degrees either way contradicts
the type and keeps the projection icon (no angle, as NAVER sends, draws the U-turn). Roundabouts send 32 (counter-clockwise travel, right-hand traffic) or 33
(clockwise, left-hand traffic) by driving side, with the exit clock position measured clockwise
from 12 o'clock as direction; positions require an explicit exit angle; ordinal exit numbers
do not provide an angular position. A plain left or right turn (types 1 and 2) with the roundabout
junction flag set and an explicit non-zero exit angle is the roundabout exit and sends 32 / 33 the
same way (0 is the entry marker of the projection icon table, not a position; no angle keeps the
projection icon). NAVER's own roundabouts arrive as type 0 with junction 1 and exit 180 (every
recorded sighting, a likely placeholder) and keep the projection icon 102. Plain turns outside a
roundabout still need the side's 45 degree band (225..315 / 45..135); wider angles keep the
projection icon until the cluster is photographed at those directions. Ambiguous or contradictory geometry retains the projection
icon. When the next maneuver is not known yet the projection icon is resent; the idle compass
is only for stop and disconnect.
The bar decreases linearly from 100 at entry to 0 at the maneuver. Route states Loading and
Rerouting send stock types 9 and 10. The HUD F2 list retains its projection icon format.

The classified car sweep is in local, gitignored dataset `datasets/cluster-ar-tbt/`: `summary.md`, per-row `classify.csv`, second-pass review in `classify-reviewed.csv` and `review.md`.

## Android Auto policy

`AaTurns` uses our `AaGuidance` with the CarPlay windows (300 m; 600 m for on/off ramps, forks and
merges), the raw distance in metres, and a fresh distance after the next turn changes (event,
side, angle or road). Android Auto's legacy next-turn event carries an event, a side and, for
roundabouts only, an exit angle; no junction geometry. Mapping:

| AA event (side) | Stock type, direction |
|---|---|
| TURN / SLIGHT_TURN / SHARP_TURN (L/R) | 13 at 270/315/225 or 90/45/135 |
| STRAIGHT, NAME_CHANGE (no side) | 13 at 0 |
| U_TURN | 31 at 270 (90 when the phone says right) |
| ON_RAMP / OFF_RAMP (L/R) | 18 at 270 / 17 at 90 (no lane recommendation to pick 19 / 20) |
| ROUNDABOUT_ENTER_AND_EXIT (RIGHT, angle 1-360) | 32 at the exit's clock position, stock GPM's bins |
| DESTINATION (L/R / none) | 2 at 270 / 90, ARRIVED 3 |
| STRAIGHT or NAME_CHANGE with a side (keeps), FORK, MERGE, sideless turns, ROUNDABOUT_EXIT, other roundabout sides, DEPART, ferries, UNKNOWN | projection icon |

Stock types go out with sideStreet 0 (65535 draws a road in every direction); icons keep
65535. Rerouting (status 3) sends 10 and holds turns until the next turn, active status or five
distance updates. GPM renews the bar lease (`ApproachBar`, every second) with the same
`CpTrapOverlay`. Not yet seen on a drive.

Evidence: event/side/status numbers match AOSP `CarNavigationStatusManager` (API 26) and the AA
protos in open-headunit; the roundabout angle is travelled from the entry (90 right, 180
straight, 270 left; AOSP and Car App Library `getRoundaboutExitAngle`); stock `HKMC_GPM`
`GpmNaviTBTManager` reads the callback's fifth argument as that angle with the same bins and
side RIGHT as right-hand traffic (offline dump, `setRoundAboutDisplayType`); Car App Library
`KEEP_LEFT/RIGHT` is a no-turn choice, which open-headunit sends as STRAIGHT with a side.
Reference implementation: HMG-API PR #75 (US Ioniq 5, its own window and bar).

## Reading the state

`ClusterService` does not log `updateTBTInfo`; `dumpsys com.hkmc.micom.cluster` ("TBT Info",
"TBT Trap Info") shows the current values. Probe scripts: `tmp/lane-probe/tbt.sh`, `trap.sh`.
