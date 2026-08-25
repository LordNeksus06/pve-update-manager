// The target grid's own decisions, called directly.
//
// PVE.updmgr.TargetGrid is a config object until ExtJS builds it, and its
// methods are ordinary functions - so they can be called against a stand-in
// `me` with a fake store behind it. That is not a browser and does not replace
// opening the page, but it does test the parts that are logic rather than
// layout: which columns exist, which row buttons are offered to whom, what the
// confirmation dialog says, and what a click actually sends.
//
//   node tests/js/grid.test.js

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

const ROWS = [
    { type: 'node', id: 'node-a', name: 'node-a', stored: true, order: 0,
      parallel_manual: false, snapshot_shutdown: true },
    { type: 'lxc', id: '101', vmid: 101, name: 'db', stored: true, order: 5 },
    { type: 'lxc', id: '102', vmid: 102, name: 'web', stored: true, order: 0 },
];

// Enough of a store and a selection model for the methods under test.
function gridFor(answer, options) {
    options = options || {};
    const loaded = load(answer || (() => ({})), options);
    const cfg = loaded.classes['PVE.updmgr.TargetGrid'];

    const records = (options.rows || ROWS).map((data) => ({ data: data }));
    const selected = (options.selected || []).map(
        (id) => records.find((rec) => rec.data.id === id),
    );

    const me = Object.assign({}, cfg, {
        nodename: 'node-a',
        canEditHost: options.canEditHost !== false,
        canEditGuest: options.canEditGuest !== false,
        reloaded: 0,
        reload: function () {
            me.reloaded += 1;
        },
        setLoading: function () {},
        getStore: function () {
            return {
                each: function (fn) {
                    for (const rec of records) {
                        if (fn(rec) === false) {
                            return;
                        }
                    }
                },
            };
        },
        getSelectionModel: function () {
            return { getSelection: () => selected };
        },
    });

    return { me: me, records: records, ...loaded };
}

claim('the grid has an Order column, and an unset one reads as "last"', () => {
    const { me } = gridFor();
    const columns = me.buildColumns.call(me);

    const order = columns.find((c) => c.dataIndex === 'order');
    assert.ok(order, 'the column is there');
    assert.strictEqual(order.header, 'Order');
    assert.ok(String(order.renderer(5)).includes('5'), 'a number shows as itself');
    assert.ok(
        String(order.renderer(0)).includes('last'),
        'and 0 is not shown as a number, because it is not one - it means "after the rest"',
    );
});

claim('a failed row with no exit code says so, rather than saying "undefined"', () => {
    const { updmgr } = load(() => ({}));

    // A state file that lost its exit code - hand-edited, or written by
    // something that is not us. The word "undefined" in a grid cell reads as a
    // broken addon, which is a worse answer than "we do not know".
    assert.ok(updmgr.renderLastRun({ last_state: 'failed' }).includes('exit ?'));
    assert.ok(updmgr.renderLastRun({ last_state: 'failed', last_exit: 0 }).includes('exit 0'),
        'and a real 0 is still a 0, not mistaken for nothing');
    assert.ok(updmgr.renderLastRun({ last_state: 'failed', last_exit: 100 }).includes('exit 100'));
});

claim('what the server put in a row is escaped before it becomes a cell', () => {
    const { updmgr } = load(() => ({}));

    // The note carries text from outside: a storage error, PVE's own words for
    // why a removal failed. It ends up in innerHTML, so it goes through
    // htmlEncode - and this test only means anything because the harness
    // encodes for real.
    const cell = updmgr.renderLastRun({
        last_state: 'skipped',
        last_note: '<img src=x onerror="boom">',
    });

    assert.ok(!cell.includes('<img'), `raw tag in a grid cell: ${cell}`);
    assert.ok(cell.includes('&lt;img'), 'it is shown as text instead');

    // Same for a state nobody wrote on purpose - a hand-edited file.
    const odd = updmgr.renderLastRun({ last_state: '<b>x</b>' });
    assert.ok(!odd.includes('<b>'), odd);
});

claim('and so is the name of whoever saved a version', () => {
    const { updmgr } = load(() => ({}));

    const items = updmgr.versionMenuItems(
        [{ version: 1755690000, user: '<script>x</script>' }],
        () => {},
    );

    assert.ok(!items[0].text.includes('<script>'), items[0].text);
    assert.ok(items[0].text.includes('&lt;script&gt;'));
});

