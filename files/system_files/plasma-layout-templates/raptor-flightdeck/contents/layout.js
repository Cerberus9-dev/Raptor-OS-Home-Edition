// Raptor Flight Deck panel preset for KDE Plasma 6.
// Adds a new panel without deleting or modifying the user's existing panels.
var panel = new Panel;
panel.location = "bottom";
panel.alignment = "center";
panel.lengthMode = "fit";
panel.height = Math.round(gridUnit * 3.2);
panel.hiding = "dodgewindows";

var available = knownWidgetTypes;
var addIfAvailable = function (pluginId) {
    if (available.includes(pluginId)) {
        panel.addWidget(pluginId);
    }
};

// Keep the panel familiar and functional: app launcher, virtual desktops,
// running applications, system tray and clock. No third-party widget required.
addIfAvailable("org.kde.plasma.kickoff");
addIfAvailable("org.kde.plasma.pager");
addIfAvailable("org.kde.plasma.taskmanager");
addIfAvailable("org.kde.plasma.systemtray");
addIfAvailable("org.kde.plasma.digitalclock");
