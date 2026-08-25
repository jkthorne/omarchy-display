# jack.display

Omarchy bar widget that combines the stock Display panel (brightness, text size, scale) with [hyprmoncfg](https://hyprmoncfg.dev/) multi-monitor layouts in one icon.

A clone of `omarchy.monitor`, so `SUPER + CTRL + D` still opens it.

## Install

```sh
omarchy plugin add https://github.com/jkthorne/omarchy-display.git --enable
```

Enabling replaces the stock Display widget (`omarchy.monitor`) on the bar. It does not rewrite your Hyprland config or hyprmoncfg profiles until you turn on **Managed by hyprmoncfg** in the panel.

If hyprmoncfg is missing, open the panel and choose **Install hyprmoncfg**. That uses Omarchy's presented terminal; the plugin never requests privileges inside `omarchy-shell`.

## Remove

Hand displays back to Omarchy first if hyprmoncfg is managing, then remove the plugin:

```sh
hyprmoncfg unmanage
omarchy plugin remove jack.display
```

Removing the plugin restores the stock Display widget. Saved hyprmoncfg profiles stay on disk. Uninstall the `hyprmoncfg` package separately if you are done with it.

## What it does

- Brightness slider and wheel on the bar icon
- Text size
- Scale pills for the focused monitor (writes into hyprmoncfg when that daemon owns the displays)
- Live layout canvas and profile status from hyprmoncfg
- Manage / unmanage automatic switching on hotplug and lid events
- Opens the hyprmoncfg TUI for arrangement, colour, mirroring, and workspaces

When hyprmoncfg is managing, the simple DISPLAYS on/off list is hidden so it cannot fight the generated layout.

## Dependencies

- [Omarchy](https://omarchy.org) Quattro with third-party shell plugins
- Optional: [hyprmoncfg](https://hyprmoncfg.dev/) 1.15.0 or newer (installed from the panel when missing)

hyprmoncfg is a separate AUR package with its own daemon (`hyprmoncfgd`). This plugin talks to it over a local socket and launches `hyprmoncfg-omarchy` for the layout editor.

## License

[MIT](LICENSE). The panel is derived from Omarchy's Display widget and from [crmne/omarchy-hyprmoncfg](https://github.com/crmne/omarchy-hyprmoncfg).

## Develop

```sh
omarchy plugin validate .
node --test tests/*.js
```
