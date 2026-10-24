// The community-addon notice (#78): every Update Manager surface says, without
// a click, that this is not part of Proxmox VE and where problems go - so they
// reach the author rather than Proxmox support.
//
// What this holds is the decision - which panels carry the notice, what it
// says, where it links. How it looks is a browser's to show.
//
//   node tests/js/notice.test.js

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

claim('the notice says it is a community addon and sends problems to GitHub, not to Proxmox', () => {
    const { updmgr } = load(() => ({}));
    const n = updmgr.addonNotice();
    assert.strictEqual(n.dock, 'top', 'docked at the top');
    assert.ok(n.weight < 0, 'above the panel\'s own toolbar');
    assert.match(n.html, /community addon, not part of Proxmox VE/);
    assert.match(n.html, /not to Proxmox support/);
    assert.ok(n.html.includes('href="https://github.com/LordNeksus06/pve-update-manager/issues"'),
        'links to the issue tracker');
    assert.match(n.html, /target="_blank" rel="noopener noreferrer"/, 'in a new tab, without an opener');
});

// A stand-in `me`: the parts of a panel the tail of initComponent touches after
// the notice is docked, so that initComponent runs to its end.
function built(cls, extra) {
    const { classes } = load(() => ({}));
    const me = Object.assign({}, classes[cls], extra, {
        callParent() {}, on() {}, mon() {}, setLoading() {}, reload() {}, load() {}, loadScript() {},
    });
    me.initComponent.call(me);
    return JSON.stringify((me.dockedItems || []).map((d) => d.itemId));
}

// The toolbar's items, wherever initComponent left them: a grid's tbar is an
// array, the script panel's a toolbar config with `items`.
function toolbarOf(cls, extra) {
    const loaded = load(() => ({}));
    const me = Object.assign({}, loaded.classes[cls], extra, {
        callParent() {}, on() {}, mon() {}, setLoading() {}, reload() {}, load() {}, loadScript() {},
    });
    me.initComponent.call(me);
    const items = Array.isArray(me.tbar) ? me.tbar : (me.tbar || {}).items || [];
    return { loaded, items: Array.from(items) };
}

for (const [label, cls, extra] of [
    ['the node and datacenter lists', 'PVE.updmgr.TargetGrid', { nodename: 'node-a', targetsUrl: '/x' }],
    ['the script panel', 'PVE.updmgr.ScriptPanel',
        { nodename: 'node-a', targetType: 'lxc', targetId: '101', scriptUrl: '/s' }],
]) {
    claim(`${label}: the last toolbar button reports a problem on GitHub`, () => {
        const { loaded, items } = toolbarOf(cls, extra);
        const button = items[items.length - 1];
        assert.strictEqual(button && button.itemId, 'updmgrReportButton', 'it is the last item');
        assert.strictEqual(button.text, 'Report a problem');
        const opened = [];
        loaded.updmgr.openUrl = (url) => opened.push(url);
        button.handler();
        assert.strictEqual(JSON.stringify(opened),
            '["https://github.com/LordNeksus06/pve-update-manager/issues"]', 'and opens the issue tracker');
    });
}

claim('the node and datacenter lists carry the notice', () => {
    assert.strictEqual(built('PVE.updmgr.TargetGrid', { nodename: 'node-a', targetsUrl: '/x' }),
        '["updmgrAddonNotice"]');
});

claim('the script panel - a guest\'s tab and the editor popup - carries the notice', () => {
    assert.strictEqual(built('PVE.updmgr.ScriptPanel',
        { nodename: 'node-a', targetType: 'lxc', targetId: '101', scriptUrl: '/s' }), '["updmgrAddonNotice"]');
});

done();
