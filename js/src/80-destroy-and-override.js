// ── Throwing the stored commands away with the guest ────────────────────────
//
// A destroyed container or VM leaves everything it had in /etc/pve behind: its
// commands, the saved versions of them, its place in a run and its
// last-run record. That is not only clutter - Proxmox hands vmids out again, so
// the next guest created as 101 would inherit all of it without anybody
// having typed a line.
//
// So the destroy dialog gets one more tick, on by default, and it is a tick
// rather than an automatism because the files are also a legitimate thing to
// keep: rebuilding a guest under the same id and wanting its script back is
// a real workflow.
//
// The dialog itself is Proxmox' PVE.window.SafeDestroyGuest. Nothing of it is
// modified - the toolkit already offers both hooks this needs: `additionalItems`
// for the checkbox and `apiCallDone` for the moment the destroy was accepted.
PVE.updmgr.STORAGE_CHECKBOX = 'pveUpdMgrDropStored';

// Where to send the cleanup, given the URL the destroy dialog was built with.
//
// Read back from the dialog rather than passed in, because this override has no
// say in how the window was created - and matched strictly: the same window is
// used for other things than guests, and anything that is not exactly a
// container's or a VM's own URL must produce no request at all.
PVE.updmgr.destroyCleanupUrl = function (url) {
    let match = String(url || '').match(/^\/nodes\/([^/]+)\/(lxc|qemu)\/(\d+)$/);
    if (!match) {
        return undefined;
    }

    // purge: the last-run record, the saved versions and the order go too.
    // Keeping any of them would hand a guest's update history to whatever is
    // created with that vmid next.
    return `/nodes/${match[1]}/${match[2]}/${match[3]}/updatemgr/script?purge=1`;
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
            // Containers and VMs - Proxmox' dialog calls them 'CT' and 'VM'
            // (read off pvemanagerlib.js, PVE 9.2). Anything else it destroys
            // has no update script here, and a tick offering to delete
            // something that cannot exist is worse than none.
            let kind = (me.getItem() || {}).type;
            if (kind === 'CT' || kind === 'VM') {
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
                                'Removes this guest from the Update Manager: its commands,'
                                    + ' their saved versions, its place in a run and its'
                                    + ' last-run record. Without this they stay, and a new'
                                    + ' guest created with the same ID would inherit them.',
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
