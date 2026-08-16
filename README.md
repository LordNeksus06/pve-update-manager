# pve-update-manager

An **Update Manager** tab for Proxmox VE — per container, per node, and for the
whole datacenter.

Proxmox tells you a container has updates. It does not update it. This addon
adds the missing half: a text box per target holding the update commands *you*
write, a button that runs them, and a list that shows when each one last ran and
whether it worked.

Nothing is generated and nothing is guessed. Your commands, run as root inside
the container, in a normal Proxmox task with a normal task log.

![The Update Manager tab of a container, showing its stored apt commands](../docs/img/container-tab.png)

Every target in one list, with what it last did — tick several and update or
edit them together:

![The node view listing the host and its containers with their last run state](../docs/img/node-grid.png)

The same editor opens from a pencil on any row, without leaving the overview:

![The popup editor for a single container's update commands](../docs/img/editor-window.png)

## What it does

- **Per container** — a tab with that container's update commands and an Update
  button.
- **Per node** — the host and all its containers in one list. Tick what to
  update, or update a single row from the row itself.
- **Per datacenter** — the same list across every node of the cluster.
- **Edit Selected** — set the same commands on many targets at once, with the
  dialog telling you first whether it is about to overwrite anything.
- **Scheduled runs** — a systemd calendar event, the same syntax a backup job
  uses, running serially or all at once.
- **A real timeout** that kills the process tree rather than just giving up
  watching it, with a ceiling on how much a runaway script may write to the log.
- **Nothing gets switched off mid-update** — the container carries a config lock
  and the node holds a systemd shutdown inhibitor for as long as the job runs.

## Install

Download the `.deb` from [Releases](../../releases):

```sh
sudo apt install ./pve-update-manager_*_all.deb
```

Then reload the Proxmox web interface.

The package is `Architecture: all` — there is nothing compiled in it, only Perl,
JavaScript and shell, so the same file installs on amd64 and on the arm64 port
of Proxmox VE.

Removing it takes the integration back out cleanly:

```sh
sudo apt remove pve-update-manager      # keeps your stored scripts
sudo apt purge  pve-update-manager      # also deletes /etc/pve/pve-update-manager
```

## How it integrates

Proxmox' own `pvemanagerlib.js` is never modified. The tabs are added by
overriding `PVE.panel.Config.initComponent`, and the API routes are registered
at runtime — four one-line, idempotent, reversible edits to `index.html.tpl`,
`pvedaemon`, `pveproxy` and `pvesh`, re-applied automatically by a dpkg trigger
after every `pve-manager` upgrade.

```sh
pve-update-manager-hooks status   # what is in place right now
pve-update-manager-hooks revert   # take it all back out
```

Your scripts live as plain files under `/etc/pve/pve-update-manager/`, so they
are cluster-replicated, survive a migration, and can be read with `cat`.

## Permissions

Reading needs `VM.Audit` / `Sys.Audit`. Changing commands needs
`VM.Config.Options`. **Running** them needs `VM.Console` for a container and
`Sys.Console` for the host — running arbitrary commands as root is what console
access already grants, so that is the bar.

## Building from source

```sh
make test   # shellcheck, perl -c, node --check, unit tests, hook script
make deb    # builds into deb-out/
```

## Licence

[AGPL-3.0-or-later](../LICENSE) — the same licence Proxmox VE itself uses.

Anyone may use, modify and redistribute this. A fork has to keep the copyright
notice, state its changes, and stay open source. The choice is not arbitrary:
this addon imports Proxmox' own Perl modules and subclasses `PVE::RESTHandler`,
which makes it a derivative of AGPL-licensed code — a more permissive licence
could not have been granted for it.

### Copyright

```
pve-update-manager - an Update Manager tab for Proxmox VE
Copyright (C) 2026 Lukas

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. See the LICENSE file for the full text.
```

That notice is what a fork has to keep. It lives here rather than at the top of
`LICENSE`, because GitHub only recognises a licence when that file holds the
verbatim upstream text - a prepended header makes it report "Unknown license".
