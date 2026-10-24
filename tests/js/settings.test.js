// The settings window, and the multi-target editor's confirmation.
//
// Both are config objects with ordinary functions in them, so they can be
// driven against a stand-in `me`. The settings window is worth this because of
// how it fails: a field it loads but never sends is written back as whatever
// the merge produced, and a field it sends under a name nothing knows is a save
// that comes back red for every node. Neither shows up in a screenshot.
//
//   node tests/js/settings.test.js

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

const SOURCE = fs.readFileSync(
    path.resolve(__dirname, '..', '..', 'js', 'pve-update-manager.js'),
    'utf8',
);
// Literal itemIds, plus the two each parallelRow() call defines - the parallel
// switch and its "at most N" field are built by one helper for both rows.
const DEFINED_ITEM_IDS = new Set([
    ...[...SOURCE.matchAll(/itemId:\s*'([^']+)'/g)].map((m) => m[1]),
    ...[...SOURCE.matchAll(/parallelRow\('([^']+)',\s*'([^']+)'\)/g)].flatMap((m) => [m[1], m[2]]),
]);

// Everything the server answers with, all of it different from the defaults so
// a value that is quietly dropped cannot pass by accident.
const ANSWER = {
    parallel_manual: 1,
    parallel_manual_max: 4,
    timeout: 600,
    start_stopped: 1,
    reboot_vms: 1,
    snapshot_before: 1,
    snapshot_keep: 4,
    snapshot_shutdown: 1,
    rollback_on_failure: 1,
    // The one switch here whose default is ON, so 0 is the value that differs -
    // and the one a `|| default` in the load would quietly turn back on.
    rollback_remove_newer: 0,
    notify_failure: 1,
    script_versions: 5,
    schedule_enabled: 1,
    schedule_time: '04:00',
    schedule_parallel: 1,
    schedule_parallel_max: 6,
    schedule_host: 1,
    schedule_vmids: '101',
    // The seventeen of the security scan (#41, #73), each off its default. Four of
    // them are falsy on purpose - 0 minutes of gap, 0 minutes of cooldown, two switches whose default
    // is on - because a `|| default` in the load turns exactly those back.
    security_scan: 1,
    security_interval: 45,
    security_parallel: 8,
    security_targets: 'script',
    security_source: 'debian',
    security_exclude: 'linux-image-*',
    security_min_severity: 'high',
    security_notify: 0,
    security_notify_once: 0,
    security_unfixed_cooldown: 0,
    security_install: 1,
    security_install_mode: 'security',
    security_install_vmids: '101,102',
    security_install_window: '06:00-22:00',
    security_install_gap: 0,
    security_install_parallel_max: 3,
    security_reboot: 1,
    snapshot_capable: 1,
    nodes: 2,
    uniform: 0,
    last_run: 100,
    next_run: 200,
};

const SECURITY_KEYS = Object.keys(ANSWER).filter((k) => k.startsWith('security_'));

function windowFor(global, answer) {
    const loaded = load(() => answer || ANSWER);
    const cfg = loaded.classes['PVE.updmgr.SettingsWindow'];

    const touched = [];
    const fields = {};
    const hiddenTabs = {};

    const me = Object.assign({}, cfg, {
        global: global,
        nodename: 'node-a',
        preselected: {},
        nodeCount: 0,
        targetGrid: {
            marker: 'targetGrid',
            getStore: () => ({ load() {} }),
            getSelectionModel: () => ({ getSelection: () => [] }),
        },
        close() {},
        down(selector) {
            touched.push(selector.replace('#', ''));
            const id = selector.replace('#', '');
            return {
                setValue: (v) => {
                    fields[id] = v;
                },
                getValue: () => fields[id],
                setHidden() {},
                setText() {},
                setDisabled() {},
                tab: {
                    setHidden: (v) => {
                        hiddenTabs[id] = v;
                    },
                },
            };
        },
    });

    return { me: me, touched: touched, fields: fields, hiddenTabs: hiddenTabs, ...loaded };
}

