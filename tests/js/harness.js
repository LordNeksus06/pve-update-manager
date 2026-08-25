// Loads the REAL js/pve-update-manager.js into a V8 context with just enough of
// ExtJS and Proxmox behind it to let it run.
//
// Shared by every tests/js/*.test.js rather than copied into each: the stub is
// the part that decides what the interface is allowed to touch, and two copies
// of it drift until one test is exercising a file the other one is not.
//
// Not itself a test - the suite runs tests/js/*.test.js, and this is not one.

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = path.resolve(__dirname, '..', '..');
const source = fs.readFileSync(path.join(repoRoot, 'js', 'pve-update-manager.js'), 'utf8');

// `answer(url, req)` returns what the server says for one request: a UPID string
// for a task that was started, '' for a target the server skipped without
// starting one, an object for an endpoint that answers with data, or
// {failure: '...'} for a request that came back as an error.
//
// `options.guiCap` is what Ext.state.Manager.get('GuiCap') hands back, which is
// how the interface decides which buttons a user may see.
function load(answer, options) {
    options = options || {};

    const sandbox = {};
    const alerts = [];
    const requests = [];
    // Every Ext.define the file makes, by class name. The panels and grids are
    // plain config objects until ExtJS builds them, and their methods are
    // ordinary functions - so a test can call one against a stand-in `me` and
    // check what the interface DECIDES, which is as close to clicking a button
    // as this can get without a browser.
    const classes = {};
    // Every Ext.create the interface makes, in order: {xclass, config}.
    const created = [];

    const stubs = {
        console: console,
        gettext: (s) => s,
        Ext: {
            ns: function (name) {
                let node = sandbox;
                for (const part of name.split('.')) {
                    node[part] = node[part] || {};
                    node = node[part];
                }
                return node;
            },
            define: function (name, config) {
                classes[name] = config;
            },
            // The config is recorded, not only the class: what a window is built
            // WITH is the interesting half - which node's endpoint an editor was
            // pointed at is a decision, and in a cluster it is the difference
            // between reading the right machine and the one you happen to be
            // connected to.
            //
            // `on` because every window the interface opens gets a listener hung
            // on it - a task viewer that reloads the grid when it is closed.
            // Without it here, a test that drives a path as far as opening one
            // fails on the stub rather than on the interface.
            create: function (xclass, config) {
                created.push({ xclass: xclass, config: config || {} });

                return {
                    show: function () {},
                    on: function () {},
                    xclass: xclass,
                    config: config || {},
                };
            },
            getStore: function () {},
            Msg: {
                alert: function (title, msg) {
                    alerts.push({ title: title, msg: msg });
                },
                confirm: function (title, msg, cb) {
                    alerts.push({ title: title, msg: msg, confirm: cb });
                },
                prompt: function (title, msg, cb, scope, multiline, value) {
                    alerts.push({
                        title: title, msg: msg, prompt: cb, value: value,
                        multiline: multiline,
                    });
                },
            },
            String: {
                format: function (fmt, ...args) {
                    return fmt.replace(/\{(\d+)\}/g, (_m, i) => args[i]);
                },
                // The real one, not an identity function: everything the
                // interface puts into a cell or a menu entry goes through it,
                // and a stub that hands the string back unchanged makes every
                // claim about escaping untestable - the test would pass just as
                // happily against code that had stopped calling it.
                htmlEncode: (s) =>
                    String(s)
                        .replace(/&/g, '&amp;')
                        .replace(/</g, '&lt;')
                        .replace(/>/g, '&gt;')
                        .replace(/"/g, '&quot;')
                        .replace(/'/g, '&#39;'),
            },
            state: {
                Manager: {
                    get: function (key) {
                        return key === 'GuiCap' ? options.guiCap || {} : undefined;
                    },
                },
            },
        },
        Proxmox: {
            Utils: {
                override_task_descriptions: function () {},
                // Deterministic on purpose: what the tests check is which
                // timestamp an entry carries, not how a browser locale renders
                // it.
                render_timestamp: function (epoch) {
                    return `ts:${epoch}`;
                },
                API2Request: function (req) {
                    requests.push(req);
                    const res = answer(req.url, req);
                    if (res && res.failure !== undefined) {
                        req.failure({ htmlStatus: res.failure });
                    } else {
                        req.success({ result: { data: res } });
                    }
                },
            },
        },
        PVE: { Utils: {} },
    };

    Object.assign(sandbox, stubs);
    sandbox.globalThis = sandbox;

    vm.runInNewContext(source, sandbox, { filename: 'js/pve-update-manager.js' });

    return {
        updmgr: sandbox.PVE.updmgr,
        classes: classes,
        created: created,
        alerts: alerts,
        requests: requests,
    };
}

// Named as claims, so a failure reads as a sentence about the interface.
function runner() {
    let failures = 0;

    const claim = function (description, fn) {
        try {
            fn();
            console.log(`  ok   ${description}`);
        } catch (err) {
            failures += 1;
            console.log(`  FAIL ${description}`);
            console.log(String(err.message).replace(/^/gm, '       '));
        }
    };

    const done = function () {
        process.exit(failures === 0 ? 0 : 1);
    };

    return { claim: claim, done: done };
}

module.exports = { load: load, runner: runner };
