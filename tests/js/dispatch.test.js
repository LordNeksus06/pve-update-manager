// PVE.updmgr.dispatch - what pressing Update on a pile of targets puts on screen.
//
// The interface file is loaded into a V8 context carrying just enough of ExtJS
// and Proxmox to let it run: the point is to exercise the real
// js/pve-update-manager.js, not a second copy of its logic that can drift away
// from it. The loader itself lives in harness.js, shared with the other tests.
//
//   node tests/js/dispatch.test.js
//
// The shape being defended: ONE request per node, whichever way that node
// updates. It used to be one request per target for a parallel run, and that is
// what made the update order do nothing there - no task ever saw more than one
// target to put in an order. It cannot be fixed from here either: waiting for one
// position to finish before starting the next would mean a browser tab holding
// the run together, and a closed tab would take the rest of the order with it.
//
// Named as claims, so a failure reads as a sentence about the interface.

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

function containers(count, node) {
    const targets = [];
    for (let i = 0; i < count; i++) {
        targets.push({
            type: 'lxc',
            vmid: 100 + i,
            node: node || 'pve',
            name: `ct${100 + i}`,
        });
    }
    return targets;
}

// The case this exists for: forty containers on one server. One request, one
// task, and the task is what puts them in order - the browser is not asked to.
claim('a pile of containers on one server is one request', () => {
    const { updmgr, requests, alerts } = load(() => 'UPID:pve:0:updatemgr:');

    let started;
    updmgr.dispatch(containers(40), 'pve', (s) => {
        started = s;
    });

    assert.strictEqual(requests.length, 1, 'one request, not forty');
    assert.strictEqual(requests[0].url, '/nodes/pve/updatemgr/run');
    assert.strictEqual(
        requests[0].params.vmids.split(',').length,
        40,
        'and all forty are named in it',
    );
    assert.strictEqual(started.length, 1, 'one task to watch');
    assert.strictEqual(alerts.length, 0, 'and nothing on screen');
});

claim('a selection spanning servers is one request per server', () => {
    const { updmgr, requests } = load(() => 'UPID:x:0:updatemgr:');

    updmgr.dispatch(
        containers(3, 'pve-a').concat(containers(3, 'pve-b'), containers(3, 'pve-c')),
        'pve-a',
        () => {},
    );

    assert.strictEqual(requests.length, 3, 'three servers, three requests');
    assert.deepStrictEqual(
        requests.map((r) => r.url).sort(),
        [
            '/nodes/pve-a/updatemgr/run',
            '/nodes/pve-b/updatemgr/run',
            '/nodes/pve-c/updatemgr/run',
        ],
        'each one addressed to the server that owns its share',
    );
});

// A container on its own keeps its own endpoint, so the task list says
// "CT 102 - Update Manager" instead of labelling it as a job on the node -
// indistinguishable from updating the host itself.
claim('one container on its own goes to its own endpoint', () => {
    const { updmgr, requests } = load(() => 'UPID:pve:66:ctupdate:');

    updmgr.dispatch(containers(1), 'pve', () => {});

    assert.strictEqual(requests.length, 1);
    assert.strictEqual(requests[0].url, '/nodes/pve/lxc/100/updatemgr/run');
});

// ...unless the host is in the selection too, in which case there is a list to
// walk and the node's own endpoint is the one that can walk it.
claim('a container together with its host goes to the node endpoint', () => {
    const { updmgr, requests } = load(() => 'UPID:pve:0:updatemgr:');

    updmgr.dispatch(
        [{ type: 'node', node: 'pve', name: 'pve' }].concat(containers(1)),
        'pve',
        () => {},
    );

    assert.strictEqual(requests.length, 1);
    assert.strictEqual(requests[0].url, '/nodes/pve/updatemgr/run');
    assert.strictEqual(requests[0].params.host, 1, 'with the host asked for');
    assert.strictEqual(requests[0].params.vmids, '100', 'and the container listed');
});

// A single container with nothing stored is recorded as skipped on its own row
// and answers with no task at all. The screen must stay empty - that is the
// case the confirmation dialog has already described as "will be skipped".
claim('a container the server skipped produces no dialog at all', () => {
    const { updmgr, alerts } = load(() => '');

    let started;
    updmgr.dispatch(containers(1), 'pve', (s) => {
        started = s;
    });

    assert.strictEqual(alerts.length, 0, 'no message box was opened');
    assert.strictEqual(started.length, 0, 'nothing started, nothing reported as running');
});

// The dialog is not gone, only the reason for it: a request that genuinely
// failed still has to be said out loud, once, naming which server it was.
claim('a real failure is still reported, and still in a single dialog', () => {
    const { updmgr, alerts } = load((url) =>
        url.includes('/pve-a/') || url.includes('/pve-b/')
            ? { failure: 'permission denied' }
            : '',
    );

    updmgr.dispatch(
        containers(2, 'pve-a').concat(containers(2, 'pve-b'), containers(2, 'pve-c')),
        'pve-a',
        () => {},
    );

    assert.strictEqual(alerts.length, 1, 'exactly one message box, not one per server');
    assert.match(alerts[0].msg, /2 of 3 targets could not be started/);
    assert.match(alerts[0].msg, /pve-a/);
    assert.match(alerts[0].msg, /pve-b/);
    assert.doesNotMatch(alerts[0].msg, /pve-c/, 'and the one that worked is not in it');
});

// A row with no node of its own - the node tab's own list - falls back to the
// tab's node rather than being dropped on the floor.
claim('a target with no node of its own uses the tab it was clicked on', () => {
    const { updmgr, requests } = load(() => 'UPID:pve:0:updatemgr:');

    updmgr.dispatch(
        [
            { type: 'lxc', vmid: 101, name: 'a' },
            { type: 'lxc', vmid: 102, name: 'b' },
        ],
        'pve-here',
        () => {},
    );

    assert.strictEqual(requests.length, 1);
    assert.strictEqual(requests[0].url, '/nodes/pve-here/updatemgr/run');
});

// runUrlFor is for containers, and a host row must not sneak through it into an
// endpoint that would then be missing host=1 - a request that runs nothing.
claim('the one-container endpoint refuses a host row', () => {
    const { updmgr } = load(() => '');

    assert.strictEqual(
        updmgr.runUrlFor({ type: 'node', node: 'pve', name: 'pve' }, 'pve'),
        undefined,
    );
    assert.strictEqual(
        updmgr.runUrlFor({ type: 'lxc', vmid: 101, name: 'db' }, 'pve').url,
        '/nodes/pve/lxc/101/updatemgr/run',
        'while a container gets its own endpoint',
    );
    assert.strictEqual(
        updmgr.runUrlFor({ type: 'lxc', vmid: 101, name: 'db' }),
        undefined,
        'and a container with no node anywhere is not guessed at',
    );
});

claim('nothing to send is answered without a request', () => {
    const { updmgr, requests } = load(() => 'UPID:x');

    let started = 'not called';
    updmgr.dispatch([], undefined, (s) => {
        started = s;
    });

    assert.strictEqual(requests.length, 0);
    assert.deepStrictEqual(started.length, 0, 'the callback still runs, with nothing in it');
});

done();
