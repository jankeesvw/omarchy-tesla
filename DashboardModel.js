// The field model behind the data columns: every leaf of the reading,
// grouped, labelled and formatted for one line each. Owner API adapter only;
// Fleet Telemetry names are not an Owner API contract.

function costScenario(energy, tariff) {
    var price = tariff && tariff.price;
    var valid = typeof energy === 'number' && isFinite(energy) && energy >= 0
        && typeof price === 'number' && isFinite(price) && price >= 0;
    var amount = valid ? energy * price : null;
    if (amount !== null && !isFinite(amount)) amount = null;
    return {amount:amount, note:'Scenario using battery-side energy and the selected current tariff; not a bill. Charging losses, fees and historical location are unknown.'};
}

// Plumbing the panel already folds into other lines: the units ride on their
// values, and ok/fresh are how the reading arrived, not what the car said.
var HIDDEN = {ok:1, fresh:1, range_unit:1, speed_unit:1, temp_unit:1, tyre_unit:1};
// Seconds since the epoch, shown as a clock time.
var EPOCH = {at:1, eta:1, gps_as_of:1};

function group(key) {
    var k = key.split('.')[0];
    if (/^(battery|battery_usable|range|charge.*|charging|energy_added|minutes_to_full|plugged_in)$/.test(k)) return 'Charging';
    if (/^(climate.*|inside_temp|outside_temp|defrost|seats|wheel_heater)$/.test(k)) return 'Climate';
    if (/^(driving|speed|shift|odometer|destination|eta.*)$/.test(k)) return 'Driving';
    if (/^(lat|lon|gps_as_of|heading)$/.test(k)) return 'Position';
    return 'Vehicle';
}

function clock(seconds) {
    var d = new Date(seconds * 1000);
    if (isNaN(d.getTime())) return 'unavailable';
    var h = d.getHours(), m = d.getMinutes();
    return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m;
}

function fields(reading, section) {
    var result = [];
    var units = {battery:'%', battery_usable:'%', charge_limit:'%', range:reading && reading.range_unit,
        odometer:reading && reading.range_unit, speed:reading && reading.speed_unit,
        charger_power:'kW', energy_added:'kWh', charge_amps:'A', charge_amps_max:'A',
        minutes_to_full:'min', inside_temp:reading && reading.temp_unit, outside_temp:reading && reading.temp_unit,
        'tyres.min':reading && reading.tyre_unit, 'tyres.max':reading && reading.tyre_unit,
        eta_distance:reading && reading.range_unit, eta_delay:'min', heading:'\u00b0'};
    function visit(value, key) {
        if (HIDDEN[key]) return;
        if (value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length) {
            Object.keys(value).sort().forEach(function(child) { visit(value[child], key ? key+'.'+child : child); });
            return;
        }
        var g = group(key);
        if (section !== 'All data' && section !== g) return;
        var text;
        if (value === null || value === undefined) text = 'unavailable';
        else if (typeof value === 'boolean') text = value ? 'yes' : 'no';
        else if (Array.isArray(value)) text = value.length ? value.join(', ') : 'none';
        else if (typeof value === 'object') text = 'none';
        else if (EPOCH[key]) text = clock(value);
        else text = String(value);
        if (value !== null && value !== undefined && !EPOCH[key] && units[key]) text += ' ' + units[key];
        result.push({key:key, label:key.replace(/[_.]/g,' '), value:text, group:g});
    }
    if (reading && typeof reading === 'object') Object.keys(reading).sort().forEach(function(k) { visit(reading[k], k); });
    return result;
}

// Never derive engagement duration from instantaneous driving or an odometer.
function drivingAnalytics(reading) {
    return {
        distanceShare: null,
        timeShare: null,
        reason: "Unavailable: this provider has no verified same-period FSD and total distance counters.",
        note: "Non-FSD is not manual; it may include basic Autopilot.",
        timeReason: "Unavailable: engagement duration and total driving duration are not supplied. Time / odometer is not a percentage."
    };
}