claim('the row buttons are refused to somebody who may not edit that target', () => {
    const { me, records } = gridFor(null, { canEditGuest: false });
    const actions = me.buildColumns.call(me).find((c) => c.xtype === 'actioncolumn');
    const orderButton = actions.items.find((i) => i.tooltip === 'Update order');

    assert.ok(orderButton, 'the order button is on the row');
    assert.strictEqual(
        orderButton.isActionDisabled(null, 0, 0, orderButton, records[1]),
        true,
        'a container is refused without VM.Config.Options',
    );
    assert.strictEqual(
        orderButton.isActionDisabled(null, 0, 0, orderButton, records[0]),
        false,
        'while the host still follows its own privilege',
    );
});

claim('setting an order sends the number to that target\'s own node', () => {
    const { me, records, alerts, requests } = gridFor(() => null);

    me.editOrder.call(me, records[1]);

    assert.strictEqual(alerts.length, 1, 'it asks first');
    assert.strictEqual(alerts[0].value, '5', 'prefilled with what the row has');
    assert.ok(alerts[0].msg.includes('CT 101'), 'and names the target');

    alerts[0].prompt('ok', '12');

    assert.strictEqual(requests.length, 1);
    assert.strictEqual(requests[0].url, '/nodes/node-a/lxc/101/updatemgr/order');
    assert.strictEqual(requests[0].method, 'PUT');
    // Field by field, not deepStrictEqual: the object was built inside the
    // sandbox's own realm, so it is not reference-equal to a plain one here.
    assert.strictEqual(requests[0].params.order, 12);
    assert.strictEqual(me.reloaded, 1, 'and the row is re-read afterwards');
});

claim('an empty field clears it, and a typo sends nothing at all', () => {
    let g = gridFor(() => null);
    g.me.editOrder.call(g.me, g.records[1]);
    g.alerts[0].prompt('ok', '');
    assert.strictEqual(g.requests[0].params.order, 0, 'empty clears it');

    g = gridFor(() => null);
    g.me.editOrder.call(g.me, g.records[1]);
    g.alerts[0].prompt('ok', 'ten');
    assert.strictEqual(g.requests.length, 0, 'a typo is not sent');
    assert.strictEqual(g.alerts.length, 2, 'it is reported instead');
    assert.ok(g.alerts[1].msg.includes('number'), 'and the message says what was wrong');

    g = gridFor(() => null);
    g.me.editOrder.call(g.me, g.records[1]);
    g.alerts[0].prompt('cancel', '99');
    assert.strictEqual(g.requests.length, 0, 'and Cancel writes nothing');
});

claim('the confirmation counts the containers that will be switched off', () => {
    const { me, alerts } = gridFor(() => null, { selected: ['101', '102'] });

    me.runSelected.call(me);

    assert.strictEqual(alerts.length, 1);
    assert.ok(
        alerts[0].msg.includes('2 of them are shut down for their snapshot'),
        `downtime is named before it happens: ${alerts[0].msg}`,
    );
});

claim('and says nothing about downtime where the node does not do that', () => {
    const rows = JSON.parse(JSON.stringify(ROWS));
    rows[0].snapshot_shutdown = false;

    const { me, alerts } = gridFor(() => null, { rows: rows, selected: ['101', '102'] });

    me.runSelected.call(me);

    assert.ok(!alerts[0].msg.includes('shut down for their snapshot'));
});

claim('the host row is not counted as a container that gets shut down', () => {
    const { me, alerts } = gridFor(() => null, { selected: ['node-a'] });

    me.runSelected.call(me);

    // The setting is about containers. A host row in the selection would
    // otherwise promise downtime that nothing in the run produces.
    assert.ok(!alerts[0].msg.includes('shut down for their snapshot'));
});

// ── what the confirmation promises about a parallel run ─────────────────────
//
// The dialog has to match what will actually happen, and what happens changed:
// a parallel run no longer starts everything at once regardless of the order, it
// starts a whole position at once and waits for it. A dialog still promising the
// old behaviour would be describing a run nobody can get any more.
claim('a parallel node says the run goes by update-order position', () => {
    const rows = JSON.parse(JSON.stringify(ROWS));
    rows[0].parallel_manual = true;

    const { me, alerts } = gridFor(() => null, { rows: rows, selected: ['101', '102'] });

    me.runSelected.call(me);

    assert.match(alerts[0].msg, /sharing an update-order position start at once/);
    assert.match(alerts[0].msg, /the next position waits/);
    assert.doesNotMatch(
        alerts[0].msg,
        /each in its own task/,
        'and no longer promises a task per target, which is not what it does',
    );
});

