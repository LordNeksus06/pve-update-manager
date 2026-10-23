Ext.define('PVE.updmgr.LogWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveUpdMgrLogWindow',

    // `/nodes/<node>/(lxc/<vmid>/)?updatemgr/logs`
    logsUrl: undefined,
    // The last run's task, from the target's state file. Kept even when no logs
    // are: switching run_logs off must not take the way to Proxmox' own log with
    // it, which is what the old Last Log button did.
    lastUpid: undefined,
    targetLabel: '',

    width: 900,
    height: 640,
    layout: 'border',
    modal: true,

    // Loads the list, then selects the newest - so opening the window already
    // shows the run somebody came here for. A target that has never run gets an
    // empty grid and a text pane that says so, rather than a blank box.
    reloadLogs: function () {
        let me = this;

        Proxmox.Utils.API2Request({
            url: me.logsUrl,
            method: 'GET',
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function (response) {
                let rows = response.result.data || [];
                me.grid.getStore().loadData(rows);

                if (!rows.length) {
                    me.setLogText(gettext('No run has been logged for this target yet.'));
                    return;
                }

                me.grid.getSelectionModel().select(0);
            },
        });
    },

    setLogText: function (text) {
        let me = this;

        me.textPane.setValue(text);
    },

    showLog: function (rec) {
        let me = this;

        me.taskButton.setDisabled(!rec.data.upid);
        me.selectedUpid = rec.data.upid;

        Proxmox.Utils.API2Request({
            url: `${me.logsUrl}/${encodeURIComponent(rec.data.log)}`,
            method: 'GET',
            waitMsgTarget: me,
            failure: function (response) {
                me.setLogText(response.htmlStatus);
            },
            success: function (response) {
                me.setLogText(response.result.data.log);
            },
        });
    },

    initComponent: function () {
        let me = this;

        if (!me.logsUrl) {
            throw 'no logsUrl specified';
        }

        me.title = Ext.String.format(gettext('Logs of {0}'), me.targetLabel || '');

        me.textPane = Ext.create('Ext.form.field.TextArea', {
            readOnly: true,
            hideLabel: true,
            fieldStyle: {
                'font-family': 'monospace',
                'font-size': '12px',
                'white-space': 'pre',
                'overflow-wrap': 'normal',
                'overflow-x': 'auto',
            },
        });

        // Opens Proxmox' own task log - of the selected run where that run
        // recorded one, and of the last run otherwise. That second case is what
        // keeps this reachable with run_logs switched off, where there are no
        // rows to select at all.
        me.taskButton = Ext.create('Ext.Button', {
            text: gettext('Proxmox Task Log'),
            iconCls: 'fa fa-list-alt',
            disabled: !me.lastUpid,
            handler: function () {
                PVE.updmgr.showLog(me.selectedUpid || me.lastUpid);
            },
        });

        me.grid = Ext.create('Ext.grid.Panel', {
            region: 'north',
            height: 200,
            split: true,
            border: false,
            store: Ext.create('Ext.data.Store', {
                fields: [
                    'log',
                    'state',
                    'note',
                    'upid',
                    { name: 'time', type: 'int' },
                    { name: 'size', type: 'int' },
                ],
                data: [],
            }),
            columns: [
                {
                    header: gettext('When'),
                    dataIndex: 'time',
                    width: 160,
                    renderer: (v) => Proxmox.Utils.render_timestamp(v),
                },
                {
                    header: gettext('Result'),
                    dataIndex: 'state',
                    flex: 1,
                    renderer: (v, meta, rec) => PVE.updmgr.renderLogState(v, rec.data.note),
                },
                {
                    header: gettext('Size'),
                    dataIndex: 'size',
                    width: 100,
                    renderer: (v) => PVE.updmgr.formatLogSize(v),
                },
            ],
            listeners: {
                selectionchange: function (sm, selected) {
                    if (selected.length) {
                        me.showLog(selected[0]);
                    }
                },
            },
        });

        Ext.apply(me, {
            tbar: [
                me.taskButton,
                '->',
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function () {
                        me.reloadLogs();
                    },
                },
            ],
            items: [
                me.grid,
                {
                    region: 'center',
                    xtype: 'panel',
                    layout: 'fit',
                    border: false,
                    items: [me.textPane],
                },
            ],
        });

        me.callParent();

        me.reloadLogs();
    },
});

