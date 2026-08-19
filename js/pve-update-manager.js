// pve-update-manager - Update Manager tabs for the Proxmox VE web interface.
//
// Loaded by one <script> line added to /usr/share/pve-manager/index.html.tpl,
// right after pvemanagerlib.js. Nothing in pvemanagerlib.js is modified: the
// tabs are added by overriding PVE.panel.Config.initComponent, which is the one
// moment where the finished `items` array of every config panel - container,
// node, datacenter - is sitting in a variable and not yet turned into the tab
// tree.
//
// Three tabs, one idea:
//
//   Container -> Update Manager   a text box with that container's update
//                                 commands and a button that runs them
//   Node      -> Update Manager   the host and every container on it in one
//                                 list, tick what to update - plus the Settings
//                                 window, which lives here and nowhere else
//   Datacenter-> Update Manager   the same list for the WHOLE cluster, across
//                                 every node
//
// Every row carries its own Update button, its own last-run state, and a button
// that opens the log of exactly the run that produced that state.
//
// The commands are written by hand and stored per target under
// /etc/pve/pve-update-manager/. Nothing is generated. A run happens when a
// button is pressed, or at the time a node's Settings window schedules.

/*global Ext, PVE, Proxmox, gettext*/

Ext.ns('PVE.updmgr');

PVE.updmgr.TAB_TITLE = 'Update Manager';
PVE.updmgr.TAB_ICON = 'fa fa-arrow-circle-o-up';

// How long to wait before re-reading a grid that has a target mid-run. Short
// enough that a row stops spinning promptly, long enough not to hammer the API
// through a whole dist-upgrade.
PVE.updmgr.RUNNING_POLL_MS = 3000;

// Without this the task log shows the raw worker type ("ctupdate 101"). The
// helper is the toolkit's own extension point for product specific task types.
if (typeof Proxmox !== 'undefined' && Proxmox.Utils && Proxmox.Utils.override_task_descriptions) {
    Proxmox.Utils.override_task_descriptions({
        ctupdate: ['CT', PVE.updmgr.TAB_TITLE],
        updatemgr: ['Node', PVE.updmgr.TAB_TITLE],
    });
}

// ── The Templates menu ──────────────────────────────────────────────────────
//
// Starting points pasted into the text box, never something that runs on its
// own. The list itself comes from /cluster/updatemgr/templates: it is editable
// and stored in /etc/pve, so there is exactly one menu for the whole cluster
// and the shipped defaults live in the Perl that has to answer with them. A
// second copy of those scripts here is how the two would drift apart.

// Filled on the first menu open and reused afterwards - a menu that fetched its
// own contents on every click would be a request per click for a list that
// changes about once a year. `undefined` means "not fetched yet"; the manager
// window clears it after every write.
PVE.updmgr.templateCache = undefined;

PVE.updmgr.loadTemplates = function (callback, force) {
    if (PVE.updmgr.templateCache && !force) {
        callback(PVE.updmgr.templateCache);
        return;
    }

    Proxmox.Utils.API2Request({
        url: '/cluster/updatemgr/templates',
        method: 'GET',
        failure: function (response) {
            // Deliberately not a dialog. This is a convenience menu; an old
            // server or a cluster subtree that failed to register may cost the
            // suggestions, and the text box still works without them.
            console.error(
                'pve-update-manager: could not load the templates',
                response.htmlStatus,
            );
            callback({ custom: false, templates: [] });
        },
        success: function (response) {
            PVE.updmgr.templateCache = response.result.data;
            callback(PVE.updmgr.templateCache);
        },
    });
};

// Editing the list is a datacenter-wide change - one menu, every node - so it
// takes the privilege datacenter options take, and not the one that edits a
// single container's commands.
PVE.updmgr.canManageTemplates = function () {
    let caps = Ext.state.Manager.get('GuiCap') || {};
    return !!(caps.dc || {})['Sys.Modify'];
};

// The items of a Templates menu, given what the server answered. Split out from
// the button below because this is the part with decisions in it: what an empty
// list looks like, and whether the Manage entry is there at all.
PVE.updmgr.templateMenuItems = function (data, apply, onManage) {
    let items = (data.templates || []).map(function (tpl) {
        return {
            text: tpl.name,
            handler: function () {
                apply(tpl.script);
            },
        };
    });

    // A menu that opens empty reads as broken. Say which of the two it is.
    if (!items.length) {
        items.push({
            text: data.custom
                ? gettext('No templates - all of them were removed')
                : gettext('No templates'),
            disabled: true,
        });
    }

    if (onManage) {
        items.push('-', {
            text: gettext('Manage Templates'),
            iconCls: 'fa fa-cog',
            handler: onManage,
        });
    }

    return items;
};

PVE.updmgr.templateMenuButton = function (apply) {
    return {
        text: gettext('Templates'),
        iconCls: 'fa fa-file-text-o',
        menu: {
            // Rebuilt on every open rather than once at construction: an edit
            // made in the manager window has to show up in the menu of an
            // editor that was already on screen when it was made.
            items: [{ text: gettext('Loading...'), disabled: true }],
            listeners: {
                beforeshow: function (menu) {
                    PVE.updmgr.loadTemplates(function (data) {
                        if (menu.destroyed) {
                            return;
                        }
                        menu.removeAll();
                        menu.add(
                            PVE.updmgr.templateMenuItems(
                                data,
                                apply,
                                PVE.updmgr.canManageTemplates()
                                    ? function () {
                                          Ext.create('PVE.updmgr.TemplateWindow').show();
                                      }
                                    : undefined,
                            ),
                        );
                    });
                },
            },
        },
    };
};

// ── Shared helpers ──────────────────────────────────────────────────────────

PVE.updmgr.targetLabel = function (data) {
    if (data.type === 'node') {
        return `Host ${data.name}`;
    }
    return `CT ${data.vmid} (${data.name})`;
};

// Where a target's commands live. A datacenter selection spans nodes, so the
// row's own node decides; `defaultNode` is only the fallback for the node tab,
// whose rows do not all carry one.
PVE.updmgr.scriptUrlFor = function (data, defaultNode) {
    let node = data.node || defaultNode;
    if (!node) {
        return undefined;
    }

    return data.type === 'node'
        ? `/nodes/${node}/updatemgr/script`
        : `/nodes/${node}/lxc/${data.vmid}/updatemgr/script`;
};

// One line summarising a target's last run, used both in a grid cell and in the
// toolbar of the container tab. The state comes from the state file the worker
// writes, not from the task archive, so it survives log rotation.
PVE.updmgr.renderLastRun = function (data) {
    if (!data.last_state) {
        return `<span class="faded">${gettext('never run')}</span>`;
    }

    let when = data.last_finished || data.last_started;
    let ts = when ? Proxmox.Utils.render_timestamp(when) : '';
    let faded = ts ? ` <span class="faded">${ts}</span>` : '';

    switch (data.last_state) {
        // fa-spinner, not fa-cog: the ring of separate bars is what Proxmox uses
        // everywhere else for "busy", and a rotating cog reads as "configuring".
        case 'running':
            return `<i class="fa fa-spinner fa-spin"></i> ${gettext('running')}`;
        case 'ok':
            return `<i class="fa fa-check good"></i> ${gettext('OK')}${faded}`;
        case 'failed':
            return (
                `<i class="fa fa-times critical"></i> ` +
                Ext.String.format(gettext('failed (exit {0})'), data.last_exit) +
                faded
            );
        case 'skipped':
            return (
                `<i class="fa fa-minus faded"></i> ${gettext('skipped')}` +
                (data.last_note ? ` <span class="faded">${Ext.String.htmlEncode(data.last_note)}</span>` : '')
            );
        // The worker was killed before it could record how the run ended, or the
        // state file is unreadable. Not a failure - we genuinely do not know
        // whether the update went through - so it says so, and the row is usable
        // again instead of spinning for ever.
        case 'unknown':
            return (
                `<i class="fa fa-question-circle warning"></i> ${gettext('no result')}` +
                (data.last_note ? ` <span class="faded">${Ext.String.htmlEncode(data.last_note)}</span>` : '') +
                faded
            );
        default:
            return Ext.String.htmlEncode(data.last_state);
    }
};

PVE.updmgr.showLog = function (upid) {
    if (!upid) {
        Ext.Msg.alert(gettext('Error'), gettext('This target has not been run yet.'));
        return;
    }
    Ext.create('Proxmox.window.TaskViewer', { upid: upid }).show();
};

// The endpoint that runs exactly one target, and the task type it produces.
PVE.updmgr.runUrlFor = function (data, defaultNode) {
    let node = data.node || defaultNode;
    if (!node) {
        return undefined;
    }

    let label = PVE.updmgr.targetLabel(data);

    return data.type === 'node'
        ? { url: `/nodes/${node}/updatemgr/run`, params: { host: 1 }, node: node, label: label }
        : {
              url: `/nodes/${node}/lxc/${data.vmid}/updatemgr/run`,
              params: {},
              node: node,
              label: label,
          };
};

