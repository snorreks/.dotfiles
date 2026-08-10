# nixos/config/home/theme/apps/pcmanfm.nix
#
# pcmanfm-qt QSS stylesheet — full Fusion styling from the palette.
{lib}: {
  mkPcmanfmQss = c: ''    /* Global Base Styling for all Qt Widgets */
    QWidget {
      background-color: #${c.base00};
      color: #${c.base05};
    }

    /* Main Window & View Background */
    QMainWindow, QDialog, Fm--MainView, Fm--FolderView {
      background-color: #${c.base00};
      color: #${c.base05};
    }

    /* Menu Bar at the very top */
    QMenuBar {
      background-color: #${c.base00};
      color: #${c.base05};
      border-bottom: 1px solid #${c.base01};
    }

    QMenuBar::item {
      background-color: transparent;
      color: #${c.base05};
      padding: 4px 8px;
      border-radius: 4px;
    }

    QMenuBar::item:selected {
      background-color: #${c.base02};
      color: #${c.base0D};
    }

    /* Toolbars & Path / Breadcrumbs */
    QToolBar {
      background-color: #${c.base01};
      border-bottom: 1px solid #${c.base02};
      spacing: 4px;
      padding: 2px;
    }

    QToolButton {
      background-color: transparent;
      color: #${c.base05};
      border: 1px solid transparent;
      border-radius: 4px;
      padding: 3px 6px;
    }

    QToolButton:hover {
      background-color: #${c.base02};
      border: 1px solid #${c.base02};
    }

    QToolButton:checked, QToolButton:pressed {
      background-color: #${c.base02};
      color: #${c.base0D};
    }

    /* Dropdowns / ComboBoxes (e.g., View Mode Selector) */
    QComboBox {
      background-color: #${c.base00};
      color: #${c.base05};
      border: 1px solid #${c.base02};
      border-radius: 4px;
      padding: 3px 8px;
    }

    QComboBox:hover {
      border: 1px solid #${c.base0D};
    }

    QComboBox::drop-down {
      border: none;
    }

    QComboBox QAbstractItemView {
      background-color: #${c.base01};
      color: #${c.base05};
      border: 1px solid #${c.base02};
      selection-background-color: #${c.base02};
      selection-color: #${c.base0D};
    }

    /* Tab Bar */
    QTabBar {
      background-color: #${c.base01};
    }

    QTabBar::tab {
      background-color: #${c.base01};
      color: #${c.base04};
      padding: 6px 12px;
      border-top-left-radius: 4px;
      border-top-right-radius: 4px;
      margin-right: 2px;
    }

    QTabBar::tab:selected {
      background-color: #${c.base00};
      color: #${c.base05};
      border-bottom: 2px solid #${c.base0D};
    }

    QTabBar::tab:hover:!selected {
      background-color: #${c.base02};
    }

    /* Location Bar Input */
    QLineEdit {
      background-color: #${c.base00};
      color: #${c.base05};
      border: 1px solid #${c.base02};
      border-radius: 6px;
      padding: 4px 8px;
      selection-background-color: #${c.base0D};
    }

    QLineEdit:focus {
      border: 1px solid #${c.base0D};
    }

    /* Side Pane (Places / Bookmarks / Devices) */
    Fm--SidePane, QDockWidget {
      background-color: #${c.base01};
      color: #${c.base05};
      border-right: 1px solid #${c.base02};
    }

    /* File List & Icon Grid View */
    QTreeView, QListView, QColumnView {
      background-color: #${c.base00};
      color: #${c.base05};
      border: none;
    }

    QTreeView::item:selected, QListView::item:selected {
      background-color: #${c.base02};
      color: #${c.base0D};
      border-radius: 4px;
    }

    QHeaderView::section {
      background-color: #${c.base01};
      color: #${c.base05};
      padding: 4px;
      border: none;
      border-right: 1px solid #${c.base02};
      border-bottom: 1px solid #${c.base02};
    }

    /* Right-Click Context Menus */
    QMenu {
      background-color: #${c.base01};
      color: #${c.base05};
      border: 1px solid #${c.base02};
      border-radius: 8px;
      padding: 4px;
    }

    QMenu::item {
      padding: 6px 20px 6px 10px;
      border-radius: 4px;
    }

    QMenu::item:selected {
      background-color: #${c.base02};
      color: #${c.base0D};
    }

    /* Scrollbars */
    QScrollBar:vertical, QScrollBar:horizontal {
      background: #${c.base00};
      width: 8px;
      height: 8px;
      border: none;
    }

    QScrollBar::handle:vertical, QScrollBar::handle:horizontal {
      background: #${c.base02};
      border-radius: 4px;
      min-height: 20px;
    }

    /* Status Bar at Bottom */
    QStatusBar {
      background-color: #${c.base01};
      color: #${c.base05};
      border-top: 1px solid #${c.base02};
    }
  '';
}
