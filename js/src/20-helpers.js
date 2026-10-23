// ── Shared helpers ──────────────────────────────────────────────────────────

// A guest is a container ('lxc') or a VM ('qemu') - Proxmox' own type names,
// which are also the path segment of its API: /nodes/<node>/lxc/<vmid> and
// /nodes/<node>/qemu/<vmid>. Anything that is not 'qemu' is a container, which is
// what every row was before VMs existed here.
PVE.updmgr.guestPath = function (data) {
    return data.type === 'qemu' ? 'qemu' : 'lxc';
};

// 'CT' / 'VM', as the Proxmox interface itself abbreviates them.
PVE.updmgr.guestLabel = function (data) {
    return data.type === 'qemu' ? 'VM' : 'CT';
};

PVE.updmgr.targetLabel = function (data) {
    if (data.type === 'node') {
        return `Host ${data.name}`;
    }
    return `${PVE.updmgr.guestLabel(data)} ${data.vmid} (${data.name})`;
};

// Where a target's commands live. A datacenter selection spans nodes, so the
// row's own node decides; `defaultNode` is only the fallback for the node tab,
// whose rows do not all carry one.
PVE.updmgr.scriptUrlFor = function (data, defaultNode) {
    let node = data.node || defaultNode;
    if (!node) {
        return undefined;
    }

    return data.type === 'node'
        ? `/nodes/${node}/updatemgr/script`
        : `/nodes/${node}/${PVE.updmgr.guestPath(data)}/${data.vmid}/updatemgr/script`;
};

// Where a target's position in a run is written. Same shape as
// scriptUrlFor and for the same reason: a datacenter selection spans nodes.
PVE.updmgr.orderUrlFor = function (data, defaultNode) {
    let node = data.node || defaultNode;
    if (!node) {
        return undefined;
    }

    return data.type === 'node'
        ? `/nodes/${node}/updatemgr/order`
        : `/nodes/${node}/${PVE.updmgr.guestPath(data)}/${data.vmid}/updatemgr/order`;
};

// Where a target's kept run logs live. Same shape as orderUrlFor and for the same
// reason: a datacenter selection spans nodes, and a log is the one thing here that
// is NOT replicated - so an URL pointing at the wrong node answers with an empty
// list rather than an error.
PVE.updmgr.logsUrlFor = function (data, defaultNode) {
    let node = data.node || defaultNode;
    if (!node) {
        return undefined;
    }

    return data.type === 'node'
        ? `/nodes/${node}/updatemgr/logs`
        : `/nodes/${node}/${PVE.updmgr.guestPath(data)}/${data.vmid}/updatemgr/logs`;
};

// What the operator typed into the order prompt, as the API wants it.
//
// Returns 0 for an empty box - that is how "no answer given" is spelled, and it
// is what clears the value - and undefined for anything that is not a plain
// number in range, which the caller reports rather than sending.
PVE.updmgr.parseOrder = function (text) {
    let raw = String(text === undefined || text === null ? '' : text).trim();

    if (!raw.length) {
        return 0;
    }
    if (!/^\d+$/.test(raw)) {
        return undefined;
    }

    let value = parseInt(raw, 10);

    return value <= PVE.updmgr.MAX_ORDER ? value : undefined;
};

// The menu behind the History button: one entry per saved version of the
// script, newest first, as the server listed them.
//
// "latest save" and not "current": the file in /etc/pve can be edited with an
// editor, and that write goes through nothing that could record a version - so
// the newest entry is the newest SAVE, which is a claim this can actually make.
PVE.updmgr.versionMenuItems = function (list, apply) {
    let items = (list || []).map(function (entry, index) {
        let who = entry.user ? ` — ${Ext.String.htmlEncode(entry.user)}` : '';
        let tag = index === 0 ? ` (${gettext('latest save')})` : '';

        return {
            // `time` to show, `version` to ask with. They used to be the same
            // number; the identifier is the local second that stands in the
            // file's name now, and rendering that as though it were an epoch
            // would date every entry to 1970.
            text: `${Proxmox.Utils.render_timestamp(entry.time)}${who}${tag}`,
            handler: function () {
                apply(entry.version, entry.time);
            },
        };
    });

    // A menu that opens empty reads as broken.
    if (!items.length) {
        items.push({ text: gettext('Nothing saved yet'), disabled: true });
    }

    return items;
};

