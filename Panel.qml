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
  // start reading as decoration. It is used on the panel's status dot only,
  // the bar stays monochrome.
  readonly property color liveGreen: "#4caf50"

  // ----------------------------------------------------------------- settings

  readonly property string vin: setting("vin", "")
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

  function cmd(args) {
    var base = [root.script,
                "--park-throttle", String(root.parkThrottleMinutes * 60),
                "--tile-url", root.tileUrl]
    if (root.vin !== "") base = base.concat(["--vin", root.vin])
    return base.concat(args)
  }

  // -------------------------------------------------------------------- state

  // What the free poll last said: "online", "asleep", "offline", or "" before
  // the first answer.
  property string carState: ""
  // The last full reading, from `tesla car`. Null until one lands.
  property var reading: null
  // The tile plan for the position in `reading`.
  property var mapPlan: null
  // The position in `reading`, as a street and a town. Kept in parts, because
  // the house number is worth having when the car is parked and noise when it
  // is moving.
  property string placeStreet: ""
  property string placeNumber: ""
  property string placeTown: ""

  // At speed the nearest address changes every second, so the number is
  // dropped and only the road is named: "De Hees, Kronenberg" holds still
  // while "De Hees 39" flickers through the whole street.
  readonly property string place: {
    if (placeStreet === "" && placeTown === "") return ""
    var head = placeStreet
    if (!driving && placeNumber !== "" && head !== "") head += " " + placeNumber
    return [head, placeTown].filter(function(part) { return part !== "" }).join(", ")
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
        // Read before the ok check, because `car` can succeed at showing you
        // the last known position and still have something to report about
        // why it is the last known one.
        root.errorText = data.error || ""
        root.errorHint = data.hint || ""
        if (data.ok !== true) return

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
        root.reading = data
      }
    }
  }

  function refresh(force) {
    if (carProc.running) return
    carProc.command = root.cmd(force ? ["car", "--force"] : ["car"])
    carProc.running = true
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
          root.placeNumber = ok ? (data.number || "") : ""
          root.placeTown = ok ? (data.town || "") : ""
        } catch (e) {
          root.placeStreet = ""
          root.placeNumber = ""
          root.placeTown = ""
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

  readonly property string carName: {
    if (!hasReading) return "Tesla"
    if (reading.name && reading.name !== "Tesla") return reading.name
    // Falls back to what the car is rather than a name nobody set: "MODEL S
    // 100D" beats "TESLA" at the top of a panel about one specific car.
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
    var items = reading.open
    var list = items.length === 1
      ? items[0]
      : items.slice(0, -1).join(", ") + " and " + items[items.length - 1]
    return list.charAt(0).toUpperCase() + list.slice(1)
      + (items.length === 1 ? " is open" : " are open")
  }

  readonly property string barSpeed:
    driving && reading.speed !== null ? reading.speed + " " + reading.speed_unit : ""

  // --------------------------------------------------------------------- bar

  // The bar is the mark and nothing else. An earlier version slid the speed in
  // beside it while the car was moving, which made the bar shuffle every time
  // a car pulled away. A lot of movement in the corner of your eye to say
  // something the panel says better. The colour carries it instead.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar

    iconComponent: Component {
      TeslaMark {
        iconSize: Style.bar.iconFont
        color: button.foreground
      }
    }

    // No colour, ever. A coloured glyph in a bar full of monochrome ones is
    // a permanent small distraction, and a car being driven is not news you
    // need shouted at you. It is news you go and look for. Asleep dims, and
    // that is the whole vocabulary.
    dimmed: root.asleep || root.errorText !== ""
    tooltipText: {
      if (root.errorText !== "") return "Dude, where's my car? " + root.errorText
      if (!root.hasReading) return "Dude, where's my car?"
      if (root.driving) return root.summary
      if (root.place !== "") return "Parked at " + root.place
      return root.summary
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        root.openInMaps()
        return
      }
      root.toggle()
    }
  }

  // ------------------------------------------------------------------- panel

  PopupCard {
    id: popup
    anchorItem: button
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
                 : root.liveGreen
            opacity: root.asleep ? 0.7 : 1
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.stateWord
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.7
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
          accent: root.accent
          fontFamily: root.fontFamily
        }

        Text {
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
          width: parent.width
          visible: root.place !== ""
          text: root.place
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          color: root.foreground
        }

        Text {
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
            color: root.charging ? root.accent : root.foreground
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
          label: "tyres"
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
        width: parent.width
        visible: root.openText !== ""
        text: root.openText
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.urgent
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

  // One looked-up fact: what it is, small and quiet, with the answer under it.
  component Detail: Column {
    property string label: ""
    property string value: ""

    width: Math.floor((detailGrid.width - Style.space(8)) / 2)
    spacing: Style.space(2)

    Text {
      text: label
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.foreground
      opacity: 0.5
    }

    Text {
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

    function park(): string {
      if (!root.hasReading) return "no reading to park yet"
      var next = JSON.parse(JSON.stringify(root.reading))
      next.driving = false
      next.shift = "P"
      next.speed = null
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
