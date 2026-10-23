// ── The tabs of the settings window (#45) ───────────────────────────────────
//
// One tab per subject, like PVE's own "Create CT" dialog, which had 33 settings
// to show once the security scan came (#41) - too many for one scrolling
// column. The order and contents of the four tabs are the owner's (#45):
//
//   General   timeout, start_stopped, reboot_vms, notify_failure, the two
//             retention counts - and manual runs' parallel pair as a section,
//             not a tab of its own ("parallel raus das ist unterpunkt")
//   Snapshot  the five snapshot and rollback switches
//   Schedule  the schedule, its parallel pair and its targets
//   Security  the sixteen security_* settings, see 59-settings-security.js
//
// Every builder takes the window as `me`: the parallel rows and the target
// grid are the window's.

PVE.updmgr.settingsGeneralTab = function (me) {
    return {
        title: gettext('General'),
        itemId: 'generalTab',
        scrollable: 'y',
        items: [
            {
                xtype: 'fieldset',
                title: gettext('Updates'),
                items: [
                    {
                        // Minutes, because the useful values are hours. The API
                        // speaks seconds.
                        xtype: 'proxmoxintegerfield',
                        itemId: 'timeout',
                        fieldLabel: gettext('Timeout (minutes)'),
                        labelWidth: 160,
                        minValue: 1,
                        maxValue: 1440,
                        allowBlank: false,
                        emptyText: '240',
                    },
                    {
                        xtype: 'checkbox',
                        itemId: 'startStopped',
                        boxLabel: gettext('Start stopped guests for the update, then stop them'),
                    },
                    {
                        // VMs only: a container shares the node's kernel, so a
                        // reboot gives it nothing new.
                        xtype: 'checkbox',
                        itemId: 'rebootVms',
                        boxLabel: gettext('Reboot VMs when the update requires it'),
                    },
                    {
                        // No address field: delivery is configured once, under
                        // Datacenter -> Notifications.
                        xtype: 'checkbox',
                        itemId: 'notifyFailure',
                        boxLabel: gettext('Send a notification when a target fails'),
                    },
                ],
            },
            {
                xtype: 'fieldset',
                title: gettext('Parallel (manual runs)'),
                items: [
                    // Its own switch, not shared with the schedule: a click is
                    // somebody watching, the timer is not.
                    me.parallelRow('parallelManual', 'parallelManualMax'),
                ],
            },
            {
                xtype: 'fieldset',
                title: gettext('Retention'),
                items: [
                    {
                        xtype: 'proxmoxintegerfield',
                        itemId: 'scriptVersions',
                        fieldLabel: gettext('Script versions'),
                        labelWidth: 160,
                        minValue: 1,
                        maxValue: 50,
                        allowBlank: false,
                        emptyText: '3',
                    },
                    {
                        // Kept on the node rather than in /etc/pve, where a file
                        // may not exceed 1 MiB.
                        xtype: 'proxmoxintegerfield',
                        itemId: 'runLogs',
                        fieldLabel: gettext('Run logs'),
                        labelWidth: 160,
                        minValue: 0,
                        maxValue: 50,
                        allowBlank: false,
                        emptyText: '3',
                    },
                ],
            },
        ],
    };
};

PVE.updmgr.settingsSnapshotTab = function () {
    return {
        title: gettext('Snapshot'),
        itemId: 'snapshotTab',
        scrollable: 'y',
        // Shown only where a container on this node can be snapshotted - see
        // load(). On the tab BUTTON: ExtJS hides a card's button only when the
        // card is hidden at the moment it is added (Ext.tab.Panel.onAdd), so
        // hiding the card later would leave a button that opens an empty page.
        tabConfig: { hidden: true },
        items: [
            {
                xtype: 'checkbox',
                itemId: 'snapshotBefore',
                boxLabel: gettext('Take a snapshot before each update'),
            },
            {
                xtype: 'proxmoxintegerfield',
                itemId: 'snapshotKeep',
                fieldLabel: gettext('Snapshots to keep'),
                labelWidth: 160,
                minValue: 1,
                maxValue: 100,
                allowBlank: false,
                emptyText: '3',
            },
            {
                xtype: 'checkbox',
                itemId: 'rollbackOnFailure',
                boxLabel: gettext('Roll back when the update fails'),
            },
            {
                // Kept as text, not a tooltip: this is the one switch here that
                // throws data away.
                xtype: 'displayfield',
                userCls: 'faded',
                value: gettext('Discards every change since the snapshot, not only the update.'),
            },
            {
                xtype: 'checkbox',
                itemId: 'rollbackRemoveNewer',
                boxLabel: gettext('Remove newer snapshots that block the rollback'),
            },
            {
                // Neither a container snapshot nor the disk-only VM one holds
                // memory, so a running guest is caught as if the power had been
                // pulled.
                xtype: 'checkbox',
                itemId: 'snapshotShutdown',
                boxLabel: gettext('Shut down the guest for a consistent snapshot'),
            },
        ],
    };
};

PVE.updmgr.settingsScheduleTab = function (me) {
    return {
        title: gettext('Schedule'),
        itemId: 'scheduleTab',
        // Not scrollable, and a vbox: the target grid takes what the fields
        // above it leave. Inside a scrolling body there is no bounded height for
        // a flex to divide, and the grid collapsed to nothing - which is why it
        // had a fixed height while the window was one long column.
        layout: { type: 'vbox', align: 'stretch' },
        items: [
            {
                xtype: 'checkbox',
                itemId: 'scheduleEnabled',
                boxLabel: gettext('Enabled'),
            },
            {
                // The field and syntax of a backup job: 03:00, mon..fri 02:30,
                // */8:00.
                xtype: 'pveCalendarEvent',
                itemId: 'scheduleTime',
                name: 'schedule_time',
                fieldLabel: gettext('Schedule'),
                labelWidth: 160,
                margin: '0 0 8 0',
                value: '03:00',
            },
            me.parallelRow('scheduleParallel', 'scheduleParallelMax'),
            // A vmid lives on one node, so global mode offers only the host
            // tick and says where the rest is.
            me.global
                ? {
                      xtype: 'checkbox',
                      itemId: 'scheduleHost',
                      boxLabel: gettext('Include the host'),
                  }
                : me.targetGrid,
            me.global
                ? {
                      xtype: 'displayfield',
                      userCls: 'faded',
                      value: gettext('Containers are selected per node.'),
                  }
                : { xtype: 'container', height: 0 },
        ],
    };
};

PVE.updmgr.settingsTabs = function (me) {
    return [
        PVE.updmgr.settingsGeneralTab(me),
        PVE.updmgr.settingsSnapshotTab(me),
        PVE.updmgr.settingsScheduleTab(me),
        PVE.updmgr.securityTab(me),
    ];
};
