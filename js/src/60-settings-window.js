// ── The settings window, of one node or of all of them ──────────────────────
//
// A container has no opinion about when it should be updated, and a
// cluster-wide schedule would have to pick a node to run it - so this belongs
// to the node that owns the targets and whose timer will fire.
Ext.define('PVE.updmgr.SettingsWindow', {
    extend: 'Ext.window.Window',

    // The size of PVE's own wizards (PVE.window.Wizard in pvemanagerlib.js),
    // whose tabbed layout this window copies (#45). The tabs are built in
    // 58-settings-tabs.js and 59-settings-security.js. Each tab scrolls its own
    // body, so a setting added later lengthens one tab, not the window.
    //
    // No maxHeight here. It was once set to '90%', and ExtJS wants a number of
    // pixels: the string made the whole size calculation collapse, leaving a
    // window about as tall as its own title bar, parked in the top left corner.
    // The cap is computed against the real viewport in initComponent instead.
    width: 760,
    height: 570,
    layout: { type: 'vbox', align: 'stretch' },
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
                // Blank for 0: the field's empty text says "no limit".
                me.down('#parallelManualMax').setValue(data.parallel_manual_max || null);
                me.down('#timeout').setValue(Math.round((data.timeout || 14400) / 60));
                me.down('#startStopped').setValue(!!data.start_stopped);
                me.down('#rebootVms').setValue(!!data.reboot_vms);
                me.down('#snapshotBefore').setValue(!!data.snapshot_before);
                me.down('#snapshotKeep').setValue(data.snapshot_keep || 3);
                me.down('#snapshotShutdown').setValue(!!data.snapshot_shutdown);
                me.down('#rollbackOnFailure').setValue(!!data.rollback_on_failure);
                // No `|| 1`: this one defaults to on, so a falsy-or-default would
                // show a tick where the server said untick and save it back that way.
                me.down('#rollbackRemoveNewer').setValue(
                    data.rollback_remove_newer === undefined ? true : !!data.rollback_remove_newer,
                );
                me.down('#notifyFailure').setValue(!!data.notify_failure);
                me.down('#scriptVersions').setValue(data.script_versions || 3);
                // Not `|| 3`: 0 is a real answer here - keep no run logs - and a
                // falsy-or-default would quietly turn it back on.
                me.down('#runLogs').setValue(
                    data.run_logs === undefined ? 3 : data.run_logs,
                );
                // Hidden, not disabled, and decided by the server: a switch
                // that is visible but can do nothing is a question the operator
                // has to answer and then find out did not matter. What the
                // server checks is every container's volumes, which is the only
                // honest answer - "does the node have ZFS" is not the question.
                // In global mode the answer is per node and there is no single
                // one, so the tab stays visible: the setting is written
                // everywhere and simply does nothing on the nodes that cannot.
                // The tab BUTTON, not the card - see settingsSnapshotTab.
                me.down('#snapshotTab').tab.setHidden(!me.global && !data.snapshot_capable);
                me.down('#scheduleEnabled').setValue(!!data.schedule_enabled);
                me.down('#scheduleTime').setValue(data.schedule_time);
                me.down('#scheduleParallel').setValue(!!data.schedule_parallel);
                me.down('#scheduleParallelMax').setValue(data.schedule_parallel_max || null);
                PVE.updmgr.loadSecurity(me, data);

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
            gettext('Saving applies to all {0} nodes.'),
            data.nodes,
        );
        if (!data.uniform) {
            text += ` ${gettext('Their current settings differ.')}`;
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
    // per-node mode and from a plain checkbox in global mode. The security
    // settings leave out their own per-node list the same way, from their table.
    commonParams: function () {
        let me = this;

        return Ext.apply({
            parallel_manual: me.down('#parallelManual').getValue() ? 1 : 0,
            parallel_manual_max: me.down('#parallelManualMax').getValue() || 0,
            timeout: me.down('#timeout').getValue() * 60,
            start_stopped: me.down('#startStopped').getValue() ? 1 : 0,
            reboot_vms: me.down('#rebootVms').getValue() ? 1 : 0,
            snapshot_before: me.down('#snapshotBefore').getValue() ? 1 : 0,
            snapshot_keep: me.down('#snapshotKeep').getValue(),
            snapshot_shutdown: me.down('#snapshotShutdown').getValue() ? 1 : 0,
            rollback_on_failure: me.down('#rollbackOnFailure').getValue() ? 1 : 0,
            rollback_remove_newer: me.down('#rollbackRemoveNewer').getValue() ? 1 : 0,
            notify_failure: me.down('#notifyFailure').getValue() ? 1 : 0,
            script_versions: me.down('#scriptVersions').getValue(),
            run_logs: me.down('#runLogs').getValue(),
            schedule_enabled: me.down('#scheduleEnabled').getValue() ? 1 : 0,
            schedule_time: me.down('#scheduleTime').getValue(),
            schedule_parallel: me.down('#scheduleParallel').getValue() ? 1 : 0,
            schedule_parallel_max: me.down('#scheduleParallelMax').getValue() || 0,
        }, PVE.updmgr.securityParams(me));
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
                    'Overwrite the settings of all {0} nodes? Each node keeps its scheduled'
                        + ' containers.',
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

    // A parallel switch and, right beside it, how many targets it may start at
    // once. One helper for both rows, because a manual run and a scheduled one
    // must offer the same thing in the same place. The number is greyed out
    // while its switch is off: it means nothing for a serial run.
    parallelRow: function (switchId, maxId) {
        let me = this;

        return {
            xtype: 'fieldcontainer',
            layout: 'hbox',
            margin: '0 0 8 0',
            items: [
                {
                    xtype: 'checkbox',
                    itemId: switchId,
                    boxLabel: gettext('Update in parallel'),
                    width: 200,
                    listeners: {
                        change: function (box, value) {
                            me.down(`#${maxId}`).setDisabled(!value);
                        },
                    },
                },
                {
                    xtype: 'proxmoxintegerfield',
                    itemId: maxId,
                    fieldLabel: gettext('Max. at once'),
                    labelWidth: 90,
                    width: 200,
                    minValue: 1,
                    maxValue: 100,
                    allowBlank: true,
                    emptyText: gettext('no limit'),
                    disabled: true,
                },
            ],
        };
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
        // On a small screen it would otherwise run off the bottom.
        let viewport = Ext.Element.getViewportHeight();
        if (viewport > 200) {
            me.height = Math.max(420, Math.min(me.height, viewport - 60));
        }

        me.preselected = {};
        me.nodeCount = 0;

        me.targetGrid = me.global ? undefined : Ext.create('Ext.grid.GridPanel', {
            // flex, inside a Schedule tab that does not scroll - see
            // settingsScheduleTab. The minimum keeps a few rows visible in a
            // window shrunk to fit a small screen.
            flex: 1,
            minHeight: 120,
            border: true,
            title: gettext('Scheduled targets'),
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
            dockedItems: [PVE.updmgr.addonNotice()],
            title: me.global
                ? gettext('Update Manager Settings: All Nodes')
                : Ext.String.format(gettext('Update Manager Settings: {0}'), me.nodename),
            items: [
                // Before the tabs, not only in the confirmation: whoever opens
                // this to look at a value should know what Save does.
                me.global
                    ? {
                          xtype: 'displayfield',
                          userCls: 'pmx-hint',
                          padding: '5 10 0 10',
                          value: gettext('Saving overwrites these settings on every node.'),
                      }
                    : { xtype: 'container', height: 0 },
                {
                    // As in PVE.window.Wizard: a tab panel with no padding of
                    // its own and 10 pixels around each tab's contents. Not its
                    // step navigation - every tab here can be saved from.
                    xtype: 'tabpanel',
                    itemId: 'tabs',
                    flex: 1,
                    bodyPadding: 0,
                    defaults: { padding: 10 },
                    // ExtJS renders a tab only when it is first opened, by
                    // default (Ext.tab.Panel.deferredRender). load() fills and
                    // ticks the target grid while General is showing, so every
                    // tab is rendered up front.
                    deferredRender: false,
                    items: PVE.updmgr.settingsTabs(me),
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