// Starts the update of a set of targets.
//
// Two shapes, and the difference is real work, not a label:
//
//   parallel   one request per target, so every target gets its own Proxmox
//              worker and they all run at the same time. A row's task is then
//              that row's task - "CT 102 - Update Manager" - and its log holds
//              nothing but its own output.
//   serial     targets are grouped by the node that owns them and one request
//              goes out per node. Each node works through its share one after
//              another, in a single task with a banner per target and a summary
//              at the end. Several NODES still run at the same time; it is the
//              targets within a node that queue up.
//
// `callback` gets the list of started tasks once every request has answered.
PVE.updmgr.dispatch = function (targets, defaultNode, parallel, callback) {
    let requests = [];

    if (parallel) {
        targets.forEach(function (data) {
            let req = PVE.updmgr.runUrlFor(data, defaultNode);
            if (req) {
                requests.push(req);
            }
        });
    } else {
        let byNode = {};

        targets.forEach(function (data) {
            let node = data.node || defaultNode;
            if (!node) {
                return;
            }
            if (!byNode[node]) {
                byNode[node] = { host: 0, vmids: [] };
            }
            if (data.type === 'node') {
                byNode[node].host = 1;
            } else {
                byNode[node].vmids.push(data.vmid);
            }
        });

        Object.keys(byNode).forEach(function (node) {
            let group = byNode[node];

            if (!group.host && group.vmids.length === 1) {
                // One container on its own goes to its own endpoint even in
                // serial mode. Same work either way, but the task is then typed
                // `ctupdate` with the vmid as its id, so the task list says
                // "CT 102 - Update Manager" instead of labelling it as a job on
                // the node - indistinguishable from updating the host itself.
                requests.push({
                    url: `/nodes/${node}/lxc/${group.vmids[0]}/updatemgr/run`,
                    params: {},
                    node: node,
                    label: `CT ${group.vmids[0]}`,
                });
                return;
            }

            let params = {};
            if (group.vmids.length) {
                params.vmids = group.vmids.join(',');
            }
            if (group.host) {
                params.host = 1;
            }
            requests.push({
                url: `/nodes/${node}/updatemgr/run`,
                params: params,
                node: node,
                label: node,
            });
        });
    }

    if (!requests.length) {
        callback([]);
        return;
    }

    let started = [];
    // Collected, not alerted one by one: Ext.Msg is a singleton MessageBox, so a
    // dozen simultaneous alert() calls reconfigure and re-show the SAME window
    // and the user is left with whichever arrived last. With one request per
    // target that is now the normal case, not a corner.
    let failures = [];
    let pending = requests.length;
    let done = function () {
        pending--;
        if (pending > 0) {
            return;
        }
        if (failures.length) {
            Ext.Msg.alert(
                gettext('Error'),
                Ext.String.format(
                    gettext('{0} of {1} targets could not be started:'),
                    failures.length,
                    requests.length,
                ) + `<br><br>${failures.join('<br>')}`,
            );
        }
        callback(started);
    };

    requests.forEach(function (req) {
        Proxmox.Utils.API2Request({
            url: req.url,
            method: 'POST',
            params: req.params,
            failure: function (response) {
                // Named per target: with a dozen in flight, "failed" without
                // saying which one is not an error message.
                failures.push(`${req.label}: ${response.htmlStatus}`);
                done();
            },
            success: function (response) {
                let upid = response.result.data;
                // An empty answer is a target that was skipped before any task
                // existed - nothing stored to run - and the server has already
                // written that on its row. There is nothing to watch and nothing
                // to report, which is the whole point: forty containers without
                // a script must not turn into forty lines in a dialog.
                if (upid) {
                    started.push({ node: req.node, upid: upid });
                }
                done();
            },
        });
    });
};

// ── The text box, its toolbar, and the load/save/run plumbing ───────────────
//
// Used three times: as the container tab, inside the popup editor of the grids,
// and for a host's own script. Everything it needs is two URLs.
Ext.define('PVE.updmgr.ScriptPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveUpdMgrScriptPanel',

    layout: 'fit',
    border: false,

    // /nodes/x/lxc/101/updatemgr/script  or  /nodes/x/updatemgr/script
    scriptUrl: undefined,
    // /nodes/x/updatemgr/run
    runUrl: undefined,
    // extra POST params for runUrl, e.g. { host: 1 } or { vmids: '101' }
    runParams: undefined,
    // what the run is about, for messages: 'CT 101 (nextcloud)'
    targetLabel: '',

    canRun: true,
    canEdit: true,

    lastUpid: undefined,

    loadScript: function () {
        let me = this;

        Proxmox.Utils.API2Request({
            url: me.scriptUrl,
            method: 'GET',
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function (response) {
                let data = response.result.data;
                me.editor.setValue(data.script);
                me.stored = !!data.stored;
                me.lastUpid = data.last_upid;
                me.setLoaded(true);
                me.updateStatus(data);
            },
        });
    },

    // Save and Update stay disabled until the box holds what the server sent.
    // The load is asynchronous, so an editor opened and saved quickly would
    // otherwise store the empty box it started out as.
    setLoaded: function (loaded) {
        let me = this;

        me.loaded = loaded;
        if (me.saveButton) {
            me.saveButton.setDisabled(!loaded);
        }
        if (me.runButton) {
            me.runButton.setDisabled(!loaded);
        }
        me.updateRemoveButton();
    },

    // Only offer to remove something that is actually stored - on a target that
    // has never been saved the box holds a template, and there is nothing to
    // delete.
    updateRemoveButton: function () {
        let me = this;

        if (me.removeButton) {
            me.removeButton.setDisabled(!me.loaded || !me.stored);
        }
    },

    // Removes the stored commands, so the target falls back to showing the
    // template and is skipped by a run instead of doing something half-defined.
    // The recorded last run is deliberately kept - when a target was last
    // updated stays true whether or not commands are stored for it now.
    removeScript: function () {
        let me = this;

        Ext.Msg.confirm(
            gettext('Confirm'),
            Ext.String.format(
                gettext('Remove the stored update commands of {0}? The recorded last run is kept.'),
                me.targetLabel || gettext('this target'),
            ),
            function (btn) {
                if (btn !== 'yes') {
                    return;
                }

                Proxmox.Utils.API2Request({
                    url: me.scriptUrl,
                    method: 'DELETE',
                    waitMsgTarget: me,
                    failure: function (response) {
                        Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                    },
                    success: function () {
                        me.stored = false;
                        // Re-read rather than just blanking the box: the server
                        // answers with the template, which is what an empty
                        // target is supposed to show - and with the last run,
                        // which survives the delete.
                        me.loadScript();
                    },
                });
            },
        );
    },

    saveScript: function (callback) {
        let me = this;
        let script = me.editor.getValue();

        if (!script || !script.trim()) {
            Ext.Msg.alert(
                gettext('Error'),
                gettext('There are no commands to save. Empty update commands would be stored as "nothing to do".'),
            );
            return;
        }

        Proxmox.Utils.API2Request({
            url: me.scriptUrl,
            method: 'PUT',
            params: { script: script },
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function () {
                me.stored = true;
                me.updateRemoveButton();
                if (callback) {
                    callback();
                }
            },
        });
    },

    // Saved before every run on purpose. The button says "Update", and running
    // anything other than the text currently on screen would be a trap.
    runScript: function () {
        let me = this;

        let script = me.editor.getValue();
        if (!script || !script.trim()) {
            Ext.Msg.alert(gettext('Error'), gettext('There are no commands to run.'));
            return;
        }

        me.saveScript(function () {
            Proxmox.Utils.API2Request({
                url: me.runUrl,
                method: 'POST',
                params: Ext.apply({}, me.runParams || {}),
                waitMsgTarget: me,
                failure: function (response) {
                    Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                },
                success: function (response) {
                    let upid = response.result.data;
                    me.lastUpid = upid;
                    let win = Ext.create('Proxmox.window.TaskViewer', { upid: upid });
                    win.on('destroy', function () {
                        me.loadScript();
                    });
                    win.show();
                },
            });
        });
    },

    updateStatus: function (data) {
        let me = this;

        if (me.statusText) {
            me.statusText.setText(
                `${gettext('Last run')}: ${PVE.updmgr.renderLastRun(data || {})}`,
            );
        }
        if (me.logButton) {
            me.logButton.setDisabled(!me.lastUpid);
        }
    },

    initComponent: function () {
        let me = this;

        if (!me.scriptUrl) {
            throw 'no scriptUrl specified';
        }

        me.editor = Ext.create('Ext.form.field.TextArea', {
            hideLabel: true,
            spellcheck: false,
            readOnly: !me.canEdit,
            // A hint, not content: it disappears the moment anything is typed and
            // is never saved. Pre-filling the box with a template made an empty
            // target look like a configured one.
            emptyText: gettext(
                'No update commands stored. Write them here, or pick a starting point from Templates.',
            ),
            fieldStyle: {
                'font-family': 'monospace',
                'font-size': '12px',
                'white-space': 'pre',
                'overflow-wrap': 'normal',
                'overflow-x': 'auto',
            },
        });

        me.statusText = Ext.create('Ext.toolbar.TextItem', { text: '' });

        me.logButton = Ext.create('Ext.Button', {
            text: gettext('Last Log'),
            iconCls: 'fa fa-file-text-o',
            disabled: true,
            handler: function () {
                PVE.updmgr.showLog(me.lastUpid);
            },
        });

        let tbar = [];

        if (me.runUrl && me.canRun) {
            me.runButton = Ext.create('Ext.Button', {
                text: gettext('Update'),
                iconCls: 'fa fa-play',
                disabled: true,
                handler: function () {
                    me.runScript();
                },
            });
            tbar.push(me.runButton);
        }

        if (me.canEdit) {
            me.saveButton = Ext.create('Ext.Button', {
                text: gettext('Save'),
                iconCls: 'fa fa-floppy-o',
                disabled: true,
                handler: function () {
                    me.saveScript();
                },
            });
            tbar.push(me.saveButton);
        }

        tbar.push({
            text: gettext('Revert'),
            iconCls: 'fa fa-undo',
            handler: function () {
                me.loadScript();
            },
        });

        if (me.canEdit) {
            me.removeButton = Ext.create('Ext.Button', {
                text: gettext('Remove'),
                iconCls: 'fa fa-trash-o',
                disabled: true,
                handler: function () {
                    me.removeScript();
                },
            });
            tbar.push(me.removeButton);
        }

        if (me.canEdit) {
            tbar.push(
                PVE.updmgr.templateMenuButton(function (script) {
                    me.editor.setValue(script);
                }),
            );
        }

        tbar.push('->', me.statusText, me.logButton);

        Ext.apply(me, {
            tbar: tbar,
            items: [me.editor],
        });

        me.callParent();

        me.loadScript();
    },
});

