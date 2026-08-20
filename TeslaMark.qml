import QtQuick
import QtQuick.Shapes
import qs.Commons

// The Tesla wordmark's T, drawn rather than typed. No Nerd Font ships it, and
// a generic car glyph in the bar would say "a car" when the whole joke is that
// it says "your car".
//
// The outline is Simple Icons' tesla path, which is public domain, on their
// 24×24 grid. Everything here scales that grid to whatever size the bar hands
// over, so the mark stays sharp at any font size.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  implicitWidth: iconSize
  implicitHeight: iconSize

  Item {
    anchors.centerIn: parent
    width: 24
    height: 24
    scale: root.iconSize / 24

    Shape {
      anchors.fill: parent
      antialiasing: true
      // The mark is mostly a thin horn and a tapering stem; without
      // multisampling both alias badly at bar sizes.
      layer.enabled: true
      layer.samples: 4
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.WindingFill

        PathSvg {
          path: "M12 5.362l2.475-3.026s4.245.09 8.471 2.054c-1.082 1.636-3.231 2.438-3.231 2.438-.146-1.439-1.154-1.79-4.354-1.79L12 24 8.619 5.034c-3.18 0-4.188.354-4.335 1.792 0 0-2.148-.796-3.229-2.43C5.28 2.431 9.525 2.34 9.525 2.34L12 5.362l-.004.002H12zm0-3.899c3.415-.03 7.326.528 11.328 2.28.535-.968.672-1.395.672-1.395C19.626.836 15.616.089 12 .062 8.384.089 4.374.836 0 2.346c0 0 .195.526.672 1.396C4.674 1.99 8.585 1.434 12 1.464z"
        }
      }
    }
  }
}
