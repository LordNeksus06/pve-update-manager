// The security check in the target lists (#41): the cell, the column and the
// "Check now" button, against the real built bundle.
//
// Not a browser, and no claim about how it looks - only about what it decides.
//
//   node tests/js/security.test.js

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

claim('a target no check has seen says so, without a number', () => {
    const { updmgr } = load(() => ({}));
    const cell = updmgr.renderSecurity({});
    assert.ok(cell.includes('not checked'), cell);
    assert.ok(!/\d/.test(cell), `no number for a target nobody checked: ${cell}`);
});

claim('a checked target with nothing pending shows 0', () => {
    const { updmgr } = load(() => ({}));
    const cell = updmgr.renderSecurity({ security_status: 'ok', security_count: 0 });
    assert.ok(cell.includes('0'), cell);
    assert.ok(cell.includes('fa-check'), cell);
});

claim('pending updates show their count and names, with "…" when there are more', () => {
    const { updmgr } = load(() => ({}));
    const cell = updmgr.renderSecurity({
        security_status: 'ok', security_count: 7, security_packages: 'openssl,libc6',
    });
    assert.ok(cell.includes('7 (openssl, libc6, …)'), cell);
    assert.ok(cell.includes('fa-exclamation-triangle'), cell);
});

claim('pending updates whose source has no packages say so, count kept, reason on hover (#53)', () => {
    const { updmgr } = load(() => ({}));
    const cell = updmgr.renderSecurity({
        security_status: 'ok', security_count: 3, security_packages: 'dpkg,libc6,login',
        security_warning: 'package files answer HTTP 404 <b>',
    });
    assert.ok(cell.includes('(dpkg, libc6, login)'), cell);
    // Before the names: behind a long list the column cuts the words off.
    assert.ok(/3 – packages unavailable \(dpkg/.test(cell), cell);
    assert.ok(cell.includes('fa-times-circle'), cell);
    assert.ok(cell.includes('data-qtip=') && cell.includes('HTTP 404'), cell);
    assert.ok(!cell.includes('<b>'), 'the reason is escaped: ' + cell);
});

claim('a target that could not be checked gets a dash and the reason - never a 0', () => {
    const { updmgr } = load(() => ({}));
    const cell = updmgr.renderSecurity({
        security_status: 'no-agent', security_count: 0, security_reason: 'agent did not answer',
    });
    assert.ok(cell.includes('no guest agent'), cell);
    assert.ok(cell.includes('agent did not answer'), 'the reason is in the tooltip');
    assert.ok(!/>\s*0\b/.test(cell) && !cell.includes('fa-check'), `no "0", no tick: ${cell}`);
});

claim('package names and reasons from the server are escaped', () => {
    const { updmgr } = load(() => ({}));
    const a = updmgr.renderSecurity({
        security_status: 'ok', security_count: 1, security_packages: '<img src=x onerror=boom>',
    });
    assert.ok(!a.includes('<img'), a);
    const b = updmgr.renderSecurity({ security_status: 'error', security_reason: '"><script>x</script>' });
    assert.ok(!b.includes('<script>'), b);
});

claim('the node and datacenter grids have the column, the container tab does not', () => {
    const loaded = load(() => ({}));
    const cfg = loaded.classes['PVE.updmgr.TargetGrid'];
    const withIt = cfg.buildColumns.call(Object.assign({}, cfg, { showSettings: true }));
    const without = cfg.buildColumns.call(Object.assign({}, cfg, { showSettings: false }));
    assert.ok(withIt.some((c) => c.header === 'Security'), 'node/datacenter: there');
    assert.ok(!without.some((c) => c.header === 'Security'), 'container tab: not there');
});

claim('"Check now" is a node-tab button, not a datacenter one', () => {
    const { classes } = load(() => ({}));
    assert.strictEqual(classes['PVE.updmgr.NodePanel'].showCheckNow, true);
    assert.ok(!classes['PVE.updmgr.DcPanel'].showCheckNow, 'the check runs per node');
});

claim('"Check now" posts to that node\'s endpoint and opens the task it started', () => {
    const loaded = load(() => 'UPID:node-a:1:2:3:updmgrscan::root@pam:');
    let reloaded = 0;
    loaded.updmgr.checkNow({ reload: () => { reloaded += 1; } }, 'node-a');
    const req = loaded.requests[loaded.requests.length - 1];
    assert.strictEqual(req.url, '/nodes/node-a/updatemgr/security/scan');
    assert.strictEqual(req.method, 'POST');
    const viewer = loaded.created.find((c) => c.xclass === 'Proxmox.window.TaskViewer');
    assert.ok(viewer, 'a task viewer is opened');
    assert.strictEqual(viewer.config.upid, 'UPID:node-a:1:2:3:updmgrscan::root@pam:');
});

done();
