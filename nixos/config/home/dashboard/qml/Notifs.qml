// nixos/config/home/dashboard/qml/Notifs.qml
//
// Quickshell IS the notification daemon now — swaync is gone, because both
// bind org.freedesktop.Notifications and a client daemon has no way to hand
// its list to another process. Merging the drawer and the control center
// therefore means owning the bus name.
//
// Two consumers of the same state:
//   • NotifView  — the grouped, persistent list in the drawer.
//   • Toasts     — the transient top-right popups.
// plus waybar's pill, synced through a file + realtime signal (see below).
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

Singleton {
    id: root

    // Suppresses popups only. Notifications still land in the list — the
    // point of DND is "don't interrupt me", not "throw it away".
    property bool dnd: false

    // `var`, not `list<Notification>`. A typed QML list property is backed by
    // QQmlListProperty, which exposes `length` but NOT the array methods —
    // `.slice()`, `.sort()`, spread, `for...of`. `groups` below is built with
    // all four, so with a typed property the whole binding threw and evaluated
    // to undefined: the bell showed the right count (that only needs `length`)
    // while the Alerts tab rendered an empty list. `values` is already a plain
    // JS array, so holding it in a `var` keeps it one.
    readonly property var all: server.trackedNotifications.values
    readonly property int count: all.length

    // Popup stack, newest last. Held separately from the tracked list because
    // dismissing a toast must not clear the notification. Same `var` reasoning.
    property var popups: []

    // Gated by shell.qml — see the ticker below.
    property bool listVisible: false

    // Arrival times, keyed by notification id — the Notification object has
    // no timestamp of its own, so "2 mins ago" has to be recorded here.
    property var times: ({})

    // Newest first, grouped by app. One entry per app: { app, icon, items }.
    readonly property var groups: {
        const byApp = {};
        const order = [];
        const sorted = all.slice().sort((a, b) => (times[b.id] ?? 0) - (times[a.id] ?? 0));
        for (const n of sorted) {
            const key = n.appName || "Unknown";
            if (!byApp[key]) {
                byApp[key] = {
                    app: key,
                    icon: n.appIcon ?? "",
                    desktopEntry: n.desktopEntry ?? "",
                    items: []
                };
                order.push(key);
            }
            byApp[key].items.push(n);
        }
        return order.map(k => byApp[k]);
    }

    NotificationServer {
        id: server

        // Survive a config reload — without this every `qs reload` silently
        // drops the user's unread notifications.
        keepOnReload: true

        actionsSupported: true
        actionIconsSupported: true
        bodySupported: true
        bodyMarkupSupported: true
        bodyImagesSupported: true
        imageSupported: true
        inlineReplySupported: true
        persistenceSupported: true

        onNotification: n => {
            // `transient` is the hint an app sets for "popup only, don't
            // persist" (volume OSDs and the like). Everything else is
            // retained — without `tracked` the object is destroyed as soon
            // as its popup ends, so the drawer list would always be empty.
            n.tracked = !n.transient;
            root.times[n.id] = Date.now();

            n.closed.connect(() => {
                root.dropPopup(n);
                delete root.times[n.id];
                sync.restart();
            });

            if (!root.dnd)
                root.popups = [...root.popups, n];

            sync.restart();
        }
    }

    function dropPopup(n: Notification): void {
        const i = root.popups.indexOf(n);
        if (i >= 0) {
            const next = root.popups.slice();
            next.splice(i, 1);
            root.popups = next;
        }
    }

    function dismiss(n: Notification): void {
        n.dismiss();
    }

    function clearAll(): void {
        // Snapshot first: dismiss() mutates trackedNotifications as we walk it.
        for (const n of all.slice())
            n.dismiss();
        root.popups = [];
        sync.restart();
    }

    function toggleDnd(): void {
        root.dnd = !root.dnd;
        if (root.dnd)
            root.popups = [];
        sync.restart();
    }

    // Relative timestamp, matching swaync's `relative-timestamps` wording.
    function ago(n: Notification): string {
        const t = times[n.id];
        if (!t)
            return "";
        const s = Math.max(0, Math.floor((clock.now - t) / 1000));
        if (s < 60)
            return "now";
        if (s < 3600)
            return Math.floor(s / 60) + "m ago";
        if (s < 86400)
            return Math.floor(s / 3600) + "h ago";
        return Math.floor(s / 86400) + "d ago";
    }

    // Single ticker driving every "x ago" label — and only while one is
    // actually on screen, which means the Alerts tab is up or a toast is out.
    // A closed drawer ticks nothing.
    QtObject {
        id: clock
        property double now: Date.now()
    }
    Timer {
        interval: 30000
        repeat: true
        running: (root.listVisible && root.count > 0) || root.popups.length > 0
        onTriggered: clock.now = Date.now()
    }

    // ── waybar pill sync ─────────────────────────────────────────────────
    // waybar's custom/notification used to read `swaync-client -swb`. There is
    // no equivalent stream to inherit, so instead: write the module's own JSON
    // to a file and raise SIGRTMIN+7, which is waybar's documented `signal`
    // mechanism and stays event-driven (no interval, no spawn per tick).
    //
    // RTMIN+7 because +8 and +9 are already claimed by toggle_vpn.sh and
    // change_brightness.sh. The target is `.waybar-wrapped`, not `waybar` —
    // that is the actual process name under the Nix wrapper.
    Timer {
        id: sync
        interval: 60 // coalesce bursts of notifications into one bar update
        repeat: false
        onTriggered: {
            const n = root.count;
            const alt = (root.dnd ? "dnd-" : "") + (n > 0 ? "notification" : "none");
            stateFile.setText(JSON.stringify({
                text: n > 0 ? String(n) : "",
                alt: alt,
                class: alt,
                tooltip: (n > 0 ? n + (n === 1 ? " notification" : " notifications") : "No notifications") + (root.dnd ? " · Do Not Disturb" : "")
            }) + "\n");
            signalWaybar.running = true;
        }
    }

    FileView {
        id: stateFile
        // Directory is created by dashboard-launch before quickshell starts.
        path: Quickshell.env("HOME") + "/.cache/dashboard/notify.json"
        printErrors: false
    }

    Process {
        id: signalWaybar
        command: ["pkill", "-RTMIN+7", ".waybar-wrapped"]
    }

    // Write once at startup so the pill has a value before the first
    // notification ever arrives (waybar reads the file on its `once` exec).
    Component.onCompleted: sync.restart()
}
