// ── Container and VM tab ────────────────────────────────────────────────────
//
// One panel for both kinds: `guestType` is 'lxc' or 'qemu' and picks the API
// path and the label, and nothing else about the tab differs.
Ext.define('PVE.updmgr.LxcPanel', {
    extend: 'PVE.updmgr.ScriptPanel',
    alias: 'widget.pveUpdMgrLxc',

    guestType: 'lxc',

    initComponent: function () {
        let me = this;

        if (!me.nodename) {
            throw 'no node name specified';
        }
        if (!me.vmid) {
            throw 'no vmid specified';
        }

        let data = { type: me.guestType };
        let path = PVE.updmgr.guestPath(data);
        let label = PVE.updmgr.guestLabel(data);

        Ext.apply(me, {
            scriptUrl: `/nodes/${me.nodename}/${path}/${me.vmid}/updatemgr/script`,
            runUrl: `/nodes/${me.nodename}/${path}/${me.vmid}/updatemgr/run`,
            targetLabel: me.guestName ? `${label} ${me.vmid} (${me.guestName})` : `${label} ${me.vmid}`,
        });

        me.callParent();
    },
});

// ── Popup editor used by the grids ──────────────────────────────────────────
Ext.define('PVE.updmgr.ScriptWindow', {
    extend: 'Ext.window.Window',

    // 800 was chosen when the toolbar had four buttons. It has six now, plus the
    // last run and its log button, and at 800 the right-hand end was cut off.
    width: 940,
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

