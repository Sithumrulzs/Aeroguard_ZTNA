"""
AeroGuard ZTNA - Secure Terminal v5.0
Pure terminal interface - type commands, see results.
Polls the gateway for a live, granted laptop session — never listens
for an inbound trigger, so there is nothing for another device on the
LAN to fake.
"""

import tkinter as tk
from tkinter import scrolledtext
import tkinter.font as tkfont
import threading, sqlite3, os, sys, datetime, webbrowser, time, math
import urllib.request, urllib.error, json, secrets, socket, uuid
import pystray
import qrcode
from PIL import Image, ImageTk, ImageDraw, ImageFilter

# ══════════════════════════════════════════════════
#  CONFIG
# ══════════════════════════════════════════════════
GATEWAY_HOST          = "192.168.100.130"
GATEWAY_PORT          = 8000
TERMINAL_SESSION_URL  = f"http://{GATEWAY_HOST}:{GATEWAY_PORT}/api/v1/terminal-session"
POLL_INTERVAL_SECONDS = 3
REVOKE_MISS_THRESHOLD = 3   # consecutive failed polls before treating as a real revoke
FIDS_HOST            = "127.0.0.1"
FIDS_PORT            = 5000
FIDS_URL             = f"http://{FIDS_HOST}:{FIDS_PORT}"

# This exe is identical for every vendor — it never knows in advance which
# session it belongs to. CENTRAL_AUTH is the always-reachable cloud broker
# that links this device's self-reported identity to a vendor's session the
# moment they scan the QR this exe generates, no typing, no per-vendor build.
CENTRAL_AUTH_URL       = "https://aeroguard-ztna.onrender.com"
REGISTER_PAIRING_URL   = f"{CENTRAL_AUTH_URL}/api/v1/device/register-pairing"
IS_ADMIN_LAPTOP_URL    = f"{CENTRAL_AUTH_URL}/api/v1/device/is-admin-laptop"

_here = os.path.dirname(os.path.abspath(sys.argv[0]))
DB_CANDIDATES = [
    os.path.join(_here, "airport_system.db"),
    os.path.join(_here, "..", "airport_system.db"),
    os.path.join(_here, "fids", "airport_system.db"),
]
DB_PATH = next((p for p in DB_CANDIDATES if os.path.exists(p)), DB_CANDIDATES[0])

def resource_path(rel_path):
    """Resolve bundled assets — works both as a script and as a PyInstaller exe."""
    base = getattr(sys, "_MEIPASS", _here)
    return os.path.join(base, rel_path)

ICON_PNG = resource_path(os.path.join("assets", "aeroguard_icon.png"))
ICON_ICO = resource_path(os.path.join("assets", "aeroguard.ico"))

# ══════════════════════════════════════════════════
#  THEME  -  matches aeroguard_app/lib/main.dart ColorScheme
#  primary cyan #00C3FF, near-black bg, status colours from
#  the Flutter dashboard's live indicator palette.
# ══════════════════════════════════════════════════
BG        = "#0A0A0A"        # ThemeData.scaffoldBackgroundColor
BAR_BG    = "#0D1421"        # dashboard_panel.dart card background
FG        = "#00C3FF"        # ColorScheme.primary
FG_DIM    = "#94A3B8"        # dashboard_panel.dart secondary text
FG_CYAN   = "#00C3FF"
FG_YELLOW = "#F59E0B"        # amber — admin_dashboard warn accent
FG_RED    = "#EF4444"        # admin_dashboard error accent
FG_ORANGE = "#F59E0B"
FG_GREEN  = "#10B981"        # admin_dashboard "secured/online" accent
FG_WHITE  = "#FFFFFF"
FG_HEADER = "#00C3FF"
CURSOR    = "#00C3FF"
SELECT_BG = "#0D2A3D"

# Output area stays monospace (column alignment matters for tables);
# chrome — headers, badges, buttons, splash windows — uses a clean sans,
# matching the mobile app's typography instead of a typewriter look.
MONO      = "Consolas"
SANS      = "Segoe UI"
FONT      = (MONO, 12)
FONT_B    = (MONO, 12, "bold")
FONT_LG   = (MONO, 14, "bold")
UI_FONT   = (SANS, 11)
UI_FONT_B = (SANS, 11, "bold")
UI_FONT_LG = (SANS, 16, "bold")

# Matches the exact gradient used on aeroguard_app's sign-in/load screens.
GRADIENT_TOP    = "#050810"
GRADIENT_BOTTOM = "#0A1628"

def _hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def _lerp_color(c1, c2, t):
    r1, g1, b1 = _hex_to_rgb(c1)
    r2, g2, b2 = _hex_to_rgb(c2)
    return "#%02x%02x%02x" % (
        int(r1 + (r2 - r1) * t), int(g1 + (g2 - g1) * t), int(b1 + (b2 - b1) * t))

def draw_vertical_gradient(canvas, width, height, top_color, bottom_color):
    for y in range(height):
        canvas.create_line(0, y, width, y, fill=_lerp_color(top_color, bottom_color, y / height))

def _measure(font, text):
    return tkfont.Font(font=font).measure(text)

def draw_rounded_rect(canvas, x1, y1, x2, y2, r, **kwargs):
    points = [
        x1 + r, y1,  x2 - r, y1,  x2, y1,  x2, y1 + r,
        x2, y2 - r,  x2, y2,  x2 - r, y2,  x1 + r, y2,
        x1, y2,  x1, y2 - r,  x1, y1 + r,  x1, y1,
    ]
    return canvas.create_polygon(points, smooth=True, **kwargs)

# ══════════════════════════════════════════════════
#  REAL BLUR RENDERING  -  Tkinter's canvas has no native blur/shadow,
#  so true glassmorphism (soft drop shadows, frosted tint, a logo that
#  glows rather than just changing a flat fill) is pre-rendered with
#  Pillow at 2x and downscaled — actual Gaussian blur, not a fake.
# ══════════════════════════════════════════════════
def make_background(width, height, top_color, bottom_color, accent_color):
    """The window backdrop — a smoothly supersampled gradient with soft
    blurred color blobs bleeding through, the actual source of a 'glass'
    look (real translucency blended at render time against this, not a
    window-level alpha that would also wash out the text on top)."""
    scale = 2
    w, h = width * scale, height * scale
    top, bottom = _hex_to_rgb(top_color), _hex_to_rgb(bottom_color)
    grad = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    img = grad.resize((w, h)).convert("RGBA")

    blobs = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    r, g, b = _hex_to_rgb(accent_color)
    bd = ImageDraw.Draw(blobs)
    bd.ellipse([w * 0.50, -h * 0.05, w * 1.05, h * 0.38], fill=(r, g, b, 100))
    bd.ellipse([-w * 0.30, h * 0.62, w * 0.28, h * 1.10], fill=(r, g, b, 75))
    blobs = blobs.filter(ImageFilter.GaussianBlur(w * 0.07))
    img.alpha_composite(blobs)

    return img.resize((width, height), Image.LANCZOS)

