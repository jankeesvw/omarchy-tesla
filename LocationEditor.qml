import QtQuick
import QtQuick.Controls as QQC
import Quickshell.Io
import qs.Commons
import qs.Ui
import "DashboardModel.js" as Model

// The tariff notebook: named charging places and what a kWh costs at each,
// kept in ~/.config/omarchy-tesla/locations.json and nowhere else. Nothing
// here is geocoded or matched to the car's position; a place is chosen by
// hand, and the cost line is a scenario, never a bill.
Item {
    id: editor
    property bool loaded: false
    property color foreground: "#e5e9f0"
    property color accent: "#8fbcbb"
    property color background: "#171b22"
    property string fontFamily: "sans-serif"
    property var energy: null
    property var locations: []
    property int selected: -1
    property int step: 0
    property int historyIndex: 0
    property string editingId: ""
    property string feedback: ""
    property string pending: ""
    property bool saving: false
    readonly property var location: selected >= 0 && selected < locations.length ? locations[selected] : null
    readonly property var tariff: location && location.tariffs.length ? location.tariffs[location.tariffs.length - 1] : null
    readonly property var scenario: Model.costScenario(energy, tariff)
    readonly property string script: Qt.resolvedUrl("bin/locations.py").toString().replace(/^file:\/\//, "")
    readonly property bool fitsViewport: actionRow.y >= content.implicitHeight && actionRow.y + actionRow.height <= height + 1

    function edit(isNew) {
        editingId = !isNew && location ? location.id : ""
        nameField.text = !isNew && location ? location.name : ""
        addressField.text = !isNew && location ? location.address : ""
        priceField.text = !isNew && tariff && tariff.price !== null ? String(tariff.price) : ""
        currencyField.text = !isNew && tariff ? tariff.currency : "USD"
        feedback = ""
        step = 1
        nameField.forceActiveFocus()
    }
    // The store is read the first time the tab is shown, not when the panel
    // is built: the widget is re-created many times a day, and each one
    // running python for a tab nobody opened is a process for nothing.
    onVisibleChanged: {
        if (!visible || loaded) return
        loaded = true
        store.command = ["python3", script]
        store.running = true
    }
    function saveEntry() {
        if (store.running) return
        // Blank currency means dollars; the store insists on a three-letter
        // code and would otherwise refuse the whole entry.
        pending = JSON.stringify({id:editingId, name:nameField.text, address:addressField.text, price:priceField.text,
                                  currency:(currencyField.text.trim().toUpperCase() || "USD")})
        saving = true
        store.command = ["python3", script, "save"]
        store.running = true
    }
    Shortcut {
        sequence: "Alt+N"
        enabled: editor.visible && !store.running
        onActivated: editor.edit(true)
    }
    Shortcut {
        sequence: "Alt+Return"
        enabled: editor.visible && editor.step === 1 && nameField.text.trim() !== ""
        onActivated: { editor.step = 2; priceField.forceActiveFocus() }
    }
    Shortcut {
        sequence: "Alt+S"
        enabled: editor.visible && editor.step === 2 && !store.running
        onActivated: editor.saveEntry()
    }
    Process {
        id: store
        command: ["python3", editor.script]
        running: false
        stdinEnabled: true
        onStarted: if (editor.saving) { write(editor.pending + "\n"); editor.pending = "" }
        stdout: StdioCollector {
            onStreamFinished: {
                var response
                try { response = JSON.parse(text) } catch (e) { editor.feedback = "Private store unavailable"; editor.saving = false; return }
                if (!response.ok) { editor.feedback = response.error; editor.saving = false; return }
                editor.locations = response.data.locations
                // Selecting a saved place is a deliberate cost scenario, never a GPS match.
                if (editor.saving) {
                    var idx = editor.locations.findIndex(function(v) { return v.id === editor.editingId })
                    editor.selected = idx >= 0 ? idx : editor.locations.length - 1
                    editor.step = 0
                    editor.feedback = "Saved locally. Rate effective now; prior rates retained."
                }
                editor.saving = false
            }
        }
    }
    component Action: QQC.Button {
        id: a
        height: 32
        font.family: editor.fontFamily
        font.pixelSize: 12
        activeFocusOnTab: true
        contentItem: Text { text: a.text; font: a.font; color: editor.foreground; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; textFormat: Text.PlainText }
        background: Rectangle { radius: 6; color: Qt.rgba(editor.accent.r,editor.accent.g,editor.accent.b,0.1); border.color: a.activeFocus ? editor.accent : Qt.rgba(editor.foreground.r,editor.foreground.g,editor.foreground.b,0.2); opacity: a.enabled ? 1 : 0.4 }
    }
    // The shell's own text field, so it looks like every other input in a
    // panel and follows the theme.
    component Input: TextField {
        height: 32
        width: parent.width
        foreground: editor.foreground
        accent: editor.accent
        font.family: editor.fontFamily
        font.pixelSize: 13
        selectByMouse: true
    }
    component LabelText: Text {
        color: editor.foreground
        font.family: editor.fontFamily
        font.pixelSize: 12
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        width: parent.width
    }
    Column {
        id: content
        width: parent.width
        spacing: 7
        Column {
            visible: editor.step === 0
            width: parent.width
            spacing: 8
            Dropdown {
                width: parent.width
                showLabel: false
                fontFamily: editor.fontFamily
                foreground: editor.foreground
                accent: editor.accent
                options: [{value: "", label: "Choose a location (no automatic match)"}].concat(
                    editor.locations.map(function(v) { return {value: String(v.id), label: String(v.name)} }))
                value: editor.location ? String(editor.location.id) : ""
                onChanged: function(v) {
                    editor.selected = editor.locations.findIndex(function(l) { return String(l.id) === v })
                }
            }
            LabelText {
                text: editor.tariff ? "Current tariff: " + (editor.tariff.price === null ? "Unknown" : editor.tariff.price === 0 ? "Free · 0 " + editor.tariff.currency + "/kWh" : editor.tariff.price + " " + editor.tariff.currency + "/kWh") : "Name your charging places and define their rates."
                font.pixelSize: 17
                color: editor.accent
            }
            LabelText {
                text: "Battery-energy scenario: " + (editor.scenario.amount === null ? "Unavailable" : editor.scenario.amount.toFixed(2) + " " + (editor.tariff ? editor.tariff.currency : "")) + "\nNot a bill. Uses last reported battery-side energy × chosen current rate; losses, fees and actual charge location unknown."
            }
            LabelText { text: editor.feedback || "Addresses stay on this computer. No external lookup or automatic tariff assignment."; opacity: 0.6; font.pixelSize: 11 }
        }
        Column {
            visible: editor.step === 1
            width: parent.width
            spacing: 5
            LabelText { text: "1 / 2 · Name and address · Alt+Enter: next"; color: editor.accent }
            Input { id: nameField; placeholderText: "Location name"; maximumLength: 120 }
            Input { id: addressField; placeholderText: "Address (optional, never geocoded)"; maximumLength: 500 }
            LabelText { text: "Local label only. A stored address does not prove where a charging session occurred."; opacity: 0.6; font.pixelSize: 11 }
        }
        Column {
            visible: editor.step === 2
            width: parent.width
            spacing: 5
            LabelText { text: "2 / 2 · Energy tariff · Alt+S: save"; color: editor.accent }
            Input { id: priceField; placeholderText: "Price per kWh · 0 = free · blank = unknown"; maximumLength: 20 }
            Input { id: currencyField; placeholderText: "Currency, e.g. USD"; maximumLength: 3 }
            LabelText { text: editor.feedback || "Takes effect when saved. Previous rates are retained. No charging history is backfilled."; opacity: 0.6; font.pixelSize: 11 }
        }
        Column {
            visible: editor.step === 3
            width: parent.width
            spacing: 10
            LabelText { text: "Tariff history · " + (editor.historyIndex + 1) + " / " + (editor.location ? editor.location.tariffs.length : 0); color: editor.accent; font.pixelSize: 18 }
            LabelText {
                text: {
                    if (!editor.location) return "No location selected"
                    var t = editor.location.tariffs[editor.historyIndex]
                    if (!t) return "Unavailable"
                    return "Effective from: " + t.effective_from + "\nRate: " + (t.price === null ? "Unknown" : t.price + " " + t.currency + "/kWh") + "\nRecorded locally, not a provider billing record."
                }
            }
        }
    }
    Row {
        id: actionRow
        anchors.bottom: parent.bottom
        width: parent.width
        height: 32
        spacing: 6
        Action {
            width: (parent.width - 12) / 3
            text: editor.step === 0 ? "New (Alt+N)" : "Back"
            enabled: !store.running
            onClicked: {
                if (editor.step === 0) editor.edit(true)
                else editor.step = editor.step === 2 ? 1 : 0
            }
        }
        Action {
            width: (parent.width - 12) / 3
            text: editor.step === 0 ? "Edit tariff" : editor.step === 1 ? "Next →" : editor.step === 2 ? "Save locally" : "← Older"
            enabled: !store.running && (editor.step !== 0 || editor.location !== null) && (editor.step !== 1 || nameField.text.trim() !== "") && (editor.step !== 3 || editor.historyIndex > 0)
            onClicked: {
                if (editor.step === 0) editor.edit(false)
                else if (editor.step === 1) { editor.step = 2; priceField.forceActiveFocus() }
                else if (editor.step === 2) editor.saveEntry()
                else editor.historyIndex--
            }
        }
        Action {
            width: (parent.width - 12) / 3
            text: editor.step === 0 ? "Rate history" : editor.step === 3 ? "Newer →" : "Cancel"
            enabled: !store.running && (editor.step !== 0 || editor.location !== null) && (editor.step !== 3 || (editor.location && editor.historyIndex < editor.location.tariffs.length - 1))
            onClicked: {
                if (editor.step === 0) { editor.step = 3; editor.historyIndex = editor.location.tariffs.length - 1 }
                else if (editor.step === 3) editor.historyIndex++
                else editor.step = 0
            }
        }
    }
}
