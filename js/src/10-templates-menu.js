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
            // A template name is free text somebody with Sys.Modify on / typed,
            // and a menu item's text is rendered as HTML. Reading the menu takes
            // no privilege at all, so an unescaped name here is markup planted
            // in every logged-in user's browser.
            text: Ext.String.htmlEncode(tpl.name),
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

