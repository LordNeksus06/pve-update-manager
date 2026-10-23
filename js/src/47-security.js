// ── The security check in the target lists (#41) ────────────────────────────
//
// One column and one button. What the column shows was written by the
// background check (#40) into a summary per node; the list endpoint only reads
// that file, so loading the grid never waits on a guest (#35).

// The row fields the targets endpoints send for it (SecSummary::row_schema).
PVE.updmgr.SECURITY_ROW_FIELDS = [
    'security_status',
    { name: 'security_count', type: 'int' },
    'security_packages',
    'security_reason',
    'security_warning',
    { name: 'security_busy', type: 'boolean' },
    { name: 'security_checked', type: 'int' },
];

// What a status that is not a count means, in the words the cell uses.
PVE.updmgr.SECURITY_STATUS_TEXT = {
    timeout: gettext('check timed out'),
    stopped: gettext('stopped'),
    'no-agent': gettext('no guest agent'),
    unsupported: gettext('not supported'),
    'no-security-source': gettext('no security source'),
    'source-unreachable': gettext('source unreachable'),
    error: gettext('error'),
};

// The cell. A number only where there is one to show: a target that could not
// be checked gets a dash and the reason, never a 0 - "0 pending" on a guest
// nobody could read would be the one wrong answer this column can give.
PVE.updmgr.renderSecurity = function (data) {
    let enc = Ext.String.htmlEncode;
    let status = data.security_status;

    if (!status) {
        return `<span class="faded">${gettext('not checked')}</span>`;
    }

    let busy = data.security_busy ? ` <span class="faded">(${gettext('was updating')})</span>` : '';

    if (status !== 'ok') {
        let text = PVE.updmgr.SECURITY_STATUS_TEXT[status] || status;
        let tip = data.security_reason ? ` data-qtip="${enc(enc(data.security_reason))}"` : '';
        return `<span class="faded"${tip}>– ${enc(text)}</span>${busy}`;
    }

    let count = data.security_count || 0;
    if (!count) {
        return `<i class="fa fa-check good"></i> 0${busy}`;
    }

    let names = String(data.security_packages || '').split(',').filter((n) => n.length);
    let shown = names.join(', ') + (count > names.length ? ', …' : '');

    // Pending, but not installable from the source the guest names (#53): the
    // count stays, the reason is said in the cell and in full on hover. The
    // words come before the names - behind them the column cut them off
    // (seen in the browser with 35 names).
    if (data.security_warning) {
        let tip = ` data-qtip="${enc(enc(data.security_warning))}"`;
        return `<span${tip}><i class="fa fa-times-circle critical"></i> ${count}`
            + ` – ${gettext('packages unavailable')} (${enc(shown)})</span>${busy}`;
    }

    return `<i class="fa fa-exclamation-triangle warning"></i> ${count} (${enc(shown)})${busy}`;
};

PVE.updmgr.securityColumn = function () {
    return {
        header: gettext('Security'),
        dataIndex: 'security_count',
        width: 220,
        renderer: function (value, meta, rec) {
            return PVE.updmgr.renderSecurity(rec.data);
        },
    };
};

// "Check now" on a node: starts the check as a task and shows it. The call
// returns at once; the grid reloads when the task window is closed.
PVE.updmgr.checkNow = function (grid, nodename) {
    Proxmox.Utils.API2Request({
        url: `/nodes/${nodename}/updatemgr/security/scan`,
        method: 'POST',
        failure: function (response) {
            Ext.Msg.alert(gettext('Error'), response.htmlStatus);
        },
        success: function (response) {
            let win = Ext.create('Proxmox.window.TaskViewer', { upid: response.result.data });
            win.on('destroy', function () {
                grid.reload();
            });
            win.show();
        },
    });
};
