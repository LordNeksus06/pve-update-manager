// ── Managing the Templates menu ─────────────────────────────────────────────
//
// One list for the whole cluster, stored in /etc/pve. Until something is
// changed here the menu is the built-in set that ships with the package; the
// first change writes the whole set out, so from then on a shipped default no
// longer moves under a user who edited a different entry. Reset throws the
// stored list away and follows the shipped defaults again.
Ext.define('PVE.updmgr.TemplateEditWindow', {
    extend: 'Ext.window.Window',

    width: 760,
    height: 560,
    layout: 'fit',
    modal: true,
    resizable: true,

    // set by the caller: the entry being changed, or undefined when adding
    template: undefined,

    submit: function () {
        let me = this;

        let name = me.down('#name').getValue();
        let script = me.editor.getValue();

        if (!name || !name.match(/\S/)) {
            Ext.Msg.alert(gettext('Error'), gettext('A template needs a name.'));
            return;
        }
        if (!script || !script.match(/\S/)) {
            Ext.Msg.alert(gettext('Error'), gettext('A template needs commands.'));
            return;
        }

        let params = { name: name, script: script };
        // Only on a real rename: sending oldname === name would make the server
        // look for an entry that may not exist yet, turning an add into an
        // error.
        if (me.template && me.template.name !== name) {
            params.oldname = me.template.name;
        }

        Proxmox.Utils.API2Request({
            url: '/cluster/updatemgr/templates',
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

    initComponent: function () {
        let me = this;

        me.editor = Ext.create('Ext.form.field.TextArea', {
            hideLabel: true,
            spellcheck: false,
            value: me.template ? me.template.script : '',
            emptyText: gettext('The commands this entry pastes into the editor.'),
            fieldStyle: {
                'font-family': 'monospace',
                'font-size': '12px',
                'white-space': 'pre',
                'overflow-wrap': 'normal',
                'overflow-x': 'auto',
            },
        });

        Ext.apply(me, {
            title: me.template
                ? Ext.String.format(
                      gettext('Edit template: {0}'),
                      Ext.String.htmlEncode(me.template.name),
                  )
                : gettext('New template'),
            items: [me.editor],
            dockedItems: [
                {
                    xtype: 'toolbar',
                    dock: 'top',
                    items: [
                        {
                            xtype: 'textfield',
                            itemId: 'name',
                            fieldLabel: gettext('Name'),
                            labelWidth: 50,
                            width: 500,
                            allowBlank: false,
                            value: me.template ? me.template.name : '',
                        },
                    ],
                },
            ],
            buttons: [
                {
                    text: gettext('Cancel'),
                    handler: function () {
                        me.close();
                    },
                },
                {
                    text: gettext('OK'),
                    iconCls: 'fa fa-floppy-o',
                    handler: function () {
                        me.submit();
                    },
                },
            ],
        });

        me.callParent();
    },
});

Ext.define('PVE.updmgr.TemplateWindow', {
    extend: 'Ext.window.Window',

    width: 700,
    height: 480,
    layout: 'fit',
    modal: true,
    resizable: true,

    title: gettext('Update Manager templates'),

    reload: function () {
        let me = this;

        // force: this window is the one place that just changed the list, so
        // reading the cache back would show the state before its own write.
        PVE.updmgr.loadTemplates(function (data) {
            if (me.destroyed) {
                return;
            }
            me.grid.getStore().loadData(data.templates || []);
            me.down('#reset').setDisabled(!data.custom);
            me.down('#stored').setHtml(
                Ext.String.htmlEncode(
                    data.custom
                        ? gettext('This list is stored in /etc/pve and shared by every node.')
                        : gettext(
                              'These are the built-in templates. Changing one stores the whole list.',
                          ),
                ),
            );
        }, true);
    },

    // Every write goes through here so exactly one thing has to be remembered:
    // the cached menu is stale the moment the server accepted a change.
    //
    // The URL is passed in whole, query string included, because a DELETE does
    // not reliably carry `params` to this API - the toolkit's own
    // ConfirmRemoveDialog builds its query string by hand for exactly that
    // reason.
    write: function (method, url, params) {
        let me = this;

        Proxmox.Utils.API2Request({
            url: url,
            method: method,
            params: params,
            waitMsgTarget: me,
            failure: function (response) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function () {
                PVE.updmgr.templateCache = undefined;
                me.reload();
            },
        });
    },

    edit: function (rec) {
        let me = this;

        let win = Ext.create('PVE.updmgr.TemplateEditWindow', {
            template: rec ? { name: rec.data.name, script: rec.data.script } : undefined,
        });
        win.on('destroy', function () {
            PVE.updmgr.templateCache = undefined;
            me.reload();
        });
        win.show();
    },

    initComponent: function () {
        let me = this;

        me.grid = Ext.create('Ext.grid.GridPanel', {
            border: false,
            store: Ext.create('Ext.data.Store', {
                fields: ['name', 'script'],
                data: [],
            }),
            columns: [
                {
                    header: gettext('Name'),
                    dataIndex: 'name',
                    width: 260,
                    // A column with no renderer puts the value into the cell as
                    // markup. The Commands column beside it has always encoded;
                    // this one is the same free text and needs the same.
                    renderer: (v) => Ext.String.htmlEncode(v || ''),
                },
                {
                    header: gettext('Commands'),
                    dataIndex: 'script',
                    flex: 1,
                    // The first line that is neither empty nor a comment: the
                    // shebang and the header comment are the same in half the
                    // entries, so showing those would make every row look alike.
                    renderer: function (script) {
                        let line = String(script || '')
                            .split('\n')
                            .find((l) => l.match(/\S/) && !l.match(/^\s*#/));
                        return Ext.String.htmlEncode(line || '');
                    },
                },
            ],
            listeners: {
                itemdblclick: function (view, rec) {
                    me.edit(rec);
                },
            },
        });

        Ext.apply(me, {
            items: [me.grid],
            tbar: [
                {
                    text: gettext('Add'),
                    iconCls: 'fa fa-plus',
                    handler: function () {
                        me.edit(undefined);
                    },
                },
                {
                    text: gettext('Edit'),
                    iconCls: 'fa fa-pencil',
                    handler: function () {
                        let rec = me.grid.getSelection()[0];
                        if (rec) {
                            me.edit(rec);
                        }
                    },
                },
                {
                    text: gettext('Remove'),
                    iconCls: 'fa fa-trash-o',
                    handler: function () {
                        let rec = me.grid.getSelection()[0];
                        if (!rec) {
                            return;
                        }
                        Ext.Msg.confirm(
                            gettext('Confirm'),
                            Ext.String.format(
                                gettext('Remove the template "{0}" from the menu?'),
                                Ext.String.htmlEncode(rec.data.name),
                            ),
                            function (btn) {
                                if (btn === 'yes') {
                                    me.write(
                                        'DELETE',
                                        '/cluster/updatemgr/templates?name='
                                            + encodeURIComponent(rec.data.name),
                                    );
                                }
                            },
                        );
                    },
                },
                '-',
                {
                    text: gettext('Reset to Defaults'),
                    itemId: 'reset',
                    iconCls: 'fa fa-undo',
                    disabled: true,
                    handler: function () {
                        Ext.Msg.confirm(
                            gettext('Confirm'),
                            gettext(
                                'Throw the stored template list away and go back to the'
                                    + ' built-in templates? Every entry added or edited here'
                                    + ' is lost.',
                            ),
                            function (btn) {
                                if (btn === 'yes') {
                                    // Its own path, not a DELETE with the name
                                    // left off: a parameter that goes missing
                                    // must not turn a removal into a reset.
                                    me.write('POST', '/cluster/updatemgr/templates/reset');
                                }
                            },
                        );
                    },
                },
            ],
            dockedItems: [
                {
                    xtype: 'component',
                    itemId: 'stored',
                    dock: 'bottom',
                    padding: '6 10',
                    style: { 'white-space': 'normal' },
                    html: '',
                },
            ],
            buttons: [
                {
                    text: gettext('Close'),
                    handler: function () {
                        me.close();
                    },
                },
            ],
        });

        me.callParent();

        me.reload();
    },
});

