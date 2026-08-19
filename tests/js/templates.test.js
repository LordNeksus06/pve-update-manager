// The Templates menu - where its entries come from and who may change them.
//
// The scripts themselves are the server's business and are tested in
// tests/perl/templates.t. What is decided HERE is the menu: that it is fetched
// once and reused, that a failed fetch costs the suggestions and nothing else,
// that an empty menu says which kind of empty it is, and that the entry which
// edits a cluster-wide list is only offered to somebody allowed to edit one.
//
//   node tests/js/templates.test.js

'use strict';

const assert = require('assert');
const { load, runner } = require('./harness.js');

const { claim, done } = runner();

const TEMPLATES = {
    custom: false,
    templates: [
        { name: 'Debian / Ubuntu (apt)', script: '#!/bin/bash\napt-get update\n' },
        { name: 'Alpine (apk)', script: '#!/bin/sh\napk upgrade\n' },
    ],
};

// Everything a template menu can be built from, without an Ext menu in sight.
function itemsFor(updmgr, data, onManage) {
    const applied = [];
    const items = updmgr.templateMenuItems(data, (script) => applied.push(script), onManage);
    return { items: items, applied: applied };
}

claim('the templates come from the server, not from a copy in the interface file', () => {
    const { updmgr, requests } = load(() => TEMPLATES);

    let seen;
    updmgr.loadTemplates((data) => {
        seen = data;
    });

    assert.strictEqual(requests.length, 1, 'exactly one request');
    assert.strictEqual(
        requests[0].url,
        '/cluster/updatemgr/templates',
        'and it asks the cluster-wide endpoint, so every node offers the same menu',
    );
    assert.strictEqual(seen.templates.length, 2);
});

claim('the list is fetched once and reused until something changes it', () => {
    const { updmgr, requests } = load(() => TEMPLATES);

    updmgr.loadTemplates(() => {});
    updmgr.loadTemplates(() => {});
    updmgr.loadTemplates(() => {});

    assert.strictEqual(requests.length, 1, 'three opens, one request');

    // Which is exactly why a write has to be able to invalidate it - otherwise
    // the manager window would keep showing the list from before its own edit.
    updmgr.templateCache = undefined;
    updmgr.loadTemplates(() => {});
    assert.strictEqual(requests.length, 2, 'and clearing the cache fetches again');
});

claim('a forced reload asks the server even with a cache in hand', () => {
    const { updmgr, requests } = load(() => TEMPLATES);

    updmgr.loadTemplates(() => {});
    updmgr.loadTemplates(() => {}, true);

    assert.strictEqual(requests.length, 2);
});

// A menu is a convenience. Losing it must not put a dialog in front of somebody
// who was editing a container's commands and never asked about templates.
claim('a server that cannot answer costs the suggestions and nothing else', () => {
    const { updmgr, alerts } = load(() => ({ failure: 'no such endpoint' }));

    let seen;
    updmgr.loadTemplates((data) => {
        seen = data;
    });

    assert.strictEqual(alerts.length, 0, 'no message box');
    // length, not deepStrictEqual: the array is built inside the V8 context and
    // so is not reference-equal to an array made out here.
    assert.strictEqual(seen.templates.length, 0, 'and an empty menu rather than an exception');
});

claim('a failed fetch is not cached, so the next open tries again', () => {
    let answers = 0;
    const { updmgr, requests } = load(() => {
        answers += 1;
        return answers === 1 ? { failure: 'boom' } : TEMPLATES;
    });

    updmgr.loadTemplates(() => {});
    let second;
    updmgr.loadTemplates((data) => {
        second = data;
    });

    assert.strictEqual(requests.length, 2, 'the failure did not become the cached answer');
    assert.strictEqual(second.templates.length, 2, 'and the retry got the real list');
});

claim('every template becomes one entry that pastes its own script', () => {
    const { updmgr } = load(() => TEMPLATES);

    const { items, applied } = itemsFor(updmgr, TEMPLATES);

    assert.strictEqual(items.length, 2, 'no Manage entry without the privilege for it');
    assert.deepStrictEqual(
        items.map((i) => i.text),
        ['Debian / Ubuntu (apt)', 'Alpine (apk)'],
        'in the order the server sent them',
    );

    items[1].handler();
    assert.deepStrictEqual(applied, ['#!/bin/sh\napk upgrade\n'], 'and it pastes that entry');
});

// "Nothing is stored yet" and "somebody removed every entry" look identical in
// the menu and are not the same thing at all.
claim('an empty menu says which kind of empty it is', () => {
    const { updmgr } = load(() => TEMPLATES);

    const builtin = itemsFor(updmgr, { custom: false, templates: [] }).items;
    assert.strictEqual(builtin.length, 1);
    assert.ok(builtin[0].disabled, 'the placeholder cannot be clicked');
    assert.doesNotMatch(builtin[0].text, /removed/);

    const emptied = itemsFor(updmgr, { custom: true, templates: [] }).items;
    assert.match(emptied[0].text, /removed/, 'a list emptied on purpose says so');
});

claim('Manage is appended behind a separator when it is offered at all', () => {
    const { updmgr } = load(() => TEMPLATES);

    const { items } = itemsFor(updmgr, TEMPLATES, () => {});

    assert.strictEqual(items.length, 4, 'two templates, a separator and the entry');
    assert.strictEqual(items[2], '-', 'the separator keeps it away from the paste entries');
    assert.match(items[3].text, /Manage/);
});

// Editing the list changes one menu for the whole cluster, so it takes the
// datacenter-wide privilege - not the one that edits a single container.
claim('managing the templates is offered to Sys.Modify on / and to nobody else', () => {
    const allowed = load(() => TEMPLATES, { guiCap: { dc: { 'Sys.Modify': 1 } } });
    assert.strictEqual(allowed.updmgr.canManageTemplates(), true);

    const denied = load(() => TEMPLATES, {
        guiCap: { vms: { 'VM.Config.Options': 1 }, nodes: { 'Sys.Modify': 1 } },
    });
    assert.strictEqual(
        denied.updmgr.canManageTemplates(),
        false,
        'being allowed to edit a container - or even a node - is not enough',
    );

    const nothing = load(() => TEMPLATES, { guiCap: {} });
    assert.strictEqual(nothing.updmgr.canManageTemplates(), false);
});

done();
