// ── The text box, its toolbar, and the load/save/run plumbing ───────────────
//
// Used three times: as the container tab, inside the popup editor of the grids,
// and for a host's own script. Everything it needs is two URLs.
Ext.define('PVE.updmgr.ScriptPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveUpdMgrScriptPanel',

    layout: 'fit',
    border: false,

    // /nodes/x/lxc/101/updatemgr/script  or  /nodes/x/updatemgr/script
    scriptUrl: undefined,
    // /nodes/x/updatemgr/run
    runUrl: undefined,
    // extra POST params for runUrl, e.g. { host: 1 } or { vmids: '101' }
    runParams: undefined,
    // what the run is about, for messages: 'CT 101 (nextcloud)'
    targetLabel: '',

    canRun: true,
    canEdit: true,

    lastUpid: undefined,

    loadScript: function () {
        let me = this;

        Proxmox.Utils.API2Request({
            url: me.scriptUrl,
            method: 'GET',
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function (response) {
                let data = response.result.data;
                me.editor.setValue(data.script);
                me.stored = !!data.stored;
                me.lastUpid = data.last_upid;
                me.setLoaded(true);
                me.updateStatus(data);
                me.setVersionHint(undefined);
            },
        });
    },

    // Puts an older version into the box and says so. It is NOT restored by
    // this: restoring is a normal save of that text, so the box can still be
    // edited first and Revert still throws it away - which is also what keeps
    // this readable by somebody who may look but not save.
    loadVersion: function (version, time) {
        let me = this;

        Proxmox.Utils.API2Request({
            // Encoded: the identifier is a string in a path now, and while the
            // two shapes it can have carry nothing that needs escaping, a path
            // built by concatenation is a path that stops being safe the day the
            // shape changes.
            url: `${me.scriptUrl}/versions/${encodeURIComponent(version)}`,
            method: 'GET',
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function (response) {
                me.editor.setValue(response.result.data.script);
                me.setVersionHint(time);
            },
        });
    },

    // Takes the SECOND, not the identifier: the identifier is a local timestamp
    // string now, and render_timestamp() would read it as an epoch and date the
    // line to 1970.
    setVersionHint: function (time) {
        let me = this;

        if (!me.versionText) {
            return;
        }

        me.versionText.setText(
            time
                ? Ext.String.format(
                      gettext('Showing the version of {0} - Save to restore it'),
                      Proxmox.Utils.render_timestamp(time),
                  )
                : '',
        );
    },

    // Save and Update stay disabled until the box holds what the server sent.
    // The load is asynchronous, so an editor opened and saved quickly would
    // otherwise store the empty box it started out as.
    setLoaded: function (loaded) {
        let me = this;

        me.loaded = loaded;
        if (me.saveButton) {
            me.saveButton.setDisabled(!loaded);
        }
        if (me.runButton) {
            me.runButton.setDisabled(!loaded);
        }
        me.updateRemoveButton();
    },

    // Only offer to remove something that is actually stored - on a target that
    // has never been saved the box holds a template, and there is nothing to
    // delete.
    updateRemoveButton: function () {
        let me = this;

        if (me.removeButton) {
            me.removeButton.setDisabled(!me.loaded || !me.stored);
        }
    },

    // Removes the stored commands, so the target falls back to showing the
    // template and is skipped by a run instead of doing something half-defined.
    // The recorded last run is deliberately kept - when a target was last
    // updated stays true whether or not commands are stored for it now.
    removeScript: function () {
        let me = this;

        Ext.Msg.confirm(
            gettext('Confirm'),
            Ext.String.format(
                gettext('Remove the stored update commands of {0}? The recorded last run is kept.'),
                me.targetLabel || gettext('this target'),
            ),
            function (btn) {
                if (btn !== 'yes') {
                    return;
                }

                Proxmox.Utils.API2Request({
                    url: me.scriptUrl,
                    method: 'DELETE',
                    waitMsgTarget: me,
                    failure: function (response) {
                        Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                    },
                    success: function () {
                        me.stored = false;
                        // Re-read rather than just blanking the box: the server
                        // answers with the template, which is what an empty
                        // target is supposed to show - and with the last run,
                        // which survives the delete.
                        me.loadScript();
                    },
                });
            },
        );
    },

    saveScript: function (callback) {
        let me = this;
        let script = me.editor.getValue();

        if (!script || !script.trim()) {
            Ext.Msg.alert(
                gettext('Error'),
                gettext('There are no commands to save. Empty update commands would be stored as "nothing to do".'),
            );
            return;
        }

        Proxmox.Utils.API2Request({
            url: me.scriptUrl,
            method: 'PUT',
            params: { script: script },
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function () {
                me.stored = true;
                me.updateRemoveButton();
                // What is in the box is what is stored now, so it is no longer
                // "a version of 10:04" - and the save has just become the
                // newest entry in the history itself.
                me.setVersionHint(undefined);
                if (callback) {
                    callback();
                }
            },
        });
    },

    // Saved before every run on purpose. The button says "Update", and running
    // anything other than the text currently on screen would be a trap.
    runScript: function () {
        let me = this;

        let script = me.editor.getValue();
        if (!script || !script.trim()) {
            Ext.Msg.alert(gettext('Error'), gettext('There are no commands to run.'));
            return;
        }

        me.saveScript(function () {
            Proxmox.Utils.API2Request({
                url: me.runUrl,
                method: 'POST',
                params: Ext.apply({}, me.runParams || {}),
                waitMsgTarget: me,
                failure: function (response) {
                    Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                },
                success: function (response) {
                    let upid = response.result.data;
                    me.lastUpid = upid;
                    let win = Ext.create('Proxmox.window.TaskViewer', { upid: upid });
                    win.on('destroy', function () {
                        me.loadScript();
                    });
                    win.show();
                },
            });
        });
    },

    // Where this target's kept run logs live. Derived from the script endpoint
    // rather than passed in: they are the same target's endpoints under the same
    // path, and a second URL to keep in step is a second URL to get wrong.
    logsUrl: function () {
        let me = this;

        return me.scriptUrl.replace(/\/script$/, '/logs');
    },

    openLogs: function () {
        let me = this;

        Ext.create('PVE.updmgr.LogWindow', {
            logsUrl: me.logsUrl(),
            // From the state file, so the task log stays reachable even with
            // run_logs switched off - which is exactly the case where the window
            // has no rows to select.
            lastUpid: me.lastUpid,
            targetLabel: me.targetLabel || '',
        }).show();
    },

    updateStatus: function (data) {
        let me = this;

        if (me.statusText) {
            me.statusText.setText(
                `${gettext('Last run')}: ${PVE.updmgr.renderLastRun(data || {})}`,
            );
        }
    },

    initComponent: function () {
        let me = this;

        if (!me.scriptUrl) {
            throw 'no scriptUrl specified';
        }

        me.editor = Ext.create('Ext.form.field.TextArea', {
            hideLabel: true,
            spellcheck: false,
            readOnly: !me.canEdit,
            // A hint, not content: it disappears the moment anything is typed and
            // is never saved. Pre-filling the box with a template made an empty
            // target look like a configured one.
            emptyText: gettext(
                'No update commands stored. Write them here, or pick a starting point from Templates.',
            ),
            fieldStyle: {
                'font-family': 'monospace',
                'font-size': '12px',
                'white-space': 'pre',
                'overflow-wrap': 'normal',
                'overflow-x': 'auto',
            },
        });

        me.statusText = Ext.create('Ext.toolbar.TextItem', { text: '' });
        me.versionText = Ext.create('Ext.toolbar.TextItem', { text: '' });



        let tbar = [];

        if (me.runUrl && me.canRun) {
            me.runButton = Ext.create('Ext.Button', {
                text: gettext('Update'),
                iconCls: 'fa fa-play',
                disabled: true,
                handler: function () {
                    me.runScript();
                },
            });
            tbar.push(me.runButton);
        }

        if (me.canEdit) {
            me.saveButton = Ext.create('Ext.Button', {
                text: gettext('Save'),
                iconCls: 'fa fa-floppy-o',
                disabled: true,
                handler: function () {
                    me.saveScript();
                },
            });
            tbar.push(me.saveButton);
        }

        tbar.push({
            text: gettext('Revert'),
            iconCls: 'fa fa-undo',
            handler: function () {
                me.loadScript();
            },
        });

        if (me.canEdit) {
            me.removeButton = Ext.create('Ext.Button', {
                text: gettext('Remove'),
                iconCls: 'fa fa-trash-o',
                disabled: true,
                handler: function () {
                    me.removeScript();
                },
            });
            tbar.push(me.removeButton);
        }

        if (me.canEdit) {
            tbar.push(
                PVE.updmgr.templateMenuButton(function (script) {
                    me.editor.setValue(script);
                }),
            );

            // Rebuilt on every open: a save made in this very window has to
            // show up the next time the menu is dropped down.
            tbar.push({
                text: gettext('History'),
                iconCls: 'fa fa-history',
                menu: {
                    items: [{ text: gettext('Loading...'), disabled: true }],
                    listeners: {
                        beforeshow: function (menu) {
                            Proxmox.Utils.API2Request({
                                url: `${me.scriptUrl}/versions`,
                                method: 'GET',
                                failure: function (response) {
                                    if (menu.destroyed) {
                                        return;
                                    }
                                    menu.removeAll();
                                    menu.add({
                                        text: response.htmlStatus,
                                        disabled: true,
                                    });
                                },
                                success: function (response) {
                                    if (menu.destroyed) {
                                        return;
                                    }
                                    menu.removeAll();
                                    menu.add(
                                        PVE.updmgr.versionMenuItems(
                                            response.result.data,
                                            function (version, time) {
                                                me.loadVersion(version, time);
                                            },
                                        ),
                                    );
                                },
                            });
                        },
                    },
                },
            });
        }

        // ONE button, and a plain one. It used to be two - "Last Log" for
        // Proxmox' task log of the last run, and a "Run Logs" dropdown for the
        // kept copies - which were two buttons for one question. The window
        // behind this lists the kept runs, shows what each printed, and carries
        // the task log as a button of its own; the newest row IS the last run.
        //
        // Always enabled, unlike Last Log: a target with kept logs and no current
        // task still has something to show, and the button inside the window is
        // the one that goes grey when there is no task.
        tbar.push(
            PVE.updmgr.logsButton(function () {
                me.openLogs();
            }),
        );

        Ext.apply(me, {
            // Buttons on top, STATE at the bottom - and that split is what fixed
            // the row rather than any single button.
            //
            // "Last run: failed 2026-08-21 14:07:03" and "Showing the version of
            // ..." are the widest things this window puts anywhere, and they used
            // to sit on the right of the same row as the buttons. Six buttons and
            // those two texts did not fit the window, so ExtJS folded the end into
            // its overflow menu and the buttons somebody actually wanted were
            // behind a ☰. State is not a button, it belongs under the box it
            // describes, and moving it there gives the whole width back.
            //
            // enableOverflow stays as the net for a narrow screen: with it, what
            // does not fit is reachable; without it, it is simply cut off. That
            // is why it was added and it is not a reason to keep crowding the row.
            tbar: {
                xtype: 'toolbar',
                enableOverflow: true,
                items: tbar,
            },
            bbar: {
                xtype: 'toolbar',
                items: [me.statusText, '->', me.versionText],
            },
            items: [me.editor],
        });

        me.callParent();

        me.loadScript();
    },
});