claim('a serial node still says one after another', () => {
    const { me, alerts } = gridFor(() => null, { selected: ['101', '102'] });

    me.runSelected.call(me);

    assert.match(alerts[0].msg, /one after another, per server/);
});

// Confirming sends ONE call, whichever way the nodes update - the split into a
// parallel half and a serial half is gone, because the two are now sent the same
// way and only the node decides what it does with its share.
claim('confirming a mixed selection sends one request per node, not per mode', () => {
    const rows = [
        { type: 'node', id: 'node-a', name: 'node-a', stored: true, order: 0,
          parallel_manual: true },
        { type: 'lxc', id: '101', vmid: 101, name: 'db', stored: true, order: 5,
          node: 'node-a' },
        { type: 'lxc', id: '102', vmid: 102, name: 'web', stored: true, order: 0,
          node: 'node-a' },
    ];

    const { me, alerts, requests } = gridFor(() => 'UPID:node-a:0:updatemgr:', {
        rows: rows,
        selected: ['101', '102'],
    });

    const before = requests.length;
    me.runSelected.call(me);
    assert.strictEqual(requests.length - before, 0, 'nothing is sent before the answer');

    alerts[0].confirm('yes');

    assert.strictEqual(requests.length - before, 1, 'one node, one request');
    assert.strictEqual(requests[before].url, '/nodes/node-a/updatemgr/run');
    assert.strictEqual(requests[before].params.vmids, '101,102', 'carrying both targets');
});

// ── Order Selected ─────────────────────────────────────────────────────────
//
// One number, written to every ticked target. The interesting part is not the
// loop, it is what the button refuses to do: send a typo, write a target the
// user may not change, or leave the grid showing numbers that are no longer
// there.
claim('ordering a selection sends the same number to every target', () => {
    const g = gridFor(() => null, { selected: ['101', '102'] });

    g.me.orderSelected.call(g.me);

    assert.strictEqual(g.alerts.length, 1, 'it asks once, for one number');
    assert.match(g.alerts[0].msg, /these 2 targets/, 'saying how many it will write');
    assert.match(g.alerts[0].msg, /SAME number/, 'and that they all get the same one');

    const before = g.requests.length;
    g.alerts[0].prompt('ok', '7');

    const sent = g.requests.slice(before);
    assert.strictEqual(sent.length, 2, 'one request per target');
    assert.deepStrictEqual(
        sent.map((r) => r.url).sort(),
        ['/nodes/node-a/lxc/101/updatemgr/order', '/nodes/node-a/lxc/102/updatemgr/order'],
        'each to its own target',
    );
    assert.ok(
        sent.every((r) => r.params.order === 7 && r.method === 'PUT'),
        'all carrying the one number that was typed',
    );
});

claim('the host row goes to its own order endpoint', () => {
    const g = gridFor(() => null, { selected: ['node-a', '101'] });

    g.me.orderSelected.call(g.me);
    const before = g.requests.length;
    g.alerts[0].prompt('ok', '3');

    assert.deepStrictEqual(
        g.requests.slice(before).map((r) => r.url).sort(),
        ['/nodes/node-a/lxc/101/updatemgr/order', '/nodes/node-a/updatemgr/order'],
        'the host has no vmid, so it is not addressed as though it had one',
    );
});

// A single target keeps the prompt it always had: that one names the target and
// prefills its own number, which a selection cannot.
claim('one ticked target still gets the single-target prompt', () => {
    const g = gridFor(() => null, { selected: ['101'] });

    g.me.orderSelected.call(g.me);

    assert.strictEqual(g.alerts.length, 1);
    assert.match(g.alerts[0].msg, /Where CT 101 \(db\) goes/, 'it names the one target');
    assert.strictEqual(g.alerts[0].value, '5', 'and offers the number it has');
});