for (const global of [false, true]) {
    const scope = global ? 'for every node' : 'for one node';

    claim(`the settings window ${scope} only reaches for fields that exist`, () => {
        const { me, touched } = windowFor(global);

        me.load.call(me);

        // A typo here is not a wrong value, it is `setValue` on null - the
        // window throws while opening and shows nothing at all.
        const unknown = touched.filter((id) => !DEFINED_ITEM_IDS.has(id));
        assert.deepStrictEqual(unknown, [], `unknown itemIds: ${unknown.join(', ')}`);
        assert.ok(touched.length >= 10, 'and it really did load a windowful of them');
    });

    claim(`every value it shows ${scope} is a value it sends back`, () => {
        const { me } = windowFor(global);

        me.load.call(me);
        const sent = me.commonParams.call(me);

        // schedule_host and schedule_vmids are the two the two modes add
        // themselves, and last_run belongs to the scheduler.
        // security_install_vmids is a list of one node's guests: in global
        // mode it is neither shown nor sent (a claim of its own below).
        const ignored = ['schedule_host', 'schedule_vmids', 'last_run', 'next_run',
            'snapshot_capable', 'nodes', 'uniform'];
        if (global) {
            ignored.push('security_install_vmids');
        }

        for (const key of Object.keys(ANSWER)) {
            if (ignored.includes(key)) {
                continue;
            }
            assert.strictEqual(
                sent[key],
                ANSWER[key],
                `${key} came back as ${sent[key]} instead of ${ANSWER[key]}`,
            );
        }
    });
}

claim('the timeout survives the trip through minutes', () => {
    const { me, fields } = windowFor(false);

    me.load.call(me);

    // The field is in minutes because the useful values are hours; the API
    // speaks seconds. A window that showed 10 and saved 10 would cut a four
    // hour limit to ten seconds.
    assert.strictEqual(fields.timeout, 10, 'shown in minutes');
    assert.strictEqual(me.commonParams.call(me).timeout, 600, 'sent in seconds');
});

// ── the tabs (#45) ──────────────────────────────────────────────────────────

// The owner's split (#45): which tab carries which setting.
const TAB_OF = {
    General: ['timeout', 'start_stopped', 'reboot_vms', 'notify_failure', 'script_versions',
        'run_logs', 'parallel_manual', 'parallel_manual_max'],
    Snapshot: ['snapshot_before', 'snapshot_keep', 'snapshot_shutdown', 'rollback_on_failure',
        'rollback_remove_newer'],
    Schedule: ['schedule_enabled', 'schedule_time', 'schedule_parallel', 'schedule_parallel_max',
        'schedule_host', 'schedule_vmids'],
    Security: SECURITY_KEYS,
};

// The field that carries each of the nineteen older settings. On a node the
// host tick and the ticked containers are both the target grid.
function itemOf(global, updmgr) {
    const map = {
        timeout: 'timeout', start_stopped: 'startStopped', reboot_vms: 'rebootVms',
        notify_failure: 'notifyFailure', script_versions: 'scriptVersions', run_logs: 'runLogs',
        parallel_manual: 'parallelManual', parallel_manual_max: 'parallelManualMax',
        snapshot_before: 'snapshotBefore', snapshot_keep: 'snapshotKeep',
        snapshot_shutdown: 'snapshotShutdown', rollback_on_failure: 'rollbackOnFailure',
        rollback_remove_newer: 'rollbackRemoveNewer', schedule_enabled: 'scheduleEnabled',
        schedule_time: 'scheduleTime', schedule_parallel: 'scheduleParallel',
        schedule_parallel_max: 'scheduleParallelMax',
        schedule_host: global ? 'scheduleHost' : 'targetGrid',
        schedule_vmids: global ? undefined : 'targetGrid',
    };
    for (const f of updmgr.SECURITY_FIELDS) {
        map[f.key] = global && f.perNode ? undefined : f.itemId;
    }
    return map;
}

// Every itemId (and the target grid) somewhere below one tab.
function idsIn(node, out) {
    if (node && typeof node === 'object') {
        if (node.itemId) {
            out.push(node.itemId);
        }
        if (node.marker) {
            out.push(node.marker);
        }
        for (const child of node.items || []) {
            idsIn(child, out);
        }
    }
    return out;
}

claim('the security table names exactly the seventeen security settings', () => {
    const { updmgr } = windowFor(false);

    assert.deepStrictEqual(
        [...updmgr.SECURITY_FIELDS.map((f) => f.key)].sort(),
        [...SECURITY_KEYS].sort(),
    );
    assert.strictEqual(SECURITY_KEYS.length, 17);
});

