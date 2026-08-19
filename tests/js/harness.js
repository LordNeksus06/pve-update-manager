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
            define: function () {},
            create: function (xclass) {
                return { show: function () {}, xclass: xclass };
            },
            getStore: function () {},
            Msg: {
                alert: function (title, msg) {
                    alerts.push({ title: title, msg: msg });
                },
                confirm: function (title, msg, cb) {
                    alerts.push({ title: title, msg: msg, confirm: cb });
                },
            },
            String: {
                format: function (fmt, ...args) {
                    return fmt.replace(/\{(\d+)\}/g, (_m, i) => args[i]);
                },
                htmlEncode: (s) => String(s),
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

    return { updmgr: sandbox.PVE.updmgr, alerts: alerts, requests: requests };
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