def make_glass_card(width, height, radius, tint_rgba, shadow_alpha=110, blur=16):
    """A rounded glass panel with a real soft drop shadow and a faint
    bright top-edge highlight, composited as one image."""
    scale = 2
    w, h = width * scale, height * scale
    r = radius * scale
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [scale * 2, scale * 8, w - scale * 2, h - scale * 2], radius=r,
        fill=(0, 0, 0, shadow_alpha))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur * scale / 2))
    out.alpha_composite(shadow)

    card = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(card).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=tint_rgba)
    out.alpha_composite(card)

    highlight = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(highlight).rounded_rectangle(
        [scale, scale, w - scale, h - scale], radius=r,
        outline=(255, 255, 255, 50), width=scale * 2)
    out.alpha_composite(highlight)

    return out.resize((width, height), Image.LANCZOS)

def make_shadow_strip(width, height=14):
    """A soft horizontal drop shadow — used under the terminal's header
    bar so it reads as a glass panel floating above the content instead
    of a flat colored rectangle with a hard line under it."""
    scale = 2
    w, h = max(int(width * scale), 2), height * scale
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(img).rectangle([0, 0, w, h * 0.4], fill=(0, 0, 0, 90))
    img = img.filter(ImageFilter.GaussianBlur(h * 0.18))
    return img.resize((max(int(width), 1), height), Image.LANCZOS)

def make_logo_glow(size, pulse_color, intensity, logo_img=None, ripple_phase=0.0):
    """One composited image: a soft core glow plus real blurred ripple
    rings that continuously expand outward and fade — like a sonar ping
    rendered with actual Gaussian blur instead of hard canvas outlines —
    with the crisp logo centered on top. Regenerated each frame so the
    glow and ripples animate while the logo itself never moves, resizes,
    or distorts."""
    scale = 2
    big = size * scale
    cx = cy = big / 2
    out = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    r, g, b = _hex_to_rgb(pulse_color)

    # Steady core glow — the logo's constant soft presence.
    glow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    alpha = int(90 + intensity * 110)
    gr = big * 0.27
    ImageDraw.Draw(glow).ellipse([cx - gr, cy - gr, cx + gr, cy + gr],
                                  fill=(r, g, b, alpha))
    glow = glow.filter(ImageFilter.GaussianBlur(big * 0.07))
    out.alpha_composite(glow)

    # Two staggered ripple rings, continuously expanding and fading —
    # drawn as a real ring (not filled) then blurred for a soft glowing
    # edge instead of a crisp outline.
    rings = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rings)
    r_min, r_max = big * 0.24, big * 0.50
    ring_w = max(int(big * 0.045), 3)
    for offset in (0.0, 0.5):
        phase  = (ripple_phase + offset) % 1.0
        radius = r_min + phase * (r_max - r_min)
        fade   = 1.0 - phase
        ring_alpha = int(fade * 215)
        if ring_alpha > 2:
            rd.ellipse([cx - radius, cy - radius, cx + radius, cy + radius],
                       outline=(r, g, b, ring_alpha), width=ring_w)
    rings = rings.filter(ImageFilter.GaussianBlur(big * 0.028))
    out.alpha_composite(rings)

    if logo_img is not None:
        logo = logo_img.copy()
        logo.thumbnail((int(big * 0.34), int(big * 0.34)), Image.LANCZOS)
        out.alpha_composite(logo, (int(cx - logo.width / 2), int(cy - logo.height / 2)))

    return out.resize((size, size), Image.LANCZOS)

# ══════════════════════════════════════════════════
#  DB + FIDS HELPERS
# ══════════════════════════════════════════════════
def db_query(sql, params=()):
    if not os.path.exists(DB_PATH):
        return None, f"Database not found: {DB_PATH}"
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(sql, params).fetchall()
        conn.close()
        return [dict(r) for r in rows], None
    except Exception as e:
        return None, str(e)

def fids_get(endpoint):
    try:
        req = urllib.request.urlopen(f"{FIDS_URL}{endpoint}", timeout=4)
        return json.loads(req.read().decode()), None
    except urllib.error.URLError as e:
        return None, f"FIDS unreachable: {e.reason}"
    except Exception as e:
        return None, str(e)

def poll_session():
    """
    Active connectivity check — never a passive listener.
    Only succeeds once the sniffer has actually injected an INPUT ACCEPT
    rule for this machine's IP, so a successful response IS the proof
    of a real, granted session, not a trusted inbound message.
    """
    try:
        req = urllib.request.urlopen(TERMINAL_SESSION_URL, timeout=5)
        return json.loads(req.read().decode())
    except Exception:
        return None

def _own_mac():
    node = uuid.getnode()
    return ":".join(f"{(node >> shift) & 0xff:02x}" for shift in range(40, -1, -8))

def _own_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((GATEWAY_HOST, 1))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()

def is_admin_laptop():
    """
    Asks central_auth whether this machine's MAC is a pre-registered admin
    workstation. Admin access is granted purely by MAC resolution — no
    pairing involved — so a recognized admin laptop should never show a
    QR at all. Defaults to False (vendor-style fallback) on any failure,
    since failing to confirm admin status should never hide pairing UI
    that a vendor might actually need.
    """
    try:
        req = urllib.request.Request(
            f"{IS_ADMIN_LAPTOP_URL}?mac={_own_mac()}", method="GET")
        resp = urllib.request.urlopen(req, timeout=6)
        return bool(json.loads(resp.read().decode()).get("is_admin"))
    except Exception:
        return False

