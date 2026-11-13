-- Copper Linux -- the Hyprland session configuration.
--
-- Hyprland 0.57 loads its config as Lua from hyprland.lua, not from the old
-- hyprland.conf; a .conf sitting beside this file is ignored entirely. Seeded
-- into ~/.config/hypr/hyprland.lua by starthyprland: the copy in your home is
-- yours, and the shipped copy under /usr/share/copper/hyprland-skel is only read
-- to fill in files that are missing.
--
-- Copper's identity is copper #B87333 on slate #0F172A, carried through the
-- active border, the focus ring and the bar.

-- ---------------------------------------------------------------------
-- Monitors
-- ---------------------------------------------------------------------
-- Left automatic on purpose: Hyprland asks the DRM/KMS backend what is plugged
-- in, so a fixed layout would fight a machine with a different screen count.
hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "auto",
})

-- ---------------------------------------------------------------------
-- The programs this session launches
-- ---------------------------------------------------------------------
local terminal    = "kitty"
local fileManager = "thunar"
local menu        = "fuzzel"

-- ---------------------------------------------------------------------
-- Autostart
-- ---------------------------------------------------------------------
-- Everything the session needs, in order. The compositor starts children with
-- the session's environment, so these inherit the bus, the runtime directory
-- and the Wayland display.
hl.on("hyprland.start", function()
    hl.exec_cmd("hyprpaper")
    hl.exec_cmd("waybar")
    hl.exec_cmd("dunst")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("hyprpolkitagent")
end)

-- ---------------------------------------------------------------------
-- Environment
-- ---------------------------------------------------------------------
hl.env("XCURSOR_SIZE", "24")

-- ---------------------------------------------------------------------
-- Look and feel
-- ---------------------------------------------------------------------
hl.config({
    general = {
        gaps_in     = 6,
        gaps_out    = 12,
        border_size = 1,

        col = {
            active_border   = "rgba(b87333ee)",
            inactive_border = "rgba(3b4261aa)",
        },

        -- Dragging on a border or gap resizes without reaching for the corner.
        resize_on_border = true,

        -- Tearing is a niche win and a visible artifact elsewhere; the image has
        -- no display server tuned for it, so leave it off.
        allow_tearing = false,

        layout = "dwindle",
    },

    decoration = {
        rounding       = 8,
        rounding_power = 2,

        active_opacity   = 1.0,
        inactive_opacity = 0.94,

        shadow = {
            enabled      = true,
            range        = 6,
            render_power = 3,
            color        = 0x66000000,
        },

        blur = {
            enabled  = true,
            size     = 3,
            passes   = 2,
            vibrancy = 0.16,
        },
    },

    animations = {
        enabled = true,
    },
})

-- ---------------------------------------------------------------------
-- Motion
-- ---------------------------------------------------------------------
-- Curves and springs. These are the ones the animations below name. They are
-- declared here rather than assumed: a missing curve is reported against the
-- animation that uses it, not silently replaced with a default.
hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1}    } })
hl.curve("almostLinear", { type = "bezier", points = { {0.5, 0.5}, {0.75, 1}   } })
hl.curve("easy",         { type = "spring", mass = 1, stiffness = 238.1191,
                                             damping = 24.21279333            })

-- Gently slower than the defaults: windows and workspaces settle rather than
-- snap. Speeds are the multipliers Hyprland applies to the named curve or
-- spring above.
hl.animation({ leaf = "global",     enabled = true, speed = 10,  bezier = "default" })
hl.animation({ leaf = "border",     enabled = true, speed = 5,   bezier = "easeOutQuint" })
hl.animation({ leaf = "windows",    enabled = true, speed = 4.2, spring = "easy" })
hl.animation({ leaf = "windowsIn",  enabled = true, speed = 3.6, spring = "easy", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.4, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 1.7, bezier = "almostLinear", style = "fade" })

hl.config({
    dwindle = { preserve_split = true },
    master  = { new_status = "master" },
})

-- ---------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------
hl.config({
    input = {
        kb_layout  = "us",
        kb_variant = "",
        kb_model   = "",
        kb_options = "",

        follow_mouse = 1,
        sensitivity  = 0,

        numlock_by_default = true,

        touchpad = {
            natural_scroll       = false,
            disable_while_typing = true,
        },
    },
})

-- A three-finger horizontal swipe moves between workspaces.
hl.gesture({
    fingers   = 3,
    direction = "horizontal",
    action    = "workspace",
})

-- ---------------------------------------------------------------------
-- Misc
-- ---------------------------------------------------------------------
hl.config({
    misc = {
        -- No anime mascot wallpaper behind hyprpaper, no logo on empty outputs.
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
    },
})

-- ---------------------------------------------------------------------
-- Key bindings
-- ---------------------------------------------------------------------
local mainMod = "SUPER"

hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + D",      hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + E",      hl.dsp.exec_cmd(fileManager))

hl.bind(mainMod .. " + Q",     hl.dsp.window.close())
hl.bind(mainMod .. " + V",     hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + F",     hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))

hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))

hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"))

-- Workspaces 1-9, and moving the focused window to one.
for i = 1, 9 do
    hl.bind(mainMod .. " + " .. i,         hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end

-- Scroll across existing workspaces.
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Move and resize by dragging with the modifier held.
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Leave, and reload without leaving.
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("hyprctl dispatch exit"))
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd("hyprctl reload"))

-- Laptop multimedia keys.
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1+ -l 1.0"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.1-"),         { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),        { locked = true, repeating = true })
hl.bind("XF86MonBrightnessUp",  hl.dsp.exec_cmd("brightnessctl set +10%"),                            { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 10%-"),                           { locked = true, repeating = true })
