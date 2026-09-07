# Tesla

An [Omarchy](https://omarchy.org) bar widget for your Teslas. The bar shows the
Tesla mark and nothing else. Click it and a panel comes down with a map of
where the selected car is, which way it is pointing, how full the battery is, how far
that gets you, and the handful of things you actually end up wondering about a
parked car.

| Tokyo Night | Catppuccin Latte | Matte Black |
| --- | --- | --- |
| <img src="screenshots/tokyo-night.png" alt="The panel under the Tokyo Night theme" width="280"> | <img src="screenshots/catppuccin-latte.png" alt="The panel under the Catppuccin Latte theme, with the light basemap" width="280"> | <img src="screenshots/matte-black.png" alt="The panel under the Matte Black theme" width="280"> |

The same car under three themes. The map picks its own basemap to match, and
everything drawn over it takes its contrast from the tiles rather than from the
theme, so a light map inside a dark panel still reads.

## Install

```bash
omarchy plugin add https://github.com/jankeesvw/omarchy-tesla.git --enable
```

Then give it a token. That is the whole of the setup, and it is worth a section
of its own.

The widget lands in the right section of the bar. Move it with
`omarchy bar move`, or from the bar's own settings panel.

## Getting a token

This talks to Tesla's **owner API**, the one the phone app uses. It has no
concept of a scoped API key you can go and create: what it takes is an OAuth
token belonging to your own Tesla account, and there is nowhere in the Tesla app
that will hand you one. You have to run the login yourself and keep what comes
back.

Two things come out of that login. An **access token**, which is what every
request carries and which expires after about eight hours, and a **refresh
token**, which mints new access tokens indefinitely. Only the second one matters
here: give the widget the refresh token and it looks after the rest on its own,
for as long as you leave it signed in.

The pleasant way is to let one of these apps do the login and hand you a token:

| Where | What |
| --- | --- |
| Linux, macOS, Windows | [tesla_auth](https://github.com/adriankumpf/tesla_auth), a small desktop app by the author of TeslaMate. The most actively maintained of the lot, and the one that needs no phone. |
| iOS | [Auth app for Tesla](https://apps.apple.com/nl/app/auth-app-for-tesla/id1552058613) |
| Android | [Tesla Tokens](https://play.google.com/store/apps/details?id=net.leveugle.teslatokens). Still the one the Home Assistant Tesla integration points at, though it has gone missing from Google Play before. |
| Chromium, Edge | [Chromium Tesla Token Generator](https://github.com/DoctorMcKay/chromium-tesla-token-generator), an extension |

Then paste the **refresh** token in:

```bash
~/.config/omarchy/plugins/jankeesvw.tesla/bin/tesla token
```

It spends the token on an access token there and then, so if it says you are
signed in, you are.

China-region accounts are detected from the token issuer automatically. Their
tokens are refreshed through `auth.tesla.cn` and their car data is read from
Tesla's China Owner API; no region setting is needed.

There is also `tesla login`, which runs the whole browser flow itself. It works,
but Tesla has taken `https://auth.tesla.com/void/callback` off the allowlist for
the `ownerapi` client, so the only accepted redirect left is `tesla://auth/callback`
and no browser will follow that. You have to open the developer tools on the
Network tab and read the address off the last redirect. Use one of the apps
unless you enjoy that sort of thing.

All of them drive Tesla's real login page, so none of them ever sees your
password. If you would rather place the file yourself, `tesla token` is only
doing this:

```bash
mkdir -p ~/.config/omarchy-tesla
(umask 077; printf '%s\n' "paste-the-refresh-token-here" > ~/.config/omarchy-tesla/refresh-token)
```

The first line with something on it is the token, trimmed. Nothing else in the
file is read, and the widget never writes to it except to store a rotated token
when Tesla hands one back.

### If you get a 403 telling you to use the Fleet API

This one is worth knowing about, because it lies to you.

```
403 {"response":null,"error":"forbidden, see https://developer.tesla.com/docs/fleet-api"}
```

That reads like the owner API has been retired for your account and the only
way forward is a Fleet API developer application, a domain you control and a
public key hosted on it. It is not. **It means the token was minted over
TLS 1.2.**

Tesla's auth edge inspects the TLS handshake of the *token request* and records
what it saw, encrypted, in an `x-enc` claim inside the token it returns. The
owner API opens that claim and refuses anything minted over TLS 1.2. The token
is otherwise perfect: right audience, right scopes, unexpired, and it decodes to
claims byte-identical to a working one apart from that field. Ask for the same
token with `curl --tlsv1.3` and the very same API call returns 200.

`bin/tesla` pins TLS 1.3 on both token calls for exactly this reason. If you
port this to another language, that is the line to carry over: Python's
`requests` and anything else that negotiates down to TLS 1.2 will hand you a
token that looks fine and is refused everywhere.

## Removing it

```bash
omarchy plugin remove jankeesvw.tesla
```

That takes the widget out of the bar and deletes the plugin. It leaves your
credentials alone, on purpose: an accidental removal should not cost you a
sign-in. To take those out too:

```bash
tesla logout                        # before removing, while the script is still there
rm -rf ~/.config/omarchy-tesla      # or afterwards, by hand
rm -rf ~/.cache/omarchy-tesla       # map tiles, addresses, the last reading
```

Deleting the token stops this machine, not the token itself. Revoke it properly
under **Security → Third-Party Apps** in your Tesla account.

## Letting the car sleep

This is the part worth reading, because it is the part that can cost you range.

Tesla's API has two kinds of call, and they are not equally cheap.

**Free.** `GET /api/1/products` and `GET /api/1/vehicles/{id}` are answered by
Tesla's servers out of what they already know. They report `online`, `asleep`
or `offline`, and the car is never involved. You can ask as often as you like.

**Not free.** `GET /api/1/vehicles/{id}/vehicle_data` is answered by the car.
On a car that is already asleep it returns 408 and does *not* wake it, and that
part is harmless. The problem is a car that is awake: every reading resets its
sleep timer, and a Tesla needs roughly fifteen unbothered minutes before it
drops off. A widget refreshing itself every thirty seconds means a car that
never sleeps at all, which is a few percent of battery a day for a car sitting
on a driveway. This is the drain third-party Tesla apps are known for, and it
is entirely self-inflicted.

**Waking.** `POST /api/1/vehicles/{id}/wake_up` is the only call that wakes a
sleeping car. It runs from the Wake button in the panel and from nowhere else.

So the widget is built around leaving the car alone:

- The bar polls only the free call, every five minutes. That is what dims the
  icon when the car is asleep, and it costs the car nothing at any interval.
- The car itself is read when **you open the panel**, and otherwise only while
  it is **driving** or **charging**, both cases where something other than
  this widget is already holding it awake, so a reading costs nothing that was
  not already being spent.
- A parked, awake car is read at most once every fifteen minutes, and in
  practice not at all, because nothing is polling it. That limit lives in
  `bin/tesla`, not in the QML, so a mistake in the interface cannot get past
  it.
- Refresh forces a reading past the limit, because somebody clicking Refresh
  has decided they would rather have the truth. Its tooltip says what that
  costs. It still cannot wake a sleeping car: it is disabled while the car is
  asleep, and the call behind it would only collect a 408 anyway.

If you shorten **Leave a parked car alone for** below fifteen minutes you are
turning this off. The setting goes down to five so you can, not because you
should.

## Telling it what to do

Everything above is about reading a car without disturbing it. The controls are
the other half, and they get the opposite rule.

A command is answered by the car itself, not by Tesla's records, so a sleeping
car cannot hear one. That leaves two honest choices: refuse the command, or
wake the car to deliver it. This wakes it. A Lock button that quietly did
nothing because the car was asleep would be worse than no Lock button at all —
it would be a car you believed was locked.

So: **nothing here runs on a timer, and nothing here happens because the panel
opened.** A command is sent because somebody pressed a button, and pressing it
costs a wake. That is the whole of the policy, and it is enforced in
`bin/tesla` rather than in the QML, the same as the sleep guard is.

What the buttons say is what pressing them will *do*, not what the car is
currently doing — the details grid two rows up already says that. So the button
reads **Unlock** when the car is locked, and the word *locked* is four lines
above it. Nothing has to be reconciled in your head.

Three other things worth knowing:

- **Closing the windows only works near the car.** Tesla checks the position
  itself and refuses from anywhere else; the same goes for HomeLink. Venting
  works from anywhere.
- **A refusal comes back in words.** Tesla says no in tokens like
  `not_charging`, so the common ones are translated into a sentence under the
  controls. A button that failed silently would be the worst outcome here.
- **The reading catches up on its own.** A command corrects the cached reading
  for the field it changed, then asks the car for a fresh one four seconds
  later — long enough for the car to have actually done the thing, rather than
  just to have accepted being asked.

Set **Controls** to `Off` if you would rather the widget stayed something that
only looks.

## What it shows

**In the bar**, the mark and nothing else. It turns green while the car is
moving, sits plain while it is parked and awake, and dims while it sleeps.
Three states, no numbers: a bar full of coloured glyphs is a bar you stop
reading, so the colour is saved for the one thing worth catching out of the
corner of your eye.

**In the panel**, top to bottom:

- The car's name. Accounts with more than one car also get a row of car buttons;
  each button switches the panel to that VIN without changing the saved default.
- A map centred on the car, with it drawn as an arrow pointing the way it is
  facing, the same heading the Tesla app shows under Location. The marker
  pulses while it is moving.
- The street it is on, and one line saying what it is doing and how old the
  whole reading is: `Driving 53 km/h · fetched just now`. Everything on the
  panel came out of that one reading, so one line dates all of it. Parked, the
  street comes with its house number, in the order that country writes it
  (`1600 Pennsylvania Avenue Northwest, Washington, DC` in the US; `De Hees 39,
  Kronenberg` in the Netherlands); moving, it does not, because at speed the
  nearest address changes every second and the line flickers through numbers
  nobody is reading.
- While it is driving somewhere, one line for where somewhere is and when it
  gets there: `Home at 19:48 · 2.6 km`. A clock time rather than a countdown,
  because arriving is something you meet the car at, and to the minute rather
  than the second, which is not a thing anybody meets anything at. Traffic
  joins the line when it costs a minute or more. No route set, or parked, and
  the line is not there.
- The battery bar with the charge limit notched on it, and under it the
  percentage and the remaining range.
- Ten things you end up looking up: whether it is locked, whether sentry mode
  is on, the odometer, the tyre pressures, inside and outside temperature, the
  charge limit, what the last charge put in, whether the climate is running,
  and which software it is on. In that order, because "is it locked" is what
  you check when you cannot find your car and the software version is trivia.
- A line in red when a door, the boot, the frunk or a window is open. Absent
  the rest of the time, which is what makes it worth reading when it turns up.

Miles or kilometres, Celsius or Fahrenheit, bar or psi: none of these are
settings. The car reports both its raw numbers and which units its own screen
is showing, and the panel follows the screen. A range here that disagreed with
the range in the car would be worse than no range at all.

Clicking the map opens the position in Google Maps, which is configurable.
Middle-clicking the bar icon does the same without opening the panel.

## Where the map comes from

Tiles come from [OpenStreetMap](https://www.openstreetmap.org/) and the address
from OpenStreetMap's [Nominatim](https://nominatim.org/). Both are free and
neither needs a key.

It used to be CARTO's dark and light basemaps, which read better behind a
marker. CARTO now enforces an API key on those, and a keyless request comes
back with "API KEY NEEDED" stamped across the map, so the default moved to the
tiles that stay free without an account.

OpenStreetMap ships one style and it is a pale one, so **Dark** is that same
map turned dark rather than a different basemap. Black laid over the top was
the obvious way and it looks it: white goes to grey while the yellows and
greens stay just as loud underneath. What the panel does instead is what
OpenStreetMap's own site does for its dark mode, invert the tiles and then turn
the hue a half circle, so the colours that survived the inversion land back
where they started. Water stays blue, parks stay green, and the paper the map
is printed on goes black.

**Auto** follows your theme and is the default, because a light map inside a
dark panel is a torch in the face and a dark one inside a light panel is a hole
in it.

Everything painted over the tiles is coloured off the map rather than off the
theme, for the same reason: the marker's ring and the attribution have to
contrast with what is underneath them, and those two can disagree when you pin
the map to Light inside a dark theme.

They are also somebody else's servers being generous, so the widget behaves:
tiles are cached on disk forever and fetched once, addresses are cached per
position so a parked car is a single lookup however often you look at it, and
every request identifies itself. If you would rather nothing but Tesla learned
where the car is, turn **Look the position up by name** off; the map still
works, because tiles say nothing about which one of them you cared about.

## Keeping the token safe

The refresh token sits in `~/.config/omarchy-tesla/refresh-token`, readable only
by you, and the access tokens minted from it in `access-token` beside it. The
QML never touches any of them: everything that holds a credential is in
`bin/tesla`.

> ⚠️ That file is your Tesla account. Not a scoped key, not a read-only key, the
> account. Anything that can read it can locate and unlock your car. Tesla's
> owner API has no way to narrow that down, which is worth knowing before you
> copy the file anywhere or hand it to a backup that syncs.

To revoke it, `tesla logout` removes the local copy, and Tesla's account page
under **Security → Third-Party Apps** revokes it properly. Do the second one as
well as the first: deleting the file stops this machine, not the token.

`TESLA_REFRESH_TOKEN` in the environment overrides the file, for anybody keeping
secrets somewhere else.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| VIN | empty | Which car is initially selected. Empty takes the first; switch cars in the panel. |
| Controls | Essentials | Which commands the panel offers. `Off` leaves it read-only; `Everything` adds charging, seat heaters, dog and camp mode, valet and HomeLink. |
| Map | Auto | Follows the theme. Or force CARTO dark, CARTO light, or OpenStreetMap's own tiles. |
| Zoom | 16 | 16 shows the street and its neighbours. Lower for which town, higher for which parking space. |
| Panel width | 380 | Sizes the whole panel; everything else is measured off the map. |
| Look the position up by name | on | Reverse geocoding through Nominatim. |
| Check whether the car is awake every | 5 min | The free poll. Costs the car nothing at any interval. |
| Leave a parked car alone for | 15 min | The sleep guard. See above before lowering it. |
| Where a click on the map goes | Google Maps | `{lat}` and `{lon}` are substituted. |

## The command line

`bin/tesla` is the whole of the Tesla side and is useful on its own:

```
token                     paste a refresh token from a token app. The easy way
login                     sign in through the browser instead. Needs devtools
logout                    forget the tokens on this machine
state                     online / asleep / offline. Free; never wakes the car
car [--force]             everything the panel shows, subject to the sleep policy
wake                      wake a sleeping car. The only call that does
map LAT LON ZOOM W H      map tiles around a point, fetched and cached
place LAT LON             that point as a street and a town
```

And the commands. Each of these wakes the car first, on purpose — see
**Telling it what to do** below:

```
lock                      lock the doors
unlock                    unlock the doors
trunk                     open the boot (and close it, on an S or an X)
frunk                     open the frunk
windows vent|close        vent or close all four. Closing needs the car nearby
sentry on|off             sentry mode
valet on|off [PIN]        valet mode. The PIN sets one; leaving it off is fine
drive                     keyless driving, for the next two minutes
climate on|off            climate control
temp DEGREES[C|F]         cabin setpoint. Bare number means the car's own unit
defrost on|off            max defrost
keeper off|keep|dog|camp  what the car does about the cabin while you are gone
seat SEAT 0-3             seat heater. front-left, front-right, rear-left,
                          rear-center, rear-right
wheel on|off              steering wheel heater
charge start|stop         charging
port open|close           the charge port door
limit PERCENT             charge limit, 50-100
amps AMPS                 charging current
horn                      honk
flash                     flash the lights
homelink                  the garage door the car is parked in front of
nav DESTINATION           send somewhere to the car's navigation
```

Everything prints one line of JSON, including failures, so nothing that goes
wrong reaches the panel as a parse error.

It needs `curl`, `jq`, `awk` and `openssl`, all of which Omarchy already has.

## Testing it without going for a drive

Synthetic input does not reach the shell, so there is an IPC hook instead:

```bash
omarchy-shell jankeesvw.tesla.test drive 87 243   # moving at 87, heading WSW
omarchy-shell jankeesvw.tesla.test navigate "Home" 6
omarchy-shell jankeesvw.tesla.test park
omarchy-shell jankeesvw.tesla.test sleep
omarchy-shell jankeesvw.tesla.test live           # back to the real car
```

For working on the panel itself, a whole reading can be pinned instead. Put one
in `~/.config/omarchy-tesla/fixture.json` and `tesla state` and `tesla car`
serve that and never call Tesla at all. The panel behaves exactly as it does
with a real car, but the car stops moving underneath you between restarts.
`tesla car > ~/.config/omarchy-tesla/fixture.json` makes one from whatever the
car is doing now; delete the file to go back to it. A fixture taken mid-drive
keeps driving: the timestamp and the arrival time are both moved forward by
however long ago it was written, so a car saved four minutes from home stays
four minutes from home. The screenshot above is a
fixture, which is also how it manages to be somewhere other than my driveway.

## Which cars this works with

The owner API, which is what this uses, still answers. It is being retired
endpoint by endpoint rather than all at once: `/api/1/vehicles` already returns
`Endpoint is only available on fleetapi`, which is why the vehicle list here
comes from `/api/1/products` instead. Expect more of that.

Reading data is all this does, so the Tesla Vehicle Command Protocol, which
2021-and-later cars require for *commands*, does not come into it. A 2018
Model S is what it was built against.

If a call comes back pointing at the Fleet API, read the TLS 1.3 note above
before concluding anything. That error means what it says far less often than
it appears to.

## Licence

MIT. Not affiliated with, endorsed by, or connected to Tesla, Inc. in any way;
the Tesla name and mark belong to them. The mark drawn in the bar is [Simple
Icons](https://simpleicons.org/)' tesla path, which is public domain.
