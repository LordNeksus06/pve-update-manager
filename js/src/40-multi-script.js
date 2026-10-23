// ── Editing several targets' commands at once ───────────────────────────────
//
// Deliberately NOT the single-target editor with a wider selection bolted on.
// That one is about one target: it runs it, removes it, shows its last log. This
// one writes the same text to every selected target and does nothing else, which
// is the whole reason it can be safe about it - it reads what is there first and
// says whether it is about to replace anything.
Ext.define('PVE.updmgr.MultiScriptWindow', {
    extend: 'Ext.window.Window',

    width: 820,
    height: 560,
    layout: 'fit',
    modal: true,
    resizable: true,

    // array of grid row data
    targets: undefined,
    defaultNode: undefined,

    // Reading every target before offering a box to type in: without this the
    // dialog cannot tell "these all already say the same thing" from "these say
    // four different things", and those need opposite warnings.
    load: function () {
        let me = this;

        let scripts = [];
        let failures = [];
        let pending = me.targets.length;

        // Masked once around the whole batch, not per request: N requests each
        // clearing the mask on their own means the first one to answer unmasks
        // while the rest are still in flight.
        me.setLoading(true);

        let finish = function () {
            pending--;
            if (pending > 0) {
                return;
            }

            me.setLoading(false);

            let stored = scripts.filter((s) => s.stored);
            let unique = [];
            stored.forEach(function (s) {
                if (!unique.includes(s.script)) {
                    unique.push(s.script);
                }
            });

            me.replacing = stored.length;

            if (unique.length === 1 && stored.length === me.targets.length) {
                // Everything already agrees, so the box is an edit of a shared
                // script rather than a fresh one - and saving replaces nothing
                // the user has not already seen.
                me.editor.setValue(unique[0]);
                me.identical = true;
                // Kept so save() can ask whether the box still holds it. Without
                // that, editing a shared script and saving skipped the
                // confirmation - "they already hold exactly this text" was true
                // when the window opened and not when Save was pressed.
                me.sharedScript = unique[0];
                me.setStatus(
                    Ext.String.format(
                        gettext('All {0} selected targets currently share these commands.'),
                        me.targets.length,
                    ),
                    'good',
                );
            } else if (unique.length === 0) {
                me.setStatus(
                    Ext.String.format(
                        gettext('None of the {0} selected targets has commands stored yet.'),
                        me.targets.length,
                    ),
                    'faded',
                );
            } else {
                // Left EMPTY on purpose. Picking one of several differing
                // scripts to prefill would make one target's commands look like
                // the selection's, and Save would then quietly spread it.
                me.setStatus(
                    Ext.String.format(
                        gettext(
                            '{0} of {1} selected targets already have commands, and they are not'
                                + ' all the same. Saving replaces every one of them.',
                        ),
                        stored.length,
                        me.targets.length,
                    ),
                    'warning',
                );
            }

            if (failures.length) {
                Ext.Msg.alert(
                    gettext('Error'),
                    gettext('Could not read the current commands of:')
                        + `<br><br>${failures.join('<br>')}`,
                );
            }

            me.saveButton.setDisabled(false);
        };

        me.targets.forEach(function (data) {
            let url = PVE.updmgr.scriptUrlFor(data, me.defaultNode);
            if (!url) {
                failures.push(`${PVE.updmgr.targetLabel(data)}: ${gettext('unknown node')}`);
                finish();
                return;
            }

            Proxmox.Utils.API2Request({
                url: url,
                method: 'GET',
                failure: function (response) {
                    failures.push(`${PVE.updmgr.targetLabel(data)}: ${response.htmlStatus}`);
                    finish();
                },
                success: function (response) {
                    let d = response.result.data;
                    scripts.push({ stored: !!d.stored, script: d.script || '' });
                    finish();
                },
            });
        });
    },

    setStatus: function (text, cls) {
        let me = this;
        me.down('#status').update(`<span class="${cls}">${Ext.String.htmlEncode(text)}</span>`);
    },

    save: function () {
        let me = this;

        let script = me.editor.getValue();
        if (!script || !script.match(/\S/)) {
            // The API refuses an empty script for the same reason: it reads as
            // "saved" and then silently skips at run time. Removing commands is
            // a different act, and it has its own button on the row.
            Ext.Msg.alert(
                gettext('Error'),
                gettext(
                    'Write the commands to store. To take commands away from a target,'
                        + ' use the remove button on its row.',
                ),
            );
            return;
        }

        let write = function () {
            let failures = [];
            let pending = me.targets.length;

            me.setLoading(true);

            let finish = function () {
                pending--;
                if (pending > 0) {
                    return;
                }

                me.setLoading(false);

                if (failures.length) {
                    // One dialog, not one per target: Ext.Msg is a singleton, so
                    // a dozen alerts leave only the last one standing.
                    Ext.Msg.alert(
                        gettext('Error'),
                        Ext.String.format(
                            gettext('{0} of {1} targets could not be saved:'),
                            failures.length,
                            me.targets.length,
                        ) + `<br><br>${failures.join('<br>')}`,
                    );
                    // Left open on purpose: some targets did get the script and
                    // some did not, and closing here would throw away the text
                    // needed to finish the job.
                    return;
                }

                me.close();
            };

            me.targets.forEach(function (data) {
                let url = PVE.updmgr.scriptUrlFor(data, me.defaultNode);
                if (!url) {
                    failures.push(`${PVE.updmgr.targetLabel(data)}: ${gettext('unknown node')}`);
                    finish();
                    return;
                }

                Proxmox.Utils.API2Request({
                    url: url,
                    method: 'PUT',
                    params: { script: script },
                    failure: function (response) {
                        failures.push(`${PVE.updmgr.targetLabel(data)}: ${response.htmlStatus}`);
                        finish();
                    },
                    success: finish,
                });
            });
        };

        // Asked only when something is actually lost. Targets that are empty, or
        // that already hold exactly this text, are not worth a dialog - and a
        // confirmation that appears every time is one nobody reads.
        if (me.replacing && !(me.identical && script === me.sharedScript)) {
            Ext.Msg.confirm(
                gettext('Confirm'),
                Ext.String.format(
                    gettext(
                        '{0} of the {1} selected targets already have update commands.'
                            + ' Replace all of them with what is in the box?',
                    ),
                    me.replacing,
                    me.targets.length,
                ),
                function (btn) {
                    if (btn === 'yes') {
                        write();
                    }
                },
            );
            return;
        }

        write();
    },

    initComponent: function () {
        let me = this;

        if (!me.targets || !me.targets.length) {
            throw 'no targets specified';
        }

        me.editor = Ext.create('Ext.form.field.TextArea', {
            hideLabel: true,
            spellcheck: false,
            emptyText: gettext(
                'Write the commands to store on every selected target, or pick a starting'
                    + ' point from Templates.',
            ),
            fieldStyle: {
                'font-family': 'monospace',
                'font-size': '12px',
                'white-space': 'pre',
                'overflow-wrap': 'normal',
                'overflow-x': 'auto',
            },
        });

        me.saveButton = Ext.create('Ext.Button', {
            text: gettext('Save to All'),
            iconCls: 'fa fa-floppy-o',
            // Until the current contents are known, Save cannot say what it
            // would replace - so it does not offer to.
            disabled: true,
            handler: function () {
                me.save();
            },
        });

        Ext.apply(me, {
            // Named, not just counted - "4 targets" is not something anyone can
            // check before pressing Save. Cut off after a handful so that
            // selecting the whole datacenter does not produce a title bar the
            // window cannot show.
            title: Ext.String.format(
                gettext('Update commands for {0} targets: {1}'),
                me.targets.length,
                me.targets.length > 5
                    ? me.targets.slice(0, 5).map(PVE.updmgr.targetLabel).join(', ')
                          + Ext.String.format(gettext(' and {0} more'), me.targets.length - 5)
                    : me.targets.map(PVE.updmgr.targetLabel).join(', '),
            ),
            items: [me.editor],
            tbar: [
                me.saveButton,
                PVE.updmgr.templateMenuButton(function (script) {
                    me.editor.setValue(script);
                }),
            ],
            // The status line is NOT a tbtext in the toolbar above. A toolbar
            // lays its items out on one row and clips what does not fit, and
            // these sentences are the ones that say what Save is about to
            // overwrite - exactly the text that must not be cut off. Docked on
            // its own row it has the full width and is allowed to wrap.
            dockedItems: [
                {
                    xtype: 'component',
                    itemId: 'status',
                    dock: 'top',
                    padding: '6 10',
                    style: { 'white-space': 'normal' },
                    html: '',
                },
            ],
            buttons: [
                {
                    text: gettext('Cancel'),
                    handler: function () {
                        me.close();
                    },
                },
            ],
        });

        me.callParent();

        me.load();
    },
});

