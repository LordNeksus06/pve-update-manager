// What the destroy dialog's extra tick sends, and what it must never send.
//
// The tick itself and the dialog around it belong to Proxmox and are only
// reachable in a browser. What is decided HERE is the one thing that can go
// wrong quietly: which URL the cleanup is aimed at. The same window destroys
// containers and VMs, and a VM's cleanup aimed at the container path would hit
// an endpoint that answers "not a container" - or worse, a container that
// happens to share the id.
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

claim("a VM's destroy URL becomes the VM's own update manager URL, not a container's", () => {
    assert.strictEqual(
        updmgr.destroyCleanupUrl('/nodes/pve-a/qemu/101'),
        '/nodes/pve-a/qemu/101/updatemgr/script?purge=1',
    );
});

claim('and nothing else that is not exactly a guest produces a request', () => {
    for (const url of [
        undefined,
        '',
        '/nodes/pve-a/lxc/101/snapshot',
        '/nodes/pve-a/qemu/101/snapshot',
        '/nodes/pve-a/lxc/abc',
        '/nodes/pve-a/lxc/',
        '/nodes/pve-a/openvz/101',
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
