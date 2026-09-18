# Tesla native data view — implementation evidence and handoff

## Status: working data view tested; final concurrent integration NOT deployed

Implemented the analytics/data work in **`/home/pi/Projects/tesla.omarchy`**, the canonical existing plugin repository, not a website. A concurrent writer restored the old cockpit and click-to-wake while this worker was testing, and committed the combined tree as **`257e5bf`** (`checkpoint: hermes' data view integrated beside the restored cockpit — not finished`). This worker did not make that commit and has not reverted that writer's work.

**Do not claim final delivery or whole-app no-scroll acceptance yet.** The current tree differs from the tested VM in `Panel.qml`, `Dashboard.qml`, `LocationEditor.qml`, `bin/locations.py`, and `manifest.json`. Exact hashes are in [source-vs-tested-vm.json](source-vs-tested-vm.json). The restored default cockpit still uses its content's implicit height and includes the previous wake/control UI. The new data view is paginated. Reconcile the restored cockpit with Fred's expanded no-scroll request and the task's no-vehicle-action boundary before deploying. The installed host plugin remains at `7d594cf`; this worker did not modify or reload it.

## Canonical repository discovery

- `tesla.omarchy` and installed `jankeesvw.tesla` both began at `7d594cf` (1.3.2); their `Panel.qml` matched byte-for-byte and both working trees were clean.
- `/home/pi/Projects/omarchy-tesla` was an older checkout at `8a50e9e`.
- Both project remotes point to `nixfred/omarchy-tesla`; upstream is `jankeesvw/omarchy-tesla`. Installed origin uses SSH for the same fork.
- Active host shell was discovered at `/home/pi/Projects/video.on.desktop.omarchy/omarchy/shell`, not guessed from PATH. Its `KeyboardPanel.qml` and `Panel.qml` matched `/usr/share/omarchy/shell/Ui` byte-for-byte. Host `omarchy-shell` in this worker's environment needs the discovered `OMARCHY_PATH`; no host restart was attempted.

## Read-only provider findings

[Sanitized capability evidence](capabilities.json) records the real discovery, not fixture data.

- Existing provider: **Tesla Owner API**, not Fleet Telemetry, TeslaMate or Tessie.
- Existing credentials were present. A direct authenticated **GET `/api/1/products` succeeded** using the existing access token held only in memory. No token was printed or refreshed.
- Raw `vehicle_data` was skipped because the result was not an unambiguous online vehicle. No wake, vehicle command, account mutation, or forced polling was attempted.
- The existing normalized cached reading contained **57 leaf fields**. Evidence lists their names and types only, with cache age at inspection. It contains no vehicle identifier, coordinates, address, token or measured value.
- Available families include battery/range, battery-side energy added, charging state/power/current/limit, odometer, instantaneous driving/shift/speed, navigation state, climate temperatures/setpoints/keeper/seat levels, lock/sentry/windows/open state, tire-pressure min/max, model/trim/software, and reading freshness. Nulls remain unavailable.
- No compatible FSD/total-distance counters or actual engagement/driving-duration fields were present in this adapter/cache. **FSD distance share, manual mileage and driving-time share cannot be calculated from it.** The code never divides time by odometer, estimates engagement from instantaneous `driving`, substitutes 0%, or fabricates counters.
- Non-FSD is explicitly **not manual**; basic Autopilot may be included.
- Tesla's [Fleet Telemetry available-data documentation](https://developer.tesla.com/docs/fleet-api/fleet-telemetry/available-data) is a separate provider contract. The supplied research notes `MilesSinceReset` and `SelfDrivingMilesSinceReset` require HW4 and firmware >=2025.44.25.5. This account's hardware/firmware support was not verified, and no Fleet Telemetry adapter was invented. A fresh page extraction returned only an initial part of the table, so it did not independently verify those rows. There is no verified engagement-time field in this work.

## Implemented artifacts

- `DashboardModel.js`: normalized-field grouping, full leaf-field enumeration, responsive pagination capacity, honest Owner API driving unavailability, and cost scenarios that distinguish zero from unknown and reject invalid/non-finite inputs.
- `Dashboard.qml`: native Overview, Driving, Charging, Locations, Vehicle, Climate, All data and Map sections; bounded pages; complete-value views; keyboard navigation and measured viewport/content-fit diagnostics.
- `LocationEditor.qml`: native two-step local location/rate editor, explicit location selection, rate history, and actual Quickshell Process integration. Alt+N creates, Alt+Enter advances, Alt+S saves.
- `bin/locations.py`: private local JSON store, file locking, atomic writes, 0600 file/0700 directory, stable IDs and timestamped tariff revisions. Invalid rates do not overwrite the store. JSON-line stdin avoids waiting indefinitely for the parent process to close its pipe. The concurrent writer subsequently added field-specific errors/currency normalization; final host tests pass for those additions, but their GUI was not retested by this worker.
- `Panel.qml`: native data-view integration and read-only diagnostic IPC. This worker's original replacement removed automatic wake and controls from the new cockpit. The concurrent integration restored those prior behaviors beside the data view; that distinction is not hidden.
- `tests/dashboard.test.cjs`, `tests/test_locations.py`, `tests/native_dashboard.py`, `tests/native_locations.py`, `tests/fixtures/dashboard.json`: model, storage, native-layout and real-keyboard tests. The fixture is explicitly synthetic and has no real location or credential.
- README and manifest metadata describe current local work, with a concurrency warning rather than an unverified completed-delivery claim.

## Home tariff configured privately

The user-specified home address was saved **only** to `~/.config/omarchy-tesla/locations.json`, with explicit **0 USD/kWh**. A readback verified the matching private entry, zero rate and mode 0600. The actual address is deliberately absent from this report, source, fixtures and screenshots. No geocoding or external lookup was performed.

