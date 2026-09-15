function costScenario(energy, tariff) {
    var price = tariff && tariff.price;
    var valid = typeof energy === 'number' && isFinite(energy) && energy >= 0
        && typeof price === 'number' && isFinite(price) && price >= 0;
    var amount = valid ? energy * price : null;
    if (amount !== null && !isFinite(amount)) amount = null;
    return {amount:amount, note:'Scenario using battery-side energy and the selected current tariff; not a bill. Charging losses, fees and historical location are unknown.'};
}

function columns(width) { return width >= 650 ? 3 : width >= 340 ? 2 : 1; }
function pageSize(width, height) { return columns(width) * Math.max(1, Math.floor((height - 180) / 80)); }
function group(key) {
    var k = key.split('.')[0];
    if (/^(battery|battery_usable|range|range_unit|charge.*|charging|energy_added|minutes_to_full|plugged_in)$/.test(k)) return 'Charging';
    if (/^(climate.*|inside_temp|outside_temp|temp_unit|defrost|seats|wheel_heater)$/.test(k)) return 'Climate';
    if (/^(driving|speed|speed_unit|shift|odometer|heading|destination|eta.*)$/.test(k)) return 'Driving';
    if (/^(lat|lon|gps_as_of)$/.test(k)) return 'Locations';
    return 'Vehicle';
}
function fields(reading, section) {
    var result = [];
    var units = {battery:'%', battery_usable:'%', charge_limit:'%', range:reading && reading.range_unit,
        odometer:reading && reading.range_unit, speed:reading && reading.speed_unit,
        charger_power:'kW', energy_added:'kWh (battery-side)', charge_amps:'A', charge_amps_max:'A',
        minutes_to_full:'min', inside_temp:reading && reading.temp_unit, outside_temp:reading && reading.temp_unit};
    function visit(value, key) {
        if (value && typeof value === 'object' && Object.keys(value).length) {
            Object.keys(value).sort().forEach(function(child) { visit(value[child], key ? key+'.'+child : child); });
            return;
        }
        var g = group(key);
        var overview = ['battery','range','charging','locked','sentry','odometer','inside_temp','outside_temp','software'];
        if (section !== 'All data' && (section === 'Overview' ? overview.indexOf(key)<0 : section !== g)) return;
        var text = value === null || value === undefined ? 'Unavailable' : typeof value === 'boolean' ? (value ? 'Yes' : 'No') : typeof value === 'object' ? 'None reported' : String(value);
        if (value !== null && value !== undefined && units[key]) text += ' '+units[key];
        result.push({key:key, label:key.replace(/[_.]/g,' '), value:text, group:g});
    }
    if (reading && typeof reading === 'object') Object.keys(reading).sort().forEach(function(k) { visit(reading[k], k); });
    return result;
}

// Owner API adapter only. Fleet Telemetry names are not an Owner API contract.
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
