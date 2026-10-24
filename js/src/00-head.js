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

// Where problems with this addon go (#78). The tab sits among Proxmox' own and
// looks like one of them, so whoever hits a problem in it would write to
// Proxmox support - who did not write it and cannot fix it. The public
// repository, because that is the address anyone outside can reach.
PVE.updmgr.PROJECT_URL = 'https://github.com/LordNeksus06/pve-update-manager';

// The line at the top of every Update Manager tab and of its settings window,
// visible without a click (owner, 2026-10-24: "das müsste im ui sofort
// ersichtlich sein"). Docked rather than an item, so no panel's layout - a
// grid, a script editor, a tabbed window - has to make room for it; the low
// weight puts it above the panel's own toolbar.
PVE.updmgr.addonNotice = function () {
    let enc = Ext.String.htmlEncode;

    return {
        xtype: 'component',
        dock: 'top',
        weight: -100,
        itemId: 'updmgrAddonNotice',
        cls: 'pmx-hint',
        padding: '5 10',
        html:
            '<i class="fa fa-info-circle"></i> ' +
            enc(gettext('pve-update-manager is a community addon, not part of Proxmox VE. ' +
                'Please report problems with it on GitHub, not to Proxmox support.')) +
            ` <a href="${enc(PVE.updmgr.PROJECT_URL)}/issues" target="_blank" rel="noopener noreferrer">` +
            `${enc(gettext('Report a problem'))}</a>`,
    };
};

// The same address as a button at the end of every Update Manager toolbar
// (#78, owner 2026-10-24: "ja mach das so") - for whoever reads buttons, not
// banners. Through openUrl so a test can see where it goes without a browser.
PVE.updmgr.openUrl = function (url) {
    window.open(url, '_blank', 'noopener,noreferrer');
};

PVE.updmgr.reportButton = function () {
    return {
        text: gettext('Report a problem'),
        iconCls: 'fa fa-bug',
        itemId: 'updmgrReportButton',
        tooltip: gettext('Opens the issue tracker of pve-update-manager on GitHub - not Proxmox support'),
        handler: function () {
            PVE.updmgr.openUrl(`${PVE.updmgr.PROJECT_URL}/issues`);
        },
    };
};

// How long to wait before re-reading a grid that has a target mid-run. Short
// enough that a row stops spinning promptly, long enough not to hammer the API
// through a whole dist-upgrade.
PVE.updmgr.RUNNING_POLL_MS = 3000;

// The ceiling the API puts on a target's position in a run. Rejected
// here as well so a typo is a message in the prompt rather than a request that
// comes back red.
PVE.updmgr.MAX_ORDER = 99999;

// Without this the task log shows the raw worker type ("ctupdate 101"). The
// helper is the toolkit's own extension point for product specific task types.
if (typeof Proxmox !== 'undefined' && Proxmox.Utils && Proxmox.Utils.override_task_descriptions) {
    Proxmox.Utils.override_task_descriptions({
        ctupdate: ['CT', PVE.updmgr.TAB_TITLE],
        vmupdate: ['VM', PVE.updmgr.TAB_TITLE],
        updatemgr: ['Node', PVE.updmgr.TAB_TITLE],
        // The background security check (#40), started by the timer or by
        // "Check now".
        updmgrscan: ['Node', gettext('Security check')],
    });
}

