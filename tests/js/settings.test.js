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
const DEFINED_ITEM_IDS = new Set(
    [...SOURCE.matchAll(/itemId:\s*'([^']+)'/g)].map((m) => m[1]),
);

// Everything the server answers with, all of it different from the defaults so
// a value that is quietly dropped cannot pass by accident.
const ANSWER = {
    parallel_manual: 1,
    timeout: 600,
    start_stopped: 1,
    snapshot_before: 1,
    snapshot_keep: 4,
    snapshot_shutdown: 1,
    notify_failure: 1,
    script_versions: 5,
    schedule_enabled: 1,
    schedule_time: '04:00',
    schedule_parallel: 1,
    schedule_host: 1,
    schedule_vmids: '101',
    snapshot_capable: 1,
    nodes: 2,
    uniform: 0,
    last_run: 100,
    next_run: 200,
};

function windowFor(global) {
    const loaded = load(() => ANSWER);
    const cfg = loaded.classes['PVE.updmgr.SettingsWindow'];

    const touched = [];
    const fields = {};

    const me = Object.assign({}, cfg, {
        global: global,
        nodename: 'node-a',
        preselected: {},
        nodeCount: 0,
        targetGrid: {
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
            };
        },
    });

    return { me: me, touched: touched, fields: fields, ...loaded };
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
        const ignored = ['schedule_host', 'schedule_vmids', 'last_run', 'next_run',
            'snapshot_capable', 'nodes', 'uniform'];

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

done();