// ── Container tab ───────────────────────────────────────────────────────────
Ext.define('PVE.updmgr.LxcPanel', {
    extend: 'PVE.updmgr.ScriptPanel',
    alias: 'widget.pveUpdMgrLxc',

    initComponent: function () {
        let me = this;

        if (!me.nodename) {
            throw 'no node name specified';
        }
        if (!me.vmid) {
            throw 'no vmid specified';
        }

        Ext.apply(me, {
            scriptUrl: `/nodes/${me.nodename}/lxc/${me.vmid}/updatemgr/script`,
            runUrl: `/nodes/${me.nodename}/lxc/${me.vmid}/updatemgr/run`,
            targetLabel: me.guestName ? `CT ${me.vmid} (${me.guestName})` : `CT ${me.vmid}`,
        });

        me.callParent();
    },
});

// ── Popup editor used by the grids ──────────────────────────────────────────
Ext.define('PVE.updmgr.ScriptWindow', {
    extend: 'Ext.window.Window',

    width: 800,
    height: 520,
    layout: 'fit',
    modal: true,
    resizable: true,

    initComponent: function () {
        let me = this;

        me.panel = Ext.create('PVE.updmgr.ScriptPanel', {
            scriptUrl: me.scriptUrl,
            runUrl: me.runUrl,
            runParams: me.runParams,
            targetLabel: me.targetLabel,
            canRun: me.canRun,
            canEdit: me.canEdit,
        });

        Ext.apply(me, {
            title: Ext.String.format(gettext('Update commands for {0}'), me.targetLabel),
            items: [me.panel],
        });

        me.callParent();
    },
});

// ── Editing several targets' commands at once ───────────────────────────────
//
// Deliberately NOT the single-target editor with a wider selection bolted on.
// That one is about one target: it runs it, removes it, shows its last log. This
// one writes the same text to every selected target and does nothing else, which
// is the whole reason it can be safe about it - it reads what is there first and
// says whether it is about to replace anything.
Ext.define('PVE.updmgr.MultiScriptWindow', {
    extend: 'Ext.window.Window',

    width: 820,
    height: 560,
    layout: 'fit',
    modal: true,
    resizable: true,

    // array of grid row data
    targets: undefined,
    defaultNode: undefined,

    // Reading every target before offering a box to type in: without this the
    // dialog cannot tell "these all already say the same thing" from "these say
    // four different things", and those need opposite warnings.
    load: function () {
        let me = this;

        let scripts = [];
        let failures = [];
        let pending = me.targets.length;

        // Masked once around the whole batch, not per request: N requests each
        // clearing the mask on their own means the first one to answer unmasks
        // while the rest are still in flight.
        me.setLoading(true);

        let finish = function () {
            pending--;
            if (pending > 0) {
                return;
            }

            me.setLoading(false);

            let stored = scripts.filter((s) => s.stored);
            let unique = [];
            stored.forEach(function (s) {
                if (!unique.includes(s.script)) {
                    unique.push(s.script);
                }
            });

            me.replacing = stored.length;

            if (unique.length === 1 && stored.length === me.targets.length) {
                // Everything already agrees, so the box is an edit of a shared
                // script rather than a fresh one - and saving replaces nothing
                // the user has not already seen.
                me.editor.setValue(unique[0]);
                me.identical = true;
                me.setStatus(
                    Ext.String.format(
                        gettext('All {0} selected targets currently share these commands.'),
                        me.targets.length,
                    ),
                    'good',
                );
            } else if (unique.length === 0) {
                me.setStatus(
                    Ext.String.format(
                        gettext('None of the {0} selected targets has commands stored yet.'),
                        me.targets.length,
                    ),
                    'faded',
                );
            } else {
                // Left EMPTY on purpose. Picking one of several differing
                // scripts to prefill would make one target's commands look like
                // the selection's, and Save would then quietly spread it.
                me.setStatus(
                    Ext.String.format(
                        gettext(
                            '{0} of {1} selected targets already have commands, and they are not'
                                + ' all the same. Saving replaces every one of them.',
                        ),
                        stored.length,
                        me.targets.length,
                    ),
                    'warning',
                );
            }

            if (failures.length) {
                Ext.Msg.alert(
                    gettext('Error'),
                    gettext('Could not read the current commands of:')
                        + `<br><br>${failures.join('<br>')}`,
                );
            }

            me.saveButton.setDisabled(false);
        };

        me.targets.forEach(function (data) {
            let url = PVE.updmgr.scriptUrlFor(data, me.defaultNode);
            if (!url) {
                failures.push(`${PVE.updmgr.targetLabel(data)}: ${gettext('unknown node')}`);
                finish();
                return;
            }

            Proxmox.Utils.API2Request({
                url: url,
                method: 'GET',
                failure: function (response) {
                    failures.push(`${PVE.updmgr.targetLabel(data)}: ${response.htmlStatus}`);
                    finish();
                },
                success: function (response) {
                    let d = response.result.data;
                    scripts.push({ stored: !!d.stored, script: d.script || '' });
                    finish();
                },
            });
        });
    },

    setStatus: function (text, cls) {
        let me = this;
        me.down('#status').update(`<span class="${cls}">${Ext.String.htmlEncode(text)}</span>`);
    },

    save: function () {
        let me = this;

        let script = me.editor.getValue();
        if (!script || !script.match(/\S/)) {
            // The API refuses an empty script for the same reason: it reads as
            // "saved" and then silently skips at run time. Removing commands is
            // a different act, and it has its own button on the row.
            Ext.Msg.alert(
                gettext('Error'),
                gettext(
                    'Write the commands to store. To take commands away from a target,'
                        + ' use the remove button on its row.',
                ),
            );
            return;
        }

        let write = function () {
            let failures = [];
            let pending = me.targets.length;

            me.setLoading(true);

            let finish = function () {
                pending--;
                if (pending > 0) {
                    return;
                }

                me.setLoading(false);

                if (failures.length) {
                    // One dialog, not one per target: Ext.Msg is a singleton, so
                    // a dozen alerts leave only the last one standing.
                    Ext.Msg.alert(
                        gettext('Error'),
                        Ext.String.format(
                            gettext('{0} of {1} targets could not be saved:'),
                            failures.length,
                            me.targets.length,
                        ) + `<br><br>${failures.join('<br>')}`,
                    );
                    // Left open on purpose: some targets did get the script and
                    // some did not, and closing here would throw away the text
                    // needed to finish the job.
                    return;
                }

                me.close();
            };

            me.targets.forEach(function (data) {
                let url = PVE.updmgr.scriptUrlFor(data, me.defaultNode);
                if (!url) {
                    failures.push(`${PVE.updmgr.targetLabel(data)}: ${gettext('unknown node')}`);
                    finish();
                    return;
                }

                Proxmox.Utils.API2Request({
                    url: url,
                    method: 'PUT',
                    params: { script: script },
                    failure: function (response) {
                        failures.push(`${PVE.updmgr.targetLabel(data)}: ${response.htmlStatus}`);
                        finish();
                    },
                    success: finish,
                });
            });
        };

        // Asked only when something is actually lost. Targets that are empty, or
        // that already hold exactly this text, are not worth a dialog - and a
        // confirmation that appears every time is one nobody reads.
        if (me.replacing && !me.identical) {
            Ext.Msg.confirm(
                gettext('Confirm'),
                Ext.String.format(
                    gettext(
                        '{0} of the {1} selected targets already have update commands.'
                            + ' Replace all of them with what is in the box?',
                    ),
                    me.replacing,
                    me.targets.length,
                ),
                function (btn) {
                    if (btn === 'yes') {
                        write();
                    }
                },
            );
            return;
        }

        write();
    },

    initComponent: function () {
        let me = this;

        if (!me.targets || !me.targets.length) {
            throw 'no targets specified';
        }

        me.editor = Ext.create('Ext.form.field.TextArea', {
            hideLabel: true,
            spellcheck: false,
            emptyText: gettext(
                'Write the commands to store on every selected target, or pick a starting'
                    + ' point from Templates.',
            ),
            fieldStyle: {
                'font-family': 'monospace',
                'font-size': '12px',
                'white-space': 'pre',
                'overflow-wrap': 'normal',
                'overflow-x': 'auto',
            },
        });

        me.saveButton = Ext.create('Ext.Button', {
            text: gettext('Save to All'),
            iconCls: 'fa fa-floppy-o',
            // Until the current contents are known, Save cannot say what it
            // would replace - so it does not offer to.
            disabled: true,
            handler: function () {
                me.save();
            },
        });

        Ext.apply(me, {
            // Named, not just counted - "4 targets" is not something anyone can
            // check before pressing Save. Cut off after a handful so that
            // selecting the whole datacenter does not produce a title bar the
            // window cannot show.
            title: Ext.String.format(
                gettext('Update commands for {0} targets: {1}'),
                me.targets.length,
                me.targets.length > 5
                    ? me.targets.slice(0, 5).map(PVE.updmgr.targetLabel).join(', ')
                          + Ext.String.format(gettext(' and {0} more'), me.targets.length - 5)
                    : me.targets.map(PVE.updmgr.targetLabel).join(', '),
            ),
            items: [me.editor],
            tbar: [
                me.saveButton,
                PVE.updmgr.templateMenuButton(function (script) {
                    me.editor.setValue(script);
                }),
            ],
            // The status line is NOT a tbtext in the toolbar above. A toolbar
            // lays its items out on one row and clips what does not fit, and
            // these sentences are the ones that say what Save is about to
            // overwrite - exactly the text that must not be cut off. Docked on
            // its own row it has the full width and is allowed to wrap.
            dockedItems: [
                {
                    xtype: 'component',
                    itemId: 'status',
                    dock: 'top',
                    padding: '6 10',
                    style: { 'white-space': 'normal' },
                    html: '',
                },
            ],
            buttons: [
                {
                    text: gettext('Cancel'),
                    handler: function () {
                        me.close();
                    },
                },
            ],
        });

        me.callParent();

        me.load();
    },
});

