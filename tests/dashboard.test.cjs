const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
test('all supplied leaf fields are accessible, grouped and paginated without discarding unknown fields', () => {
 const m = model(); assert.equal(typeof m.fields, 'function');
 const reading = {ok:true, battery:0, energy_added:12, driving:false, seats:{front:0}, new_field:'abc', odometer:123, lat:1};
 const fields = m.fields(reading, 'All data');
 assert.deepEqual(Array.from(fields, r=>r.key).sort(), ['ok','battery','energy_added','driving','seats.front','new_field','odometer','lat'].sort());
 assert.equal(m.fields(reading, 'Charging').find(r=>r.key==='battery').value, '0 %');
 assert.equal(m.fields(reading, 'Climate').find(r=>r.key==='seats.front').value, '0');
 assert.equal(m.pageSize(360,400), 4);
 assert.equal(m.pageSize(760,600), 15);
});
test('cost scenario distinguishes free, unknown and invalid inputs; never calls it measured', () => {
 const m = model(); assert.equal(typeof m.costScenario, 'function');
 assert.equal(m.costScenario(12, {price:0,currency:'USD'}).amount, 0);
 assert.equal(m.costScenario(12, {price:0.25,currency:'USD'}).amount, 3);
 for (const price of [null,undefined,-1,NaN,Infinity,'0',false]) assert.equal(m.costScenario(12,{price:price}).amount,null);
 for (const energy of [null,undefined,-1,NaN,Infinity,'12',false]) assert.equal(m.costScenario(energy,{price:0}).amount,null);
 assert.match(m.costScenario(12,{price:0}).note, /battery-side/);
 assert.match(m.costScenario(12,{price:0}).note, /not a bill/);
});
test('the panel keeps the cockpit and adds the bounded data view beside it', () => {
 const panel = fs.readFileSync(path.join(__dirname, '../Panel.qml'),'utf8');
 assert.match(panel,/Dashboard\s*\{/);
 // The cockpit: map, switches, Wake. Hermes removed it; it is back to stay.
 assert.match(panel,/id: content\n/);
 assert.match(panel,/id: mapArea\n/);
 assert.match(panel,/id: controls\n/);
 assert.match(panel,/onClicked: root\.wake\(\)/);
 // Fred's rule of 2026-09-13: a click on a sleeping car wakes it. Nothing on
 // a timer does; the data view itself never asks the car for anything.
 assert.match(panel,/if \(root\.asleep && !root\.opened\) root\.wake\(\)/);
 // The data view is a fixed viewport that pages to fit, never a scroller.
 assert.match(panel,/fittedContentHeight\(Style\.space\(600\)\)/);
 assert.match(panel,/visible: !root\.dataView/);
});
const source = path.join(__dirname, '../DashboardModel.js');
function model() { const c = {}; vm.createContext(c); vm.runInContext(fs.existsSync(source) ? fs.readFileSync(source, 'utf8') : '', c); return c; }
test('Owner API cannot infer FSD/manual distance or time from odometer and driving state', () => {
 const m = model(); assert.equal(typeof m.drivingAnalytics, 'function');
 for (const reading of [null, {}, {ok:true, odometer:12500, driving:true}, {ok:true, odometer:0}, {ok:true, odometer:-1}, {ok:true, MilesSinceReset:100, SelfDrivingMilesSinceReset:80}]) {
  const result = m.drivingAnalytics(reading);
  assert.equal(result.distanceShare, null);
  assert.equal(result.timeShare, null);
  assert.match(result.reason, /same-period/);
  assert.match(result.note, /not manual/);
 }
});
