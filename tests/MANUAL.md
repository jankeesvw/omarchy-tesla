# Manual checks (no QML test runner)

Copy and the parked tooltip live in the panel. `tests/place.sh` does not cover them.

Do not run live `tesla place` against the car as a test. Old cache files miss and that would hit Nominatim.

## Fixture for the open sentence

Copy a reading, then set the rear trunk token:

```
tesla car > ~/.config/omarchy-tesla/fixture.json
```

Edit `open` to `["the boot"]`. Delete the file when done.

## C1 — this machine, US English (`en_US`)

- Details label reads `tires`, not `tyres`.
- With the fixture above, the red line reads `The trunk is open`.
- Parked tooltip is `Parked at ` plus the glance line, unelided.
- Glance line may elide at panel width. Do not wrap it.

## C2 — `en_CA`

Restart the bar with `LC_ALL=en_CA.UTF-8` if Qt picks that up. Same as C1 (`tires`, `The trunk is open`). If the bar ignores a one-shot `LC_ALL`, write unverified here rather than guessing.

## C3 — `en_GB` / `en_AU` / `nl_NL`

Restart with `LC_ALL=en_GB.UTF-8` (or `en_AU` / `nl_NL`). Label `tyres`. Fixture sentence `The boot is open`.

## C4 — US desktop, Dutch pin

Address follows the pin; copy follows the desktop. Do not call live Nominatim. Seed the place cache for the car's rounded coordinates with the A3 contract, then open the panel.

```
lat=$(jq -r .lat ~/.cache/omarchy-tesla/car.json)
lon=$(jq -r .lon ~/.cache/omarchy-tesla/car.json)
key=$(awk -v a="$lat" -v b="$lon" 'BEGIN { printf "%.4f_%.4f", a, b }')
cp tests/fixtures/a3.out.json ~/.cache/omarchy-tesla/places/$key.json
```

Glance line: `Venweg 12, Kronenberg`. Label: `tires`. Remove the seeded file afterwards.

## A2 — moving

IPC `omarchy-shell jankeesvw.tesla.test drive 87 243` (or drive the car). Glance line drops the house number. Street and town stay, including a US `, PA` / `, DC` suffix.

## A14 — tooltip

Parked, with a place: tooltip is `Parked at ` plus the same string as the glance line.
