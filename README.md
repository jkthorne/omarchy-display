# jack.display

Omarchy bar widget that combines the stock Display panel (brightness, text size, scale) with [hyprmoncfg](https://hyprmoncfg.dev/) multi-monitor layouts in one icon.

A clone of `omarchy.monitor`, so `SUPER + CTRL + D` still opens it.

## Install

```sh
omarchy plugin add https://github.com/jkthorne/omarchy-display.git --enable
```

If hyprmoncfg is missing, open the panel and choose **Install hyprmoncfg**.

## What it does

- Brightness slider and wheel on the bar icon
- Text size
- Scale pills for the focused monitor (writes into hyprmoncfg when that daemon owns the displays)
- Live layout canvas and profile status from hyprmoncfg
- Manage / unmanage automatic switching on hotplug and lid events
- Opens the hyprmoncfg TUI for arrangement, colour, mirroring, and workspaces

When hyprmoncfg is managing, the simple DISPLAYS on/off list is hidden so it cannot fight the generated layout.

## Develop

```sh
omarchy plugin validate .
node --test tests/*.js
```
