const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = path.join(__dirname, '../DashboardModel.js');
function model() { const c = {}; vm.createContext(c); vm.runInContext(fs.readFileSync(source, 'utf8'), c); return c; }

test('every leaf field is listed once, grouped, with units; plumbing keys are folded away', () => {
 const m = model();
 const reading = {ok:true, fresh:false, range_unit:'mi', battery:0, energy_added:12, driving:false,
                  seats:{front:0}, new_field:'abc', odometer:123, lat:1, open:[], windows_open:true, heading:90};
 const all = m.fields(reading, 'All data');
 assert.deepEqual(Array.from(all, r=>r.key).sort(),
   ['battery','energy_added','driving','seats.front','new_field','odometer','lat','open','windows_open','heading'].sort());
 assert.equal(m.fields(reading, 'Charging').find(r=>r.key==='battery').value, '0 %');
 assert.equal(m.fields(reading, 'Driving').find(r=>r.key==='odometer').value, '123 mi');
 assert.equal(m.fields(reading, 'Driving').find(r=>r.key==='driving').value, 'no');
 assert.equal(m.fields(reading, 'Climate').find(r=>r.key==='seats.front').value, '0');
 assert.equal(m.fields(reading, 'Vehicle').find(r=>r.key==='open').value, 'none');
 assert.equal(m.fields(reading, 'Vehicle').find(r=>r.key==='new_field').value, 'abc');
 assert.equal(m.fields(reading, 'Position').find(r=>r.key==='heading').value, '90 \u00b0');
 assert.equal(m.fields({ok:true, destination:null}, 'Driving')[0].value, 'unavailable');
 assert.match(m.fields({ok:true, at:1789479507}, 'Vehicle')[0].value, /^\d\d:\d\d$/);
 assert.equal(m.fields(null, 'All data').length, 0);
});

test('cost scenario distinguishes free, unknown and invalid inputs; never calls it measured', () => {
 const m = model();
 assert.equal(m.costScenario(12, {price:0,currency:'USD'}).amount, 0);
 assert.equal(m.costScenario(12, {price:0.25,currency:'USD'}).amount, 3);
 for (const price of [null,undefined,-1,NaN,Infinity,'0',false]) assert.equal(m.costScenario(12,{price:price}).amount,null);
 for (const energy of [null,undefined,-1,NaN,Infinity,'12',false]) assert.equal(m.costScenario(energy,{price:0}).amount,null);
 assert.match(m.costScenario(12,{price:0}).note, /battery-side/);
 assert.match(m.costScenario(12,{price:0}).note, /not a bill/);
});

test('the panel is one screen: cockpit, switches, every field, notebook, no second view', () => {
 const panel = fs.readFileSync(path.join(__dirname, '../Panel.qml'),'utf8');
 assert.doesNotMatch(panel,/Dashboard\s*\{/);
 assert.doesNotMatch(panel,/dataView/);
 assert.doesNotMatch(panel,/fittedContentHeight\(Style\.space\(600\)\)/);
 for (const id of ['content','mapArea','controls','actions','dataColumnA','dataColumnB','locations'])
   assert.match(panel, new RegExp('id: ' + id + '\\n'), id);
 assert.match(panel,/columns: 4\n/);
 assert.match(panel,/contentHeight: popup\.fittedContentHeight\(content\.implicitHeight\)/);
 // Fred's rule of 2026-09-13: a click on a sleeping car wakes it, and the
 // panel's Wake button stays.
 assert.match(panel,/if \(root\.asleep && !root\.opened\) root\.wake\(\)/);
 assert.match(panel,/onClicked: root\.wake\(\)/);
 assert.ok(!fs.existsSync(path.join(__dirname, '../Dashboard.qml')), 'Dashboard.qml is gone');
});

test('Owner API cannot infer FSD/manual distance or time from odometer and driving state', () => {
 const m = model();
 for (const reading of [null, {}, {ok:true, odometer:12500, driving:true}, {ok:true, odometer:0}, {ok:true, odometer:-1}, {ok:true, MilesSinceReset:100, SelfDrivingMilesSinceReset:80}]) {
  const result = m.drivingAnalytics(reading);
  assert.equal(result.distanceShare, null);
  assert.equal(result.timeShare, null);
  assert.match(result.reason, /same-period/);
  assert.match(result.note, /not manual/);
 }
});
