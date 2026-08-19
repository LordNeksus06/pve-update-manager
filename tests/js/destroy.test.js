// What the destroy dialog's extra tick sends, and what it must never send.
//
// The tick itself and the dialog around it belong to Proxmox and are only
// reachable in a browser. What is decided HERE is the one thing that can go
// wrong quietly: which URL the cleanup is aimed at. The same window destroys
// VMs, and a request built from a VM's URL would be aimed at an endpoint that
// does not exist - or worse, at a container that happens to share the id.
//
//   node tests/js/destroy.test.js

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

const { updmgr } = load(() => '');

claim("a container's destroy URL becomes its update manager URL", () => {
    assert.strictEqual(
        updmgr.destroyCleanupUrl('/nodes/pve-a/lxc/101'),
        '/nodes/pve-a/lxc/101/updatemgr/script?purge=1',
    );
});

// The record of when a container was last updated is deliberately kept when
// only its commands are deleted. Here it must go: the vmid comes back.
claim('and it purges the last-run record too, not only the commands', () => {
    assert.match(updmgr.destroyCleanupUrl('/nodes/pve/lxc/999'), /[?&]purge=1$/);
});

claim('a VM produces no cleanup at all', () => {
    assert.strictEqual(updmgr.destroyCleanupUrl('/nodes/pve-a/qemu/101'), undefined);
});

claim('and neither does anything else that is not exactly a container', () => {
    for (const url of [
        undefined,
        '',
        '/nodes/pve-a/lxc/101/snapshot',
        '/nodes/pve-a/lxc/abc',
        '/nodes/pve-a/lxc/',
        '/cluster/updatemgr/targets',
        'lxc/101',
    ]) {
        assert.strictEqual(
            updmgr.destroyCleanupUrl(url),
            undefined,
            `${JSON.stringify(url)} must not produce a request`,
        );
    }
});

// A node name is not always a bare word - a fully qualified one has dots in it,
// and a strict pattern that forgot them would silently stop cleaning up.
claim('a node name with dots and dashes in it still matches', () => {
    assert.strictEqual(
        updmgr.destroyCleanupUrl('/nodes/pve-a.example.test/lxc/101'),
        '/nodes/pve-a.example.test/lxc/101/updatemgr/script?purge=1',
    );
});

done();