PVE.updmgr.showLog = function (upid) {
    if (!upid) {
        Ext.Msg.alert(gettext('Error'), gettext('This target has not been run yet.'));
        return;
    }
    Ext.create('Proxmox.window.TaskViewer', { upid: upid }).show();
};

// The endpoint that runs exactly one GUEST, and the task type it produces:
// `ctupdate` or `vmupdate` with the vmid as its id, so the task list says "CT 102
// - Update Manager" instead of labelling it as a job on the node.
//
// Guests only. The host has no endpoint of its own - updating it is the node
// endpoint with host=1 - and a branch here for a case nothing reaches would only
// suggest there was one. dispatch() is the single caller and it calls this for
// one guest on its own; everything else goes to the node.
PVE.updmgr.runUrlFor = function (data, defaultNode) {
    let node = data.node || defaultNode;
    if (!node || data.type === 'node') {
        return undefined;
    }

    return {
        url: `/nodes/${node}/${PVE.updmgr.guestPath(data)}/${data.vmid}/updatemgr/run`,
        params: {},
        node: node,
        label: PVE.updmgr.targetLabel(data),
    };
};

// Starts the update of a set of targets.
//
// One request per node, whichever way that node updates. The request becomes ONE
// Proxmox task that works through that node's share of the selection: one target
// at a time, or a whole update-order position at a time where the node is set to
// update in parallel. Which of the two happens is the node's own setting and is
// decided on the node, not here.
//
// It used to be one request per TARGET for a parallel run, and that is what this
// replaces. Two things were wrong with it. The update order did nothing, because
// no task ever saw more than one target to put in an order - and it cannot be
// fixed from here either: waiting for one position to finish before starting the
// next would mean a browser tab holding the run together, and a tab that is
// closed mid-run would take the rest of the order with it. And nothing knew when
// the run as a whole was finished, which is what a notification about it needs.
//
// Several NODES still run at the same time; it is the targets within one node
// that its task puts in order.
//
// `callback` gets the list of started tasks once every request has answered.
PVE.updmgr.dispatch = function (targets, defaultNode, callback) {
    let requests = [];
    let byNode = {};

    targets.forEach(function (data) {
        let node = data.node || defaultNode;
        if (!node) {
            return;
        }
        if (!byNode[node]) {
            byNode[node] = { host: 0, vmids: [], single: undefined };
        }
        if (data.type === 'node') {
            byNode[node].host = 1;
        } else {
            byNode[node].vmids.push(data.vmid);
            // Kept for the one-guest case below, which needs the record and
            // not just the vmid. Containers and VMs share the vmids list: a vmid
            // is unique across both, and the node tells them apart itself.
            byNode[node].single = data;
        }
    });

    Object.keys(byNode).forEach(function (node) {
        let group = byNode[node];

        if (!group.host && group.vmids.length === 1) {
            // One guest on its own goes to its own endpoint. Same work
            // either way, but the task is then typed `ctupdate`/`vmupdate` with the vmid as
            // its id, so the task list says "CT 102 - Update Manager" instead of
            // labelling it as a job on the node - indistinguishable from
            // updating the host itself.
            let req = PVE.updmgr.runUrlFor(group.single, defaultNode);
            if (req) {
                requests.push(req);
            }
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

    if (!requests.length) {
        callback([]);
        return;
    }

    let started = [];
    // Collected, not alerted one by one: Ext.Msg is a singleton MessageBox, so a
    // dozen simultaneous alert() calls reconfigure and re-show the SAME window
    // and the user is left with whichever arrived last. A datacenter selection
    // spans as many requests as it spans nodes, so that is a real case.
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

