// nixos/config/home/dashboard/qml/Theme.qml
//
// The live palette, as individual color properties rather than one `var`
// object: QML re-evaluates a binding on `Theme.hi` only when `hi` itself
// changes, whereas a binding on `Theme.obj.hi` re-runs every time any key
// in the object changes. With ~60 color bindings on screen at once that is
// the difference between a repaint of one tile and a repaint of the panel.
//
// Source is ~/.cache/theme/dashboard.json (theme/apps/dashboard.nix renders
// it; matugen rewrites it on wallpaper change). `watchChanges` means the
// panel re-colors live with no reload and no signal — which is why, unlike
// swaync, nothing in theme-render needs to nudge this process.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // Fallback tokyo-night values so nothing renders with undefined colors
    // in the window between process start and the first FileView load.
    property color bg: "#1a1b26"
    property color surface: "#16161e"
    property color overlay: "#2f3549"
    property color muted: "#444b6a"
    property color subtle: "#787c99"
    property color fg: "#a9b1d6"
    property color red: "#c0caf5"
    property color orange: "#a9b1d6"
    property color yellow: "#0db9d7"
    property color green: "#9ece6a"
    property color cyan: "#b4f9f8"
    property color blue: "#2ac3de"
    property color magenta: "#bb9af7"
    property color txt: "#a9b1d6"
    property color hi: "#2ac3de"
    property color ok: "#9ece6a"
    property color warn: "#0db9d7"
    property color crit: "#c0caf5"

    // Tint helper — the JSON carries flat colors only (see apps/dashboard.nix),
    // so every translucent surface in the panel is derived here instead.
    function alpha(c: color, a: real): color {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    // Green → yellow → red for a 0..1 utilisation figure. One place, so every
    // meter in SystemView grades on the same thresholds.
    function grade(v: real): color {
        return v >= 0.9 ? root.crit : v >= 0.75 ? root.warn : root.ok;
    }

    FileView {
        path: Quickshell.env("HOME") + "/.cache/theme/dashboard.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            let j;
            try {
                j = JSON.parse(text());
            } catch (e) {
                console.warn("dashboard: failed to parse theme json:", e);
                return;
            }
            for (const k in j) {
                if (root.hasOwnProperty(k))
                    root[k] = j[k];
            }
        }
    }
}
