import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "DashboardModel.js" as Model

// The data view: every field the car reports, read-only, in tabs. Every page
// is bounded by the popup viewport; additional fields become pages, never a
// hidden overflow or a scroll surface. The cockpit (map, switches, Wake) is
// the panel's other view; `back` returns to it.
FocusScope {
    id: dash
    signal back()
    signal closeRequested()
    property var reading: null
    property string status: "Waiting for a reading"
    property color foreground: "#e5e9f0"
    property color accent: "#8fbcbb"
    property color background: "#171b22"
    property string fontFamily: "sans-serif"
    property var mapPlan: null
    property bool darkMap: true
    property var cars: []
    property string selectedVin: ""
    signal selectCar(string vin, string name)
    property int tabIndex: 0
    property int page: 0
    property string expandedLabel: ""
    property string expandedValue: ""
    property int textPage: 0
    readonly property var tabs: ["Overview", "Driving", "Charging", "Locations", "Vehicle", "Climate", "All data", "Map"]
    // Read-only diagnostics for the IPC test hooks.
    readonly property int locationsStep: locations.step
    readonly property bool locationsBusy: locations.busy
    readonly property string locationsFeedback: locations.feedback
    readonly property string focusedName: dash.activeFocus ? (locations.activeFocus ? "editor" : "dashboard") : "none"
    readonly property string section: tabs[tabIndex]
    readonly property var analytics: Model.drivingAnalytics(reading)
    readonly property var items: Model.fields(reading, section)
    readonly property int cols: Model.columns(width)
    readonly property int rows: Math.max(1, Math.floor(body.height / 84))
    readonly property int capacity: cols * rows
    readonly property int pages: Math.max(1, Math.ceil(items.length / capacity))
    readonly property real mapViewportWidth: body.width
    readonly property real mapViewportHeight: body.height
    readonly property int textChunk: Math.max(40, Math.floor(body.width / 9) * Math.max(1, Math.floor((body.height - 65) / 24)))
    readonly property int textPages: Math.max(1, Math.ceil(expandedValue.length / textChunk))
    readonly property bool fitsViewport: footer.y + footer.height <= height + 1 && body.height >= 84 && header.width <= width + 1
    readonly property bool contentFits: (!contextCard.visible || contextText.contentHeight <= contextText.height + 1)
        && (!cards.visible || cards.implicitHeight <= body.height + 1)
        && (!locations.visible || locations.fitsViewport)
        && (!expanded.visible || expanded.implicitHeight <= body.height + 1)
    onTabIndexChanged: { page = 0; expandedLabel = ""; expandedValue = ""; focusSection() }
    // Keys go to whichever item has focus and bubble up from there, never
    // down. The notebook has shortcuts of its own, so while its tab shows it
    // must be the focused item; the section keys still reach this scope
    // because the notebook leaves them unhandled.
    onActiveFocusChanged: if (activeFocus) focusSection()
    function focusSection() {
        if (section === "Locations" && locations.visible) locations.forceActiveFocus()
        else dash.forceActiveFocus()
    }
    onCapacityChanged: page = Math.max(0, Math.min(page, pages - 1))
    onItemsChanged: page = Math.max(0, Math.min(page, pages - 1))
    onTextChunkChanged: textPage = Math.max(0, Math.min(textPage, textPages - 1))
    focus: true

    function nextPage(delta) {
        if (expandedLabel !== "") textPage = Math.max(0, Math.min(textPages - 1, textPage + delta))
        else page = Math.max(0, Math.min(pages - 1, page + delta))
    }
    Keys.onPressed: function(event) {
        // The notebook's Alt shortcuts work wherever focus happens to be in
        // this scope: KeyboardPanel re-focuses the dashboard itself after the
        // popup maps, so the editor cannot rely on holding focus.
        if (section === "Locations" && locations.visible) {
            locations.handleKey(event)
            if (event.accepted) return
        }
        if (event.key === Qt.Key_Right && event.modifiers & Qt.ControlModifier) { tabIndex = (tabIndex + 1) % tabs.length; event.accepted = true }
        else if (event.key === Qt.Key_Left && event.modifiers & Qt.ControlModifier) { tabIndex = (tabIndex + tabs.length - 1) % tabs.length; event.accepted = true }
        else if (event.key === Qt.Key_PageDown) { nextPage(1); event.accepted = true }
        else if (event.key === Qt.Key_PageUp) { nextPage(-1); event.accepted = true }
        else if (event.key === Qt.Key_Escape && expandedLabel !== "") { expandedLabel = ""; event.accepted = true }
        else if (event.key === Qt.Key_Escape) { dash.closeRequested(); event.accepted = true }
    }

    component Nav: QQC.Button {
        id: nav
        property bool chosen: false
        font.family: dash.fontFamily
        font.pixelSize: 12
        height: 32
        activeFocusOnTab: true
        contentItem: Text {
            text: nav.text
            textFormat: Text.PlainText
            color: nav.chosen ? dash.background : dash.foreground
            font: nav.font
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            radius: 6
            color: nav.chosen ? dash.accent : Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, nav.hovered ? 0.13 : 0.05)
            border.width: nav.activeFocus ? 2 : 1
            border.color: nav.activeFocus ? dash.accent : Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.16)
            opacity: nav.enabled ? 1 : 0.4
        }
    }
    Row {
        id: header
        width: parent.width
        height: 52
        spacing: 8
        Rectangle { width: 4; height: 37; radius: 2; color: dash.accent }
        Column {
            width: parent.width - 12 - cockpitButton.width - 8 - (carChoice.visible ? carChoice.width + 8 : 0)
            spacing: 2
            Text { text: "TESLA / " + dash.section.toUpperCase(); color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: 21; font.bold: true }
            Text { width: parent.width; text: (dash.reading && dash.reading.fixture ? "SYNTHETIC FIXTURE · " : "") + dash.status; color: dash.foreground; opacity: 0.65; font.family: dash.fontFamily; font.pixelSize: 11; elide: Text.ElideRight; textFormat: Text.PlainText }
        }
        // The shell's own dropdown rather than a Controls ComboBox: it is what
        // every other panel uses, and it draws its list inside the popup.
        Dropdown {
            id: carChoice
            visible: dash.cars.length > 1
            width: visible ? Math.min(160, dash.width * 0.3) : 0
            anchors.verticalCenter: parent.verticalCenter
            showLabel: false
            fontFamily: dash.fontFamily
            foreground: dash.foreground
            accent: dash.accent
            options: dash.cars.map(function(c) { return {value: String(c.vin), label: String(c.name || "Tesla")} })
            value: dash.selectedVin
            onChanged: function(v) {
                var car = dash.cars.find(function(c) { return String(c.vin) === v })
                if (car) dash.selectCar(String(car.vin), String(car.name || "Tesla"))
            }
        }
        Nav {
            id: cockpitButton
            width: 96
            anchors.verticalCenter: parent.verticalCenter
            text: "\u2039 Cockpit"
            onClicked: dash.back()
        }
    }
    Grid {
        id: navigation
        anchors.top: header.bottom
        width: parent.width
        columns: dash.width >= 650 ? 8 : 4
        spacing: 4
        Repeater {
            model: dash.tabs
            Nav {
                required property int index
                required property string modelData
                width: (navigation.width - navigation.spacing * (navigation.columns - 1)) / navigation.columns
                text: modelData
                chosen: dash.tabIndex === index
                onClicked: { dash.tabIndex = index; dash.focusSection() }
            }
        }
    }
    Rectangle {
        id: contextCard
        anchors.top: navigation.bottom
        anchors.topMargin: 10
        width: parent.width
        height: visible ? contextText.contentHeight + 20 : 0
        visible: dash.section === "Driving" || dash.section === "Overview" || dash.section === "Charging"
        radius: 8
        color: Qt.rgba(dash.accent.r, dash.accent.g, dash.accent.b, 0.09)
        border.color: Qt.rgba(dash.accent.r, dash.accent.g, dash.accent.b, 0.25)
        Text {
            id: contextText
            anchors.fill: parent
            anchors.margins: 10
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: dash.foreground
            font.family: dash.fontFamily
            font.pixelSize: 12
            text: dash.section === "Driving"
                ? "FSD distance & driving-time share: unavailable\nNo verified same-period counters or engagement durations. Non-FSD is not manual (may include basic Autopilot). Time / odometer is not a percentage."
                : dash.section === "Charging"
                ? "Energy added is battery-side, not measured charger input. Tariffs live in Locations. Costs are explicit scenarios, never bills or inferred charging history. Unknown rates are not free."
                : "A snapshot, not a journey log\nBattery, range and vehicle health from the existing Owner API. Browse every supplied field in All data; select any card to read its complete value."
        }
    }
    Item {
        id: body
        anchors.top: contextCard.visible ? contextCard.bottom : navigation.bottom
        anchors.topMargin: 10
        anchors.bottom: footer.top
        anchors.bottomMargin: 10
        width: parent.width
        Grid {
            id: cards
            visible: dash.section !== "Locations" && dash.section !== "Map" && dash.expandedLabel === ""
            width: parent.width
            columns: dash.cols
            spacing: 8
            Repeater {
                model: dash.items.slice(dash.page * dash.capacity, (dash.page + 1) * dash.capacity)
                QQC.Button {
                    id: card
                    required property var modelData
                    width: (cards.width - cards.spacing * (cards.columns - 1)) / cards.columns
                    height: 76
                    activeFocusOnTab: true
                    onClicked: { dash.expandedLabel = modelData.label; dash.expandedValue = modelData.value; dash.textPage = 0; dash.forceActiveFocus() }
                    background: Rectangle {
                        radius: 8
                        color: Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, card.hovered ? 0.1 : 0.04)
                        border.color: card.activeFocus ? dash.accent : Qt.rgba(dash.foreground.r, dash.foreground.g, dash.foreground.b, 0.13)
                    }
                    contentItem: Column {
                        spacing: 5
                        Text { width: parent.width; text: card.modelData.label.toUpperCase(); font.family: dash.fontFamily; font.pixelSize: 10; color: dash.foreground; opacity: 0.6; elide: Text.ElideRight; textFormat: Text.PlainText }
                        Text { width: parent.width; text: card.modelData.value; font.family: dash.fontFamily; font.pixelSize: 18; color: card.modelData.value === "Unavailable" ? Qt.rgba(dash.foreground.r,dash.foreground.g,dash.foreground.b,0.5) : dash.foreground; elide: Text.ElideRight; textFormat: Text.PlainText }
                    }
                }
            }
        }
        Text {
            visible: dash.items.length === 0 && dash.section !== "Locations" && dash.section !== "Map"
            anchors.centerIn: parent
            width: parent.width
            text: "No reading yet.\nThe cockpit can wake the car; the next poll fills this in."
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: dash.foreground
            font.family: dash.fontFamily
            font.pixelSize: 14
        }
        Column {
            id: expanded
            visible: dash.expandedLabel !== ""
            width: parent.width
            spacing: 12
            Nav { text: "← Back to fields"; width: 150; onClicked: dash.expandedLabel = "" }
            Text { width: parent.width; text: dash.expandedLabel; textFormat: Text.PlainText; color: dash.accent; font.family: dash.fontFamily; font.pixelSize: 14; wrapMode: Text.WrapAnywhere }
            Text { width: parent.width; text: dash.expandedValue.slice(dash.textPage * dash.textChunk, (dash.textPage + 1) * dash.textChunk); textFormat: Text.PlainText; color: dash.foreground; font.family: dash.fontFamily; font.pixelSize: 14; lineHeight: 1.15; wrapMode: Text.WrapAnywhere }
        }
        LocationEditor {
            id: locations
            anchors.fill: parent
            visible: dash.section === "Locations"
            foreground: dash.foreground
            accent: dash.accent
            background: dash.background
            fontFamily: dash.fontFamily
            energy: dash.reading ? dash.reading.energy_added : null
        }
        MapView {
            visible: dash.section === "Map"
            hasPosition: !!(dash.reading && dash.reading.lat !== null && dash.reading.lat !== undefined
                            && dash.reading.lon !== null && dash.reading.lon !== undefined)
            anchors.fill: parent
            plan: dash.mapPlan
            darkMap: dash.darkMap
            lightMap: !dash.darkMap
            heading: dash.reading && dash.reading.heading !== null ? dash.reading.heading : 0
            driving: dash.reading && dash.reading.driving === true
            stale: !(dash.reading && dash.reading.fresh)
            foreground: dash.foreground
            accent: dash.accent
            fontFamily: dash.fontFamily
        }
        Text {
            visible: dash.section === "Map" && !dash.mapPlan
            anchors.centerIn: parent
            width: parent.width
            text: "No map available\nCoordinates, if supplied, are in All data."
            color: dash.foreground
            font.family: dash.fontFamily
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }
    Row {
        id: footer
        anchors.bottom: parent.bottom
        width: parent.width
        height: 32
        spacing: 6
        Nav { width: 64; text: "← Prev"; enabled: dash.expandedLabel !== "" ? dash.textPage > 0 : dash.page > 0; visible: dash.section !== "Locations" && dash.section !== "Map"; onClicked: dash.nextPage(-1) }
        Text {
            width: parent.width - (dash.section === "Locations" || dash.section === "Map" ? 0 : 140)
            height: 32
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            color: dash.foreground
            opacity: 0.6
            font.family: dash.fontFamily
            font.pixelSize: 11
            text: dash.section === "Locations" ? "Private local notebook · no geocoding · Alt+N new · Alt+Enter next · Alt+S save"
                : dash.section === "Map" ? "Read-only map · no vehicle commands"
                : dash.expandedLabel !== "" ? "Value " + (dash.textPage + 1) + " / " + dash.textPages
                : (dash.page + 1) + " / " + dash.pages + " · " + dash.items.length + " fields · PgUp / PgDn"
        }
        Nav { width: 64; text: "Next →"; enabled: dash.expandedLabel !== "" ? dash.textPage < dash.textPages - 1 : dash.page < dash.pages - 1; visible: dash.section !== "Locations" && dash.section !== "Map"; onClicked: dash.nextPage(1) }
    }
}
