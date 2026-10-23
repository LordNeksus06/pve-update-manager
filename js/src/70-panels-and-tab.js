// ── Node tab: this node and its containers ──────────────────────────────────
Ext.define('PVE.updmgr.NodePanel', {
    extend: 'PVE.updmgr.TargetGrid',
    alias: 'widget.pveUpdMgrNode',

    // The container tab has a single target and no say over the node's timer, so
    // it gets no Settings button. The datacenter tab gets one too - the same
    // window in its global mode, see PVE.updmgr.DcPanel.
    showSettings: true,
    showCheckNow: true,

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

    checkNow: function () {
        PVE.updmgr.checkNow(this, this.nodename);
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
// PVE.qemu.Config, PVE.node.Config and PVE.dc.Config have finished filling
// me.items by the time they call up into it, and it has not yet been consumed.
// $className tells them apart, so one override serves all four without touching
// any of them.
PVE.updmgr.injectTab = function (panel) {
    let cls = panel.$className;

    let guestType = { 'PVE.lxc.Config': 'lxc', 'PVE.qemu.Config': 'qemu' }[cls];

    if (!guestType && cls !== 'PVE.node.Config' && cls !== 'PVE.dc.Config') {
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

    if (guestType) {
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
            guestType: guestType,
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