// ── Managing the Templates menu ─────────────────────────────────────────────
//
// One list for the whole cluster, stored in /etc/pve. Until something is
// changed here the menu is the built-in set that ships with the package; the
// first change writes the whole set out, so from then on a shipped default no
// longer moves under a user who edited a different entry. Reset throws the
// stored list away and follows the shipped defaults again.
Ext.define('PVE.updmgr.TemplateEditWindow', {
    extend: 'Ext.window.Window',

    width: 760,
    height: 560,
    layout: 'fit',
    modal: true,
    resizable: true,

    // set by the caller: the entry being changed, or undefined when adding
    template: undefined,

    submit: function () {
        let me = this;

        let name = me.down('#name').getValue();
        let script = me.editor.getValue();

        if (!name || !name.match(/\S/)) {
            Ext.Msg.alert(gettext('Error'), gettext('A template needs a name.'));
            return;
        }
        if (!script || !script.match(/\S/)) {
            Ext.Msg.alert(gettext('Error'), gettext('A template needs commands.'));
            return;
        }

        let params = { name: name, script: script };
        // Only on a real rename: sending oldname === name would make the server
        // look for an entry that may not exist yet, turning an add into an
        // error.
        if (me.template && me.template.name !== name) {
            params.oldname = me.template.name;
        }

        Proxmox.Utils.API2Request({
            url: '/cluster/updatemgr/templates',
            method: 'PUT',
            params: params,
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function () {
                me.close();
            },
        });
    },

    initComponent: function () {
        let me = this;

        me.editor = Ext.create('Ext.form.field.TextArea', {
            hideLabel: true,
            spellcheck: false,
            value: me.template ? me.template.script : '',
            emptyText: gettext('The commands this entry pastes into the editor.'),
            fieldStyle: {
                'font-family': 'monospace',
                'font-size': '12px',
                'white-space': 'pre',
                'overflow-wrap': 'normal',
                'overflow-x': 'auto',
            },
        });

        Ext.apply(me, {
            title: me.template
                ? Ext.String.format(gettext('Edit template: {0}'), me.template.name)
                : gettext('New template'),
            items: [me.editor],
            dockedItems: [
                {
                    xtype: 'toolbar',
                    dock: 'top',
                    items: [
                        {
                            xtype: 'textfield',
                            itemId: 'name',
                            fieldLabel: gettext('Name'),
                            labelWidth: 50,
                            width: 500,
                            allowBlank: false,
                            value: me.template ? me.template.name : '',
                        },
                    ],
                },
            ],
            buttons: [
                {
                    text: gettext('Cancel'),
                    handler: function () {
                        me.close();
                    },
                },
                {
                    text: gettext('OK'),
                    iconCls: 'fa fa-floppy-o',
                    handler: function () {
                        me.submit();
                    },
                },
            ],
        });

        me.callParent();
    },
});

