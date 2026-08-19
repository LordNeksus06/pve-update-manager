// PVE.updmgr.dispatch - what pressing Update on a pile of targets puts on screen.
//
// The interface file is loaded into a V8 context carrying just enough of ExtJS
// and Proxmox to let it run: the point is to exercise the real
// js/pve-update-manager.js, not a second copy of its logic that can drift away
// from it. The loader itself lives in harness.js, shared with the other tests.
//
//   node tests/js/dispatch.test.js
//
// Named as claims, so a failure reads as a sentence about the interface.

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

function containers(count) {
    const targets = [];
    for (let i = 0; i < count; i++) {
        targets.push({ type: 'lxc', vmid: 100 + i, node: 'pve', name: `ct${100 + i}` });
    }
    return targets;
}

// The case this exists for: forty containers, twelve of them with nothing
// stored. The server records those as skipped on their own row and answers with
// no task - so the screen must stay empty of dialogs, whatever the count.
claim('containers the server skipped produce no dialog at all', () => {
    const withoutScript = new Set([103, 107, 111, 115, 119, 123, 127, 131, 133, 135, 137, 139]);
    const { updmgr, alerts } = load((url) => {
        const vmid = Number(url.match(/lxc\/(\d+)\//)[1]);
        return withoutScript.has(vmid) ? '' : `UPID:pve:${vmid}:ctupdate:`;
    });

    let started;
    updmgr.dispatch(containers(40), 'pve', true, (s) => {
        started = s;
    });

    assert.strictEqual(alerts.length, 0, 'no message box was opened');
    assert.strictEqual(started.length, 28, '28 of the 40 actually started');
    assert.ok(
        started.every((t) => t.upid),
        'and every one of those carries a task to watch',
    );
});

claim('a skipped target is not counted as a task that was started', () => {
    const { updmgr } = load(() => '');

    let started;
    updmgr.dispatch(containers(3), 'pve', true, (s) => {
        started = s;
    });

    // length, not deepStrictEqual: the array is built inside the V8 context and
    // so is not reference-equal to an array made out here.
    assert.strictEqual(started.length, 0, 'nothing started, nothing reported as running');
});

// The dialog is not gone, only the reason for it: a request that genuinely
// failed still has to be said out loud, once, naming which target it was.
claim('a real failure is still reported, and still in a single dialog', () => {
    const { updmgr, alerts } = load((url) =>
        url.includes('/101/') || url.includes('/102/')
            ? { failure: 'CT is locked (mounted)' }
            : '',
    );

    updmgr.dispatch(containers(5), 'pve', true, () => {});

    assert.strictEqual(alerts.length, 1, 'exactly one message box, not one per target');
    assert.match(alerts[0].msg, /2 of 5 targets could not be started/);
    assert.match(alerts[0].msg, /CT 101/);
    assert.match(alerts[0].msg, /CT 102/);
});

claim('a failure among skipped ones names only the failure', () => {
    const { updmgr, alerts } = load((url) =>
        url.includes('/104/') ? { failure: 'CT is locked (mounted)' } : '',
    );

    updmgr.dispatch(containers(5), 'pve', true, () => {});

    assert.strictEqual(alerts.length, 1);
    assert.match(alerts[0].msg, /1 of 5 targets could not be started/);
    assert.doesNotMatch(alerts[0].msg, /CT 100|CT 101|CT 102|CT 103\b/);
});

// Serial mode sends one request per node, and that request is a task even when
// some of the containers in it have no script - the worker skips those itself
// and writes the same note on their rows.
claim('serial mode still gets its one task per node', () => {
    const { updmgr, alerts } = load(() => 'UPID:pve:0:updatemgr:');

    let started;
    updmgr.dispatch(containers(40), 'pve', false, (s) => {
        started = s;
    });

    assert.strictEqual(started.length, 1, 'one request, one task');
    assert.strictEqual(alerts.length, 0);
});

done();