claim('the box is prefilled only with a number they all share', () => {
    // 101 is on 5 and 102 has none, so there is nothing to suggest.
    let g = gridFor(() => null, { selected: ['101', '102'] });
    g.me.orderSelected.call(g.me);
    assert.strictEqual(g.alerts[0].value, '', 'no shared number, empty box');

    const rows = JSON.parse(JSON.stringify(ROWS));
    rows[1].order = 4;
    rows[2].order = 4;
    g = gridFor(() => null, { rows: rows, selected: ['101', '102'] });
    g.me.orderSelected.call(g.me);
    assert.strictEqual(g.alerts[0].value, '4', 'a shared number is offered back');
});

claim('an empty answer clears the order of all of them', () => {
    const g = gridFor(() => null, { selected: ['101', '102'] });

    g.me.orderSelected.call(g.me);
    const before = g.requests.length;
    g.alerts[0].prompt('ok', '   ');

    const sent = g.requests.slice(before);
    assert.strictEqual(sent.length, 2);
    assert.ok(sent.every((r) => r.params.order === 0), '0 is how "no answer given" is spelled');
});

claim('a typo is reported instead of sent, and Cancel writes nothing', () => {
    let g = gridFor(() => null, { selected: ['101', '102'] });
    g.me.orderSelected.call(g.me);
    let before = g.requests.length;
    g.alerts[0].prompt('ok', '9e9');

    assert.strictEqual(g.requests.length - before, 0, 'nothing was sent');
    assert.strictEqual(g.alerts.length, 2, 'it is reported');
    assert.match(g.alerts[1].msg, /number between 0 and 99999/, 'with the range');

    g = gridFor(() => null, { selected: ['101', '102'] });
    g.me.orderSelected.call(g.me);
    before = g.requests.length;
    g.alerts[0].prompt('cancel', '7');
    assert.strictEqual(g.requests.length - before, 0, 'and Cancel writes nothing at all');
});

// Refused BEFORE the prompt, not after: otherwise the operator types a number
// and the permission error arrives once per target, with some already written.
claim('a target the user may not change stops the whole write', () => {
    const g = gridFor(() => null, {
        selected: ['node-a', '101'],
        canEditHost: false,
    });

    g.me.orderSelected.call(g.me);

    assert.strictEqual(g.requests.length, 0, 'nothing is sent');
    assert.strictEqual(g.alerts.length, 1);
    assert.match(g.alerts[0].msg, /may not change the update order/);
    assert.match(g.alerts[0].msg, /Host node-a/, 'and it names which one');
    assert.ok(!g.alerts[0].prompt, 'and it is not the prompt - nothing was asked');
});

claim('failures are collected into one dialog, and the grid is reloaded anyway', () => {
    const g = gridFor(
        (url) => (url.includes('/102/') ? { failure: 'permission denied' } : null),
        { selected: ['101', '102'] },
    );

    g.me.orderSelected.call(g.me);
    g.alerts[0].prompt('ok', '2');

    assert.strictEqual(g.alerts.length, 2, 'exactly one dialog for the failures');
    assert.match(g.alerts[1].msg, /1 of 2 targets could not be changed/);
    assert.match(g.alerts[1].msg, /CT 102 \(web\)/, 'naming the one that did not take');
    assert.strictEqual(g.me.reloaded, 1, 'and the row that DID change is shown as it is now');
});

claim('nothing selected is an error, not an empty write', () => {
    const g = gridFor(() => null, { selected: [] });

    g.me.orderSelected.call(g.me);

    assert.strictEqual(g.requests.length, 0);
    assert.strictEqual(g.alerts.length, 1);
    assert.match(g.alerts[0].msg, /No target selected/);
});

// ── the row's log button ───────────────────────────────────────────────────
//
// It used to open Proxmox' task log of the last run - one log, and grey when there
// was none. There is no "show me exactly one log" anywhere any more: picking which
// one is what the window is for, and a target with kept logs and no current task
// still has something to show.
claim('the row opens the window with ALL logs, never a single one', () => {
    const { me, records } = gridFor(() => null);
    const actions = me.buildColumns.call(me).find((c) => c.xtype === 'actioncolumn');
    const logButton = actions.items.find((i) => i.tooltip === 'Logs');

    assert.ok(logButton, 'the row has a log button');
    assert.strictEqual(
        logButton.isActionDisabled,
        undefined,
        'and it is never disabled - the task log is a button INSIDE the window now',
    );
});

