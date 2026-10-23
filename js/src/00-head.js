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

