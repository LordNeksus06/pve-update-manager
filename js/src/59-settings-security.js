// ── The Security tab of the settings window (#41, #45) ──────────────────────
//
// Sixteen settings, described once in a table and walked three times: to build
// the fields, to fill them from the server's answer, and to send them back.
// Written out by hand like the older settings they would be three lists of
// seventeen that have to stay in step, and the one that drifts is the one that
// costs a value: a field shown but never sent is written back as whatever the
// merge produced. tests/run-tests.sh reads the `key:` lines of this table to
// hold it against the API schema.
//
// Names, ranges and defaults are the server's, from SecSettings.pm. `def` is
// only used when the server's answer has no such key - never for a falsy one,
// because 0 minutes of gap and an empty severity are real answers.
//
// kind: bool  -> checkbox, sent as 1/0
//       int   -> integer field with the server's range
//       str   -> text field, checked against the server's pattern
//       combo -> fixed choices; '' is the toolkit's '__default__' key, because
//                Proxmox.form.KVComboBox treats that key as "nothing chosen"
//
// perNode: a list of vmids exists on one node only, like schedule_vmids, and a
// datacenter-wide save must not broadcast it (SecSettings::PER_NODE). In global
// mode the field is not built, not filled and not sent.
PVE.updmgr.SECURITY_FIELDS = [
    {
        key: 'security_scan',
        itemId: 'securityScan',
        section: 'check',
        kind: 'bool',
        def: 0,
        label: gettext('Check the guests for pending security updates'),
    },
    {
        key: 'security_interval',
        itemId: 'securityInterval',
        section: 'check',
        kind: 'int',
        def: 30,
        min: 5,
        max: 10080,
        // The timer ticks every 5 minutes, so anything finer is not real.
        label: gettext('Check every (minutes)'),
    },
    {
        key: 'security_parallel',
        itemId: 'securityParallel',
        section: 'check',
        kind: 'int',
        def: 4,
        min: 1,
        max: 64,
        // Worded against security_install_parallel_max (#41): this one reads
        // package lists, that one runs updates.
        label: gettext('Guests checked at once'),
    },
    {
        key: 'security_targets',
        itemId: 'securityTargets',
        section: 'check',
        kind: 'combo',
        def: 'all',
        label: gettext('Guests to check'),
        items: [
            ['all', gettext('All guests')],
            ['script', gettext('Only guests with an update script')],
        ],
    },
    {
        key: 'security_source',
        itemId: 'securitySource',
        section: 'check',
        kind: 'combo',
        def: 'configured',
        label: gettext('Security lists from'),
        items: [
            ['configured', gettext("Each guest's own sources and proxy")],
            ['debian', gettext('Debian directly')],
        ],
    },
    {
        key: 'security_exclude',
        itemId: 'securityExclude',
        section: 'check',
        kind: 'str',
        def: '',
        label: gettext('Ignore packages'),
        empty: 'linux-image-*, firmware-*',
        maxLength: 1024,
        regex: /^[a-z0-9+.*?,\s-]*$/,
        regexText: gettext('Package names with * and ?, separated by commas'),
    },
    {
        key: 'security_min_severity',
        itemId: 'securityMinSeverity',
        section: 'check',
        kind: 'combo',
        def: '',
        label: gettext('Minimum severity'),
        items: [
            ['__default__', gettext('All')],
            ['low', gettext('Low and above')],
            ['medium', gettext('Medium and above')],
            ['high', gettext('High')],
        ],
        // Text, not a tooltip: the server counts an unrated fix as reaching any
        // threshold, and somebody choosing "High" would not guess that.
        note: gettext('A fix Debian has not rated yet counts as any severity.'),
    },
    {
        key: 'security_notify',
        itemId: 'securityNotify',
        section: 'notify',
        kind: 'bool',
        def: 1,
        label: gettext('Send a notification when a check finds security updates'),
    },
    {
        key: 'security_notify_once',
        itemId: 'securityNotifyOnce',
        section: 'notify',
        kind: 'bool',
        def: 1,
        label: gettext('Only once per package and guest'),
    },
    {
        key: 'security_unfixed_cooldown',
        itemId: 'securityUnfixedCooldown',
        section: 'notify',
        kind: 'int',
        def: 300,
        min: 0,
        max: 10080,
        label: gettext('NOT FIXED notification at most every (minutes)'),
        note: gettext('After a run, security updates still not installed make it NOT FIXED.'),
    },
    {
        key: 'security_install',
        itemId: 'securityInstall',
        section: 'install',
        kind: 'bool',
        def: 0,
        label: gettext('Update a guest as soon as a check finds a security update'),
    },
    {
        key: 'security_install_mode',
        itemId: 'securityInstallMode',
        section: 'install',
        kind: 'combo',
        def: 'script',
        label: gettext('Run'),
        items: [
            ['script', gettext("The guest's update script")],
            ['security', gettext('Only the affected packages')],
        ],
    },
    {
        key: 'security_install_vmids',
        itemId: 'securityInstallVmids',
        section: 'install',
        kind: 'str',
        def: '',
        perNode: true,
        label: gettext('Only these guests'),
        empty: gettext('every guest with pending updates'),
        maxLength: 4096,
        regex: /^(\d+(,\d+)*)?$/,
        regexText: gettext('Guest IDs separated by commas, e.g. 101,102'),
    },
    {
        key: 'security_install_window',
        itemId: 'securityInstallWindow',
        section: 'install',
        kind: 'str',
        def: '',
        label: gettext('Only between'),
        empty: gettext('06:00-22:00, empty = any time'),
        regex: /^(([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d)?$/,
        regexText: gettext('HH:MM-HH:MM, e.g. 06:00-22:00'),
    },
    {
        key: 'security_install_gap',
        itemId: 'securityInstallGap',
        section: 'install',
        kind: 'int',
        def: 60,
        min: 0,
        max: 1440,
        label: gettext('Not if the schedule is due within (minutes)'),
    },
    {
        key: 'security_install_parallel_max',
        itemId: 'securityInstallParallelMax',
        section: 'install',
        kind: 'int',
        def: 1,
        min: 1,
        max: 64,
        label: gettext('Updates at once'),
    },
    {
        key: 'security_reboot',
        itemId: 'securityReboot',
        section: 'install',
        kind: 'bool',
        def: 0,
        label: gettext('Restart a guest that requires it after such an update'),
    },
];

// The fields that exist in this window: all seventeen on a node, sixteen for the
// datacenter.
PVE.updmgr.securityFieldsFor = function (global) {
    return PVE.updmgr.SECURITY_FIELDS.filter((f) => !(global && f.perNode));
};

PVE.updmgr.securityField = function (f) {
    if (f.kind === 'bool') {
        return { xtype: 'checkbox', itemId: f.itemId, boxLabel: f.label };
    }

    let field = { itemId: f.itemId, fieldLabel: f.label, labelWidth: 260 };

    // Combo boxes and text fields get 300 px of body (#46). With only the
    // label width set, ExtJS left them at ~170 px, which cut "Each guest's own
    // sources and proxy" off after "sourc". Number fields keep the narrow
    // default - a wide box around "30" reads as a text field.
    if (f.kind === 'combo' || f.kind === 'str') {
        field.width = 260 + 300;
    }

    if (f.kind === 'int') {
        return Ext.apply(field, {
            xtype: 'proxmoxintegerfield',
            minValue: f.min,
            maxValue: f.max,
            allowBlank: false,
            emptyText: String(f.def),
        });
    }
    if (f.kind === 'combo') {
        return Ext.apply(field, {
            xtype: 'proxmoxKVComboBox',
            comboItems: f.items,
            allowBlank: false,
        });
    }

    return Ext.apply(field, {
        xtype: 'textfield',
        allowBlank: true,
        emptyText: f.empty,
        maxLength: f.maxLength,
        regex: f.regex,
        regexText: f.regexText,
    });
};

// The Security tab: three sections, in the order a reader decides them - what
// is checked, who hears about it, and whether anything is done about it.
PVE.updmgr.securityTab = function (me) {
    let sections = [
        ['check', gettext('Check')],
        ['notify', gettext('Notification')],
        ['install', gettext('Immediate updates')],
    ];

    return {
        title: gettext('Security'),
        itemId: 'securityTab',
        scrollable: 'y',
        items: sections.map(([section, title]) => {
            let items = [];
            PVE.updmgr.SECURITY_FIELDS
                .filter((f) => f.section === section)
                .forEach(function (f) {
                    if (f.perNode && me.global) {
                        // Says where the list is, instead of a field that would
                        // write one node's guest IDs onto every other node.
                        items.push({
                            xtype: 'displayfield',
                            userCls: 'faded',
                            value: gettext('Guests for immediate updates are selected per node.'),
                        });
                        return;
                    }
                    items.push(PVE.updmgr.securityField(f));
                    if (f.note) {
                        items.push({ xtype: 'displayfield', userCls: 'faded', value: f.note });
                    }
                });
            return { xtype: 'fieldset', title: title, items: items };
        }),
    };
};

PVE.updmgr.loadSecurity = function (me, data) {
    PVE.updmgr.securityFieldsFor(me.global).forEach(function (f) {
        let v = data[f.key] === undefined ? f.def : data[f.key];

        if (f.kind === 'bool') {
            v = !!Number(v);
        } else if (f.kind === 'combo' && v === '') {
            v = '__default__';
        }
        me.down(`#${f.itemId}`).setValue(v);
    });
};

PVE.updmgr.securityParams = function (me) {
    let params = {};

    PVE.updmgr.securityFieldsFor(me.global).forEach(function (f) {
        let v = me.down(`#${f.itemId}`).getValue();

        if (f.kind === 'bool') {
            v = v ? 1 : 0;
        } else if (f.kind === 'combo' && v === '__default__') {
            v = '';
        } else if (f.kind === 'str') {
            // '' rather than null: the schema spells "none" as the empty
            // string (its patterns end in `?` for exactly that).
            v = v || '';
        }
        params[f.key] = v;
    });

    return params;
};
