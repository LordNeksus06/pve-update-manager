// The History menu of the editor - the saved versions of one target's script.
//
// Storage and retention are the server's business and are tested in
// tests/perl/versions.t. What is decided HERE is the menu: that it names a time
// and an author, that the newest entry is marked as the latest save rather than
// as "current", and that an empty history says so instead of opening blank.
//
//   node tests/js/history.test.js

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

// Two fields, and the difference is the whole point: `version` is the
// identifier, which is the local second standing in the file's own name, and
// `time` is the same moment as an epoch for rendering. A menu that rendered the
// identifier would date every entry to 1970. The last entry is a version saved
// before that naming existed, which the server still lists by its epoch.
const VERSIONS = [
    { version: '2026-08-21-13-21-12', time: 1755690300, user: 'alice@pve', size: 40 },
    { version: '2026-08-20-09-04-55', time: 1755690100, user: 'root@pam', size: 30 },
    { version: '1755690000', time: 1755690000, size: 20 },
];

function itemsFor(updmgr, list) {
    const picked = [];
    const items = updmgr.versionMenuItems(list, (version) => picked.push(version));
    return { items: items, picked: picked };
}

claim('every saved version is offered, newest first as the server listed them', () => {
    const { updmgr } = load(() => ({}));
    const { items } = itemsFor(updmgr, VERSIONS);

    assert.strictEqual(items.length, 3);
    assert.ok(items[0].text.includes('ts:1755690300'), 'the entry names when it was saved');
    assert.ok(items[0].text.includes('alice@pve'), 'and who saved it');
});

claim('the newest entry is marked as the latest save, not as the current text', () => {
    const { updmgr } = load(() => ({}));
    const { items } = itemsFor(updmgr, VERSIONS);

    // The file in /etc/pve can be edited with an editor, and that write goes
    // through nothing that could record a version - so "current" would be a
    // claim the interface is in no position to make.
    assert.ok(items[0].text.includes('latest save'));
    assert.ok(!items[1].text.includes('latest save'));
});

claim('a version saved by nobody in particular says nothing rather than guessing', () => {
    const { updmgr } = load(() => ({}));
    const { items } = itemsFor(updmgr, VERSIONS);

    assert.strictEqual(items[2].text, 'ts:1755690000');
});

claim('picking an entry hands back the version, which is what the endpoint wants', () => {
    const { updmgr } = load(() => ({}));
    const { items, picked } = itemsFor(updmgr, VERSIONS);

    items[1].handler();

    assert.deepStrictEqual(picked, ['2026-08-20-09-04-55'], 'the identifier, not the epoch');
});

claim('a target that was never saved says so instead of opening an empty menu', () => {
    const { updmgr } = load(() => ({}));

    for (const empty of [[], undefined, null]) {
        const { items } = itemsFor(updmgr, empty);
        assert.strictEqual(items.length, 1);
        assert.strictEqual(items[0].text, 'Nothing saved yet');
        assert.strictEqual(items[0].disabled, true, 'and it cannot be clicked');
    }
});

// ── the editor's side of it ─────────────────────────────────────────────────
//
// PVE.updmgr.ScriptPanel is a config object until ExtJS builds it, so its
// methods can be called against a stand-in `me`. What is checked is the part
// that is logic: which URL a picked version is fetched from, that the text
// lands in the box, and that the "you are looking at an old version" line
// appears and disappears at the right moments.

function panelFor(answer) {
    const loaded = load(answer);
    const cfg = loaded.classes['PVE.updmgr.ScriptPanel'];

    const me = Object.assign({}, cfg, {
        scriptUrl: '/nodes/node-a/lxc/101/updatemgr/script',
        value: undefined,
        hint: 'unset',
        stored: false,
        editor: {
            setValue: (v) => {
                me.value = v;
            },
            getValue: () => me.value,
        },
        versionText: {
            setText: (t) => {
                me.hint = t;
            },
        },
        setLoaded: () => {},
        updateStatus: () => {},
        updateRemoveButton: () => {},
    });

    return { me: me, ...loaded };
}

claim('picking a version fetches that one and puts it in the box', () => {
    const { me, requests } = panelFor((url) =>
        url.endsWith('/versions/2026-08-20-09-04-55') ? { script: 'the older text\n' } : {},
    );

    me.loadVersion.call(me, '2026-08-20-09-04-55', 1755690100);

    assert.strictEqual(
        requests[0].url,
        '/nodes/node-a/lxc/101/updatemgr/script/versions/2026-08-20-09-04-55',
        'the version hangs off the target\'s own script endpoint, by its identifier',
    );
    assert.strictEqual(me.value, 'the older text\n');
    // The epoch, not the identifier: rendering '2026-08-20-09-04-55' as a
    // timestamp is a date in 1970 with the year as the seconds.
    assert.ok(me.hint.includes('ts:1755690100'), `the line names which version: ${me.hint}`);
    assert.ok(me.hint.includes('Save'), 'and says it is not restored until Save');
});