claim('and it opens it on that row\'s own target and node', () => {
    const rows = [
        { type: 'node', id: 'node-a', name: 'node-a', stored: true, order: 0 },
        { type: 'lxc', id: '201', vmid: 201, name: 'far', stored: true, order: 0,
          node: 'node-b', last_upid: 'UPID:node-b:1:2:3:ctupdate:201:root@pam:' },
    ];
    const g = gridFor(() => null, { rows: rows });

    g.me.openLogs.call(g.me, g.records[1]);

    const win = g.created[g.created.length - 1];
    assert.strictEqual(win.xclass, 'PVE.updmgr.LogWindow');
    assert.strictEqual(win.config.logsUrl, '/nodes/node-b/lxc/201/updatemgr/logs');
    assert.strictEqual(
        win.config.lastUpid,
        'UPID:node-b:1:2:3:ctupdate:201:root@pam:',
        "the row's own last task, so Proxmox' log stays reachable with logs switched off",
    );
    assert.match(win.config.targetLabel, /CT 201/);
});

claim('the host row goes to the host log endpoint', () => {
    const { updmgr } = load(() => ({}));

    assert.strictEqual(
        updmgr.logsUrlFor({ type: 'node', node: 'node-b', name: 'node-b' }, 'node-a'),
        '/nodes/node-b/updatemgr/logs',
        'the host has no vmid, so it is not addressed as though it had one',
    );
    assert.strictEqual(
        updmgr.logsUrlFor({ type: 'lxc', vmid: 201 }, 'node-a'),
        '/nodes/node-a/lxc/201/updatemgr/logs',
        'and a row with no node of its own uses the tab it was clicked on',
    );
    assert.strictEqual(
        updmgr.logsUrlFor({ type: 'lxc', vmid: 201 }),
        undefined,
        'while no node anywhere is not guessed at',
    );
});

// ── a cluster: the target's own node, not the one you are connected to ─────
//
// Every endpoint behind these windows is `proxyto => 'node'`, so the node in the
// PATH is the machine that answers. Get it wrong and the datacenter tab reads
// the scripts, the versions and the run logs of whichever node the browser
// happens to be talking to - and the run logs are the one thing that is NOT
// replicated, so it would silently show nothing instead of the wrong thing.
claim('the editor of a container on another node is addressed to that node', () => {
    const rows = [
        { type: 'node', id: 'node-a', name: 'node-a', stored: true, order: 0 },
        { type: 'lxc', id: '201', vmid: 201, name: 'far', stored: true, order: 0,
          node: 'node-b' },
    ];
    const g = gridFor(() => null, { rows: rows, selected: [] });

    g.me.editTarget.call(g.me, g.records[1]);

    const win = g.created[g.created.length - 1];
    assert.strictEqual(win.xclass, 'PVE.updmgr.ScriptWindow');
    assert.strictEqual(
        win.config.scriptUrl,
        '/nodes/node-b/lxc/201/updatemgr/script',
        'the editor reads node-b, not the tab we are on',
    );
    assert.strictEqual(win.config.runUrl, '/nodes/node-b/lxc/201/updatemgr/run');
});

claim('and its run logs are read from that node too', () => {
    const { classes } = load(() => ({}));
    const panel = Object.assign({}, classes['PVE.updmgr.ScriptPanel'], {
        scriptUrl: '/nodes/node-b/lxc/201/updatemgr/script',
    });

    // The one endpoint whose answer only EXISTS on the owning node: a run log is
    // written to /var/lib there and is not replicated, so an URL pointing at the
    // wrong node answers with an empty list rather than an error.
    assert.strictEqual(panel.logsUrl.call(panel), '/nodes/node-b/lxc/201/updatemgr/logs');
});

claim('a host row on another node is addressed to that host', () => {
    const rows = [
        { type: 'node', id: 'node-b', name: 'node-b', stored: true, order: 0,
          node: 'node-b' },
    ];
    const g = gridFor(() => null, { rows: rows, selected: [] });

    g.me.editTarget.call(g.me, g.records[0]);

    const win = g.created[g.created.length - 1];
    assert.strictEqual(win.config.scriptUrl, '/nodes/node-b/updatemgr/script');
    // Field by field, not deepStrictEqual: the object was built inside the V8
    // context and its prototype is that realm's, so it is never reference-equal
    // to one made out here. The dispatch tests carry the same note.
    assert.strictEqual(win.config.runParams.host, 1, 'and asks for the host itself');
});

done();
