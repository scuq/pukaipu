from libqtile import bar, layout, widget, hook, qtile
from libqtile.config import Key, Group, Match, Screen
from libqtile.lazy import lazy
import os
import shlex
import time

mod = "control"

# --- cyberpunk palette ---
BG = "#0b0f14"
FG = "#d6deeb"
DIM = "#52606d"
PINK = "#ff2bd6"
GREEN = "#00ff9a"

# ---------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------
groups = [
    Group("1", label="1", matches=[Match(wm_class="brave-browser"), Match(wm_class="Brave-browser")]),
    Group("2", label="2"),
    Group("3", label="3"),
    Group("4", label="4"),
]

# ---------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------
keys = [
    Key([mod], "d", lazy.spawn("rofi -show drun -theme ~/.config/rofi/theme.rasi")),
    Key([mod], "Return", lazy.spawn("kitty")),

    Key([mod], "q", lazy.window.kill()),
    Key([mod, "shift"], "r", lazy.restart()),
    Key([mod, "shift"], "q", lazy.shutdown()),

    Key([mod], "space", lazy.next_layout()),

    Key([mod, "shift"], "Left", lazy.screen.prev_group()),
    Key([mod, "shift"], "Right", lazy.screen.next_group()),
]

for g in groups:
    keys.append(Key([mod], g.name, lazy.group[g.name].toscreen()))
    keys.append(Key([mod, "shift"], g.name, lazy.window.togroup(g.name)))

# ---------------------------------------------------------------------
# Layouts
# ---------------------------------------------------------------------
layouts = [
    layout.MonadTall(border_width=2, margin=6),
    layout.Max(),
]

# ---------------------------------------------------------------------
# Bar
# ---------------------------------------------------------------------
screens = [
    Screen(
        top=bar.Bar(
            [
                widget.GroupBox(
                    disable_drag=True,
                    background=BG,
                    foreground=FG,
                    active=FG,
                    inactive=DIM,
                    highlight_method="line",
                    this_current_screen_border=PINK,
                    this_screen_border=GREEN,
                    other_current_screen_border=GREEN,
                    other_screen_border=DIM,
                    urgent_border=PINK,
                    fontsize=12,
                    padding=3,
                ),
                widget.Spacer(background=BG),
                widget.WindowName(background=BG, foreground=FG, max_chars=80),
                widget.Spacer(background=BG),
                widget.Clock(format="%H:%M", background=BG, foreground=GREEN),
            ],
            26,
            background=BG,
            margin=[6, 6, 0, 6],
            border_width=[0, 0, 2, 0],
            border_color=PINK,
        )
    )
]

# ---------------------------------------------------------------------
# Deterministic kitty placement via queue (no startup races)
# ---------------------------------------------------------------------
KITTY_TARGET_GROUPS = ["2", "2", "3", "4"]

@hook.subscribe.client_new
def place_initial_kitties(c):
    global KITTY_TARGET_GROUPS

    wm = c.get_wm_class() or []
    wm_l = [x.lower() for x in wm]

    # Only intercept kitty windows, and only while we still have targets queued.
    if "kitty" in wm_l and KITTY_TARGET_GROUPS:
        target = KITTY_TARGET_GROUPS.pop(0)
        c.togroup(target, switch_group=False)

@hook.subscribe.startup_complete
def autostart():
    # Start Brave on group 1 (Match rule pins it there)
    brave_url = os.environ.get("BRAVE_URL", "https://example.com")
    brave_args = os.environ.get(
        "BRAVE_ARGS",
        "--disable-dev-shm-usage --no-first-run --disable-features=Translate",
    )

    brave_cmd = "brave-browser " + " ".join(
        shlex.quote(x) for x in (shlex.split(brave_args) + [brave_url])
    )
    qtile.cmd_spawn(brave_cmd)

    # Spawn 4 kitty windows; the client_new hook will distribute them: 2,2,3,4
    # (stagger slightly so Xpra/Qtile startup stays smooth)
    qtile.call_later(0.8, lambda: qtile.cmd_spawn("kitty"))
    qtile.call_later(1.0, lambda: qtile.cmd_spawn("kitty"))
    qtile.call_later(1.2, lambda: qtile.cmd_spawn("kitty"))
    qtile.call_later(1.4, lambda: qtile.cmd_spawn("kitty"))

    # Keep you on group 1
    qtile.call_later(1.6, lambda: qtile.cmd_set_group("1"))

wmname = "LG3D"