// A version saved before the new naming existed is still asked for by the epoch
// the server listed, and the path must carry it unchanged.
claim('an older epoch-named version is still fetched by its own name', () => {
    const { me, requests } = panelFor(() => ({ script: 'ancient\n' }));

    me.loadVersion.call(me, '1755690000', 1755690000);

    assert.strictEqual(
        requests[0].url,
        '/nodes/node-a/lxc/101/updatemgr/script/versions/1755690000',
    );
    assert.strictEqual(me.value, 'ancient\n');
});

claim('the line goes away once that text is saved, or the box is re-read', () => {
    let p = panelFor(() => ({ script: 'x' }));
    p.me.loadVersion.call(p.me, '2026-08-20-09-04-55', 1755690100);
    assert.notStrictEqual(p.me.hint, '');

    p.me.saveScript.call(p.me);
    assert.strictEqual(p.me.hint, '', 'a save makes it the current text, so it is no longer old');

    p = panelFor(() => ({ script: 'y', stored: true }));
    p.me.loadVersion.call(p.me, '2026-08-20-09-04-55', 1755690100);
    p.me.loadScript.call(p.me);
    assert.strictEqual(p.me.hint, '', 'and Revert throws the version away with it');
});

// ── the kept run logs ──────────────────────────────────────────────────────
//
// One plain button, one window. It used to be two buttons - "Last Log" for
// Proxmox' task log and a "Run Logs" dropdown - which between them pushed the end
// of the editor's toolbar into ExtJS' overflow menu, and were two buttons for one
// question anyway. So the window lists the kept runs, shows what each printed, and
// carries the task log inside it.

// A PLAIN button, and it has to stay one. It was a dropdown once, and together
// with the second log button it pushed the end of the editor's toolbar into
// ExtJS' overflow menu - the ☰ that hides the buttons somebody wanted.
claim('the Logs button is a button, not a menu', () => {
    const { updmgr } = load(() => ({}));

    let opened = 0;
    const btn = updmgr.logsButton(() => {
        opened += 1;
    });

    assert.strictEqual(btn.menu, undefined, 'no dropdown hangs off it');
    assert.strictEqual(typeof btn.handler, 'function', 'clicking it does something itself');
    assert.strictEqual(btn.text, 'Logs');

    btn.handler();
    assert.strictEqual(opened, 1, 'and what it does is open the window');
});

claim('the Logs button opens the window on this target, not on the tab', () => {
    const loaded = load(() => ({}));
    const me = Object.assign({}, loaded.classes['PVE.updmgr.ScriptPanel'], {
        scriptUrl: '/nodes/node-b/lxc/201/updatemgr/script',
        targetLabel: 'CT 201 (far)',
        lastUpid: 'UPID:node-b:1:2:3:ctupdate:201:root@pam:',
    });

    me.openLogs.call(me);

    const win = loaded.created[loaded.created.length - 1];
    assert.strictEqual(win.xclass, 'PVE.updmgr.LogWindow');
    assert.strictEqual(win.config.logsUrl, '/nodes/node-b/lxc/201/updatemgr/logs');
    assert.strictEqual(win.config.targetLabel, 'CT 201 (far)');
    // Carried in even though the window lists logs of its own: with run_logs
    // switched off there are no rows to select, and this is what keeps Proxmox'
    // own log reachable - which is what the old Last Log button did.
    assert.strictEqual(
        win.config.lastUpid,
        'UPID:node-b:1:2:3:ctupdate:201:root@pam:',
        'the last run\'s task comes along',
    );
});

// A row has to say how the run ended without being opened, or the only way to
// find the failed one is to read all of them.
claim('a run that failed looks failed in the list, with its note', () => {
    const { updmgr } = load(() => ({}));

    const failed = updmgr.renderLogState('failed', 'exit 100 after 1s');
    assert.match(failed, /fa-times/, 'the same icon a failed row carries elsewhere');
    assert.match(failed, /failed/);
    assert.match(failed, /exit 100 after 1s/, 'and the note beside it');

    assert.match(updmgr.renderLogState('ok'), /fa-check/);
    assert.match(updmgr.renderLogState('skipped'), /fa-minus/);
});

claim('a log with no header says so rather than passing as OK', () => {
    const { updmgr } = load(() => ({}));

    // What a killed worker leaves behind: output, no header. Drawing that as a
    // successful run is the one answer that would be a lie.
    const none = updmgr.renderLogState(undefined, undefined);
    assert.match(none, /no result/);
    assert.doesNotMatch(none, /fa-check/);
});

claim('what a run printed is escaped before it becomes a cell', () => {
    const { updmgr } = load(() => ({}));

    const out = updmgr.renderLogState('failed', '<script>alert(1)</script>');
    assert.doesNotMatch(out, /<script>/, `the note is markup otherwise: ${out}`);
    assert.match(out, /&lt;script&gt;/);
});