def register_pairing(pairing_code):
    """
    Self-report this machine's identity against a fresh pairing code —
    no vendor token involved. Over HTTPS to central_auth (cloud), reachable
    long before this laptop is anywhere near the gateway's LAN.
    """
    body = json.dumps({
        "pairing_code": pairing_code,
        "mac":          _own_mac(),
        "hostname":     socket.gethostname(),
        "local_ip":     _own_local_ip(),
    }).encode()
    req = urllib.request.Request(
        REGISTER_PAIRING_URL, data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        urllib.request.urlopen(req, timeout=8)
        return True
    except Exception as e:
        print(f"[-] Pairing registration failed: {e}")
        return False

# ══════════════════════════════════════════════════
#  TERMINAL
# ══════════════════════════════════════════════════
class AeroGuardTerminal:
    def __init__(self, root, session):
        self.root    = root
        self.session = session
        self.history     = []
        self.history_idx = -1

        self.root.title(f"AeroGuard ZTNA  |  {session['user']}")
        self.root.configure(bg=BG)
        self.root.geometry("1320x840")
        self.root.minsize(960, 600)
        try:
            self.root.iconbitmap(ICON_ICO)
        except Exception:
            pass
        self.root.protocol("WM_DELETE_WINDOW", self.root.withdraw)

        self._build_ui()
        self._boot()

    # ─────────────────────────────────────────────
    #  BUILD UI  -  just a terminal, nothing else
    # ─────────────────────────────────────────────
    def _build_ui(self):

        # ── STATUS BAR — glass pill badges, same visual language as the
        #    pairing window, instead of flat rectangular Label blocks ────
        header_h = 58
        bar = self.header_canvas = tk.Canvas(self.root, height=header_h,
                                              bg=BAR_BG, highlightthickness=0, bd=0)
        bar.pack(fill="x", side="top")
        cy = header_h / 2
        x = 16

        try:
            logo_src = Image.open(ICON_PNG).convert("RGBA")
            logo_src.thumbnail((28, 28), Image.LANCZOS)
            self._logo_img = ImageTk.PhotoImage(logo_src)
            bar.create_image(x + 14, cy, image=self._logo_img)
            x += 28 + 12
        except Exception:
            pass

        bar.create_text(x, cy, text="AeroGuard ZTNA", fill=FG_WHITE,
                         font=UI_FONT_B, anchor="w")
        x += _measure(UI_FONT_B, "AeroGuard ZTNA") + 18

        def _pill(text, fg, bg, min_w=0):
            nonlocal x
            w = max(_measure(UI_FONT_B, text) + 22, min_w)
            x1, x2 = x, x + w
            bg_id = draw_rounded_rect(bar, x1, cy - 13, x2, cy + 13, 13,
                                       fill=bg, outline="")
            txt_id = bar.create_text((x1 + x2) / 2, cy, text=text,
                                      fill=fg, font=UI_FONT_B)
            x = x2 + 6
            return bg_id, txt_id

        _pill(self.session["user"], BG, FG)
        _pill("GATEWAY OPEN", BG, FG_GREEN)

        # DB/FIDS badges share one fixed width (sized for their longest
        # possible text) so updating the status later never overflows
        # the pill — only fill/text change, the shape never needs to.
        badge_w = _measure(UI_FONT_B, "FIDS OFF") + 22
        self.db_bg,   self.db_txt   = _pill("DB --",   BG, FG_DIM, min_w=badge_w)
        self.fids_bg, self.fids_txt = _pill("FIDS --", BG, FG_DIM, min_w=badge_w)

        self.clock_text = bar.create_text(0, cy, text="", fill=FG_DIM,
                                           font=UI_FONT, anchor="e")
        bar.bind("<Configure>", self._on_header_resize)
        self._tick()

        # ── SEPARATOR — a real soft drop shadow so the header reads as a
        #    glass panel floating above the console, not a flat bar with
        #    a hard line under it. Regenerated whenever the window resizes.
        self.shadow_canvas = tk.Canvas(self.root, height=10, bg=BG,
                                        highlightthickness=0, bd=0)
        self.shadow_canvas.pack(fill="x")
        self.shadow_canvas.bind("<Configure>", self._on_shadow_resize)

        # ── OUTPUT AREA ─────────────────────────
        self.out = scrolledtext.ScrolledText(
            self.root,
            bg=BG, fg=FG,
            font=FONT,
            insertbackground=CURSOR,
            selectbackground=SELECT_BG,
            selectforeground=FG,
            relief="flat",
            state="disabled",
            wrap="none",
            bd=0,
            padx=10, pady=8,
        )
        self.out.pack(fill="both", expand=True)

        # colour tags
        self.out.tag_config("title",  foreground=FG,       font=FONT_LG)
        self.out.tag_config("sub",    foreground=FG_DIM,   font=FONT_B)
        self.out.tag_config("ok",     foreground=FG_GREEN)
        self.out.tag_config("err",    foreground=FG_RED)
        self.out.tag_config("warn",   foreground=FG_ORANGE)
        self.out.tag_config("info",   foreground=FG_CYAN)
        self.out.tag_config("dim",    foreground=FG_DIM)
        self.out.tag_config("prompt", foreground=FG,       font=FONT_B)
        self.out.tag_config("hdr",    foreground=FG_YELLOW,font=FONT_B)
        self.out.tag_config("white",  foreground=FG_WHITE)
        self.out.tag_config("cyan",   foreground=FG_CYAN)
        self.out.tag_config("sec",    foreground=FG,       font=FONT_B)

        # ── SEPARATOR ───────────────────────────
        tk.Frame(self.root, bg="#123247", height=2).pack(fill="x")

        # ── INPUT ROW ───────────────────────────
        inp = tk.Frame(self.root, bg=BG, pady=6)
        inp.pack(fill="x", side="bottom")

        tk.Label(inp, text=" aeroguard",
                 fg=FG, bg=BG, font=FONT_B).pack(side="left")
        tk.Label(inp, text=":~$ ",
                 fg=FG_YELLOW, bg=BG, font=FONT_B).pack(side="left")

        self.ivar = tk.StringVar()
        self.ibox = tk.Entry(
            inp, textvariable=self.ivar,
            bg=BG, fg=FG,
            insertbackground=CURSOR,
            font=FONT,
            relief="flat",
            highlightthickness=0, bd=0
        )
        self.ibox.pack(side="left", fill="x", expand=True, padx=(0, 10))
        self.ibox.bind("<Return>", self._enter)
        self.ibox.bind("<Up>",     self._hist_up)
        self.ibox.bind("<Down>",   self._hist_dn)
        self.ibox.focus_set()

    # ─────────────────────────────────────────────
    def _tick(self):
        self.header_canvas.itemconfig(
            self.clock_text,
            text=datetime.datetime.now().strftime("%Y-%m-%d  %H:%M:%S"))
        self.root.after(1000, self._tick)

    def _on_header_resize(self, event):
        self.header_canvas.coords(self.clock_text, event.width - 14,
                                   event.height / 2)

    def _on_shadow_resize(self, event):
        if event.width < 2:
            return
        img = make_shadow_strip(event.width, height=self.shadow_canvas.winfo_height() or 10)
        self._shadow_photo = ImageTk.PhotoImage(img)
        self.shadow_canvas.delete("all")
        self.shadow_canvas.create_image(0, 0, image=self._shadow_photo, anchor="nw")

    # ─────────────────────────────────────────────
    #  WRITE HELPERS
    # ─────────────────────────────────────────────
    def w(self, text, tag="ok"):
        self.out.config(state="normal")
        self.out.insert("end", text, tag)
        self.out.config(state="disabled")
        self.out.see("end")

    def wl(self, text="", tag="ok"):
        self.w(text + "\n", tag)

    def sep(self, char="-", n=90, tag="dim"):
        self.wl("  " + char * n, tag)

    # ─────────────────────────────────────────────
    #  BOOT
    # ─────────────────────────────────────────────
    def _boot(self):
        name = self.session["user"]
        self.wl()
        self.wl("  ============================================================", "dim")
        self.wl("   AEROGUARD ZTNA  --  SECURE TERMINAL  v5.0", "title")
        self.wl("   Zero Trust Network Access | Airport Infrastructure", "sub")
        self.wl("  ============================================================", "dim")
        self.wl()
        self.wl(f"   WELCOME, {name.upper()}", "title")
        self.wl(f"   This terminal session is uniquely bound to your verified identity.", "sub")
        self.wl()
        self.wl(f"  Session Time  : {self.session['time']}", "dim")
        self.wl(f"  Verified User : {name}", "ok")
        self.wl(f"  Client IP     : {self.session['ip']}", "dim")
        self.wl(f"  Auth Method   : Port-Knock ZTNA (no password required)", "dim")
        self.wl()

        # DB check
        db_ok = os.path.exists(DB_PATH)
        if db_ok:
            self.wl("  [DB]    airport_system.db ............. CONNECTED", "ok")
            self.root.after(0, lambda: (
                self.header_canvas.itemconfig(self.db_bg, fill=FG_GREEN),
                self.header_canvas.itemconfig(self.db_txt, text="DB OK")))
        else:
            self.wl(f"  [DB]    airport_system.db ............. NOT FOUND", "err")
            self.root.after(0, lambda: (
                self.header_canvas.itemconfig(self.db_bg, fill=FG_RED),
                self.header_canvas.itemconfig(self.db_txt, text="DB ERR")))

        # FIDS check async
        self.wl(f"  [FIDS]  Connecting to {FIDS_URL} ...", "dim")

        def _chk():
            data, err = fids_get("/api/summary")
            if data:
                self.root.after(0, lambda: (
                    self.wl("  [FIDS]  Dashboard ..................... ONLINE", "ok"),
                    self.header_canvas.itemconfig(self.fids_bg, fill=FG_GREEN),
                    self.header_canvas.itemconfig(self.fids_txt, text="FIDS OK"),
                    self.wl(),
                    self.wl("  Gateway is OPEN. Type  help  to see all commands.", "cyan"),
                    self.wl()
                ))
            else:
                self.root.after(0, lambda: (
                    self.wl("  [FIDS]  Dashboard ..................... OFFLINE", "warn"),
                    self.header_canvas.itemconfig(self.fids_bg, fill=FG_ORANGE),
                    self.header_canvas.itemconfig(self.fids_txt, text="FIDS OFF"),
                    self.wl(),
                    self.wl("  Gateway is OPEN. Type  help  to see all commands.", "cyan"),
                    self.wl()
                ))
        threading.Thread(target=_chk, daemon=True).start()

    # ─────────────────────────────────────────────
    #  REVOKE  -  called by TrayApp's poll loop, not a local one.
    # ─────────────────────────────────────────────
    def close_for_revoke(self):
        self.wl()
        self.wl("  [!] Session revoked or expired by gateway — closing terminal...", "err")

    # ─────────────────────────────────────────────
    #  INPUT HANDLING
    # ─────────────────────────────────────────────
    def _enter(self, _=None):
        cmd = self.ivar.get().strip()
        if not cmd:
            return
        self.ivar.set("")
        self.history.append(cmd)
        self.history_idx = len(self.history)
        self.wl(f"  aeroguard:~$ {cmd}", "prompt")
        self.wl()
        threading.Thread(target=self._process, args=(cmd,), daemon=True).start()

    def _hist_up(self, _):
        if self.history and self.history_idx > 0:
            self.history_idx -= 1
            self.ivar.set(self.history[self.history_idx])

    def _hist_dn(self, _):
        if self.history_idx < len(self.history) - 1:
            self.history_idx += 1
            self.ivar.set(self.history[self.history_idx])
        else:
            self.history_idx = len(self.history)
            self.ivar.set("")

    def _ui(self, fn):
        self.root.after(0, fn)

    # ─────────────────────────────────────────────
    #  COMMAND ROUTER
    # ─────────────────────────────────────────────
    def _process(self, raw):
        lo    = raw.strip().lower()
        parts = lo.split()
        cmd   = parts[0] if parts else ""
        args  = parts[1:]

        if cmd == "help":
            self._ui(self._help)
        elif cmd == "clear":
            self._ui(lambda: (
                self.out.config(state="normal"),
                self.out.delete("1.0", "end"),
                self.out.config(state="disabled"),
                self._boot()
            ))
        elif cmd == "whoami":
            self._ui(self._whoami)
        elif cmd == "status":
            threading.Thread(target=self._status, daemon=True).start()
        elif cmd in ("exit", "quit"):
            self._ui(lambda: (
                self.wl("  Closing terminal — AeroGuard remains active in the system tray.", "warn"),
                self.root.after(1000, self.root.withdraw)
            ))
        elif cmd == "flights":
            f = args[0] if args else None
            threading.Thread(target=self._flights, args=(f,), daemon=True).start()
        elif cmd == "flight" and args:
            threading.Thread(target=self._flight_detail,
                             args=(args[0].upper(),), daemon=True).start()
        elif cmd == "assets":
            f = args[0] if args else None
            threading.Thread(target=self._assets, args=(f,), daemon=True).start()
        elif cmd == "asset" and args:
            threading.Thread(target=self._asset_detail,
                             args=(args[0].upper(),), daemon=True).start()
        elif cmd == "staff":
            f = " ".join(args) if args else None
            threading.Thread(target=self._staff, args=(f,), daemon=True).start()
        elif cmd == "crew":
            f = args[0] if args else None
            threading.Thread(target=self._crew, args=(f,), daemon=True).start()
        elif cmd == "baggage":
            f = args[0] if args else None
            threading.Thread(target=self._baggage, args=(f,), daemon=True).start()
        elif lo in ("open fids", "fids open"):
            self._ui(self._open_fids)
        elif lo == "fids status":
            threading.Thread(target=self._fids_status, daemon=True).start()
        elif lo == "fids flights":
            threading.Thread(target=self._fids_flights, daemon=True).start()
        elif lo == "fids summary":
            threading.Thread(target=self._fids_summary, daemon=True).start()
        else:
            self._ui(lambda: (
                self.wl(f"  command not found: {raw}", "err"),
                self.wl("  type  help  to see available commands.", "dim"),
                self.wl()
            ))

    # ─────────────────────────────────────────────
    #  HELP
    # ─────────────────────────────────────────────
    def _help(self):
        self.wl("  AEROGUARD ZTNA  --  COMMAND REFERENCE", "sec")
        self.sep()
        sections = [
            ("SYSTEM", [
                ("status",           "Show system & connection status"),
                ("whoami",           "Show verified session info"),
                ("clear",            "Clear terminal"),
                ("exit",             "Close terminal"),
            ]),
            ("FLIGHTS", [
                ("flights",          "Show all flights"),
                ("flights boarding", "Show boarding flights"),
                ("flights delayed",  "Show delayed flights"),
                ("flight UL225",     "Show full detail for one flight"),
            ]),
            ("ASSETS", [
                ("assets",           "Show all infrastructure assets"),
                ("assets critical",  "Show critical assets only"),
                ("assets offline",   "Show offline assets"),
                ("asset AST-1001",   "Show detail for one asset"),
            ]),
            ("STAFF", [
                ("staff",            "Show all staff"),
                ("staff ATC",        "Filter by department"),
            ]),
            ("CREW", [
                ("crew",             "Show all crew"),
                ("crew UL225",       "Show crew for a flight"),
                ("crew onduty",      "Show crew on duty"),
            ]),
            ("BAGGAGE", [
                ("baggage",          "Show all baggage"),
                ("baggage UL225",    "Show baggage for a flight"),
                ("baggage issues",   "Show missing / delayed bags"),
            ]),
            ("FIDS DASHBOARD", [
                ("open fids",        "Open FIDS dashboard in browser"),
                ("fids status",      "Check FIDS connection"),
                ("fids flights",     "Pull live flights from FIDS API"),
                ("fids summary",     "Pull live summary from FIDS API"),
            ]),
        ]
        for cat, cmds in sections:
            self.wl(f"  [{cat}]", "hdr")
            for c, d in cmds:
                self.w(f"    {c:<26}", "cyan")
                self.wl(d, "dim")
            self.wl()
        self.sep()
        self.wl()

    # ─────────────────────────────────────────────
    #  SYSTEM COMMANDS
    # ─────────────────────────────────────────────
    def _whoami(self):
        s = self.session
        self.wl("  VERIFIED SESSION", "sec")
        self.sep(40)
        self.w("  User        : ", "dim"); self.wl(s["user"], "ok")
        self.w("  IP Address  : ", "dim"); self.wl(s["ip"], "white")
        self.w("  Auth        : ", "dim"); self.wl("Port-Knock ZTNA  (no password)", "white")
        self.w("  Time        : ", "dim"); self.wl(s["time"], "white")
        self.sep(40)
        self.wl()

    def _status(self):
        db_ok     = os.path.exists(DB_PATH)
        data, err = fids_get("/api/summary")
        fids_ok   = data is not None
        def _d():
            self.wl("  SYSTEM STATUS", "sec")
            self.sep(40)
            self.w("  Gateway     : ", "dim"); self.wl("OPEN", "ok")
            self.w("  Database    : ", "dim")
            self.wl("CONNECTED" if db_ok else "NOT FOUND", "ok" if db_ok else "err")
            self.w("  FIDS        : ", "dim")
            self.wl("ONLINE" if fids_ok else "OFFLINE", "ok" if fids_ok else "warn")
            self.w("  FIDS URL    : ", "dim"); self.wl(FIDS_URL, "white")
            self.w("  DB Path     : ", "dim"); self.wl(DB_PATH, "white")
            self.sep(40)
            self.wl()
        self._ui(_d)

    # ─────────────────────────────────────────────
    #  FLIGHTS
    # ─────────────────────────────────────────────
    def _flights(self, f=None):
        sql = ("SELECT * FROM flight_operations WHERE boarding_status='Boarding'"
               if f == "boarding" else
               "SELECT * FROM flight_operations WHERE boarding_status='Delayed'"
               if f == "delayed" else
               "SELECT * FROM flight_operations")
        rows, err = db_query(sql)
        def _d():
            if err: self.wl(f"  error: {err}", "err"); return
            self.wl(f"  FLIGHTS  ({len(rows)} records)", "sec")
            self.sep()
            self.w(f"  {'FLIGHT':<10}", "hdr")
            self.w(f"{'AIRLINE':<22}", "hdr")
            self.w(f"{'GATE':<7}", "hdr")
            self.w(f"{'DESTINATION':<16}", "hdr")
            self.w(f"{'DEPART':<9}", "hdr")
            self.w(f"{'PAX':<6}", "hdr")
            self.w(f"{'STATUS':<14}", "hdr")
            self.wl("SECURITY", "hdr")
            self.sep()
            for r in rows:
                st  = r["boarding_status"]
                tag = ("ok"   if st == "On Time"  else
                       "warn" if st == "Boarding"  else
                       "err"  if st == "Delayed"   else "white")
                self.wl(f"  {r['flight_no']:<10}{r['airline']:<22}"
                        f"{r['gate_no']:<7}{r['destination']:<16}"
                        f"{r['departure_time']:<9}{r['passenger_count']:<6}"
                        f"{st:<14}{r['security_status']}", tag)
            self.sep()
            self.wl()
        self._ui(_d)

    def _flight_detail(self, fno):
        rows, err = db_query(
            "SELECT * FROM flight_operations WHERE flight_no=?", (fno,))
        def _d():
            if err:       self.wl(f"  error: {err}", "err"); return
            if not rows:  self.wl(f"  Flight '{fno}' not found.", "err"); self.wl(); return
            f = rows[0]
            self.wl(f"  FLIGHT {fno}", "sec")
            self.sep(40)
            for k, v in f.items():
                self.w(f"  {k:<22}: ", "dim"); self.wl(str(v), "white")
            crew, _ = db_query(
                "SELECT name,role,rank,duty_status,check_in_status "
                "FROM crew_management WHERE flight_no=?", (fno,))
            if crew:
                self.wl()
                self.wl(f"  CREW ASSIGNED  ({len(crew)} members)", "hdr")
                self.sep(40)
                for c in crew:
                    tag = "ok" if c["duty_status"] == "On Duty" else "warn"
                    self.wl(f"  {c['name']:<28}{c['role']:<15}"
                            f"{c['rank']:<17}{c['duty_status']:<13}"
                            f"{c['check_in_status']}", tag)
            self.sep(40)
            self.wl()
        self._ui(_d)

    # ─────────────────────────────────────────────
    #  ASSETS
    # ─────────────────────────────────────────────
    def _assets(self, f=None):
        sql = ("SELECT * FROM airport_assets WHERE criticality='Critical'"
               if f == "critical" else
               "SELECT * FROM airport_assets WHERE network_status='Offline'"
               if f == "offline" else
               "SELECT * FROM airport_assets")
        rows, err = db_query(sql)
        def _d():
            if err: self.wl(f"  error: {err}", "err"); return
            self.wl(f"  INFRASTRUCTURE ASSETS  ({len(rows)} records)", "sec")
            self.sep()
            self.w(f"  {'ASSET ID':<11}", "hdr")
            self.w(f"{'HOSTNAME':<20}", "hdr")
            self.w(f"{'TYPE':<28}", "hdr")
            self.w(f"{'ZONE':<22}", "hdr")
            self.w(f"{'STATUS':<10}", "hdr")
            self.w(f"{'ZTNA':<13}", "hdr")
            self.wl("CRIT", "hdr")
            self.sep()
            for a in rows:
                tag = "ok" if a["network_status"] == "Online" else "err"
                self.wl(f"  {a['asset_id']:<11}{a['hostname']:<20}"
                        f"{a['device_type'][:27]:<28}{a['airport_zone']:<22}"
                        f"{a['network_status']:<10}{a['ztna_status']:<13}"
                        f"{a['criticality']}", tag)
            self.sep()
            self.wl()
        self._ui(_d)

    def _asset_detail(self, aid):
        rows, err = db_query(
            "SELECT * FROM airport_assets WHERE asset_id=?", (aid,))
        def _d():
            if err:       self.wl(f"  error: {err}", "err"); return
            if not rows:  self.wl(f"  Asset '{aid}' not found.", "err"); self.wl(); return
            self.wl(f"  ASSET {aid}", "sec")
            self.sep(40)
            for k, v in rows[0].items():
                col = ("ok"  if (k == "network_status" and v == "Online")  else
                       "err" if (k == "network_status" and v == "Offline") else
                       "ok"  if (k == "ztna_status"    and v == "Protected") else "white")
                self.w(f"  {k:<24}: ", "dim"); self.wl(str(v), col)
            self.sep(40)
            self.wl()
        self._ui(_d)

    # ─────────────────────────────────────────────
    #  STAFF
    # ─────────────────────────────────────────────
    def _staff(self, f=None):
        rows, err = (
            db_query("SELECT * FROM airport_staff WHERE "
                     "LOWER(department) LIKE ? OR LOWER(role) LIKE ?",
                     (f"%{f.lower()}%", f"%{f.lower()}%"))
            if f else db_query("SELECT * FROM airport_staff")
        )
        def _d():
            if err: self.wl(f"  error: {err}", "err"); return
            self.wl(f"  STAFF  ({len(rows)} records)", "sec")
            self.sep()
            self.w(f"  {'ID':<11}", "hdr"); self.w(f"{'NAME':<24}", "hdr")
            self.w(f"{'DEPARTMENT':<22}", "hdr"); self.w(f"{'ROLE':<18}", "hdr")
            self.w(f"{'ACCESS':<10}", "hdr"); self.w(f"{'MFA':<12}", "hdr")
            self.wl("STATUS", "hdr")
            self.sep()
            for s in rows:
                atag = "ok"   if s["account_status"] == "Active"  else "err"
                mtag = "ok"   if s["mfa_status"]     == "Enabled" else "warn"
                self.w(f"  {s['staff_id']:<11}{s['name']:<24}"
                       f"{s['department']:<22}{s['role']:<18}"
                       f"{s['access_level']:<10}", atag)
                self.w(f"{s['mfa_status']:<12}", mtag)
                self.wl(s["account_status"], atag)
            self.sep()
            self.wl()
        self._ui(_d)

    # ─────────────────────────────────────────────
    #  CREW
    # ─────────────────────────────────────────────
    def _crew(self, f=None):
        rows, err = (
            db_query("SELECT * FROM crew_management WHERE duty_status='On Duty'")
            if f == "onduty" else
            db_query("SELECT * FROM crew_management WHERE UPPER(flight_no)=?",
                     (f.upper(),))
            if f else
            db_query("SELECT * FROM crew_management ORDER BY flight_no")
        )
        def _d():
            if err: self.wl(f"  error: {err}", "err"); return
            self.wl(f"  CREW  ({len(rows)} records)", "sec")
            self.sep()
            self.w(f"  {'ID':<11}", "hdr"); self.w(f"{'NAME':<28}", "hdr")
            self.w(f"{'ROLE':<14}", "hdr"); self.w(f"{'RANK':<17}", "hdr")
            self.w(f"{'FLIGHT':<9}", "hdr"); self.w(f"{'DUTY':<13}", "hdr")
            self.wl("CHECK-IN", "hdr")
            self.sep()
            for c in rows:
                tag = ("ok"   if c["duty_status"] == "On Duty" else
                       "warn" if c["duty_status"] == "Standby" else "dim")
                self.wl(f"  {c['crew_id']:<11}{c['name']:<28}"
                        f"{c['role']:<14}{c['rank']:<17}"
                        f"{c['flight_no']:<9}{c['duty_status']:<13}"
                        f"{c['check_in_status']}", tag)
            self.sep()
            self.wl()
        self._ui(_d)

    # ─────────────────────────────────────────────
    #  BAGGAGE
    # ─────────────────────────────────────────────
    def _baggage(self, f=None):
        rows, err = (
            db_query("SELECT * FROM baggage_handling "
                     "WHERE status IN ('Missing','Delayed')")
            if f == "issues" else
            db_query("SELECT * FROM baggage_handling WHERE UPPER(flight_no)=?",
                     (f.upper(),))
            if f else
            db_query("SELECT * FROM baggage_handling ORDER BY flight_no")
        )
        def _d():
            if err: self.wl(f"  error: {err}", "err"); return
            self.wl(f"  BAGGAGE  ({len(rows)} records)", "sec")
            self.sep()
            self.w(f"  {'TAG':<13}", "hdr"); self.w(f"{'FLIGHT':<9}", "hdr")
            self.w(f"{'PASSENGER':<24}", "hdr"); self.w(f"{'FROM':<6}", "hdr")
            self.w(f"{'TO':<6}", "hdr"); self.w(f"{'KG':<7}", "hdr")
            self.w(f"{'STATUS':<13}", "hdr"); self.w(f"{'BELT':<9}", "hdr")
            self.wl("SCAN", "hdr")
            self.sep()
            for b in rows:
                tag = ("ok"   if b["status"] == "Loaded"    else
                       "warn" if b["status"] == "In Transit" else
                       "err"  if b["status"] in ("Missing","Delayed") else "dim")
                self.wl(f"  {b['bag_tag']:<13}{b['flight_no']:<9}"
                        f"{b['passenger_name']:<24}{b['origin']:<6}"
                        f"{b['destination']:<6}{b['weight_kg']:<7}"
                        f"{b['status']:<13}{b['belt_no']:<9}"
                        f"{b['security_scan']}", tag)
            self.sep()
            self.wl()
        self._ui(_d)

    # ─────────────────────────────────────────────
    #  FIDS
    # ─────────────────────────────────────────────
    def _open_fids(self):
        self.wl(f"  Opening FIDS dashboard -> {FIDS_URL}", "cyan")
        try:
            webbrowser.open(FIDS_URL)
            self.wl("  Browser launched.", "ok")
        except Exception as e:
            self.wl(f"  Failed: {e}", "err")
        self.wl()

    def _fids_status(self):
        data, err = fids_get("/api/summary")
        def _d():
            self.wl("  FIDS STATUS", "sec")
            self.sep(40)
            if err:
                self.w("  Status  : ", "dim"); self.wl("OFFLINE", "err")
                self.w("  Error   : ", "dim"); self.wl(err, "err")
            else:
                a = data.get("assets",  {})
                f = data.get("flights", {})
                self.w("  Status   : ", "dim"); self.wl("ONLINE", "ok")
                self.w("  URL      : ", "dim"); self.wl(FIDS_URL, "white")
                self.w("  Assets   : ", "dim")
                self.wl(f"{a.get('total',0)} total | "
                        f"{a.get('online',0)} online | "
                        f"{a.get('offline',0)} offline", "white")
                self.w("  Flights  : ", "dim")
                self.wl(f"{f.get('total',0)} total | "
                        f"{f.get('boarding',0)} boarding | "
                        f"{f.get('delayed',0)} delayed", "white")
            self.sep(40)
            self.wl()
        self._ui(_d)

    def _fids_flights(self):
        data, err = fids_get("/api/flights")
        def _d():
            if err: self.wl(f"  error: {err}", "err"); self.wl(); return
            self.wl(f"  FIDS -- LIVE FLIGHTS  ({len(data)} records)", "sec")
            self.sep()
            self.w(f"  {'FLIGHT':<10}", "hdr"); self.w(f"{'AIRLINE':<22}", "hdr")
            self.w(f"{'GATE':<7}", "hdr");  self.w(f"{'DESTINATION':<16}", "hdr")
            self.w(f"{'DEPART':<9}", "hdr"); self.w(f"{'PAX':<6}", "hdr")
            self.wl("STATUS", "hdr")
            self.sep()
            for f in data:
                st  = f["boarding_status"]
                tag = ("ok"   if st == "On Time" else
                       "warn" if st == "Boarding" else
                       "err"  if st == "Delayed"  else "white")
                self.wl(f"  {f['flight_no']:<10}{f['airline']:<22}"
                        f"{f['gate_no']:<7}{f['destination']:<16}"
                        f"{f['departure_time']:<9}{f['passenger_count']:<6}{st}", tag)
            self.sep()
            self.wl()
        self._ui(_d)

    def _fids_summary(self):
        data, err = fids_get("/api/summary")
        def _d():
            if err: self.wl(f"  error: {err}", "err"); self.wl(); return
            self.wl("  FIDS -- LIVE SUMMARY", "sec")
            self.sep(50)
            for section, vals in data.items():
                self.wl(f"  [{section.upper()}]", "hdr")
                for k, v in vals.items():
                    self.w(f"    {k:<24}: ", "dim")
                    self.wl(str(v), "white")
                self.wl()
            self.sep(50)
            self.wl()
        self._ui(_d)


# ══════════════════════════════════════════════════
#  PAIRING WINDOW  -  shows the QR a vendor scans with their phone to
#  link this generic, unmodified exe to their specific session — no
#  typing, no per-vendor build. Re-showable from the tray at any time.
# ══════════════════════════════════════════════════
class PairingWindow:
    WIDTH = 360   # compact, like the original — quality comes from how it's
                  # rendered (supersampled + real blur), not from being bigger

    def __init__(self, root, pairing_code):
        self.win = tk.Toplevel(root)
        self.win.title("AeroGuard ZTNA — Pair This Device")
        self.win.resizable(False, False)
        try:
            self.win.iconbitmap(ICON_ICO)
        except Exception:
            pass
        # No window-level alpha — Tkinter's -alpha blends the *entire*
        # window uniformly, which would wash out the text too. The glass
        # look instead comes from the rendered images' own transparency,
        # blended correctly against the background at draw time, so the
        # window itself stays fully opaque and every word stays crisp.
        self.win.protocol("WM_DELETE_WINDOW", self.win.withdraw)

        self._closing      = False
        self._pulse_phase   = 0.0
        self._ripple_phase  = 0.0
        self._pulse_color   = FG          # cyan while waiting, green on approval
        self._pulse_job     = None
        self._glow_size     = 168         # spreads well beyond the logo itself
        self._logo_src      = None

        # ── Layout pass — a running cursor places every element, then the
        # window is sized to exactly fit what was drawn. Nothing is ever
        # guessed/cramped, and nothing can overflow the visible card. ─────
        margin = 20
        cx = self.WIDTH / 2
        y = margin + 22

        glow_zone_h = self._glow_size + 10
        logo_cy = y + glow_zone_h / 2
        y += glow_zone_h

        wordmark_y = y; y += 24
        subtitle_y = y; y += 28
        label_y    = y; y += 22
        instr_y    = y; y += 28

        qr_size, qr_pad = 188, 12
        qr_chip = qr_size + qr_pad * 2
        qr_y1 = y
        qr_y2 = y + qr_chip
        y = qr_y2 + 16

        code_y   = y; y += 22
        status_y = y; y += 26

        btn_w, btn_h = 104, 32
        btn_y1 = y
        y = btn_y1 + btn_h + margin + 24   # bottom inner padding

        self.HEIGHT = int(y)
        self.win.geometry(f"{self.WIDTH}x{self.HEIGHT}")

        c = self.canvas = tk.Canvas(self.win, width=self.WIDTH, height=self.HEIGHT,
                                     highlightthickness=0, bd=0)
        c.pack(fill="both", expand=True)

        # ── Backdrop — smooth supersampled gradient with soft blurred
        # color blobs bleeding through, the actual depth cue a flat
        # two-color gradient never had ───────────────────────────────────
        bg_img = make_background(self.WIDTH, self.HEIGHT, GRADIENT_TOP, GRADIENT_BOTTOM, FG)
        self._bg_photo = ImageTk.PhotoImage(bg_img)
        c.create_image(0, 0, image=self._bg_photo, anchor="nw")

        # ── True glassmorphism — a real soft drop shadow + a genuinely
        # translucent frosted tint (the blobs above show faintly through
        # it) + a bright top-edge highlight, all one pre-rendered image ──
        card_w, card_h = self.WIDTH - margin * 2, self.HEIGHT - margin * 2
        glass_img = make_glass_card(card_w, card_h, 26, (66, 98, 138, 70))
        self._glass_photo = ImageTk.PhotoImage(glass_img)
        c.create_image(margin, margin, image=self._glass_photo, anchor="nw")
        self._glass_fill = _lerp_color(GRADIENT_TOP, "#3D5C82", 0.24)  # for text contrast math only

        # ── Logo glow — a real blurred shadow rendered with Pillow, fully
        # isolated in its own image so animating it never touches any
        # text item. The logo inside never moves, resizes, or distorts. ──
        self._cx, self._cy = cx, logo_cy
        try:
            self._logo_src = Image.open(ICON_PNG).convert("RGBA")
        except Exception:
            self._logo_src = None
        glow_img = make_logo_glow(self._glow_size, self._pulse_color, 0.3, self._logo_src)
        self._glow_photo = ImageTk.PhotoImage(glow_img)
        self._glow_item = c.create_image(cx, logo_cy, image=self._glow_photo)

        c.create_text(cx, wordmark_y, text="AEROGUARD",
                       fill=FG_WHITE, font=(SANS, 18, "bold"))
        c.create_text(cx, subtitle_y, text="ZERO TRUST NETWORK ACCESS",
                       fill=FG, font=(SANS, 8, "bold"))
        c.create_text(cx, label_y, text="PAIR THIS DEVICE",
                       fill=FG_DIM, font=UI_FONT_B)
        c.create_text(cx, instr_y, text="Open the AeroGuard app, then Scan Laptop",
                       fill=FG_DIM, font=UI_FONT)

        # ── QR sits on a true-white chip — kept high-contrast on purpose
        # so it stays reliably scannable. Rendered at 4x its display size
        # and downscaled with Lanczos so the modules stay crisp instead
        # of looking jagged at a smaller physical size ────────────────────
        qx1 = cx - qr_chip / 2
        draw_rounded_rect(c, qx1, qr_y1, qx1 + qr_chip, qr_y2, 16, fill="#FFFFFF", outline="")
        qr_img = qrcode.make(
            json.dumps({"type": "aeroguard_device_pairing",
                        "pairing_code": pairing_code}),
            border=2,
        ).convert("L").resize((qr_size, qr_size), Image.LANCZOS)
        self._qr_photo = ImageTk.PhotoImage(qr_img)
        c.create_image(cx, (qr_y1 + qr_y2) / 2, image=self._qr_photo)

        c.create_text(cx, code_y, text=pairing_code, fill=FG_DIM, font=(MONO, 12))
        self.status_text = c.create_text(cx, status_y, text="Waiting for scan...",
                                          fill=FG_DIM, font=UI_FONT)

        # ── Hide button ──────────────────────────────────────────────────
        bx1 = cx - btn_w / 2
        hide_btn = draw_rounded_rect(c, bx1, btn_y1, bx1 + btn_w, btn_y1 + btn_h, 9,
                                      fill="", outline=FG_DIM)
        hide_txt = c.create_text(cx, btn_y1 + btn_h / 2,
                                  text="HIDE", fill=FG_DIM, font=UI_FONT_B)
        for item in (hide_btn, hide_txt):
            c.tag_bind(item, "<Button-1>", lambda e: self.win.withdraw())
            c.tag_bind(item, "<Enter>", lambda e: c.itemconfig(hide_txt, fill=FG))
            c.tag_bind(item, "<Leave>", lambda e: c.itemconfig(hide_txt, fill=FG_DIM))

        self._animate()

    # ── continuous color pulse — no motion, no resizing of the logo, and
    #    nothing else on the card is ever touched. Only the glow image
    #    itself is regenerated each frame, with a real Gaussian blur. ────
    def _animate(self):
        if self._closing:
            return
        self._pulse_phase  += 0.072
        self._ripple_phase = (self._ripple_phase + 0.020) % 1.0
        t = (math.sin(self._pulse_phase) + 1) / 2   # smooth 0..1 breathing curve
        glow_img = make_logo_glow(self._glow_size, self._pulse_color, t,
                                   self._logo_src, self._ripple_phase)
        self._glow_photo = ImageTk.PhotoImage(glow_img)
        self.canvas.itemconfig(self._glow_item, image=self._glow_photo)
        self._pulse_job = self.win.after(65, self._animate)

    def show(self):
        self.win.deiconify()
        self.win.lift()

    def set_status(self, text):
        self.canvas.itemconfig(self.status_text, text=text)

    def play_approved_and_close(self, on_done):
        """
        Admin just approved this device — the glow turns green for a
        couple of beats, then the whole window closes for good and the
        real terminal takes over. on_done() is called after destruction.
        """
        self.show()
        self._pulse_color = FG_GREEN
        self.set_status("Device approved — connecting...")
        self.win.after(950, lambda: self._finish_close(on_done))

    def play_declined(self, message="Declined — ask the vendor to rescan"):
        """
        The admin explicitly declined this device, or the pairing code
        didn't match any vendor session. The glow turns red with a clear
        reason, then settles back to the normal waiting pulse so a fresh
        scan attempt can succeed without restarting the exe.
        """
        if self._closing:
            return
        self.show()
        self._pulse_color = FG_RED
        self.set_status(message)
        self.win.after(4000, self._reset_to_waiting)

    def _reset_to_waiting(self):
        if self._closing:
            return
        self._pulse_color = FG
        self.set_status("Waiting for scan...")

    def _finish_close(self, on_done):
        self._closing = True
        if self._pulse_job:
            try:
                self.win.after_cancel(self._pulse_job)
            except Exception:
                pass
        self.win.destroy()
        on_done()


# ══════════════════════════════════════════════════
#  TRAY APP  -  runs hidden, polls the gateway, pops the terminal
#  to the foreground on grant and drops back to tray on revoke.
#  No window is ever shown until a real session is confirmed, and
#  no inbound port is ever opened — see poll_session() above.
# ══════════════════════════════════════════════════
class TrayApp:
    def __init__(self, root):
        self.root         = root
        self.terminal     = None
        self.tray         = None
        self._withdraw_job = None
        self._miss_count   = 0
        self.pairing_code  = None
        self.pairing_win   = None    # stays None entirely on admin laptops

        root.withdraw()                 # silent from the first frame
        try:
            root.iconbitmap(ICON_ICO)
        except Exception:
            pass

        self._start_tray()
        self._schedule_poll()
        threading.Thread(target=self._decide_pairing, daemon=True).start()

    # ── Admin laptops are recognized by MAC and granted access directly —
    #    no pairing, no QR, ever. Anything else falls back to vendor-style
    #    QR pairing. Checked once at startup in the background so it never
    #    delays the tray icon or the grant-polling loop coming up ─────────
    def _decide_pairing(self):
        if is_admin_laptop():
            return
        self.pairing_code = secrets.token_hex(3).upper()   # e.g. "A3F9C2"
        self.root.after(0, self._create_pairing_window)
        self._start_pairing_refresh()

    def _create_pairing_window(self):
        if self.terminal is not None:
            return   # already granted before the admin-check even finished
        self.pairing_win = PairingWindow(self.root, self.pairing_code)
        self.pairing_win.show()
        self._set_tray_status("Waiting for pairing")

    # ── pairing — kept fresh for as long as this exe keeps running, so
    #    issuing it the day before a visit doesn't let the code expire
    #    before the vendor ever gets a chance to scan it ──────────────
    def _start_pairing_refresh(self):
        def _loop():
            while True:
                register_pairing(self.pairing_code)
                time.sleep(300)
        threading.Thread(target=_loop, daemon=True).start()

    # ── system tray icon ─────────────────────────
    def _tray_image(self):
        try:
            return Image.open(ICON_PNG)
        except Exception:
            return Image.new("RGB", (64, 64), FG)

    def _start_tray(self):
        menu = pystray.Menu(
            pystray.MenuItem("Show Terminal", self._show, default=True),
            pystray.MenuItem("Status: Waiting for authorization",
                              None, enabled=False),
            pystray.MenuItem("Exit", self._quit),
        )
        self.tray = pystray.Icon("aeroguard", self._tray_image(),
                                  "AeroGuard ZTNA — Waiting", menu)
        threading.Thread(target=self.tray.run, daemon=True).start()

    def _set_tray_status(self, text):
        if not self.tray:
            return
        self.tray.title = f"AeroGuard ZTNA — {text}"
        items = [pystray.MenuItem("Show Terminal", self._show, default=True)]
        if self.pairing_win is not None:   # vendor-mode device only
            items.append(pystray.MenuItem("Show Pairing QR", self._show_pairing))
        items += [
            pystray.MenuItem(f"Status: {text}", None, enabled=False),
            pystray.MenuItem("Exit", self._quit),
        ]
        self.tray.menu = pystray.Menu(*items)

    def _show_pairing(self, icon=None, item=None):
        # Once a real session is granted, the pairing window is torn down
        # along with everything else from a prior revoke — nothing left
        # to re-show, and that's fine, pairing has already done its job.
        def _do():
            if self.pairing_win is not None and self.pairing_win.win.winfo_exists():
                self.pairing_win.show()
        self.root.after(0, _do)

    def _show(self, icon=None, item=None):
        if self.terminal:
            self.root.after(0, self._bring_to_front)

    def _bring_to_front(self):
        self.root.deiconify()
        self.root.lift()
        self.root.focus_force()

    def _quit(self, icon, item):
        icon.stop()
        self.root.after(0, self.root.destroy)

    # ── polling — the only signal that drives every transition ──
    def _schedule_poll(self):
        threading.Thread(target=self._poll_once, daemon=True).start()
        self.root.after(POLL_INTERVAL_SECONDS * 1000, self._schedule_poll)

    def _poll_once(self):
        data   = poll_session()
        active = bool(data and data.get("active"))

        if active:
            self._miss_count = 0
            if self.terminal is None:
                self.root.after(0, lambda: self._grant(data))
            return

        # A single failed/empty poll is treated as a miss, not a revoke —
        # one slow response on ordinary WiFi (more likely exactly when the
        # gateway is busy handling a concurrent admin+vendor knock) used to
        # close the terminal immediately, then reopen it 3s later on the
        # next successful poll. Require a few consecutive misses before
        # treating it as a genuine revoke.
        if self.terminal is not None:
            self._miss_count += 1
            if self._miss_count >= REVOKE_MISS_THRESHOLD:
                self._miss_count = 0
                self.root.after(0, self._revoke)

    def _grant(self, data):
        if self._withdraw_job:                  # cancel a pending hide from a
            self.root.after_cancel(self._withdraw_job)   # just-revoked session so
            self._withdraw_job = None                     # it can't yank this new one
        session = {
            "user": data.get("username") or "Verified Operator",
            "ip":   GATEWAY_HOST,
            "time": data.get("granted_at")
                    or datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        }

        def _open_terminal():
            for w in self.root.winfo_children():   # clear any leftover widgets
                w.destroy()                          # from a prior revoked session
            self.terminal = AeroGuardTerminal(self.root, session)
            self._set_tray_status(f"Active — {session['user']}")
            self._bring_to_front()

        # First grant of this exe's life on a vendor-mode device: the
        # pairing window is still up, so play the green "approved" pulse
        # before handing off to the terminal. Admin laptops never had one
        # to begin with, and any later regrant (after a revoke) finds it
        # already destroyed — both go straight to the terminal.
        if self.pairing_win is not None and self.pairing_win.win.winfo_exists():
            self.pairing_win.play_approved_and_close(_open_terminal)
        else:
            _open_terminal()

    def _revoke(self):
        if self.terminal:
            self.terminal.close_for_revoke()
        self.terminal = None
        self._set_tray_status("Waiting for authorization")
        self._withdraw_job = self.root.after(2000, self.root.withdraw)


if __name__ == "__main__":
    root = tk.Tk()
    TrayApp(root)
    root.mainloop()
