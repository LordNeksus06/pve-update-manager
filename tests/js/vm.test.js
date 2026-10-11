// VMs in the interface: every URL a VM row produces points at the VM's own API
// path, and every label calls it a VM.
//
// The failure this defends against is quiet: a VM row that builds a container
// URL gets "not a container on node ..." back - or, worse, reaches a container
// that happens to share nothing but the path shape. The server answers both, so
// nothing on screen would look broken until a script was saved to the wrong
// place.
//
//   node tests/js/vm.test.js

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

const vm = { type: 'qemu', vmid: 200, node: 'pve-a', name: 'web-vm' };
const ct = { type: 'lxc', vmid: 101, node: 'pve-a', name: 'db' };

claim("a VM row's script, order and logs live under /qemu/, a container's under /lxc/", () => {
    const { updmgr } = load(() => '');

    assert.strictEqual(updmgr.scriptUrlFor(vm), '/nodes/pve-a/qemu/200/updatemgr/script');
    assert.strictEqual(updmgr.orderUrlFor(vm), '/nodes/pve-a/qemu/200/updatemgr/order');
    assert.strictEqual(updmgr.logsUrlFor(vm), '/nodes/pve-a/qemu/200/updatemgr/logs');
    assert.strictEqual(updmgr.scriptUrlFor(ct), '/nodes/pve-a/lxc/101/updatemgr/script');
});

claim('a VM is labelled VM, a container CT', () => {
    const { updmgr } = load(() => '');

    assert.strictEqual(updmgr.targetLabel(vm), 'VM 200 (web-vm)');
    assert.strictEqual(updmgr.targetLabel(ct), 'CT 101 (db)');
});

claim('one VM on its own is run through its own endpoint', () => {
    const { updmgr, requests } = load(() => 'UPID:pve-a:0:vmupdate:');

    updmgr.dispatch([vm], 'pve-a', () => {});

    assert.strictEqual(requests.length, 1);
    assert.strictEqual(requests[0].url, '/nodes/pve-a/qemu/200/updatemgr/run');
});

claim('a VM and a container on one server are one request naming both', () => {
    const { updmgr, requests } = load(() => 'UPID:pve-a:0:updatemgr:');

    updmgr.dispatch([ct, vm], 'pve-a', () => {});

    assert.strictEqual(requests.length, 1, 'one task per node, whatever the kinds');
    assert.strictEqual(requests[0].url, '/nodes/pve-a/updatemgr/run');
    assert.strictEqual(requests[0].params.vmids, '101,200');
});

// The tab itself is only visible in a browser; what is decided here is whether a
// VM's config panel gets one, and which kind it is told it shows.
function panelOf(cls, data) {
    return { $className: cls, pveSelNode: { data: data }, items: [{ itemId: 'summary' }] };
}

const guiCap = { vms: { 'VM.Audit': 1, 'VM.Console': 1 } };

claim("a VM's config panel gets the tab, bound to the VM API", () => {
    const { updmgr } = load(() => '', { guiCap: guiCap });
    const panel = panelOf('PVE.qemu.Config', { node: 'pve-a', vmid: 200, name: 'web-vm' });

    updmgr.injectTab(panel);

    const tab = panel.items.find((i) => i.itemId === 'updatemgr');
    assert.ok(tab, 'the tab is there');
    assert.strictEqual(tab.guestType, 'qemu');
    assert.strictEqual(tab.vmid, 200);
});

claim("a container's panel still gets it as a container", () => {
    const { updmgr } = load(() => '', { guiCap: guiCap });
    const panel = panelOf('PVE.lxc.Config', { node: 'pve-a', vmid: 101, name: 'db' });

    updmgr.injectTab(panel);

    assert.strictEqual(panel.items.find((i) => i.itemId === 'updatemgr').guestType, 'lxc');
});

claim('a VM template gets no tab', () => {
    const { updmgr } = load(() => '', { guiCap: guiCap });
    const panel = panelOf('PVE.qemu.Config', { node: 'pve-a', vmid: 9000, template: 1 });

    updmgr.injectTab(panel);

    assert.strictEqual(panel.items.length, 1);
});

done();