Selecting a location is a deliberate tariff scenario, not a claim that the last charge happened there. Cost uses last reported **battery-side** energy × the chosen current rate; it is labeled **not a bill**, with charging losses, fees and historical location unknown. Unknown tariffs remain unavailable, not free. This does not implement a measured charger-input energy ledger or historical trip/charge accounting.

## Test execution and evidence

Strict test-first cycles were exercised for missing analytics/model functions, unknown/invalid price handling, CLI JSON-line completion, QML initial negative page, actual content-fit checks and real keyboard routing. Red evidence includes [initial model failure](tdd-01-red.txt), [native integration source failure](tdd-ui-red.txt), and [minimum-width failure](minimum-width-red.txt). Several QML red failures were inspected directly in tool output before fixes: missing `contentFits`, initial page -1, PageDown not reaching PopupWindow, and unsupported `closeWriteChannel` causing the save process to wait.

Final **current-source host** commands:

```sh
node --test tests/dashboard.test.cjs
python3 -m unittest discover -s tests -p test_locations.py -v
test/all
bash tests/place.sh
git diff --check
```

- [JS](final-host-js.txt): **4 passed, 0 failed**.
- [Python](final-host-python.txt): **5 passed** (includes concurrent writer's additions).
- [Regression suite](final-regression.txt): smoke, regional routing, reading, mocked commands, parked-car throttle and the new model/storage tests pass. Commands here are fixture/mock tests, not real vehicle commands.
- [Place tests](final-place.txt): all checks passed.
- `git diff --check`: clean.

Independent VM: **`test-drive-tesla-analytics`**, created with `test-drive new plugin tesla-analytics` after reading the Test Drive README and running `test-drive list`. It was cloned from the plugin checkpoint. No standby/template/original lab was reset. Only source and synthetic fixture data were copied; no host credential/account/address data entered the VM.

Native test commands inside the dedicated guest:

```sh
python3 ~/.config/omarchy/plugins/jankeesvw.tesla/tests/native_dashboard.py
python3 ~/.config/omarchy/plugins/jankeesvw.tesla/tests/native_locations.py
```

- All **8 data sections** were measured with both viewport and actual-content fit checks.
- [Small-screen run](native-small.json): **640×480 desktop**, **348×412 content viewport**; overflow became field pages rather than scrolling/clipping.
- [Desktop run](native-desktop.json): **1920×1080 desktop**, **744×600 content viewport**.
- Real `wtype` PageDown and Ctrl+Right changed the native page and section. The original PopupWindow did not receive these keys; switching to Omarchy's `KeyboardPanel` fixed the tested path.
- Native keyboard input created a synthetic location, entered **0**, saved through the real QML-to-Python process, and verified exact JSON readback/mode 0600. No mocked storage response was substituted.
- [Guest health](vm-check.json) passed. [Tested runtime hashes](vm-runtime-sha256.json) identify the exact artifact that was tested.
- QML logs after the successful keyboard fix had no Tesla QML errors; stock portal/BlueZ warnings remained.
- The task VM is stopped, with its tested source/fixture state preserved. Standby was not changed.
- The subsequently added Escape assertion and concurrent cockpit restoration require a fresh native run against the reconciled source. Earlier native success does not prove that latest integration.

## Screenshots (synthetic native plugin, not a website)

All images are private local files under `~/Screenshots`:

- [Desktop overview](/home/pi/Screenshots/tesla-analytics-vm-desktop.png)
- [Small-screen zero-tariff location page](/home/pi/Screenshots/tesla-analytics-vm-small-locations.png)
- [Driving availability panel](/home/pi/Screenshots/tesla-analytics-vm-driving.png)

These were visually inspected: tabs, visible controls and page footer fit without scrolling in the tested data view. The small location screenshot shows explicit free 0 USD/kWh and the scenario disclaimer. They show the pre-concurrent UI, not the restored cockpit.

## Recovery and safety

Verified private backup: `/home/pi/.local/state/omarchy/backups/tesla-cockpit-20260915-002643`.

The archive contains the complete installed Tesla plugin including Git, private Tesla settings and saved shell configuration; symlink targets were materialized. All **221 regular members** were read/hashed, archive SHA-256 verification passed, and captured shell bytes matched live bytes during capture. Exact bar layout was saved privately. This is same-disk recovery, not off-machine disaster recovery; no live restore was performed. Never restore `shell.json` wholesale.

No installed plugin files, bar placement, clipboard policy or keyboard mapping were modified by this worker. Credentials were neither overwritten nor refreshed. The only intentional live configuration addition was the authorized private Home tariff. No host vehicle commands or wake calls were made.

## Remaining acceptance blockers

1. Reconcile concurrent cockpit restoration/default view and click-to-wake with the expanded no-scroll requirement and task safety boundary; preserve the other writer's work rather than blindly overwriting it.
2. Rerun native layout, keyboard, complete-value and location edit/history tests on the reconciled source. Existing model and backend tests alone are not final visual acceptance.
3. No real FSD/manual mileage or time share is possible with currently verified data. A separately authorized compatible data provider is needed, with same-period/reset semantics and actual durations before calculating shares.
4. Raw provider-wide field inventory, hardware eligibility, automatic location matching, charger-input billing, measured charging history and historical driving analytics remain unimplemented/unverified. The UI does not claim otherwise.
5. Final scoped deployment and host readback/visual verification are deliberately left to the parent after integration review. No independent reviewer tool was available to this worker; parent review remains required.

Local GPU helper was used once for a bounded README/provider summary; its output was checked against the source. Its suggestion that commands necessarily wake was not used as authorization for any action.