Ext.define('PVE.updmgr.TemplateWindow', {
    extend: 'Ext.window.Window',

    width: 700,
    height: 480,
    layout: 'fit',
    modal: true,
    resizable: true,

    title: gettext('Update Manager templates'),

    reload: function () {
        let me = this;

        // force: this window is the one place that just changed the list, so
        // reading the cache back would show the state before its own write.
        PVE.updmgr.loadTemplates(function (data) {
            if (me.destroyed) {
                return;
            }
            me.grid.getStore().loadData(data.templates || []);
            me.down('#reset').setDisabled(!data.custom);
            me.down('#stored').setHtml(
                Ext.String.htmlEncode(
                    data.custom
                        ? gettext('This list is stored in /etc/pve and shared by every node.')
                        : gettext(
                              'These are the built-in templates. Changing one stores the whole list.',
                          ),
                ),
            );
        }, true);
    },

    // Every write goes through here so exactly one thing has to be remembered:
    // the cached menu is stale the moment the server accepted a change.
    //
    // The URL is passed in whole, query string included, because a DELETE does
    // not reliably carry `params` to this API - the toolkit's own
    // ConfirmRemoveDialog builds its query string by hand for exactly that
    // reason.
    write: function (method, url, params) {
        let me = this;

        Proxmox.Utils.API2Request({
            url: url,
            method: method,
            params: params,
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function () {
                PVE.updmgr.templateCache = undefined;
                me.reload();
            },
        });
    },

    edit: function (rec) {
        let me = this;

        let win = Ext.create('PVE.updmgr.TemplateEditWindow', {
            template: rec ? { name: rec.data.name, script: rec.data.script } : undefined,
        });
        win.on('destroy', function () {
            PVE.updmgr.templateCache = undefined;
            me.reload();
        });
        win.show();
    },

    initComponent: function () {
        let me = this;

        me.grid = Ext.create('Ext.grid.GridPanel', {
            border: false,
            store: Ext.create('Ext.data.Store', {
                fields: ['name', 'script'],
                data: [],
            }),
            columns: [
                { header: gettext('Name'), dataIndex: 'name', width: 260 },
                {
                    header: gettext('Commands'),
                    dataIndex: 'script',
                    flex: 1,
                    // The first line that is neither empty nor a comment: the
                    // shebang and the header comment are the same in half the
                    // entries, so showing those would make every row look alike.
                    renderer: function (script) {
                        let line = String(script || '')
                            .split('\n')
                            .find((l) => l.match(/\S/) && !l.match(/^\s*#/));
                        return Ext.String.htmlEncode(line || '');
                    },
                },
            ],
            listeners: {
                itemdblclick: function (view, rec) {
                    me.edit(rec);
                },
            },
        });

        Ext.apply(me, {
            items: [me.grid],
            tbar: [
                {
                    text: gettext('Add'),
                    iconCls: 'fa fa-plus',
                    handler: function () {
                        me.edit(undefined);
                    },
                },
                {
                    text: gettext('Edit'),
                    iconCls: 'fa fa-pencil',
                    handler: function () {
                        let rec = me.grid.getSelection()[0];
                        if (rec) {
                            me.edit(rec);
                        }
                    },
                },
                {
                    text: gettext('Remove'),
                    iconCls: 'fa fa-trash-o',
                    handler: function () {
                        let rec = me.grid.getSelection()[0];
                        if (!rec) {
                            return;
                        }
                        Ext.Msg.confirm(
                            gettext('Confirm'),
                            Ext.String.format(
                                gettext('Remove the template "{0}" from the menu?'),
                                rec.data.name,
                            ),
                            function (btn) {
                                if (btn === 'yes') {
                                    me.write(
                                        'DELETE',
                                        '/cluster/updatemgr/templates?name='
                                            + encodeURIComponent(rec.data.name),
                                    );
                                }
                            },
                        );
                    },
                },
                '-',
                {
                    text: gettext('Reset to Defaults'),
                    itemId: 'reset',
                    iconCls: 'fa fa-undo',
                    disabled: true,
                    handler: function () {
                        Ext.Msg.confirm(
                            gettext('Confirm'),
                            gettext(
                                'Throw the stored template list away and go back to the'
                                    + ' built-in templates? Every entry added or edited here'
                                    + ' is lost.',
                            ),
                            function (btn) {
                                if (btn === 'yes') {
                                    // Its own path, not a DELETE with the name
                                    // left off: a parameter that goes missing
                                    // must not turn a removal into a reset.
                                    me.write('POST', '/cluster/updatemgr/templates/reset');
                                }
                            },
                        );
                    },
                },
            ],
            dockedItems: [
                {
                    xtype: 'component',
                    itemId: 'stored',
                    dock: 'bottom',
                    padding: '6 10',
                    style: { 'white-space': 'normal' },
                    html: '',
                },
            ],
            buttons: [
                {
                    text: gettext('Close'),
                    handler: function () {
                        me.close();
                    },
                },
            ],
        });

        me.callParent();

        me.reload();
    },
});

// ── The target grid, shared by the node tab and the datacenter tab ──────────
//
// Subclasses supply `targetsUrl`, whether there is a Node column, and (for the
// node tab) the node every row belongs to.
Ext.define('PVE.updmgr.TargetGrid', {
    extend: 'Ext.grid.GridPanel',

    border: false,

    // set by subclasses
    targetsUrl: undefined,
    nodename: undefined,
    showNodeColumn: false,

    // Everything in the list, hosts included - the button says Select All and it
    // means it. What keeps a host from being updated by accident is the
    // confirmation, which counts the hosts in the selection out loud.
    selectAll: function () {
        let me = this;

        let rows = [];
        me.getStore().each(function (rec) {
            rows.push(rec);
        });
        me.getSelectionModel().select(rows, false);
    },

    nodeOf: function (data) {
        let me = this;
        return data.node || me.nodename;
    },

    // Manual runs honour the node's own "start everything at once" setting, and
    // a datacenter-wide selection honours each node's separately - the row that
    // carries the answer is that node's own row in the same list.
    parallelFor: function (node) {
        let me = this;

        let answer = false;
        me.getStore().each(function (rec) {
            if (rec.data.type === 'node' && me.nodeOf(rec.data) === node) {
                answer = !!rec.data.parallel_manual;
                return false;
            }
            return true;
        });

        return answer;
    },

    editTarget: function (rec) {
        let me = this;
        let node = me.nodeOf(rec.data);

        let win;
        if (rec.data.type === 'node') {
            win = Ext.create('PVE.updmgr.ScriptWindow', {
                scriptUrl: `/nodes/${node}/updatemgr/script`,
                runUrl: `/nodes/${node}/updatemgr/run`,
                runParams: { host: 1 },
                targetLabel: PVE.updmgr.targetLabel(rec.data),
                canRun: me.canRunHost,
                canEdit: me.canEditHost,
            });
        } else {
            win = Ext.create('PVE.updmgr.ScriptWindow', {
                scriptUrl: `/nodes/${node}/lxc/${rec.data.vmid}/updatemgr/script`,
                runUrl: `/nodes/${node}/lxc/${rec.data.vmid}/updatemgr/run`,
                targetLabel: PVE.updmgr.targetLabel(rec.data),
                canRun: me.canRunGuest,
                canEdit: me.canEditGuest,
            });
        }

        win.on('destroy', function () {
            me.reload();
        });
        win.show();
    },

    scriptUrlOf: function (data) {
        let me = this;
        return PVE.updmgr.scriptUrlFor(data, me.nodename);
    },

    // Straight from the row, without opening the editor first - the grid is
    // where a target with stale commands is noticed.
    removeRow: function (rec) {
        let me = this;

        Ext.Msg.confirm(
            gettext('Confirm'),
            Ext.String.format(
                gettext('Remove the stored update commands of {0}? The recorded last run is kept.'),
                PVE.updmgr.targetLabel(rec.data),
            ),
            function (btn) {
                if (btn !== 'yes') {
                    return;
                }

                Proxmox.Utils.API2Request({
                    url: me.scriptUrlOf(rec.data),
                    method: 'DELETE',
                    waitMsgTarget: me,
                    failure: function (response) {
                        Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                    },
                    success: function () {
                        me.reload();
                    },
                });
            },
        );
    },

    editSelected: function () {
        let me = this;

        let sel = me.getSelectionModel().getSelection();
        if (!sel.length) {
            Ext.Msg.alert(gettext('Error'), gettext('No target selected.'));
            return;
        }

        // One target keeps the editor it always had: that window can also run
        // the script, remove it and open its last log, and none of that means
        // anything for a selection.
        if (sel.length === 1) {
            me.editTarget(sel[0]);
            return;
        }

        // Checked here rather than left to the API: without it the user types a
        // script, presses Save, and gets a permission error per target after the
        // fact - with some of them already written.
        let refused = sel
            .filter((rec) =>
                rec.data.type === 'node' ? !me.canEditHost : !me.canEditGuest,
            )
            .map((rec) => PVE.updmgr.targetLabel(rec.data));

        if (refused.length) {
            Ext.Msg.alert(
                gettext('Error'),
                gettext('You may not change the update commands of:')
                    + `<br><br>${refused.join('<br>')}`,
            );
            return;
        }

        let win = Ext.create('PVE.updmgr.MultiScriptWindow', {
            targets: sel.map((rec) => rec.data),
            defaultNode: me.nodename,
        });

        win.on('destroy', function () {
            me.reload();
        });
        win.show();
    },

    // The row button: no dialog, no selection dance. One target, one click, and
    // its task opens right away.
    runRow: function (rec) {
        let me = this;

        PVE.updmgr.dispatch([rec.data], me.nodename, true, function (started) {  // one target: identical either way
            me.reload();
            if (started.length === 1) {
                let win = Ext.create('Proxmox.window.TaskViewer', { upid: started[0].upid });
                win.on('destroy', function () {
                    me.reload();
                });
                win.show();
            }
        });
    },

    runSelected: function () {
        let me = this;

        let selection = me.getSelectionModel().getSelection();
        if (!selection.length) {
            Ext.Msg.alert(gettext('Error'), gettext('No target selected.'));
            return;
        }

        let hosts = selection.filter((rec) => rec.data.type === 'node').length;
        let missing = selection.filter((rec) => !rec.data.stored).length;
        let nodes = {};
        selection.forEach((rec) => {
            nodes[me.nodeOf(rec.data)] = true;
        });
        let nodeCount = Object.keys(nodes).length;

        // Everything worth hesitating over is said here, in one dialog: how many
        // targets, across how many servers, whether a host is among them, and
        // how many have no script and will be skipped rather than silently doing
        // nothing.
        let lines = [
            Ext.String.format(
                gettext('Run the stored update commands on {0} target(s)?'),
                selection.length,
            ),
        ];
        // Said out loud because it is a setting now, not a fixed behaviour: the
        // dialog has to match what will actually happen.
        let modes = {};
        Object.keys(nodes).forEach((node) => {
            modes[me.parallelFor(node) ? 'parallel' : 'serial'] = true;
        });
        if (selection.length > 1) {
            if (modes.parallel && !modes.serial) {
                lines.push(gettext('They all start at once, each in its own task.'));
            } else if (modes.serial && !modes.parallel) {
                lines.push(gettext('They run one after another, per server.'));
            } else {
                lines.push(gettext('Some servers start them at once, others one after another.'));
            }
        }
        if (nodeCount > 1) {
            lines.push(
                Ext.String.format(gettext('They are spread over {0} servers.'), nodeCount),
            );
        }
        if (hosts) {
            lines.push(
                Ext.String.format(gettext('{0} of them are Proxmox hosts themselves.'), hosts),
            );
        }
        if (missing) {
            lines.push(
                Ext.String.format(
                    gettext('{0} of them have no script stored and will be skipped.'),
                    missing,
                ),
            );
        }

        Ext.Msg.confirm(PVE.updmgr.TAB_TITLE, lines.join('<br>'), function (btn) {
            if (btn !== 'yes') {
                return;
            }

            // Per node, because the setting is per node: a datacenter selection
            // can legitimately be parallel on one server and serial on another.
            let byMode = { parallel: [], serial: [] };
            selection.forEach(function (rec) {
                let key = me.parallelFor(me.nodeOf(rec.data)) ? 'parallel' : 'serial';
                byMode[key].push(rec.data);
            });

            let collected = [];
            let waiting = 0;
            let finish = function (started) {
                collected = collected.concat(started);
                waiting--;
                if (waiting > 0) {
                    return;
                }
                me.reload();
                if (collected.length === 1) {
                    let win = Ext.create('Proxmox.window.TaskViewer', {
                        upid: collected[0].upid,
                    });
                    win.on('destroy', function () {
                        me.reload();
                    });
                    win.show();
                }
                // With several tasks in flight there is no single one to show -
                // the rows themselves are the progress display.
            };

            ['parallel', 'serial'].forEach(function (mode) {
                if (byMode[mode].length) {
                    waiting++;
                }
            });

            ['parallel', 'serial'].forEach(function (mode) {
                if (!byMode[mode].length) {
                    return;
                }
                PVE.updmgr.dispatch(byMode[mode], me.nodename, mode === 'parallel', finish);
            });
        });
    },

    // `quiet` is what the poller passes, and it means more than "no load mask".
    //
    // A run is watched for as long as it takes, so the grid re-reads itself
    // every few seconds. store.load() replaces every record, which makes the
    // grid rebuild its whole view - so the spinning icon on the running row
    // restarts its animation and the table visibly redraws, every three
    // seconds, on the one tab where an update is in progress. Turning the load
    // mask off did not fix that, because the mask was never what was blinking.
    //
    // So a quiet refresh does not load the store at all. It fetches the same
    // list and writes the changed fields into the records that are already
    // there: Ext then repaints the cells that differ and leaves everything else
    // untouched - the spinner keeps spinning smoothly, and the selection
    // survives, which a full reload also used to throw away mid-run.
    reload: function (quiet) {
        let me = this;

        if (me.isDestroyed) {
            return;
        }

        if (!quiet) {
            me.setLoading(true);
            me.getStore().load({
                callback: function () {
                    if (!me.isDestroyed) {
                        me.setLoading(false);
                    }
                },
            });
            return;
        }

        Proxmox.Utils.API2Request({
            url: me.targetsUrl,
            method: 'GET',
            failure: function () {
                // A refresh that fails is not worth a dialog while a run is in
                // flight - but the watch has to keep going, or a target that
                // finishes during the outage spins for ever.
                if (!me.isDestroyed) {
                    me.scheduleReloadIfRunning();
                }
            },
            success: function (response) {
                if (me.isDestroyed) {
                    return;
                }

                me.mergeRows(response.result.data || []);
                // The store's own load event is what normally re-arms the
                // poller, and nothing loaded it here.
                me.scheduleReloadIfRunning();
            },
        });
    },

    // Writes a fresh list into the existing records instead of replacing them.
    mergeRows: function (rows) {
        let me = this;
        let store = me.getStore();

        let seen = {};
        rows.forEach(function (row) {
            seen[row.id] = true;

            let rec = store.getById(row.id);
            if (rec) {
                // set() marks the record dirty, which would draw the little
                // red change marker in every cell it touched; commit() is what
                // says "this came from the server, not from an edit".
                rec.set(row);
                rec.commit();
            } else {
                store.add(row);
            }
        });

        let gone = store.getRange().filter((rec) => !seen[rec.get('id')]);
        if (gone.length) {
            store.remove(gone);
        }
    },

    scheduleReloadIfRunning: function () {
        let me = this;

        if (me.reloadTask) {
            clearTimeout(me.reloadTask);
            me.reloadTask = undefined;
        }

        let running = false;
        me.getStore().each(function (rec) {
            if (rec.data.last_state === 'running') {
                running = true;
                return false;
            }
            return true;
        });

        if (running) {
            me.reloadTask = setTimeout(function () {
                // Quiet: this one is the poller, not the user.
                me.reload(true);
            }, PVE.updmgr.RUNNING_POLL_MS);
        }
    },

    buildColumns: function () {
        let me = this;

        let columns = [
            {
                header: gettext('Type'),
                dataIndex: 'type',
                width: 80,
                renderer: function (value, meta, rec) {
                    if (value === 'node') {
                        return `<i class="fa fa-fw fa-server"></i> ${gettext('Host')}`;
                    }
                    return `<i class="fa fa-fw fa-cube"></i> ${rec.data.template ? gettext('Template') : 'CT'}`;
                },
            },
            {
                header: gettext('ID'),
                dataIndex: 'id',
                width: 90,
            },
            {
                header: gettext('Name'),
                dataIndex: 'name',
                flex: 1,
            },
        ];

        if (me.showNodeColumn) {
            columns.push({
                header: gettext('Node'),
                dataIndex: 'node',
                width: 130,
            });
        }

        columns.push(
            {
                header: gettext('Status'),
                dataIndex: 'status',
                width: 100,
                renderer: function (value) {
                    let cls = value === 'running' || value === 'online' ? 'good' : 'faded';
                    return `<span class="${cls}">${Ext.String.htmlEncode(value || '')}</span>`;
                },
            },
            {
                header: gettext('Update Commands'),
                dataIndex: 'stored',
                width: 160,
                renderer: function (value) {
                    if (value) {
                        return `<i class="fa fa-check good"></i> ${gettext('stored')}`;
                    }
                    return `<i class="fa fa-minus faded"></i> ${gettext('none')}`;
                },
            },
            {
                header: gettext('Last Run'),
                dataIndex: 'last_state',
                width: 220,
                renderer: function (value, meta, rec) {
                    return PVE.updmgr.renderLastRun(rec.data);
                },
            },
            {
                xtype: 'actioncolumn',
                header: gettext('Actions'),
                width: 120,
                align: 'center',
                items: [
                    {
                        iconCls: 'fa fa-play',
                        tooltip: gettext('Update now'),
                        isActionDisabled: function (view, rI, cI, item, rec) {
                            return !rec.data.stored || rec.data.last_state === 'running';
                        },
                        handler: function (view, rI, cI, item, e, rec) {
                            me.runRow(rec);
                        },
                    },
                    {
                        iconCls: 'fa fa-file-text-o',
                        tooltip: gettext('Last log'),
                        isActionDisabled: function (view, rI, cI, item, rec) {
                            return !rec.data.last_upid;
                        },
                        handler: function (view, rI, cI, item, e, rec) {
                            PVE.updmgr.showLog(rec.data.last_upid);
                        },
                    },
                    {
                        iconCls: 'fa fa-pencil',
                        tooltip: gettext('Edit commands'),
                        handler: function (view, rI, cI, item, e, rec) {
                            me.editTarget(rec);
                        },
                    },
                    {
                        iconCls: 'fa fa-trash-o',
                        tooltip: gettext('Remove commands'),
                        isActionDisabled: function (view, rI, cI, item, rec) {
                            return !rec.data.stored || rec.data.last_state === 'running';
                        },
                        handler: function (view, rI, cI, item, e, rec) {
                            me.removeRow(rec);
                        },
                    },
                ],
            },
        );

        return columns;
    },

    initComponent: function () {
        let me = this;

        if (!me.targetsUrl) {
            throw 'no targetsUrl specified';
        }

        let caps = Ext.state.Manager.get('GuiCap') || {};
        let nodeCaps = caps.nodes || {};
        let vmCaps = caps.vms || {};

        me.canRunHost = !!nodeCaps['Sys.Console'];
        me.canEditHost = !!nodeCaps['Sys.Modify'];
        me.canRunGuest = !!vmCaps['VM.Console'];
        me.canEditGuest = !!vmCaps['VM.Config.Options'];

        let store = Ext.create('Ext.data.Store', {
            fields: [
                'type',
                'id',
                'name',
                'status',
                'node',
                'last_state',
                'last_upid',
                'last_note',
                { name: 'vmid', type: 'int' },
                { name: 'last_started', type: 'int' },
                { name: 'last_finished', type: 'int' },
                { name: 'last_exit', type: 'int' },
                { name: 'stored', type: 'boolean' },
                { name: 'template', type: 'boolean' },
                { name: 'parallel_manual', type: 'boolean' },
            ],
            proxy: {
                type: 'proxmox',
                url: `/api2/json${me.targetsUrl}`,
            },
            listeners: {
                load: function () {
                    me.scheduleReloadIfRunning();
                },
            },
        });

        Ext.apply(me, {
            store: store,
            // See reload(): the poller must not flash a mask every few seconds,
            // and the only way to be sure of that is for the mask never to
            // exist. Explicit reloads mask themselves.
            loadMask: false,
            selModel: {
                type: 'checkboxmodel',
                mode: 'MULTI',
                checkOnly: false,
            },
            tbar: [
                {
                    text: gettext('Update Selected'),
                    iconCls: 'fa fa-play',
                    disabled: !me.canRunGuest && !me.canRunHost,
                    handler: function () {
                        me.runSelected();
                    },
                },
                {
                    text: gettext('Select All'),
                    iconCls: 'fa fa-check-square-o',
                    handler: function () {
                        me.selectAll();
                    },
                },
                {
                    text: gettext('Clear Selection'),
                    iconCls: 'fa fa-square-o',
                    handler: function () {
                        me.getSelectionModel().deselectAll();
                    },
                },
                '-',
                {
                    // Named like its neighbour Update Selected, because it acts
                    // on the same thing: one selected target opens the editor it
                    // always opened, several open one box that writes to all of
                    // them.
                    text: gettext('Edit Selected'),
                    iconCls: 'fa fa-pencil',
                    disabled: !me.canEditGuest && !me.canEditHost,
                    handler: function () {
                        me.editSelected();
                    },
                },
                // Node and datacenter tabs, not the container tab - see
                // PVE.updmgr.NodePanel and PVE.updmgr.DcPanel.
                {
                    text: gettext('Settings'),
                    iconCls: 'fa fa-cog',
                    hidden: !me.showSettings,
                    // Sys.Console specifically: the schedule endpoints want
                    // Sys.Audit to read and Sys.Console to write, so a user with
                    // only container privileges would open an empty window onto
                    // a permission error.
                    disabled: !me.canRunHost,
                    handler: function () {
                        me.openSettings();
                    },
                },
                '->',
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function () {
                        me.reload();
                    },
                },
            ],
            columns: me.buildColumns(),
            listeners: {
                itemdblclick: function (view, rec) {
                    me.editTarget(rec);
                },
                // Only on RE-activation: the first load happens below, and a
                // second request on the very first tab open would be noise.
                activate: function () {
                    if (me.getStore().isLoaded()) {
                        me.reload();
                    }
                },
                destroy: function () {
                    if (me.reloadTask) {
                        clearTimeout(me.reloadTask);
                        me.reloadTask = undefined;
                    }
                },
            },
        });

        me.callParent();

        me.reload();
    },
});

// ── Node tab: this node and its containers ──────────────────────────────────
// ── The schedule editor, node tab only ──────────────────────────────────────
//
// A container has no opinion about when it should be updated, and a
// cluster-wide schedule would have to pick a node to run it - so this belongs
// to the node that owns the targets and whose timer will fire.
Ext.define('PVE.updmgr.SettingsWindow', {
    extend: 'Ext.window.Window',

    width: 700,
    // Grown once already when two fieldsets were added above the target list and
    // squeezed it until its last containers were cut off. The height is why it
    // fits today; the scrollable body below is why the next field added here
    // cannot repeat that.
    //
    // No maxHeight here. It was once set to '90%', and ExtJS wants a number of
    // pixels: the string made the whole size calculation collapse, leaving a
    // window about as tall as its own title bar, parked in the top left corner.
    // The cap is computed against the real viewport in initComponent instead.
    height: 720,
    layout: 'fit',
    modal: true,
    resizable: true,

    settingsUrl: function () {
        let me = this;

        return me.global
            ? '/cluster/updatemgr/settings'
            : `/nodes/${me.nodename}/updatemgr/settings`;
    },

    load: function () {
        let me = this;

        Proxmox.Utils.API2Request({
            url: me.settingsUrl(),
            method: 'GET',
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function (response) {
                let data = response.result.data;

                me.down('#parallelManual').setValue(!!data.parallel_manual);
                me.down('#timeout').setValue(Math.round((data.timeout || 14400) / 60));
                me.down('#startStopped').setValue(!!data.start_stopped);
                me.down('#snapshotBefore').setValue(!!data.snapshot_before);
                me.down('#snapshotKeep').setValue(data.snapshot_keep || 3);
                // Hidden, not disabled, and decided by the server: a switch
                // that is visible but can do nothing is a question the operator
                // has to answer and then find out did not matter. What the
                // server checks is every container's volumes, which is the only
                // honest answer - "does the node have ZFS" is not the question.
                // In global mode the answer is per node and there is no single
                // one, so the fieldset stays visible: the setting is written
                // everywhere and simply does nothing on the nodes that cannot.
                me.down('#snapshots').setHidden(!me.global && !data.snapshot_capable);
                me.down('#scheduleEnabled').setValue(!!data.schedule_enabled);
                me.down('#scheduleTime').setValue(data.schedule_time);
                me.down('#scheduleParallel').setValue(!!data.schedule_parallel);

                if (me.global) {
                    me.down('#scheduleHost').setValue(!!data.schedule_host);
                    me.nodeCount = data.nodes;
                    me.updateScope(data);
                    // Only now. The load is asynchronous, and a Save pressed
                    // before it came back would write the empty form to every
                    // node in the cluster - which is the one mistake this
                    // window is in a position to make.
                    me.down('#save').setDisabled(false);
                    return;
                }

                let selected = {};
                if (data.schedule_host) {
                    selected['node'] = true;
                }
                String(data.schedule_vmids || '')
                    .split(',')
                    .filter((id) => id.length)
                    .forEach((id) => {
                        selected[id] = true;
                    });
                me.preselected = selected;

                me.targetGrid.getStore().load();
                me.updateNextRun(data);
            },
        });
    },

    // What the bottom line says in global mode, where there is no single next
    // run to report but there IS something more important: how many nodes this
    // is about to change, and whether they currently agree.
    updateScope: function (data) {
        let me = this;

        let text = Ext.String.format(
            gettext('Saving writes these settings to all {0} nodes.'),
            data.nodes,
        );
        if (!data.uniform) {
            text += ` ${gettext('They do not all have the same settings today.')}`;
        }
        me.down('#nextrun').setText(text);
    },

    updateNextRun: function (data) {
        let me = this;

        let text = gettext('No schedule');
        if (data.schedule_enabled && data.next_run) {
            text = `${gettext('Next run')}: ${Proxmox.Utils.render_timestamp(data.next_run)}`;
        }
        if (data.last_run) {
            text += ` — ${gettext('last')}: ${Proxmox.Utils.render_timestamp(data.last_run)}`;
        }
        me.down('#nextrun').setText(text);
    },

    // What both modes have in common. The two that are missing here are exactly
    // the two a datacenter-wide save may not carry: the ticked containers, which
    // exist on one node only, and the host tick, which comes from the grid in
    // per-node mode and from a plain checkbox in global mode.
    commonParams: function () {
        let me = this;

        return {
            parallel_manual: me.down('#parallelManual').getValue() ? 1 : 0,
            timeout: me.down('#timeout').getValue() * 60,
            start_stopped: me.down('#startStopped').getValue() ? 1 : 0,
            snapshot_before: me.down('#snapshotBefore').getValue() ? 1 : 0,
            snapshot_keep: me.down('#snapshotKeep').getValue(),
            schedule_enabled: me.down('#scheduleEnabled').getValue() ? 1 : 0,
            schedule_time: me.down('#scheduleTime').getValue(),
            schedule_parallel: me.down('#scheduleParallel').getValue() ? 1 : 0,
        };
    },

    save: function () {
        let me = this;

        if (me.global) {
            me.saveGlobal();
            return;
        }

        let host = 0;
        let vmids = [];
        me.targetGrid.getSelectionModel().getSelection().forEach(function (rec) {
            if (rec.data.type === 'node') {
                host = 1;
            } else {
                vmids.push(rec.data.vmid);
            }
        });

        let params = Ext.apply(me.commonParams(), {
            schedule_host: host,
            schedule_vmids: vmids.join(','),
        });

        me.write(`/nodes/${me.nodename}/updatemgr/settings`, params);
    },

    // Asked before it happens, and the question counts the nodes out loud: this
    // is the one save in the addon that changes a machine the operator is not
    // looking at.
    saveGlobal: function () {
        let me = this;

        let params = Ext.apply(me.commonParams(), {
            schedule_host: me.down('#scheduleHost').getValue() ? 1 : 0,
        });

        Ext.Msg.confirm(
            gettext('Confirm'),
            Ext.String.format(
                gettext(
                    'Overwrite the Update Manager settings of all {0} nodes with what is'
                        + ' shown here? Each node keeps its own selection of scheduled'
                        + ' containers; everything else on this page replaces what that node'
                        + ' has today.',
                ),
                me.nodeCount,
            ),
            function (btn) {
                if (btn === 'yes') {
                    me.write('/cluster/updatemgr/settings', params);
                }
            },
        );
    },

    write: function (url, params) {
        let me = this;

        Proxmox.Utils.API2Request({
            url: url,
            method: 'PUT',
            params: params,
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function () {
                me.close();
            },
        });
    },

    initComponent: function () {
        let me = this;

        // One window, two scopes. Global mode writes the same answers to every
        // node at once - which is why it has a confirmation and a per-node save
        // does not.
        if (!me.global && !me.nodename) {
            throw 'no node name specified';
        }

        // Never taller than the browser window, and a number, not a percentage.
        // On a laptop 720 would otherwise run off the bottom of the screen.
        let viewport = Ext.Element.getViewportHeight();
        if (viewport > 200) {
            me.height = Math.max(420, Math.min(me.height, viewport - 60));
        }

        me.preselected = {};
        me.nodeCount = 0;

        me.targetGrid = me.global ? undefined : Ext.create('Ext.grid.GridPanel', {
            // A fixed height, not flex: inside a scrolling body there is no
            // bounded height for a flex to divide up, so it would collapse to
            // nothing. This scrolls its own rows and the dialog scrolls around
            // it.
            height: 260,
            border: true,
            title: gettext('Run these targets on the schedule'),
            selModel: { type: 'checkboxmodel', mode: 'SIMPLE', checkOnly: true },
            store: Ext.create('Ext.data.Store', {
                fields: ['type', 'id', 'name', 'status', { name: 'vmid', type: 'int' },
                    { name: 'stored', type: 'boolean' }],
                proxy: {
                    type: 'proxmox',
                    url: `/api2/json/nodes/${me.nodename}/updatemgr/targets`,
                },
                listeners: {
                    load: function (store) {
                        // Re-tick what the stored settings name, once the rows
                        // they refer to actually exist.
                        let rows = [];
                        store.each(function (rec) {
                            let key = rec.data.type === 'node' ? 'node' : String(rec.data.vmid);
                            if (me.preselected[key]) {
                                rows.push(rec);
                            }
                        });
                        me.targetGrid.getSelectionModel().select(rows, false);
                    },
                },
            }),
            columns: [
                {
                    header: gettext('Type'),
                    dataIndex: 'type',
                    width: 80,
                    renderer: (v) =>
                        v === 'node'
                            ? `<i class="fa fa-fw fa-server"></i> ${gettext('Host')}`
                            : '<i class="fa fa-fw fa-cube"></i> CT',
                },
                { header: gettext('ID'), dataIndex: 'id', width: 80 },
                { header: gettext('Name'), dataIndex: 'name', flex: 1 },
                {
                    header: gettext('Update Commands'),
                    dataIndex: 'stored',
                    width: 160,
                    renderer: (v) =>
                        v
                            ? `<i class="fa fa-check good"></i> ${gettext('stored')}`
                            : `<i class="fa fa-minus faded"></i> ${gettext('none')}`,
                },
            ],
        });

        Ext.apply(me, {
            title: me.global
                ? gettext('Update Manager settings for all nodes')
                : Ext.String.format(gettext('Update Manager settings for {0}'), me.nodename),
            items: [
                {
                    xtype: 'panel',
                    layout: { type: 'vbox', align: 'stretch' },
                    bodyPadding: 10,
                    scrollable: 'y',
                    items: [
                        // Said before the fields rather than only in the
                        // confirmation: somebody who opens this window to look
                        // at a value should know what pressing Save would do
                        // before they start changing things.
                        me.global
                            ? {
                                  xtype: 'displayfield',
                                  userCls: 'pmx-hint',
                                  margin: '0 0 10 0',
                                  value: gettext(
                                      'These settings are written to EVERY node and replace'
                                          + ' what each of them has. A node has no way to keep'
                                          + ' its own answer to any of them.',
                                  ),
                              }
                            : { xtype: 'container', height: 0 },
                        {
                            xtype: 'fieldset',
                            title: gettext('Limits'),
                            margin: '0 0 10 0',
                            items: [
                                {
                                    // In minutes, because the useful values here
                                    // are hours and nobody should have to count
                                    // zeros to say "four hours". The API still
                                    // speaks seconds and still accepts finer
                                    // values than this field offers.
                                    xtype: 'proxmoxintegerfield',
                                    itemId: 'timeout',
                                    fieldLabel: gettext('Kill a run after'),
                                    labelWidth: 160,
                                    minValue: 1,
                                    maxValue: 1440,
                                    allowBlank: false,
                                    emptyText: '240',
                                },
                                {
                                    xtype: 'displayfield',
                                    userCls: 'faded',
                                    value: gettext(
                                        'Minutes. This kills the update and everything it started,'
                                            + ' so keep it well above the longest upgrade you expect'
                                            + ' - a package manager cut off mid-install has to be'
                                            + ' repaired by hand.',
                                    ),
                                },
                            ],
                        },
                        {
                            xtype: 'fieldset',
                            title: gettext('Stopped containers'),
                            margin: '0 0 10 0',
                            items: [
                                {
                                    xtype: 'checkbox',
                                    itemId: 'startStopped',
                                    boxLabel: gettext(
                                        'Start a stopped container for its update, then stop it again',
                                    ),
                                },
                                {
                                    xtype: 'displayfield',
                                    userCls: 'faded',
                                    value: gettext(
                                        'Off by default: a stopped container is skipped. With this on'
                                            + ' it is started, updated and shut down again, ending up'
                                            + ' the way it was found - but its services and cron run'
                                            + ' for as long as the update takes.',
                                    ),
                                },
                            ],
                        },
                        {
                            xtype: 'fieldset',
                            itemId: 'snapshots',
                            title: gettext('Snapshots'),
                            margin: '0 0 10 0',
                            // Shown only where a container on this node could
                            // actually be snapshotted - see the load() above.
                            hidden: true,
                            items: [
                                {
                                    xtype: 'checkbox',
                                    itemId: 'snapshotBefore',
                                    boxLabel: gettext(
                                        'Take a snapshot of a container before updating it',
                                    ),
                                },
                                {
                                    xtype: 'proxmoxintegerfield',
                                    itemId: 'snapshotKeep',
                                    fieldLabel: gettext('Keep the last'),
                                    labelWidth: 160,
                                    minValue: 1,
                                    maxValue: 100,
                                    allowBlank: false,
                                    emptyText: '3',
                                },
                                {
                                    xtype: 'displayfield',
                                    userCls: 'faded',
                                    value: gettext(
                                        'On by default: it is what makes a bad upgrade undoable.'
                                            + ' Only snapshots taken by the Update Manager are ever'
                                            + ' removed - one somebody made by hand is left alone.'
                                            + ' A container whose storage cannot snapshot is updated'
                                            + ' without one, and the run says so in its log.',
                                    ),
                                },
                            ],
                        },
                        {
                            xtype: 'fieldset',
                            title: gettext('Manual runs'),
                            margin: '0 0 10 0',
                            items: [
                                {
                                    xtype: 'checkbox',
                                    itemId: 'parallelManual',
                                    // Its own switch, deliberately not shared with
                                    // the schedule: pressing Update Selected is
                                    // somebody watching who wants everything
                                    // moving now, while the timer firing at 03:00
                                    // is unattended.
                                    //
                                    // "targets" rather than "containers": a host
                                    // row can be ticked too, and the label would
                                    // then be describing something it does not do.
                                    boxLabel: gettext('Update all targets in parallel'),
                                },
                            ],
                        },
                        {
                            xtype: 'fieldset',
                            title: gettext('Schedule'),
                            layout: { type: 'vbox', align: 'stretch' },
                            items: [
                                {
                                    xtype: 'checkbox',
                                    itemId: 'scheduleEnabled',
                                    margin: '0 0 8 0',
                                    boxLabel: gettext('Run on a schedule'),
                                },
                                {
                                    // The same field and the same syntax a backup
                                    // job uses, so "at 03:00" is expressible and
                                    // already familiar: 03:00, mon..fri 02:30,
                                    // */8:00.
                                    xtype: 'pveCalendarEvent',
                                    itemId: 'scheduleTime',
                                    name: 'schedule_time',
                                    fieldLabel: gettext('Schedule'),
                                    labelWidth: 90,
                                    margin: '0 0 8 0',
                                    value: '03:00',
                                },
                                {
                                    xtype: 'checkbox',
                                    itemId: 'scheduleParallel',
                                    margin: '0 0 8 0',
                                    boxLabel: gettext('Update all targets in parallel'),
                                },
                                // Which containers a schedule runs is the one
                                // answer that cannot be given for the whole
                                // cluster - a vmid lives on exactly one node.
                                // So global mode gets the host tick as a plain
                                // checkbox and says where the rest is decided.
                                me.global
                                    ? {
                                          xtype: 'checkbox',
                                          itemId: 'scheduleHost',
                                          margin: '0 0 8 0',
                                          boxLabel: gettext(
                                              "Include each node's own update script",
                                          ),
                                      }
                                    : me.targetGrid,
                                me.global
                                    ? {
                                          xtype: 'displayfield',
                                          userCls: 'faded',
                                          value: gettext(
                                              'Which containers a node updates on its'
                                                  + ' schedule stays that node\'s own setting -'
                                                  + ' a container exists on one node only. Set it'
                                                  + ' under Node → Update Manager → Settings.',
                                          ),
                                      }
                                    : { xtype: 'container', height: 0 },
                            ],
                        },
                    ],
                },
            ],
            bbar: [
                { xtype: 'tbtext', itemId: 'nextrun', text: '' },
                '->',
                {
                    text: gettext('Cancel'),
                    handler: function () {
                        me.close();
                    },
                },
                {
                    text: gettext('Save'),
                    itemId: 'save',
                    iconCls: 'fa fa-floppy-o',
                    // Global mode only - see load(). A per-node save that came
                    // in early costs one node its settings and is visible on the
                    // page the operator is already looking at.
                    disabled: !!me.global,
                    handler: function () {
                        me.save();
                    },
                },
            ],
        });

        me.callParent();

        me.load();
    },
});

Ext.define('PVE.updmgr.NodePanel', {
    extend: 'PVE.updmgr.TargetGrid',
    alias: 'widget.pveUpdMgrNode',

    // The container tab has a single target and no say over the node's timer, so
    // it gets no Settings button. The datacenter tab gets one too - the same
    // window in its global mode, see PVE.updmgr.DcPanel.
    showSettings: true,

    initComponent: function () {
        let me = this;

        if (!me.nodename) {
            throw 'no node name specified';
        }

        me.targetsUrl = `/nodes/${me.nodename}/updatemgr/targets`;

        me.callParent();
    },

    openSettings: function () {
        let me = this;

        let win = Ext.create('PVE.updmgr.SettingsWindow', { nodename: me.nodename });
        win.on('destroy', function () {
            me.reload();
        });
        win.show();
    },
});

// ── Datacenter tab: every node and every container in the cluster ───────────
Ext.define('PVE.updmgr.DcPanel', {
    extend: 'PVE.updmgr.TargetGrid',
    alias: 'widget.pveUpdMgrDc',

    showNodeColumn: true,

    // The same button as on a node, pointed at every node at once. It is here
    // and not only on the node tab because keeping twelve copies of the same
    // four answers in step by hand is how they stop being in step.
    showSettings: true,

    initComponent: function () {
        let me = this;

        me.targetsUrl = '/cluster/updatemgr/targets';

        me.callParent();
    },

    openSettings: function () {
        let me = this;

        let win = Ext.create('PVE.updmgr.SettingsWindow', { global: true });
        win.on('destroy', function () {
            me.reload();
        });
        win.show();
    },
});

// ── Hooking the tabs in ─────────────────────────────────────────────────────
//
// PVE.panel.Config.initComponent is the injection point: PVE.lxc.Config,
// PVE.node.Config and PVE.dc.Config have finished filling me.items by the time
// they call up into it, and it has not yet been consumed. $className tells them
// apart, so one override serves all three without touching any of them.
PVE.updmgr.injectTab = function (panel) {
    let cls = panel.$className;

    if (cls !== 'PVE.lxc.Config' && cls !== 'PVE.node.Config' && cls !== 'PVE.dc.Config') {
        return;
    }
    if (!Ext.isArray(panel.items)) {
        return;
    }
    if (panel.items.some((i) => i && i.itemId === 'updatemgr')) {
        return;
    }

    let caps = Ext.state.Manager.get('GuiCap') || {};
    let item;

    if (cls === 'PVE.lxc.Config') {
        let vm = panel.pveSelNode.data;

        // A template is never running, so there is nothing to exec into.
        if (vm.template) {
            return;
        }
        if (!(caps.vms || {})['VM.Audit']) {
            return;
        }

        item = {
            xtype: 'pveUpdMgrLxc',
            nodename: vm.node,
            vmid: vm.vmid,
            guestName: vm.name,
            canRun: !!(caps.vms || {})['VM.Console'],
            canEdit: !!(caps.vms || {})['VM.Config.Options'],
        };
    } else if (cls === 'PVE.node.Config') {
        if (!(caps.nodes || {})['Sys.Audit']) {
            return;
        }

        item = {
            xtype: 'pveUpdMgrNode',
            nodename: panel.pveSelNode.data.node,
        };
    } else {
        if (!(caps.nodes || {})['Sys.Audit'] && !(caps.vms || {})['VM.Audit']) {
            return;
        }

        item = { xtype: 'pveUpdMgrDc' };
    }

    Ext.apply(item, {
        title: PVE.updmgr.TAB_TITLE,
        itemId: 'updatemgr',
        iconCls: PVE.updmgr.TAB_ICON,
    });

    let idx = panel.items.findIndex((i) => i && i.itemId === 'summary');
    panel.items.splice(idx >= 0 ? idx + 1 : panel.items.length, 0, item);
};

// ── Throwing the stored commands away with the container ────────────────────
//
// A destroyed container leaves lxc-<vmid>.conf and lxc-<vmid>.state behind in
// /etc/pve. That is not only clutter: Proxmox hands vmids out again, so the next
// container created as 101 would inherit the update commands of the one that was
// deleted - and its last-run record - without anybody having typed them.
//
// So the destroy dialog gets one more tick, on by default, and it is a tick
// rather than an automatism because the files are also a legitimate thing to
// keep: rebuilding a container under the same id and wanting its script back is
// a real workflow.
//
// The dialog itself is Proxmox' PVE.window.SafeDestroyGuest. Nothing of it is
// modified - the toolkit already offers both hooks this needs: `additionalItems`
// for the checkbox and `apiCallDone` for the moment the destroy was accepted.
PVE.updmgr.STORAGE_CHECKBOX = 'pveUpdMgrDropStored';

// Where to send the cleanup, given the URL the destroy dialog was built with.
//
// Read back from the dialog rather than passed in, because this override has no
// say in how the window was created - and matched strictly, because the same
// window destroys VMs from `/nodes/<node>/qemu/<vmid>`, which has nothing stored
// here and must produce no request at all.
PVE.updmgr.destroyCleanupUrl = function (url) {
    let match = String(url || '').match(/^\/nodes\/([^/]+)\/lxc\/(\d+)$/);
    if (!match) {
        return undefined;
    }

    // purge: the last-run record goes too. Keeping it would hand a container's
    // update history to whatever is created with that vmid next.
    return `/nodes/${match[1]}/lxc/${match[2]}/updatemgr/script?purge=1`;
};

Ext.define('PVE.updmgr.SafeDestroyGuestOverride', {
    override: 'PVE.window.SafeDestroyGuest',

    initComponent: function () {
        let me = this;

        // Everything this override does sits inside a try. The tab injection is
        // wrapped for the same reason and the reason is stronger here: a throw
        // in the tab costs a tab, a throw in THIS costs the ability to delete a
        // guest at all, which is Proxmox' function and not ours to break.
        try {
            // Containers only. A VM has no update script here, and a tick
            // offering to delete something that cannot exist is worse than none.
            if ((me.getItem() || {}).type === 'CT') {
                // concat, not push: additionalItems is on the prototype and is
                // shared by every dialog this class ever opens. Pushing would
                // add a checkbox per destroyed container, for ever.
                me.additionalItems = (me.additionalItems || []).concat([
                    {
                        xtype: 'proxmoxcheckbox',
                        itemId: PVE.updmgr.STORAGE_CHECKBOX,
                        reference: PVE.updmgr.STORAGE_CHECKBOX,
                        boxLabel: gettext('Also delete the stored update commands'),
                        checked: true,
                        autoEl: {
                            tag: 'div',
                            'data-qtip': gettext(
                                'Removes this container from the Update Manager: its commands'
                                    + ' and its last-run record. Without this they stay, and a'
                                    + ' new container created with the same ID would inherit'
                                    + ' them.',
                            ),
                        },
                    },
                ]);
            }
        } catch (err) {
            console.error('pve-update-manager: could not add the cleanup checkbox', err);
        }

        me.callParent(arguments);
    },

    // Called the moment the destroy request came back - which is when the task
    // has been STARTED, not when it has finished. That is the honest place for
    // this: waiting for the task would mean this dialog stayed open watching a
    // worker it does not own, and the alternative - deleting before the destroy
    // is even accepted - would throw the commands away on a container the API
    // then refused to remove.
    apiCallDone: function (success, response, options) {
        let me = this;

        // Proxmox' own hook first and outside the try: whatever this override
        // gets wrong must not stop the dialog from closing.
        me.callParent(arguments);

        try {
            if (!success) {
                return;
            }

            let box = me.lookupReference(PVE.updmgr.STORAGE_CHECKBOX);
            if (!box || !box.checked) {
                return;
            }

            let url = PVE.updmgr.destroyCleanupUrl(me.getUrl());
            if (!url) {
                return;
            }

            Proxmox.Utils.API2Request({
                url: url,
                method: 'DELETE',
                failure: function (res) {
                    // Not a dialog. The container is being destroyed either way
                    // and this is tidying up after it; a message box here would
                    // be an error about a file on top of an operation that
                    // succeeded.
                    console.error(
                        'pve-update-manager: could not remove the stored update commands',
                        res.htmlStatus,
                    );
                },
            });
        } catch (err) {
            console.error('pve-update-manager: could not clean up after the destroy', err);
        }
    },
});

Ext.define('PVE.updmgr.ConfigPanelOverride', {
    override: 'PVE.panel.Config',

    initComponent: function () {
        let me = this;

        // A throw in here would take down the whole container, node or
        // datacenter view, and a missing tab is the only acceptable way for this
        // addon to fail.
        try {
            PVE.updmgr.injectTab(me);
        } catch (err) {
            console.error('pve-update-manager: could not add the tab', err);
        }

        me.callParent(arguments);
    },
});
