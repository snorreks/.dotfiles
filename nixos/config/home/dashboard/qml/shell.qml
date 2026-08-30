// nixos/config/home/dashboard/qml/shell.qml
//
// Entry point. Deliberately thin: state + IPC + the three windows. Everything
// with substance lives in a sibling file (Quickshell auto-registers both plain
// components and `pragma Singleton` files from this directory by name, so no
// qmldir and no imports between them are needed).
//
// This shell owns org.freedesktop.Notifications — it replaced swaync outright,
// because two daemons cannot share that bus name and merging the drawer with
// the control center means owning it. See Notifs.qml.
//
// Screen policy, unchanged from the original panel: Quickshell.screens[0] only,
// never `Variants { model: Quickshell.screens }`. Per-monitor instantiation is
// the exact cost this setup exists to avoid — legion drives 3 monitors.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    // ── IPC ───────────────────────────────────────────────────────────────
    // `toggle` cannot be called `show`/`hide`: those collide with `ipc`'s own
    // subcommand names ("qs ipc show" lists targets) and the CLI parser
    // resolves the ambiguity by running the wrong thing — `ipc call dash show`
    // silently no-ops instead of calling the handler. Confirmed live on 0.3.0.
    // `open`, `close`, `tab` and `dnd` don't collide.
    IpcHandler {
        target: "dash"

        function toggle(): void {
            if (drawer.active)
                drawer.close();
            else
                drawer.open("");
        }

        // `qs -c dashboard ipc call dash open notifications`
        function open(view: string): void {
            drawer.open(view);
        }

        function close(): void {
            drawer.close();
        }

        // Switch view without changing whether the panel is up.
        function tab(view: string): void {
            drawer.view = view;
        }

        function dnd(): void {
            Notifs.toggleDnd();
        }
    }

    // Click-away target, mapped only while the drawer is up.
    Scrim {
        visible: drawer.active
        onClicked: drawer.close()
    }

    Drawer {
        id: drawer
    }

    Toasts {
        // Suppressed whenever the drawer is up, not just on the Alerts tab:
        // both surfaces anchor to the same top-right corner, so a toast lands
        // squarely on the drawer's header and covers the tab bar. If the panel
        // is open you are already looking at it — the notification is one tab
        // away and the bell count has already moved.
        suppressed: drawer.active
    }

    // Everything with a running cost is gated on what is actually on screen:
    // an open Home tab must not cost a `dashboard-stats` spawn every 3s, and a
    // closed panel must cost nothing at all. With the drawer shut this process
    // holds no subprocesses and no timers — only its D-Bus subscriptions.
    Binding {
        target: Sys
        property: "drawerActive"
        value: drawer.active
    }
    Binding {
        target: Sys
        property: "statsActive"
        value: drawer.active && drawer.view === "system"
    }
    Binding {
        target: Sys
        property: "togglesActive"
        value: drawer.active && drawer.view === "home"
    }
    Binding {
        target: Notifs
        property: "listVisible"
        value: drawer.active && drawer.view === "notifications"
    }
}
