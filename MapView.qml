import QtQuick
import QtQuick.Shapes
import qs.Commons

// The map: tiles laid out under a marker that points the way the car is
// pointing.
//
// The tiles arrive already fetched and already positioned. `tesla map` does the Mercator arithmetic and hands over a list of files with the
// pixel each one goes at. Stitching them into a single image would want an
// image tool the helper deliberately does not depend on, and eight Images in
// a row is not something Qt struggles with.
Item {
  id: root

  // The object from `tesla map`, or null before the first one.
  property var plan: null
  // Degrees clockwise from north, the way Tesla reports it.
  property real heading: 0
  property bool driving: false
  // Whether the tiles underneath are pale. Everything drawn over them is
  // coloured off this rather than off the theme, because the map can be light
  // inside a dark panel and white-on-white reads as nothing at all.
  property bool lightMap: false
  // Dimmed when the reading it came from is old, so a stale map looks stale.
  property bool stale: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  readonly property bool ready: plan && plan.ok === true && plan.tiles && plan.tiles.length > 0

  clip: true

  // What shows through before the tiles land. Tinted the way the tiles will
  // be, so the panel does not flash the wrong colour on every open.
  Rectangle {
    anchors.fill: parent
    color: root.lightMap ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.35)
  }

  Repeater {
    model: root.ready ? root.plan.tiles : []

    Image {
      required property var modelData

      x: modelData.x
      y: modelData.y
      width: root.ready ? root.plan.tileSize : 256
      height: width
      source: "file://" + modelData.path
      // Tiles are served at exactly the size they are drawn at, so there is
      // nothing to resample and asynchronous decoding keeps the panel from
      // stuttering as eight of them land at once.
      asynchronous: true
      cache: true
      smooth: false
      opacity: root.stale ? 0.55 : 1

      Behavior on opacity {
        NumberAnimation { duration: 200 }
      }
    }
  }

  Text {
    anchors.centerIn: parent
    visible: !root.ready
    text: "Looking for the map"
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    color: root.foreground
    opacity: 0.6
  }

  // ------------------------------------------------------------------ marker

  // A ring with a beak, the shape every navigation app settled on, because it
  // answers both questions at once: the ring is where, the beak is which way.
  // A plain dot would leave the heading to a number nobody pictures.
  Item {
    id: marker

    readonly property real size: Style.space(28)

    visible: root.ready
    x: (root.ready ? root.plan.carX : 0) - width / 2
    y: (root.ready ? root.plan.carY : 0) - height / 2
    width: size
    height: size

    // Only the beak turns. A rotating ring would look like the whole marker
    // was spinning, which is not what a heading is.
    Shape {
      anchors.fill: parent
      antialiasing: true
      layer.enabled: true
      layer.samples: 4
      rotation: root.heading

      Behavior on rotation {
        // Shortest way round, so 350° to 10° is a nudge rather than a
        // full turn backwards.
        RotationAnimation { duration: 400; direction: RotationAnimation.Shortest; easing.type: Easing.OutCubic }
      }

      ShapePath {
        fillColor: root.accent
        strokeColor: Qt.rgba(0, 0, 0, 0.55)
        strokeWidth: 1

        // The base of the beak is buried in the disc and only the tip shows,
        // so the two read as one arrowhead rather than a triangle parked next
        // to a dot. It has to clear the disc by a few pixels to be legible at
        // all: at the first size tried the disc swallowed it whole.
        startX: marker.size / 2
        startY: 0
        PathLine { x: marker.size * 0.78; y: marker.size * 0.46 }
        PathLine { x: marker.size * 0.22; y: marker.size * 0.46 }
        PathLine { x: marker.size / 2; y: 0 }
      }
    }

    Rectangle {
      anchors.centerIn: parent
      width: parent.size * 0.46
      height: width
      radius: width / 2
      color: root.accent
      border.width: Math.max(1, Style.space(2))
      // The ring is there to lift the marker off the map, so it takes the
      // opposite side of whatever the map is.
      border.color: root.lightMap ? Qt.rgba(0, 0, 0, 0.75) : Qt.rgba(1, 1, 1, 0.9)
    }

    // A moving car gets a pulse. Standing still it stays quiet: a bar panel
    // that animates while nothing is happening is a bar panel you learn to
    // ignore.
    Rectangle {
      id: pulse
      anchors.centerIn: parent
      width: parent.size * 0.46
      height: width
      radius: width / 2
      color: "transparent"
      border.width: Math.max(1, Style.space(2))
      border.color: root.accent
      visible: root.driving
      opacity: 0

      SequentialAnimation {
        running: root.driving
        loops: Animation.Infinite

        ParallelAnimation {
          NumberAnimation { target: pulse; property: "scale"; from: 1; to: 2.6; duration: 1600; easing.type: Easing.OutCubic }
          SequentialAnimation {
            NumberAnimation { target: pulse; property: "opacity"; from: 0; to: 0.7; duration: 200 }
            NumberAnimation { target: pulse; property: "opacity"; to: 0; duration: 1400 }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- attribution

  // Both tile services ask for this, and both deserve it: the map is free
  // because somebody else is paying for it.
  Text {
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(4)
    visible: root.ready
    text: root.ready ? root.plan.attribution : ""
    font.family: root.fontFamily
    font.pixelSize: Math.max(8, Style.font.caption - Style.space(2))
    color: root.lightMap ? Qt.rgba(0, 0, 0, 1) : root.foreground
    opacity: 0.45
    style: Text.Outline
    styleColor: root.lightMap ? Qt.rgba(1, 1, 1, 0.7) : Qt.rgba(0, 0, 0, 0.6)
  }
}