for (const global of [false, true]) {
    const scope = global ? 'for every node' : 'for one node';

    claim(`${scope}, every setting sits in exactly one tab, the one #45 gives it`, () => {
        const { me, updmgr } = windowFor(global);
        const tabs = updmgr.settingsTabs(me);
        const item = itemOf(global, updmgr);

        assert.deepStrictEqual([...tabs.map((t) => t.title)], ['General', 'Snapshot', 'Schedule', 'Security']);

        let placed = 0;
        for (const tab of tabs) {
            const ids = idsIn(tab, []);
            for (const [title, keys] of Object.entries(TAB_OF)) {
                for (const key of keys) {
                    if (item[key] === undefined) {
                        continue;
                    }
                    const here = ids.filter((id) => id === item[key]).length;
                    // schedule_host and schedule_vmids share the grid on a node.
                    const want = title === tab.title ? 1 : 0;
                    assert.strictEqual(here, want, `${key} (${item[key]}) ${here}x in ${tab.title}`);
                    placed += want;
                }
            }
        }
        // 19 + 17 on a node; the datacenter has no container lists to show.
        assert.strictEqual(placed, global ? 34 : 36);
    });
}

claim('the tabs are a tab panel that renders every tab up front', () => {
    const { me } = windowFor(false);
    me.load = () => {};
    me.callParent = () => {};

    me.initComponent.call(me);

    const panel = me.items.find((i) => i.xtype === 'tabpanel');
    assert.ok(panel, 'there is a tab panel');
    // The target grid is filled from load() while General is showing; with
    // deferred rendering the Schedule tab would not exist yet.
    assert.strictEqual(panel.deferredRender, false);
    const snapshot = panel.items.find((t) => t.itemId === 'snapshotTab');
    assert.strictEqual(snapshot.tabConfig.hidden, true, 'the Snapshot tab starts hidden');
});

claim('the settings window carries the community-addon notice, for one node and for all (#78)', () => {
    for (const global of [false, true]) {
        const { me } = windowFor(global);
        me.load = () => {};
        me.callParent = () => {};
        me.initComponent.call(me);
        assert.strictEqual(JSON.stringify((me.dockedItems || []).map((d) => d.itemId)), '["updmgrAddonNotice"]',
            `global=${global}`);
    }
});

claim('the Snapshot tab is shown where a guest can be snapshotted, and for every node', () => {
    for (const [global, capable, hidden] of [[false, 0, true], [false, 1, false], [true, 0, false]]) {
        const { me, hiddenTabs } = windowFor(global, Object.assign({}, ANSWER, { snapshot_capable: capable }));
        me.load.call(me);
        assert.strictEqual(hiddenTabs.snapshotTab, hidden, `global=${global} capable=${capable}`);
    }
});

claim('0 and the empty string are loaded and sent as themselves', () => {
    const answer = Object.assign({}, ANSWER, {
        security_min_severity: '',
        security_install_window: '',
        security_exclude: '',
    });
    const { me, fields } = windowFor(false, answer);

    me.load.call(me);

    assert.strictEqual(fields.securityMinSeverity, '__default__', "'' is the toolkit's empty key");
    assert.strictEqual(fields.securityInstallGap, 0);
    assert.strictEqual(fields.securityNotify, false);

    const sent = me.commonParams.call(me);
    for (const key of SECURITY_KEYS) {
        assert.strictEqual(sent[key], answer[key], `${key} came back as ${sent[key]}`);
    }
});

claim('a key the server does not answer shows its server default', () => {
    const answer = Object.assign({}, ANSWER);
    SECURITY_KEYS.forEach((k) => delete answer[k]);
    const { me } = windowFor(false, answer);

    me.load.call(me);

    // SecSettings::defaults, written out here rather than read from the table
    // under test.
    assert.deepStrictEqual(
        Object.fromEntries(SECURITY_KEYS.map((k) => [k, me.commonParams.call(me)[k]])),
        {
            security_scan: 0, security_interval: 30, security_parallel: 4,
            security_targets: 'all', security_source: 'configured', security_exclude: '',
            security_min_severity: '', security_notify: 1, security_notify_once: 1,
            security_unfixed_cooldown: 300, security_install: 0, security_install_mode: 'script', security_install_vmids: '',
            security_install_window: '', security_install_gap: 60,
            security_install_parallel_max: 1, security_reboot: 0,
        },
    );
});