// ── the window's own logic ─────────────────────────────────────────────────
//
// PVE.updmgr.LogWindow is a config object until ExtJS builds it, so its methods
// can be driven against a stand-in `me`. What is checked is which URL a row is
// fetched from, that the newest run is the one shown on open, and that the task
// button follows what the selected run actually recorded.

const LOG_ROWS = [
    { log: '2026-08-21-13-21-12', time: 1755690300, size: 4096, state: 'failed',
      note: 'exit 100 after 1s', upid: 'UPID:pve:1:2:3:ctupdate:201:root@pam:' },
    { log: '2026-08-20-09-04-55', time: 1755690100, size: 128, state: 'ok' },
];

function windowFor(answer, options) {
    options = options || {};
    const loaded = load(answer);
    const cfg = loaded.classes['PVE.updmgr.LogWindow'];

    const state = { text: undefined, loaded: undefined, selected: [], taskDisabled: undefined };

    const me = Object.assign({}, cfg, {
        logsUrl: '/nodes/node-a/lxc/201/updatemgr/logs',
        lastUpid: options.lastUpid,
        textPane: { setValue: (v) => { state.text = v; } },
        taskButton: { setDisabled: (v) => { state.taskDisabled = v; } },
        grid: {
            getStore: () => ({ loadData: (rows) => { state.loaded = rows; } }),
            getSelectionModel: () => ({ select: (i) => state.selected.push(i) }),
        },
    });

    return { me: me, state: state, ...loaded };
}

claim('opening the window lists the runs and shows the newest', () => {
    const w = windowFor(() => LOG_ROWS);

    w.me.reloadLogs.call(w.me);

    assert.strictEqual(w.requests[0].url, '/nodes/node-a/lxc/201/updatemgr/logs');
    assert.strictEqual(w.state.loaded.length, 2, 'both runs are in the grid');
    assert.deepStrictEqual(w.state.selected, [0], 'and the newest is selected for you');
});

claim('a target that has never run says so instead of showing a blank box', () => {
    const w = windowFor(() => []);

    w.me.reloadLogs.call(w.me);

    assert.strictEqual(w.state.selected.length, 0, 'nothing to select');
    assert.match(w.state.text, /No run has been logged/);
});

claim('picking a run fetches that run and puts its text in the pane', () => {
    const w = windowFor((url) =>
        url.endsWith('/logs/2026-08-21-13-21-12')
            ? { log: '=== pve-update-manager ===\nReading package lists...\n' }
            : {},
    );

    w.me.showLog.call(w.me, { data: LOG_ROWS[0] });

    assert.strictEqual(
        w.requests[0].url,
        '/nodes/node-a/lxc/201/updatemgr/logs/2026-08-21-13-21-12',
    );
    assert.match(w.state.text, /Reading package lists/);
});

claim('the task button follows what the selected run recorded', () => {
    const w = windowFor(() => ({ log: 'x' }));

    w.me.showLog.call(w.me, { data: LOG_ROWS[0] });
    assert.strictEqual(w.state.taskDisabled, false, 'this run has a task to open');
    assert.strictEqual(w.me.selectedUpid, 'UPID:pve:1:2:3:ctupdate:201:root@pam:');

    // A log a killed worker left without a header has no task in it, and a button
    // that opens nothing is worse than a grey one.
    w.me.showLog.call(w.me, { data: LOG_ROWS[1] });
    assert.strictEqual(w.state.taskDisabled, true);
});

claim('a run whose log is gone is reported in the pane, not in a popup', () => {
    // The window is already open on it; an alert on top of it would have to be
    // clicked away before the next row can be tried.
    const w = windowFor(() => ({ failure: 'no such run log' }));

    w.me.showLog.call(w.me, { data: LOG_ROWS[0] });

    assert.strictEqual(w.alerts.length, 0, 'no dialog');
    assert.strictEqual(w.state.text, 'no such run log', 'the reason is where the log would be');
});

claim('and a listing that cannot be read is reported once, out loud', () => {
    const w = windowFor(() => ({ failure: 'permission denied' }));

    w.me.reloadLogs.call(w.me);

    assert.strictEqual(w.alerts.length, 1, 'this one IS worth a dialog - there is no list');
    assert.strictEqual(w.alerts[0].msg, 'permission denied');
});

claim('a failed version fetch is reported and leaves the box alone', () => {
    const { me, alerts } = panelFor(() => ({ failure: 'no such version' }));

    me.value = 'what the user has';
    me.loadVersion.call(me, '1', 1);

    assert.strictEqual(me.value, 'what the user has');
    assert.strictEqual(alerts.length, 1);
    assert.strictEqual(alerts[0].msg, 'no such version');
});

done();