// One row of the Logs window: how a past run ended.
//
// The same shape renderLastRun draws a row's state in, on purpose - a run that
// failed has to look the same in both places. `state` is absent for a log a
// killed worker left half written, which is worth saying rather than drawing as
// "ok".
PVE.updmgr.renderLogState = function (state, note) {
    let faded = note ? ` <span class="faded">${Ext.String.htmlEncode(note)}</span>` : '';

    switch (state) {
        case 'ok':
            return `<i class="fa fa-check good"></i> ${gettext('OK')}${faded}`;
        case 'not_fixed':
            return `<i class="fa fa-times-circle critical"></i> ${gettext('NOT FIXED')}${faded}`;
        case 'failed':
            return `<i class="fa fa-times critical"></i> ${gettext('failed')}${faded}`;
        case 'skipped':
            return `<i class="fa fa-minus"></i> ${gettext('skipped')}${faded}`;
        default:
            return `<i class="fa fa-question-circle warning"></i> ${gettext('no result')}`;
    }
};

// The Logs button, as a config rather than inline - so a test can hold it and
// check that it is a plain BUTTON.
//
// That is not fussiness: it used to be two buttons, one of them a dropdown, and
// between them they pushed the end of the editor's toolbar into ExtJS' overflow
// menu. A `menu:` added here again would put it straight back, and nothing else in
// the suite would notice.
PVE.updmgr.logsButton = function (open) {
    return {
        text: gettext('Logs'),
        iconCls: 'fa fa-file-text-o',
        handler: function () {
            open();
        },
    };
};

// How big a log is, for the column that says "this run said a lot" before it is
// opened. Proxmox' own formatter where the version at hand has one - it did not
// always - and plain bytes otherwise, because a number is better than nothing.
PVE.updmgr.formatLogSize = function (bytes) {
    if (Proxmox.Utils.format_size) {
        return Proxmox.Utils.format_size(bytes || 0);
    }

    return `${bytes || 0} B`;
};

// One line summarising a target's last run, used both in a grid cell and in the
// toolbar of the container tab. The state comes from the state file the worker
// writes, not from the task archive, so it survives log rotation.
PVE.updmgr.renderLastRun = function (data) {
    if (!data.last_state) {
        return `<span class="faded">${gettext('never run')}</span>`;
    }

    let when = data.last_finished || data.last_started;
    let ts = when ? Proxmox.Utils.render_timestamp(when) : '';
    let faded = ts ? ` <span class="faded">${ts}</span>` : '';

    switch (data.last_state) {
        // fa-spinner, not fa-cog: the ring of separate bars is what Proxmox uses
        // everywhere else for "busy", and a rotating cog reads as "configuring".
        case 'running':
            return `<i class="fa fa-spinner fa-spin"></i> ${gettext('running')}`;
        case 'ok':
            return `<i class="fa fa-check good"></i> ${gettext('OK')}${faded}`;
        // #73: the script exited 0, but security updates pending before the run
        // are still not installed. Red like a failure, and not called one - no
        // rollback happened for it. Which packages: on hover, from the note.
        case 'not_fixed':
            return (
                `<span data-qtip="${Ext.String.htmlEncode(Ext.String.htmlEncode(data.last_note || ''))}">` +
                `<i class="fa fa-times-circle critical"></i> ${gettext('NOT FIXED')}</span>${faded}`
            );
        case 'failed':
            return (
                `<i class="fa fa-times critical"></i> ` +
                // '?' rather than the raw value: a state file that lost its exit
                // code - hand-edited, or written by something that is not us -
                // would otherwise put the word "undefined" in the grid, which
                // reads as a bug in the addon rather than as a missing number.
                Ext.String.format(
                    gettext('failed (exit {0})'),
                    data.last_exit === undefined || data.last_exit === null
                        ? '?'
                        : data.last_exit,
                ) +
                faded
            );
        case 'skipped':
            return (
                `<i class="fa fa-minus faded"></i> ${gettext('skipped')}` +
                (data.last_note ? ` <span class="faded">${Ext.String.htmlEncode(data.last_note)}</span>` : '')
            );
        // The worker was killed before it could record how the run ended, or the
        // state file is unreadable. Not a failure - we genuinely do not know
        // whether the update went through - so it says so, and the row is usable
        // again instead of spinning for ever.
        case 'unknown':
            return (
                `<i class="fa fa-question-circle warning"></i> ${gettext('no result')}` +
                (data.last_note ? ` <span class="faded">${Ext.String.htmlEncode(data.last_note)}</span>` : '') +
                faded
            );
        default:
            return Ext.String.htmlEncode(data.last_state);
    }
};

// The Logs window: the kept runs of one target, and what each of them printed.
//
// ONE window and one plain button behind it, not a dropdown and not two buttons.
// The editor's toolbar already carries six and ExtJS was folding the end of it
// into an overflow menu - and "Last Log" was a second button for a third of the
// same thing anyway. So the newest row IS the last run, and Proxmox' own task log
// for it is a button in here.
//
// The grid is deliberately small and the text pane large: picking which run is a
// glance, reading what it said is the job.