claim('a node save sends both per-node lists, a datacenter save neither', () => {
    const node = windowFor(false);
    node.me.load.call(node.me);
    node.me.save.call(node.me);
    const nodeParams = node.requests[node.requests.length - 1].params;
    assert.strictEqual(nodeParams.security_install_vmids, '101,102');
    assert.ok('schedule_vmids' in nodeParams);
    assert.strictEqual(SECURITY_KEYS.filter((k) => k in nodeParams).length, 17);

    const all = windowFor(true);
    all.me.load.call(all.me);
    all.me.save.call(all.me);
    all.alerts[all.alerts.length - 1].confirm('yes');
    const put = all.requests[all.requests.length - 1];
    assert.strictEqual(put.url, '/cluster/updatemgr/settings');
    assert.ok(!('security_install_vmids' in put.params), 'no security vmids');
    assert.ok(!('schedule_vmids' in put.params), 'no schedule vmids');
    assert.strictEqual(SECURITY_KEYS.filter((k) => k in put.params).length, 16);
});

// ── the multi-target editor ─────────────────────────────────────────────────

function multiFor(script) {
    const loaded = load(() => ({ stored: true, script: script }));
    const cfg = loaded.classes['PVE.updmgr.MultiScriptWindow'];

    const me = Object.assign({}, cfg, {
        targets: [
            { type: 'lxc', vmid: 101, node: 'node-a', name: 'db' },
            { type: 'lxc', vmid: 102, node: 'node-a', name: 'web' },
        ],
        defaultNode: 'node-a',
        value: undefined,
        editor: {
            setValue: (v) => {
                me.value = v;
            },
            getValue: () => me.value,
        },
        saveButton: { setDisabled() {} },
        setLoading() {},
        setStatus() {},
        close() {},
    });

    me.load.call(me);

    return { me: me, ...loaded };
}

claim('saving the shared script unchanged asks nothing and writes it', () => {
    const { me, alerts, requests } = multiFor('shared\n');

    assert.strictEqual(me.value, 'shared\n', 'the box is prefilled with what they share');

    const before = requests.length;
    me.save.call(me);

    assert.strictEqual(alerts.length, 0, 'nothing is replaced that the user has not seen');
    assert.strictEqual(requests.length - before, 2, 'and both targets are written');
});

claim('editing that shared script asks before it replaces them', () => {
    const { me, alerts, requests } = multiFor('shared\n');

    me.editor.setValue('something else\n');
    const before = requests.length;
    me.save.call(me);

    // The window was opened on a script they all share; the box no longer holds
    // it. Saving now DOES replace two targets' commands with something new,
    // which is exactly what the confirmation is for.
    assert.strictEqual(alerts.length, 1, 'it asks');
    assert.ok(alerts[0].msg.includes('Replace all of them'), alerts[0].msg);
    assert.strictEqual(requests.length - before, 0, 'and writes nothing until answered');

    alerts[0].confirm('yes');
    assert.strictEqual(requests.length - before, 2, 'then both targets are written');
});

claim('an empty box is refused rather than stored as "nothing to do"', () => {
    const { me, alerts, requests } = multiFor('shared\n');

    me.editor.setValue('   \n');
    const before = requests.length;
    me.save.call(me);

    assert.strictEqual(requests.length - before, 0);
    assert.strictEqual(alerts.length, 1);
    assert.ok(alerts[0].msg.includes('remove button'), 'and it says where removing lives');
});

claim('every security field with text is wide enough to show all of it', () => {
    const { updmgr } = windowFor(false);

    // #46: with only labelWidth set, the field body kept ExtJS' ~170 px and
    // cut "Each guest's own sources and proxy" to "Each guest's own sourc".
    // 7.5 px a character is the 13 px UI font on the wide side; 30 px is the
    // trigger and the padding. Measured in the browser, not derived: at 300 px
    // the longest of these texts shows in full.
    const PX_PER_CHAR = 7.5;
    const CHROME = 30;
    let checked = 0;
    updmgr.SECURITY_FIELDS.filter((f) => f.kind === 'combo' || f.kind === 'str').forEach((f) => {
        const field = updmgr.securityField(f);
        const texts = f.kind === 'combo' ? f.items.map((i) => i[1]) : [f.empty || ''];
        const longest = Math.max(...texts.map((t) => t.length));
        const body = (field.width || 0) - field.labelWidth;
        assert.ok(
            body >= longest * PX_PER_CHAR + CHROME,
            `${f.key}: ${body} px for ${longest} characters`,
        );
        checked++;
    });
    assert.strictEqual(checked, 7, 'premise: four combos and three text fields were measured');
});

done();
