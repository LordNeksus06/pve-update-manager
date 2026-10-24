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

    // Whether a container on that node is shut down for its snapshot. Read the
    // same way as parallelFor: the answer is a node setting, and the row that
    // carries it is that node's own row in the same list.
    snapshotShutdownFor: function (node) {
        let me = this;

        let answer = false;
        me.getStore().each(function (rec) {
            if (rec.data.type === 'node' && me.nodeOf(rec.data) === node) {
                answer = !!rec.data.snapshot_shutdown;
                return false;
            }
            return true;
        });

        return answer;
    },

    // The position of one target in a run. A prompt rather than an
    // editable cell: the grid's rows are ticked to select them, and a cell
    // editor competes with that click for the same pixels.
    editOrder: function (rec) {
        let me = this;

        let url = PVE.updmgr.orderUrlFor(rec.data, me.nodename);
        if (!url) {
            return;
        }

        Ext.Msg.prompt(
            gettext('Update order'),
            Ext.String.format(
                gettext(
                    'Where {0} goes in a run. Lower runs first, and an empty field means'
                        + ' after everything that has a number. The same number means by'
                        + ' ascending ID in a serial run, and at the same time in a'
                        + ' parallel one.',
                ),
                PVE.updmgr.targetLabel(rec.data),
            ),
            function (btn, text) {
                if (btn !== 'ok') {
                    return;
                }

                let order = PVE.updmgr.parseOrder(text);
                if (order === undefined) {
                    Ext.Msg.alert(
                        gettext('Error'),
                        Ext.String.format(
                            gettext('The update order has to be a number between 0 and {0}.'),
                            PVE.updmgr.MAX_ORDER,
                        ),
                    );
                    return;
                }

                Proxmox.Utils.API2Request({
                    url: url,
                    method: 'PUT',
                    params: { order: order },
                    waitMsgTarget: me,
                    failure: function (response) {
                        Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                    },
                    success: function () {
                        me.reload();
                    },
                });
            },
            me,
            false,
            rec.data.order ? String(rec.data.order) : '',
        );
    },

    // The same thing for a whole selection: ONE number, written to every ticked
    // target.
    //
    // One number and not a sequence, deliberately. "Set the order of these five"
    // means "these five belong in the same place" far more often than it means
    // "number them 1 to 5" - a database and its two replicas go together, and a
    // parallel run then starts them together. Numbering a selection 1..N is the
    // other job and it needs an order within the selection that a checkbox grid
    // does not have: ticks have no sequence.
    orderSelected: function () {
        let me = this;

        let sel = me.getSelectionModel().getSelection();
        if (!sel.length) {
            Ext.Msg.alert(gettext('Error'), gettext('No target selected.'));
            return;
        }

        // One target keeps the prompt it always had, which names it and prefills
        // its own number - the same rule Edit Selected follows.
        if (sel.length === 1) {
            me.editOrder(sel[0]);
            return;
        }

        // Checked here rather than left to the API: without it the operator types
        // a number, and the permission error arrives once per target after the
        // fact - with some of them already written.
        let refused = sel
            .filter((rec) =>
                rec.data.type === 'node' ? !me.canEditHost : !me.canEditGuest,
            )
            .map((rec) => PVE.updmgr.targetLabel(rec.data));

        if (refused.length) {
            Ext.Msg.alert(
                gettext('Error'),
                gettext('You may not change the update order of:')
                    + `<br><br>${refused.join('<br>')}`,
            );
            return;
        }

        // Prefilled with the number they already share, empty when they do not -
        // so pressing OK on an unchanged box changes nothing, and the field never
        // suggests a value that only some of them have.
        let orders = sel.map((rec) => rec.data.order || 0);
        let shared = orders.every((o) => o === orders[0]) && orders[0] ? String(orders[0]) : '';

        Ext.Msg.prompt(
            gettext('Update order'),
            Ext.String.format(
                gettext(
                    'Where these {0} targets go in a run. They all get the SAME number:'
                        + ' in a parallel run that means they start together and the next'
                        + ' number waits for all of them, in a serial one they go one after'
                        + ' another by ascending ID. Lower runs first, and an empty field'
                        + ' means after everything that has a number.',
                ),
                sel.length,
            ),
            function (btn, text) {
                if (btn !== 'ok') {
                    return;
                }

                let order = PVE.updmgr.parseOrder(text);
                if (order === undefined) {
                    Ext.Msg.alert(
                        gettext('Error'),
                        Ext.String.format(
                            gettext('The update order has to be a number between 0 and {0}.'),
                            PVE.updmgr.MAX_ORDER,
                        ),
                    );
                    return;
                }

                let failures = [];
                let pending = sel.length;

                me.setLoading(true);

                let finish = function () {
                    pending--;
                    if (pending > 0) {
                        return;
                    }

                    me.setLoading(false);
                    // Whatever went wrong, the rows that DID change have to be
                    // shown as they are now - a grid still showing the old
                    // numbers after a partial write is the one state nobody can
                    // act on.
                    me.reload();

                    if (failures.length) {
                        // One dialog, not one per target: Ext.Msg is a singleton,
                        // so a dozen alerts leave only the last one standing.
                        Ext.Msg.alert(
                            gettext('Error'),
                            Ext.String.format(
                                gettext('{0} of {1} targets could not be changed:'),
                                failures.length,
                                sel.length,
                            ) + `<br><br>${failures.join('<br>')}`,
                        );
                    }
                };

                sel.forEach(function (rec) {
                    let url = PVE.updmgr.orderUrlFor(rec.data, me.nodename);
                    if (!url) {
                        failures.push(
                            `${PVE.updmgr.targetLabel(rec.data)}: ${gettext('unknown node')}`,
                        );
                        finish();
                        return;
                    }

                    Proxmox.Utils.API2Request({
                        url: url,
                        method: 'PUT',
                        params: { order: order },
                        failure: function (response) {
                            failures.push(
                                `${PVE.updmgr.targetLabel(rec.data)}: ${response.htmlStatus}`,
                            );
                            finish();
                        },
                        success: finish,
                    });
                });
            },
            me,
            false,
            shared,
        );
    },

    // One entry point to a target's logs, from the row as from the editor: the
    // window with all of them. There is no "show me exactly one log" anywhere any
    // more - picking which one is what the window is for.
    openLogs: function (rec) {
        let me = this;

        let url = PVE.updmgr.logsUrlFor(rec.data, me.nodename);
        if (!url) {
            return;
        }

        Ext.create('PVE.updmgr.LogWindow', {
            logsUrl: url,
            // From the row's own state, so Proxmox' task log of the last run is
            // reachable even for a target whose logs are switched off.
            lastUpid: rec.data.last_upid,
            targetLabel: PVE.updmgr.targetLabel(rec.data),
        }).show();
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
                scriptUrl: PVE.updmgr.scriptUrlFor(rec.data, node),
                runUrl: PVE.updmgr.runUrlFor(rec.data, node).url,
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

        PVE.updmgr.dispatch([rec.data], me.nodename, function (started) {
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
                lines.push(
                    gettext(
                        'Targets sharing an update-order position start at once; the next'
                            + ' position waits for all of them.',
                    ),
                );
            } else if (modes.serial && !modes.parallel) {
                lines.push(gettext('They run one after another, per server.'));
            } else {
                lines.push(gettext('Some servers start them by position, others one at a time.'));
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

        // Downtime nobody asked for at the moment of clicking, so it is said
        // here rather than discovered in the log: with this on, a running
        // container or VM is shut down for its snapshot and started again.
        let cold = selection.filter(
            (rec) => (rec.data.type === 'lxc' || rec.data.type === 'qemu')
                && me.snapshotShutdownFor(me.nodeOf(rec.data)),
        ).length;
        if (cold) {
            lines.push(
                Ext.String.format(
                    gettext(
                        '{0} of them are shut down for their snapshot and started again'
                            + ' afterwards - they are unavailable while that happens.',
                    ),
                    cold,
                ),
            );
        }

        Ext.Msg.confirm(PVE.updmgr.TAB_TITLE, lines.join('<br>'), function (btn) {
            if (btn !== 'yes') {
                return;
            }

            // One call, whichever way each node updates: the selection is
            // split by node inside dispatch, and how a node walks its own share
            // is that node's setting - answered on the node. It used to be split
            // here, into a parallel half and a serial half, because the two
            // halves were sent differently.
            PVE.updmgr.dispatch(
                selection.map((rec) => rec.data),
                me.nodename,
                function (started) {
                    me.reload();
                    if (started.length === 1) {
                        let win = Ext.create('Proxmox.window.TaskViewer', {
                            upid: started[0].upid,
                        });
                        win.on('destroy', function () {
                            me.reload();
                        });
                        win.show();
                    }
                    // With several tasks in flight there is no single one to
                    // show - the rows themselves are the progress display.
                },
            );
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
                    // The icons of the resource tree: a cube for a container, a
                    // desktop for a VM.
                    let icon = value === 'qemu' ? 'fa-desktop' : 'fa-cube';
                    let text = rec.data.template ? gettext('Template') : PVE.updmgr.guestLabel(rec.data);
                    return `<i class="fa fa-fw ${icon}"></i> ${text}`;
                },
            },
            // No renderer on these three, and that is not an oversight: an id is
            // a vmid or a node name, and a container's name is its hostname,
            // which PVE stores under `format => 'dns-name'` - letters, digits,
            // dashes and dots, read off its own JSONSchema. There is no markup
            // to escape. A template NAME is the opposite case - free text - and
            // is encoded everywhere it is shown.
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
                header: gettext('Order'),
                dataIndex: 'order',
                width: 80,
                renderer: function (value) {
                    return value
                        ? value
                        : `<span class="faded">${gettext('last')}</span>`;
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
            // Node and datacenter tabs (#41): see 47-security.js.
            ...(me.showSettings ? [PVE.updmgr.securityColumn()] : []),
            {
                xtype: 'actioncolumn',
                header: gettext('Actions'),
                width: 150,
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
                        tooltip: gettext('Logs'),
                        // Never disabled. It used to open Proxmox' task log of
                        // the last run and was grey without one; now it opens the
                        // window with ALL of this target's logs, and a target
                        // with kept logs and no current task still has something
                        // to show. The task log is a button inside it.
                        handler: function (view, rI, cI, item, e, rec) {
                            me.openLogs(rec);
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
                        iconCls: 'fa fa-sort-numeric-asc',
                        tooltip: gettext('Update order'),
                        isActionDisabled: function (view, rI, cI, item, rec) {
                            return rec.data.type === 'node' ? !me.canEditHost : !me.canEditGuest;
                        },
                        handler: function (view, rI, cI, item, e, rec) {
                            me.editOrder(rec);
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
                { name: 'order', type: 'int' },
                { name: 'parallel_manual', type: 'boolean' },
                { name: 'snapshot_shutdown', type: 'boolean' },
                ...PVE.updmgr.SECURITY_ROW_FIELDS,
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
            dockedItems: [PVE.updmgr.addonNotice()],
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
                {
                    // Beside Edit Selected because it is the same kind of act on
                    // the same thing: what the row's own Update order button does
                    // for one target, for every ticked one at once.
                    text: gettext('Order Selected'),
                    iconCls: 'fa fa-sort-numeric-asc',
                    disabled: !me.canEditGuest && !me.canEditHost,
                    handler: function () {
                        me.orderSelected();
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
                {
                    // Node tab only: the check runs per node. Sys.Console, as
                    // the endpoint asks - it can start updates (#43).
                    text: gettext('Check now'),
                    iconCls: 'fa fa-shield',
                    hidden: !me.showCheckNow,
                    disabled: !me.canRunHost,
                    handler: function () {
                        me.checkNow();
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
                PVE.updmgr.reportButton(),
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

