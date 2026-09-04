import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Dude, Where's My Car: a Tesla in the bar, and a map behind it.
//
// The bar shows the Tesla mark and, while the car is moving, how fast. The
// panel shows where it is, which way it is pointing, how full it is and how
// far that gets you.
//
// The interesting constraint is not the drawing, it is the asking. Tesla's
// API has calls that are answered by Tesla's servers and calls that are
// answered by the car, and the second kind resets the car's sleep timer. A
// widget that refreshed itself every few seconds would quietly stop the car
// ever sleeping and flatten the battery over a week of standing still.
//
// So the bar polls only the free call, online, asleep or offline, and the
// car itself is asked at three moments: when you open the panel, while it is
// driving (awake regardless of us) and while it is charging (likewise). A
// parked car is left alone. `bin/tesla` enforces that a second
// time from the other side, so a mistake in this file cannot flatten anything.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.tesla"
  ipcTarget: "jankeesvw.tesla"

  // The script that does the talking sits next to this file, so the plugin
  // runs from wherever it was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/tesla").toString().replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  // The bar exposes a foreground and a font, not an accent; the accent is a
  // theme-level colour, so it is read straight off Color.
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Omarchy's palette has a foreground, an accent, an urgent and a muted, and
  // no green. This is the one place a literal colour is right: a live
  // indicator is green everywhere, in every theme, and one that drifted to
  // whatever the accent happened to be would stop reading as "it is up" and
  // start reading as decoration. It marks the panel's status dot and the bar
  // mark while the car is moving, and nothing else.
  readonly property color liveGreen: "#4caf50"

  // And red while it is charging, for the same reason the live mark is a
  // literal green: "it is filling up" should read the same in every theme
  // rather than turning into whatever the accent is today. Material's red 500
  // to the green's 500, so the two sit at the same weight. The error state
  // keeps Color.urgent — a fault and a charge are both red, and the word
  // beside the dot is what tells them apart, the same way it already
  // distinguishes driving from parked.
  readonly property color chargeRed: "#f44336"

  // What the panel accents itself with: the charge colour while it is
  // charging, the theme's accent the rest of the time.
  readonly property color liveAccent: charging ? chargeRed : accent

  // ----------------------------------------------------------------- settings

  readonly property string configuredVin: setting("vin", "")
  property string selectedVin: configuredVin
  readonly property int panelWidth: setting("panelWidth", 380)
  readonly property int mapZoom: setting("mapZoom", 16)
  readonly property string mapStyle: setting("mapStyle", "Auto")
  readonly property int statePollMinutes: setting("statePollMinutes", 5)
  readonly property int parkThrottleMinutes: setting("parkThrottleMinutes", 15)
  readonly property bool showAddress: setting("showAddress", true)
  readonly property string mapsUrl: setting("mapsUrl",
    "https://www.google.com/maps/search/?api=1&query={lat},{lon}")

  // Whether the theme in force is a light one, judged off the panel
  // background's luminance rather than off a theme name: a theme can be
  // called anything, but a background either reflects light or it does not.
  // The coefficients are the usual perceptual weights: green carries most of
  // what the eye reads as brightness.
  readonly property bool lightTheme: {
    var bg = Color.background
    return (0.2126 * bg.r + 0.7152 * bg.g + 0.0722 * bg.b) > 0.5
  }

  // CARTO's two basemaps are quiet enough to read a marker off and come in a
  // matched pair, which is the whole reason they are the default over OSM's
  // own: a dark map dropped into a light theme is a hole in the panel, and a
  // light one in a dark theme is a torch in the face. Auto follows the theme
  // so neither happens; the explicit choices are for anyone who wants the map
  // to disagree on purpose.
  readonly property string effectiveMapStyle:
    mapStyle === "Auto" ? (lightTheme ? "Light" : "Dark") : mapStyle

  readonly property string tileUrl: {
    if (effectiveMapStyle === "Light") return "https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png"
    if (effectiveMapStyle === "OpenStreetMap") return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    return "https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"
  }

  // Whether what is about to be drawn is a pale map. Anything painted on top
  // of it, the attribution and the ring around the marker, has to contrast with
  // the tiles rather than with the panel, and those two can disagree: a dark
  // theme with the map forced to Light is exactly where white-on-white went
  // missing. OpenStreetMap's standard style counts as light too.
  readonly property bool lightMap: effectiveMapStyle !== "Dark"

  // Qt decides for itself whether a string is markup, and a Text or tooltip in
  // that mode fetches `<img src="http://...">` for real, from inside the shell
  // process. The address comes from Nominatim and the error text from Tesla, so
  // neither is ours to vouch for. The panel's own Text elements are pinned to
  // PlainText; the bar tooltip belongs to the shell and is not ours to set, so
  // anything heading that way has its angle brackets taken off first — without
  // a `<` there is nothing for Qt to mistake for a tag.
  function plain(s) {
    return String(s === undefined || s === null ? "" : s).replace(/[<>]/g, "")
  }

  function cmd(args) {
    var base = [root.script,
                "--park-throttle", String(root.parkThrottleMinutes * 60),
                "--tile-url", root.tileUrl]
    if (root.selectedVin !== "") base = base.concat(["--vin", root.selectedVin])
    return base.concat(args)
  }

  // -------------------------------------------------------------------- state

  // What the free poll last said: "online", "asleep", "offline", or "" before
  // the first answer.
  property string carState: ""
  // `state` supplies these without waking any car, so the selector can be
  // drawn before a full reading is available.
  property string selectedCarName: "Tesla"
  property var availableCars: []
  // The last full reading, from `tesla car`. Null until one lands.
  property var reading: null
  // The tile plan for the position in `reading`.
  property var mapPlan: null
  // Parked line comes pre-joined from `tesla place` (number-first or
  // number-last by the country of the pin). Street and town are kept so a
  // moving car can drop the house number without another lookup.
  property string placeStreet: ""
  property string placeTown: ""
  property string placeParked: ""

  readonly property bool usEnglish: {
    var name = String(Qt.locale().name).replace(/-/g, "_").replace(/\.[^.]+$/, "")
    return name.indexOf("en_US") === 0 || name.indexOf("en_CA") === 0
  }

  // At speed the nearest address changes every second, so the number is
  // dropped and only the road is named. Parked, the script's `place` is the
  // whole line.
  readonly property string place: {
    if (driving)
      return [placeStreet, placeTown].filter(function(part) { return part !== "" }).join(", ")
    return placeParked
  }
  property string errorText: ""
  // The sentence behind the error, when the script has one. Kept apart so the
  // status word in the header can stay two words long while the line at the
  // bottom explains itself.
  property string errorHint: ""

  readonly property bool signedIn: errorText === ""
  readonly property bool hasReading: reading !== null && reading.ok === true
  readonly property bool driving: hasReading && reading.driving === true
  readonly property bool charging: hasReading && reading.charging === "Charging"
  readonly property bool asleep: carState === "asleep" || carState === "offline"

  // Whether the car is being held awake by something that is not this widget.
  // Both cases make it free to ask, and both are cases where the answer is
  // changing, which is the only time a refresh is worth anything.
  readonly property bool awakeAnyway: driving || charging

  readonly property real lat: hasReading && reading.lat !== null ? reading.lat : 0
  readonly property real lon: hasReading && reading.lon !== null ? reading.lon : 0
  readonly property bool hasPosition: hasReading && reading.lat !== null && reading.lon !== null

  // Ticks so the "seen 4 minutes ago" line ages on screen instead of freezing
  // at whatever it said when the panel opened.
  property double now: Date.now()

  Timer {
    interval: 15000
    running: root.opened || root.driving
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  // ------------------------------------------------------------------ the car

  // The free call. This is the only thing that runs on a timer all day, and it
  // never touches the car: Tesla answers it from its own copy of the car's
  // state. Whatever else changes in this file, this has to stay the cheap one.
  Process {
    id: stateProc
    command: root.cmd(["state"])
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try {
          data = JSON.parse(text)
        } catch (e) {
          return
        }
        root.errorText = data.error || ""
        root.errorHint = data.hint || ""
        if (data.ok !== true) return
        if (!data.fixture && root.selectedVin !== ""
            && String(data.vin) !== root.selectedVin) return

        // An empty configured VIN means Tesla's first car. Once it answers,
        // make that choice explicit so every later request and cache lookup is
        // tied to the same car.
        if (root.selectedVin === "") root.selectedVin = String(data.vin)
        root.selectedCarName = data.name || "Tesla"
        root.availableCars = data.vehicles || []

        root.signedProtocol = data.signed === true

        var was = root.carState
        root.carState = data.state

        // A car that has just woken is a car somebody is using, which is
        // exactly when where-is-it stops being a rhetorical question.
        if (was !== "online" && data.state === "online") root.refresh(false)
      }
    }
  }

  Timer {
    interval: Math.max(1, root.statePollMinutes) * 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!stateProc.running) stateProc.running = true
  }

  // The expensive call, and the only place it is made. `force` is the refresh
  // button saying the person in front of the screen would rather have the
  // truth than the battery; everything else goes through the script's throttle.
  Process {
    id: carProc
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try {
          data = JSON.parse(text)
        } catch (e) {
          return
        }
        root.errorText = data.error || ""
        root.errorHint = data.hint || ""
        if (data.ok !== true) return
        if (!data.fixture && data.vin && String(data.vin) !== root.selectedVin) return
        root.reading = data
      }
    }
  }

  function refresh(force) {
    if (carProc.running) return
    carProc.command = root.cmd(force ? ["car", "--force"] : ["car"])
    carProc.running = true
  }

  readonly property bool switchBusy: stateProc.running || carProc.running
    || wakeProc.running || mapProc.running || placeProc.running
    || commandProc.running

  function selectCar(vin, name) {
    vin = String(vin || "")
    if (vin === "" || vin === selectedVin || switchBusy) return

    selectedVin = vin
    selectedCarName = name || "Tesla"
    carState = ""
    reading = null
    mapPlan = null
    placeStreet = ""
    placeTown = ""
    placeParked = ""
    errorText = ""
    errorHint = ""
    commandError = ""
    pendingCommand = ""
    settle.stop()
    mapDebounce.stop()
    placeDebounce.stop()

    stateProc.running = true
    refresh(false)
  }

  // Only while the car is awake on somebody else's account. A parked car gets
  // nothing from here at all, which is the point: fifteen minutes of being
  // left alone is what it needs to go to sleep.
  Timer {
    interval: root.driving ? 15000 : 60000
    running: root.awakeAnyway
    repeat: true
    onTriggered: root.refresh(false)
  }


  // ------------------------------------------------------------------ the map

  Process {
    id: mapProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok === true) root.mapPlan = data
        } catch (e) {
        }
      }
    }
  }

  // Tiles are fetched over the network, so this waits for the position and the
  // panel geometry to settle rather than firing on every pixel of a resize.
  Timer {
    id: mapDebounce
    interval: 250
    onTriggered: {
      if (!root.hasPosition || mapProc.running) return
      var w = Math.round(mapArea.width)
      var h = Math.round(mapArea.height)
      if (w <= 0 || h <= 0) return
      mapProc.command = root.cmd(["map", String(root.lat), String(root.lon),
                                  String(root.mapZoom), String(w), String(h)])
      mapProc.running = true
    }
  }

  function planMap() {
    if (root.opened && root.hasPosition) mapDebounce.restart()
  }

  onMapZoomChanged: planMap()

  // One handler, because QML takes one per signal: opening the panel is both
  // a reason to ask the car and a reason to lay out the map.
  onOpenedChanged: {
    planMap()
    if (!opened) return
    // Opening the panel is a person asking, so it is worth one reading,
    // still subject to the script's throttle, so opening it twice in a
    // minute costs one call, not two.
    refresh(false)
    if (!stateProc.running) stateProc.running = true
  }

  // The position moving is a reason to redraw the map and to look the new
  // spot up by name. Both are debounced, so a drive is not a thousand
  // requests.
  onLatChanged: { planMap(); placeDebounce.restart() }
  onLonChanged: { planMap(); placeDebounce.restart() }

  Process {
    id: placeProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          var ok = data.ok === true
          root.placeStreet = ok ? (data.street || "") : ""
          root.placeTown = ok ? (data.town || "") : ""
          root.placeParked = ok ? (data.place || "") : ""
        } catch (e) {
          root.placeStreet = ""
          root.placeTown = ""
          root.placeParked = ""
        }
      }
    }
  }

  Timer {
    id: placeDebounce
    interval: 400
    onTriggered: {
      if (!root.showAddress || !root.hasPosition || placeProc.running) return
      placeProc.command = root.cmd(["place", String(root.lat), String(root.lon)])
      placeProc.running = true
    }
  }

  onHasPositionChanged: if (hasPosition) placeDebounce.restart()

  // ------------------------------------------------------------------ actions

  Process { id: wakeProc }

  // The only thing in this plugin that wakes a sleeping car, behind a button
  // that only appears when the car is asleep, so it is never something that
  // merely happened.
  function wake() {
    if (wakeProc.running) return
    wakeProc.command = root.cmd(["wake"])
    wakeProc.running = true
    // The car takes a handful of seconds to answer for itself; asking again
    // straight away would just collect another 408.
    wakeTimer.restart()
  }

  Timer {
    id: wakeTimer
    interval: 12000
    onTriggered: {
      if (!stateProc.running) stateProc.running = true
      root.refresh(true)
    }
  }

  Process { id: browserProc }

  function openInMaps() {
    if (!hasPosition) return
    var url = mapsUrl.replace(/\{lat\}/g, String(lat)).replace(/\{lon\}/g, String(lon))
    browserProc.command = ["xdg-open", url]
    browserProc.running = true
    root.close()
  }

  // ----------------------------------------------------------- commanding

  // Reading and commanding are two different relationships with the same car,
  // and they get opposite defaults. A reading is refused to a parked car
  // because nobody asked for it and it costs range. A command is granted and
  // the car is woken to hear it, because somebody pressed a button and a
  // button that silently did nothing would be worse than no button.
  //
  // The script enforces the same thing from its side, so a mistake in this
  // file cannot send a command by accident any more than it can send a read.

  // What is in flight, by the name on the button that started it. Empty means
  // nothing is.
  property string pendingCommand: ""
  // Why the last one did not work, in words worth showing. Cleared the moment
  // another is sent.
  property string commandError: ""

  readonly property bool sentryOn: hasReading && reading.sentry === true
  readonly property bool climateOn: hasReading && reading.climate_on === true
  readonly property bool defrostOn: hasReading && reading.defrost === true
  readonly property bool windowsOpen: hasReading && reading.windows_open === true
  readonly property bool wheelHeaterOn: hasReading && reading.wheel_heater === true
  // A car with no wheel heater reports null rather than false, the same way it
  // does for a seat it has not got. Offering the button anyway would be
  // offering one that can only ever collect a refusal.
  readonly property bool hasWheelHeater:
    hasReading && reading.wheel_heater !== null && reading.wheel_heater !== undefined
  readonly property bool valetOn: hasReading && reading.valet === true
  readonly property bool pluggedIn: hasReading && reading.plugged_in === true
  readonly property bool portOpen: hasReading && reading.charge_port_open === true
  readonly property int keeper: hasReading && reading.climate_keeper !== undefined
    ? Number(reading.climate_keeper) : 0

  // Which controls are offered at all. Off is for anybody who wants the
  // widget to stay a widget that only looks; Everything is the full set.
  readonly property string controlsMode: setting("controls", "Essentials")

  // Whether this car needs its commands signed. Tesla retired the REST command
  // endpoints for everything but pre-2021 Model S and X, and the signed
  // protocol that replaced them has no max defrost, no climate keeper, no
  // HomeLink and no navigation share. Those four are hidden rather than
  // offered as buttons that can only ever apologise.
  property bool signedProtocol: false

  // A control is usable once there is a reading to base its label on. Before
  // that the panel does not know whether the car is locked, and a button that
  // guessed would be a button that locked a car you were trying to open.
  readonly property bool controlsUsable:
    signedIn && hasReading && !commandProc.running

  // Only the seats this car reports. A null is a seat with no heater in it,
  // and Tesla reports one for every position the model could have had.
  readonly property var seatList: {
    if (!hasReading || !reading.seats) return []
    var names = [["front-left", "FL", "Front left"],
                 ["front-right", "FR", "Front right"],
                 ["rear-left", "RL", "Rear left"],
                 ["rear-center", "RC", "Rear centre"],
                 ["rear-right", "RR", "Rear right"]]
    var out = []
    for (var i = 0; i < names.length; i++) {
      var level = reading.seats[names[i][0]]
      if (level === null || level === undefined) continue
      out.push({key: names[i][0], short: names[i][1], name: names[i][2],
                level: Number(level)})
    }
    return out
  }

  Process {
    id: commandProc
    stdout: StdioCollector {
      onStreamFinished: {
        var data
        try {
          data = JSON.parse(text)
        } catch (e) {
          root.pendingCommand = ""
          root.commandError = "the car did not answer"
          return
        }

        root.pendingCommand = ""
        // The hint is the sentence a person can act on; the error is Tesla's
        // own word for it, which is often a snake_case token. Prefer the hint
        // and fall back to the token, because a token is still better than a
        // button that failed silently.
        root.commandError = data.ok === true
          ? "" : root.plain(data.hint || data.error || "the car refused")

        // The car is awake — the command woke it — and it is no longer the car
        // the last reading describes. This is the one place a full read is
        // worth forcing: the throttle exists to let a parked car sleep, and
        // this car is not going to sleep for another quarter of an hour
        // whatever we do now.
        if (data.ok === true) settle.restart()
      }
    }
  }

  // Not straight away. Tesla accepts the command before the car has finished
  // doing it, so a reading taken immediately shows the old state and the panel
  // spends three seconds insisting nothing happened.
  Timer {
    id: settle
    interval: 4000
    onTriggered: {
      if (!stateProc.running) stateProc.running = true
      root.refresh(true)
    }
  }

  function act(label, args) {
    if (commandProc.running) return
    root.commandError = ""
    root.pendingCommand = String(label || "")
    commandProc.command = root.cmd(args)
    commandProc.running = true
  }

  // The two steppers. Both work in the units on the screen and both clamp to
  // what the car will accept, so holding a button at either end is a no-op
  // rather than a queue of refusals.
  function setTemp(delta) {
    if (!hasReading || reading.climate_setpoint === null) return
    var unit = String(reading.temp_unit || "").slice(-1)
    var next = Number(reading.climate_setpoint) + delta
    // The car's own limits, in each unit. Below the floor it does nothing and
    // above the ceiling it does nothing, so there is no sense sending either.
    var low = unit === "F" ? 59 : 15
    var high = unit === "F" ? 82 : 28
    if (next < low || next > high) return
    root.act("Cabin " + next + "°", ["temp", String(next) + unit])
  }

  function setLimit(delta) {
    if (!hasReading || reading.charge_limit === null) return
    var next = Number(reading.charge_limit) + delta
    if (next < 50 || next > 100) return
    root.act("Charge limit " + next + "%", ["limit", String(next)])
  }

  // ------------------------------------------------------------------ wording

  // There is no compass anywhere in words. Which way the car is pointing is
  // worth a glance and not a sentence, so the marker on the map carries it and
  // nothing repeats it underneath.

  function agoOf(seconds) {
    var s = Math.max(0, Math.round(seconds))
    if (s < 45) return "just now"
    if (s < 90) return "a minute ago"
    if (s < 3600) return Math.round(s / 60) + " minutes ago"
    if (s < 7200) return "an hour ago"
    if (s < 86400) return Math.round(s / 3600) + " hours ago"
    if (s < 172800) return "yesterday"
    return Math.round(s / 86400) + " days ago"
  }

  readonly property real readingAge: hasReading ? Math.max(0, now / 1000 - reading.at) : 0
  // Old enough that the map should stop looking authoritative. An hour is
  // about when "it is probably still there" turns into "it was there".
  readonly property bool stale: readingAge > 3600

  // The name Tesla has on file, when somebody set one. Otherwise what the car
  // is rather than a name nobody chose: "MODEL S 100D" beats "TESLA" for a car
  // that was never named. `state` supplies the name before any reading lands,
  // so the selector can be drawn without waking anything; the reading is what
  // knows the model, so it refines the answer once it arrives.
  readonly property string carName: {
    if (selectedCarName !== "" && selectedCarName !== "Tesla") return selectedCarName
    if (!hasReading) return selectedCarName || "Tesla"
    if (reading.name && reading.name !== "Tesla") return reading.name
    var type = String(reading.car_type || "")
    var model = type.indexOf("models") === 0 ? "Model S"
              : type.indexOf("modelx") === 0 ? "Model X"
              : type.indexOf("model3") === 0 ? "Model 3"
              : type.indexOf("modely") === 0 ? "Model Y"
              : "Tesla"
    return reading.trim ? model + " " + String(reading.trim).toUpperCase() : model
  }

  readonly property string stateWord: {
    if (errorText !== "") return errorText
    if (driving) return "driving"
    if (charging) return "charging"
    if (carState === "") return "checking"
    return carState
  }

  // The one-line answer to the question in the plugin's name.
  readonly property string summary: {
    if (!hasReading) return errorText !== "" ? errorText : "No reading yet"
    var doing = driving
      ? (reading.speed === null ? "Driving" : "Driving " + reading.speed + " " + reading.speed_unit)
      : charging
        ? (reading.charger_power ? "Charging at " + Math.round(reading.charger_power) + " kW" : "Charging")
        : "Parked"
    // Everything on this panel came out of one reading, so how old that
    // reading is belongs on the line that is already about when, rather than
    // stranded at the bottom under a list it appears to be part of.
    return doing + " · fetched " + agoOf(readingAge)
  }

  // Doors, boot and windows, as one sentence, and only when there is one to
  // make. Nearly always empty, which is exactly what earns it a place: a line
  // that is usually absent gets read on the day it appears.
  readonly property string openText: {
    if (!hasReading || !reading.open || reading.open.length === 0) return ""
    var items = reading.open.map(function(item) {
      return (root.usEnglish && item === "the boot") ? "the trunk" : item
    })
    var list = items.length === 1
      ? items[0]
      : items.slice(0, -1).join(", ") + " and " + items[items.length - 1]
    return list.charAt(0).toUpperCase() + list.slice(1)
      + (items.length === 1 ? " is open" : " are open")
  }

  // Where it is going, when it is going somewhere. A route set on a parked car
  // is not a journey, so this only speaks while the car is moving; the rest of
  // the time the panel has nothing to say about the future and says nothing.
  readonly property bool navigating:
    driving && hasReading && reading.destination && reading.eta

  // The locale's own short time, with the seconds taken out of the pattern
  // rather than out of the string: some locales put them in ShortFormat and
  // some do not, and an arrival is not a number you read to the second. Taking
  // them from the pattern leaves everything else the locale asked for, the
  // twelve-hour clock and its AM included.
  readonly property string clockFormat:
    Qt.locale().timeFormat(Locale.ShortFormat).replace(/[.:]?\bs+\b/g, "")

  // "Home at 19:48 · 2.6 km". The clock time rather than "in six
  // minutes", because arriving is something you meet the car at, and a time is
  // what you compare against the one on your own wrist.
  readonly property string etaText: {
    if (!navigating) return ""
    var parts = [reading.destination + " at "
                 + Qt.formatTime(new Date(reading.eta * 1000), clockFormat)]
    if (reading.eta_distance !== null && reading.eta_distance !== undefined)
      parts.push(reading.eta_distance + " " + reading.range_unit)
    if (reading.eta_delay) parts.push(reading.eta_delay + " min of traffic")
    return parts.join(" · ")
  }

  readonly property string barSpeed:
    driving && reading.speed !== null ? reading.speed + " " + reading.speed_unit : ""

  // --------------------------------------------------------------------- bar

  // The bar is the mark and nothing else. An earlier version slid the speed in
  // beside it while the car was moving, which made the bar shuffle every time
  // a car pulled away. A lot of movement in the corner of your eye to say
  // something the panel says better. The colour carries it instead.
  // vic: the remaining range is the bar item, as "183" (the unit is in the
  // tooltip and the panel; the bar is for the number you glance at), in the same
  // cell style the shell's battery widget uses for its percentage. It is the
  // last reading the panel already holds, so it costs the car nothing extra;
  // it is blank until a reading exists and ages with it. `showRange` turns it
  // off for anyone who wants the mark alone, as upstream ships it.
  readonly property bool showRange: setting("showRange", true)
  readonly property string barRange:
    showRange && hasReading && reading.range !== null && reading.range !== undefined
      ? String(Math.round(reading.range))
      : ""

  implicitWidth: barRow.implicitWidth
  implicitHeight: button.implicitHeight

  Row {
    id: barRow
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    spacing: 0

  BarIconButton {
    id: button
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar
    // vic: the number is the widget. The mark only stands in while there is
    // no reading to show (first start, signed out), so there is always
    // something in the bar to click.
    visible: root.barRange === ""

    iconComponent: Component {
      TeslaMark {
        iconSize: Style.bar.iconFont
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }
    }

    // Three states and no more: green while the car is moving, plain while it
    // is parked and awake, dimmed while it sleeps. The mark is monochrome the
    // rest of the time on purpose, because a bar full of coloured glyphs is a
    // bar you stop reading.
    active: root.driving
    // Green rather than the shell's urgent red, which is what WidgetButton
    // reaches for by default. A car being driven is the ordinary use of a car,
    // not an alarm, and this is the same green as the panel's live dot so the
    // two agree about what it means.
    activeColor: root.liveGreen
    dimmed: root.asleep || root.errorText !== ""
    tooltipText: {
      if (root.errorText !== "") return root.plain("Dude, where's my car? " + root.errorText)
      if (!root.hasReading) return root.plain(root.carName)
      if (root.driving) return root.plain(root.carName + ": " + root.summary)
      if (root.place !== "") return root.plain(root.carName + ": parked at " + root.place)
      return root.plain(root.carName + ": " + root.summary)
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        root.openInMaps()
        return
      }
      root.toggle()
    }
  }

  // The number. Same colour rules as the mark so the two read as one widget:
  // green while driving, dimmed while asleep. Its own cell rather than text
  // inside the icon slot because the mark is a Shape, not a glyph, and the
  // shell's icon button only knows how to typeset one or the other.
  WidgetButton {
    id: rangeLabel
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar
    text: root.barRange
    fontSize: Style.font.bodySmall
    horizontalMargin: 6
    active: root.driving
    activeColor: root.liveGreen
    dimmed: root.asleep || root.errorText !== ""
    tooltipText: button.tooltipText
    onPressed: function(b) { button.pressed(b) }
  }
  }

  // ------------------------------------------------------------------- panel

  PopupCard {
    id: popup
    anchorItem: root.barRange !== "" ? rangeLabel : button
    bar: root.bar
    owner: root
    open: root.opened
    // Click, not hover: opening this fetches map tiles and possibly asks the
    // car for a reading, so it should happen because you meant it rather than
    // because the cursor crossed the bar.
    triggerMode: "click"
    contentWidth: popup.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      anchors.fill: parent
      // Generous on purpose. This panel is read in glances rather than
      // scanned, and every section in it answers a different question, so
      // they want visible daylight between them rather than a tidy list.
      spacing: Style.space(12)

      // ------------------------------------------------------------- header

      Item {
        width: parent.width
        height: Math.max(title.implicitHeight, badge.height)

        // The plugin is called Tesla everywhere it is listed, because that is
        // what you look for when you go hunting for it. The joke is here, at
        // the top of the panel, where it is the actual question being asked.
        // Which car it is about is the selector's job, and the selector is
        // only there when the answer is not obvious.
        PanelSectionHeader {
          id: title
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "DUDE, WHERE'S MY CAR?"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: badge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          // No model name here. The panel is about one specific car and
          // naming it on every glance is noise; the bar's tooltip says which
          // one on the rare occasion that is the question.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: width
            radius: width / 2
            // Green for reachable, whatever it is doing: driving and
            // charging are both online, and the word beside the dot already
            // says which. The dot answers one question only: is the car
            // there to be asked.
            color: root.errorText !== "" ? Color.urgent
                 : root.asleep ? Color.muted
                 : root.carState === "" ? root.foreground
                 : root.charging ? root.chargeRed
                 : root.liveGreen
            opacity: root.asleep ? 0.7 : 1
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            text: root.stateWord
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.7
          }
        }
      }

      Row {
        id: carSelector
        visible: root.availableCars.length > 1
        width: parent.width
        spacing: Style.space(6)

        readonly property real buttonWidth: root.availableCars.length > 0
          ? (width - spacing * (root.availableCars.length - 1)) / root.availableCars.length
          : 0

        Repeater {
          model: root.availableCars

          Button {
            required property var modelData

            width: carSelector.buttonWidth
            text: modelData.name || "Tesla"
            tooltipText: "VIN " + modelData.vin
            selected: String(modelData.vin) === root.selectedVin
            enabled: !root.switchBusy
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.selectCar(modelData.vin, modelData.name)
          }
        }
      }

      // ---------------------------------------------------------------- map

      Rectangle {
        id: mapArea
        width: parent.width
        // Three to two rather than sixteen to nine. A map is read outwards
        // from the middle, so at a narrow width the wide aspect spends the
        // panel on horizon and leaves you two streets of context; the squarer
        // one shows the block the car is parked on.
        height: Math.round(width * 2 / 3)
        radius: Style.space(6)
        color: Qt.rgba(0, 0, 0, 0.35)
        clip: true

        MapView {
          anchors.fill: parent
          plan: root.mapPlan
          lightMap: root.lightMap
          heading: root.hasReading && root.reading.heading !== null ? root.reading.heading : 0
          driving: root.driving
          stale: root.stale
          foreground: root.foreground
          accent: root.liveAccent
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: !root.hasPosition
          text: root.errorText !== "" ? root.errorText
              : root.hasReading ? "The car is not sharing its location"
              : "Waiting for the car"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.6
        }

        // The map is the link. Where the car is and wanting to go there are
        // the same thought, so there is nothing to aim at but what you are
        // already looking at.
        MouseArea {
          anchors.fill: parent
          enabled: root.hasPosition
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openInMaps()
        }

        // No speed badge here any more. It said what the line under the map
        // already says and what the status word above it already implies, and
        // it did so on top of the one thing in the panel worth looking at.
      }

      // -------------------------------------------------------------- where

      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.place !== ""
          text: root.place
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          color: root.foreground
        }

        // Above the summary rather than below it: the summary ends in how old
        // the reading is, which is the last thing on the panel worth reading
        // and so belongs last.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.etaText !== ""
          text: root.etaText
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.liveAccent
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.summary
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.foreground
          opacity: 0.65
        }
      }

      PanelSeparator { width: parent.width }

      // -------------------------------------------------------------- stats

      // Battery and range at the two ends of one line, with the bar spanning
      // both underneath. Three columns of figures was the first arrangement
      // and it only worked while the panel was wide: narrow it and each column
      // is too tight to hold a big number and its unit without them colliding.
      // Two figures and a full-width bar survives being made small, and reads
      // better wide as well.
      // The three read as one thing, so they are spaced as one thing. Left to
      // the panel's own rhythm the figures floated a long way above their own
      // bar and the block came apart.
      Column {
        width: parent.width
        spacing: Style.space(4)

        // The bar first and the numbers under it. They used to sit above at
        // display size, which made the battery the loudest thing on a panel
        // whose subject is where the car is. The bar already carries the
        // reading at a glance; the figures are there to be precise, not to
        // shout.
        Rectangle {
          width: parent.width
          height: Style.space(6)
          radius: height / 2
          color: Qt.rgba(1, 1, 1, 0.12)

          Rectangle {
            width: parent.width * Math.max(0, Math.min(1,
              (root.hasReading && root.reading.battery !== null ? root.reading.battery : 0) / 100))
            height: parent.height
            radius: parent.radius
            color: root.charging ? root.chargeRed : root.foreground
            opacity: root.charging ? 1 : 0.8

            Behavior on width {
              NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
            }
          }

          // The charge limit is a notch rather than a third number on the
          // line below: what you read off a bar is how far the fill is from
          // the line, and the line only needs naming once.
          Rectangle {
            visible: root.hasReading && root.reading.charge_limit !== null
            x: parent.width * Math.max(0, Math.min(1,
              (root.hasReading && root.reading.charge_limit !== null ? root.reading.charge_limit : 100) / 100))
              - width / 2
            width: Math.max(1, Style.space(2))
            height: parent.height
            color: root.foreground
            opacity: 0.5
          }
        }

        // Charge on the left, what it is heading for in the middle, range on
        // the right. The three ends of the same sentence, under the bar that
        // draws it.
        Item {
          width: parent.width
          height: batteryLabel.implicitHeight

          Text {
            textFormat: Text.PlainText
            id: batteryLabel
            anchors.left: parent.left
            text: root.hasReading && root.reading.battery !== null
              ? root.reading.battery + "%" : "\u2014"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
          }

          // Nothing in the middle. The charge limit lived here, centred
          // between two aligned figures, which made it read as a third
          // unrelated item and shifted about as the numbers changed width.
          // The notch on the bar shows it, and the details grid names it.

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            text: root.hasReading && root.reading.range !== null
              ? Math.round(root.reading.range) + " " + root.reading.range_unit : "\u2014"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
          }
        }
      }

      PanelSeparator { width: parent.width }

      // ------------------------------------------------------------ details

      // The things you look up rather than watch. Two columns of label-over-
      // value, because a label beside its value needs a leader line to stay
      // readable at this width and a label above it needs nothing at all.
      Grid {
        id: detailGrid
        width: parent.width
        columns: 2
        columnSpacing: Style.space(8)
        rowSpacing: Style.space(10)

        // Ordered by what you came for. Locked is what you check when you
        // cannot find the car; software is trivia. Left as eight cells of
        // equal weight in no particular order, nothing stood out because
        // everything looked equally worth reading. Pairs are kept together
        // across each row so the two halves explain each other.
        Detail {
          label: "locked"
          value: !root.hasReading ? "\u2014" : root.reading.locked ? "yes" : "no"
        }

        Detail {
          label: "sentry"
          value: !root.hasReading ? "\u2014" : root.reading.sentry ? "on" : "off"
        }

        Detail {
          label: "odometer"
          value: root.hasReading && root.reading.odometer !== null
            ? Number(root.reading.odometer).toLocaleString(Qt.locale(), "f", 0)
              + " " + root.reading.range_unit
            : "\u2014"
        }

        Detail {
          label: root.usEnglish ? "tires" : "tyres"
          // A range rather than four numbers: what you act on is the lowest
          // one, and what tells you something is wrong is the spread.
          value: {
            if (!root.hasReading || !root.reading.tyres) return "\u2014"
            var t = root.reading.tyres
            var span = t.min === t.max ? String(t.min) : t.min + "\u2013" + t.max
            return span + " " + root.reading.tyre_unit
          }
        }

        Detail {
          label: "inside"
          value: root.hasReading && root.reading.inside_temp !== null
            ? root.reading.inside_temp + " " + root.reading.temp_unit : "\u2014"
        }

        Detail {
          label: "outside"
          value: root.hasReading && root.reading.outside_temp !== null
            ? root.reading.outside_temp + " " + root.reading.temp_unit : "\u2014"
        }

        Detail {
          label: "charge limit"
          value: root.hasReading && root.reading.charge_limit !== null
            ? root.reading.charge_limit + "%" : "\u2014"
        }

        Detail {
          label: "last charge"
          value: root.hasReading && root.reading.energy_added !== null
            ? Math.round((root.reading.energy_added || 0) * 10) / 10 + " kWh" : "\u2014"
        }

        Detail {
          label: "climate"
          value: !root.hasReading ? "\u2014" : root.reading.climate_on ? "on" : "off"
        }

        Detail {
          label: "software"
          value: root.hasReading && root.reading.software ? root.reading.software : "\u2014"
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.openText !== ""
        text: root.openText
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.urgent
      }

      // ----------------------------------------------------------- controls

      // Every control here is a verb. The button says what pressing it will
      // do, not what the car is currently doing — the grid above already says
      // that, and a row of switches that duplicate it is a row of switches you
      // have to read twice to work out which way round they are. "Unlock"
      // means the car is locked; the word for the state is four lines up.
      //
      // Nothing in this section runs on a timer, and nothing here happens
      // because the panel opened. Every call underneath wakes the car, which
      // is the right trade for a button somebody pressed and the wrong one for
      // anything else.

      PanelSeparator {
        width: parent.width
        visible: controls.visible
      }

      Column {
        id: controls
        width: parent.width
        spacing: Style.space(8)
        visible: root.controlsMode !== "Off" && root.signedIn

        Grid {
          id: controlGrid
          width: parent.width
          columns: 3
          columnSpacing: Style.space(6)
          rowSpacing: Style.space(6)

          readonly property int cellWidth:
            Math.floor((width - columnSpacing * (columns - 1)) / columns)

          // The two you came for. A car you cannot find is a car you want to
          // lock, and a car you have just parked somewhere unfamiliar is one
          // you want watching itself.
          Control {
            action: root.reading && root.reading.locked === false ? "Lock" : "Unlock"
            tooltipText: "Wakes the car"
            onClicked: root.act(action,
              [root.reading && root.reading.locked === false ? "lock" : "unlock"])
          }

          Control {
            action: root.sentryOn ? "Sentry off" : "Sentry on"
            onClicked: root.act(action, ["sentry", root.sentryOn ? "off" : "on"])
          }

          Control {
            action: root.climateOn ? "Climate off" : "Climate on"
            onClicked: root.act(action, ["climate", root.climateOn ? "off" : "on"])
          }

          // Vent and close are one button because the windows are one thing:
          // they are either sealed or they are not, and whichever they are,
          // there is only one useful thing to do about it.
          Control {
            action: root.windowsOpen ? "Close windows" : "Vent windows"
            tooltipText: root.windowsOpen
              ? "Only works within a few hundred metres of the car"
              : "Wakes the car"
            onClicked: root.act(action, ["windows", root.windowsOpen ? "close" : "vent"])
          }

          Control {
            action: "Frunk"
            onClicked: root.act(action, ["frunk"])
          }

          Control {
            // A Model 3 lid opens and closes on the same command; on an S or
            // an X it does too. One word covers it.
            action: root.usEnglish ? "Trunk" : "Boot"
            onClicked: root.act(action, ["trunk"])
          }

          // Finding the car in a car park, in the two ways a car can announce
          // itself. Flash first: it is the one you can use at night without
          // apologising to anybody.
          Control {
            action: "Flash"
            onClicked: root.act(action, ["flash"])
          }

          Control {
            action: "Honk"
            onClicked: root.act(action, ["horn"])
          }

          Control {
            visible: !root.signedProtocol
            action: root.defrostOn ? "Defrost off" : "Defrost"
            tooltipText: "Max defrost, front and rear"
            onClicked: root.act(action, ["defrost", root.defrostOn ? "off" : "on"])
          }
        }

        // -------------------------------------------------------- the cabin

        // A setpoint is not a toggle, and the two do not belong in the same
        // grid. Minus, the number, plus: the number is the control and the
        // buttons are its ends, which is how every thermostat has worked since
        // thermostats had buttons.
        Stepper {
          width: parent.width
          label: "cabin"
          visible: root.hasReading && root.reading.climate_setpoint !== null
          value: root.hasReading && root.reading.climate_setpoint !== null
            ? root.reading.climate_setpoint + " " + root.reading.temp_unit : "—"
          // One degree on the screen, whichever screen it is. A Fahrenheit car
          // steps a whole degree F and a Celsius one a whole degree C, because
          // stepping half of somebody else's unit is how you end up at 21.5
          // when you asked for 22.
          onDown: root.setTemp(-1)
          onUp: root.setTemp(1)
        }

        // The seat heaters that this car actually has. A Model 3 without rear
        // heaters reports null for them and gets no buttons, rather than three
        // that do nothing.
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.controlsMode === "Everything"
            && (root.seatList.length > 0 || root.hasWheelHeater)

          Text {
            textFormat: Text.PlainText
            text: "seats"
            width: Style.space(46)
            anchors.verticalCenter: parent.verticalCenter
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.5
          }

          Repeater {
            model: root.seatList

            // Each press is one step warmer, and 3 wraps round to off. Four
            // levels is few enough that cycling beats a menu, and a seat
            // heater is something you adjust by feel anyway.
            Button {
              required property var modelData
              width: Style.space(52)
              text: modelData.short + " " + modelData.level
              tooltipText: modelData.name + ": " + modelData.level + " of 3"
              bordered: true
              enabled: root.controlsUsable
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.act(modelData.name,
                ["seat", modelData.key, String((modelData.level + 1) % 4)])
            }
          }

          Button {
            width: Style.space(64)
            visible: root.hasWheelHeater
            text: root.wheelHeaterOn ? "wheel ●" : "wheel"
            tooltipText: "Steering wheel heater"
            bordered: true
            enabled: root.controlsUsable
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.act("Wheel heater",
              ["wheel", root.wheelHeaterOn ? "off" : "on"])
          }
        }

        // ------------------------------------------------------- the charge

        Stepper {
          width: parent.width
          label: "charge limit"
          visible: root.hasReading && root.reading.charge_limit !== null
          value: root.hasReading && root.reading.charge_limit !== null
            ? root.reading.charge_limit + "%" : "—"
          // Five at a time. Nobody has ever wanted 81%.
          onDown: root.setLimit(-5)
          onUp: root.setLimit(5)
        }

        Grid {
          width: parent.width
          columns: 3
          columnSpacing: Style.space(6)
          rowSpacing: Style.space(6)
          visible: root.controlsMode === "Everything"

          // Starting a charge means nothing without a cable, and Tesla says so
          // in a word nobody would recognise. Better not to offer it.
          Control {
            action: root.charging ? "Stop charge" : "Start charge"
            enabled: root.controlsUsable && root.pluggedIn
            tooltipText: root.pluggedIn ? "" : "Nothing is plugged in"
            onClicked: root.act(action, ["charge", root.charging ? "stop" : "start"])
          }

          Control {
            action: root.portOpen ? "Close port" : "Open port"
            onClicked: root.act(action, ["port", root.portOpen ? "close" : "open"])
          }

          Control {
            visible: !root.signedProtocol
            action: "Garage"
            tooltipText: "HomeLink, if the car is parked by the door it is paired with"
            onClicked: root.act(action, ["homelink"])
          }

          // The two the car will hold the cabin for while you are not in it.
          // Both are the same switch from Tesla's side, so turning one on
          // turns the other off, and the labels say which is running.
          Control {
            visible: !root.signedProtocol
            action: root.keeper === 2 ? "Dog off" : "Dog mode"
            onClicked: root.act(action, ["keeper", root.keeper === 2 ? "off" : "dog"])
          }

          Control {
            visible: !root.signedProtocol
            action: root.keeper === 3 ? "Camp off" : "Camp mode"
            onClicked: root.act(action, ["keeper", root.keeper === 3 ? "off" : "camp"])
          }

          Control {
            action: root.valetOn ? "Valet off" : "Valet"
            tooltipText: "Limits speed and power, and locks the boot and the glovebox"
            onClicked: root.act(action, ["valet", root.valetOn ? "off" : "on"])
          }
        }

        // What just happened, or what just would not. One line, under the
        // controls rather than over them, so the panel does not jump when it
        // appears.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: text !== ""
          text: {
            if (commandProc.running) return root.plain(root.pendingCommand) + "…"
            if (root.commandError !== "") return root.plain(root.commandError)
            return ""
          }
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: root.commandError !== "" && !commandProc.running
            ? Color.urgent : root.foreground
          opacity: root.commandError !== "" && !commandProc.running ? 1.0 : 0.6
        }
      }

      PanelSeparator { width: parent.width }

      // ------------------------------------------------------------ actions

      Row {
        id: actions
        width: parent.width
        spacing: Style.space(6)

        // Split evenly rather than sized to their labels: at this width three
        // buttons hugging their text leave a ragged gap on the right, and a
        // row of equal buttons is easier to hit besides.
        readonly property int count: root.asleep ? 3 : 2
        readonly property int buttonWidth:
          Math.floor((width - Style.space(6) * (count - 1)) / count)

        Button {
          width: actions.buttonWidth
          text: "Open in maps"
          enabled: root.hasPosition
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.openInMaps()
        }

        Button {
          // The cost goes in the tooltip rather than the label, and in as few
          // words as it takes: a tooltip long enough to be a sentence is one
          // nobody finishes. "Keeps awake" rather than "wakes" because that is
          // what happens: the button is disabled while the car is asleep, and
          // the call behind it could not wake one if it were not.
          width: actions.buttonWidth
          text: carProc.running ? "Asking\u2026" : "Refresh"
          tooltipText: "Keeps the car awake ~15 min"
          enabled: !carProc.running && !root.asleep
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.refresh(true)
        }

        Button {
          // Only offered when there is something to wake, so the call that
          // costs battery is never one click away from the call that does not.
          visible: root.asleep
          width: actions.buttonWidth
          text: wakeProc.running ? "Waking\u2026" : "Wake"
          enabled: !wakeProc.running
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.wake()
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.errorText !== ""
        text: root.errorText === "not signed in"
          ? "Run  tesla login  once, in a terminal."
          : root.errorHint !== "" ? root.errorHint : root.errorText
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: 0.6
      }
    }
  }

  // A control is a button that says what pressing it will do. The state it
  // reads off lives in the grid above it, so the two never have to be reconciled
  // in your head: one is the noun, the other is the verb.
  component Control: Button {
    property string action: ""

    width: controlGrid.cellWidth
    text: action
    bordered: true
    enabled: root.controlsUsable
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  // A number with an end at each side. Wider than a pair of buttons needs to
  // be, because the number is the thing being read and the buttons are only
  // how you change it.
  component Stepper: Item {
    id: stepper
    property string label: ""
    property string value: ""
    signal down()
    signal up()

    implicitHeight: stepperRow.implicitHeight
    height: implicitHeight

    Row {
      id: stepperRow
      width: parent.width
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: stepper.label
        width: Style.space(80)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: 0.5
      }

      Button {
        width: Style.space(40)
        text: "−"
        bordered: true
        enabled: root.controlsUsable
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: stepper.down()
      }

      Text {
        textFormat: Text.PlainText
        text: stepper.value
        width: Style.space(70)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignHCenter
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        color: root.foreground
      }

      Button {
        width: Style.space(40)
        text: "+"
        bordered: true
        enabled: root.controlsUsable
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: stepper.up()
      }
    }
  }

  // One looked-up fact: what it is, small and quiet, with the answer under it.
  component Detail: Column {
    property string label: ""
    property string value: ""

    width: Math.floor((detailGrid.width - Style.space(8)) / 2)
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      text: label
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.foreground
      opacity: 0.5
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: value
      elide: Text.ElideRight
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      color: root.foreground
    }
  }

  // Lets the panel be exercised without driving anywhere:
  //
  //   omarchy-shell jankeesvw.tesla.test drive 87 243
  //   omarchy-shell jankeesvw.tesla.test park
  //   omarchy-shell jankeesvw.tesla.test sleep
  //   omarchy-shell jankeesvw.tesla.test live
  //
  // Synthetic input does not reach this shell, so a test hook is the only way
  // to see what a moving car looks like without one.
  IpcHandler {
    target: "jankeesvw.tesla.test"

    function drive(speed: int, heading: int): string {
      if (!root.hasReading) return "no reading to base a drive on yet"
      var next = JSON.parse(JSON.stringify(root.reading))
      next.driving = true
      next.shift = "D"
      next.speed = speed
      next.heading = heading
      next.at = Math.round(Date.now() / 1000)
      root.carState = "online"
      root.reading = next
      return "driving " + speed + " " + next.speed_unit + " heading " + heading
    }

    // A route on top of whatever the panel is showing. Only visible while the
    // car is driving, so this is `drive` and then this, in that order.
    function navigate(destination: string, minutes: int): string {
      if (!root.hasReading) return "no reading to navigate from yet"
      var next = JSON.parse(JSON.stringify(root.reading))
      next.destination = destination
      next.eta = Math.round(Date.now() / 1000) + minutes * 60
      next.at = Math.round(Date.now() / 1000)
      root.carState = "online"
      root.reading = next
      return "arriving at " + destination + " in " + minutes + " minutes"
    }

    function park(): string {
      if (!root.hasReading) return "no reading to park yet"
      var next = JSON.parse(JSON.stringify(root.reading))
      next.driving = false
      next.shift = "P"
      next.speed = null
      next.destination = null
      next.eta = null
      next.at = Math.round(Date.now() / 1000)
      root.carState = "online"
      root.reading = next
      return "parked"
    }

    function sleep(): string {
      root.carState = "asleep"
      return "asleep"
    }

    // Back to whatever the car actually says, so a test never leaves the panel
    // lying about a real car.
    function live(): string {
      if (!stateProc.running) stateProc.running = true
      root.refresh(true)
      return "refreshing"
    }
  }
}
