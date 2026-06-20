"""
AeroGuard ZTNA - Secure Terminal v5.0
Pure terminal interface - type commands, see results.
Polls the gateway for a live, granted laptop session — never listens
for an inbound trigger, so there is nothing for another device on the
LAN to fake.
"""

import tkinter as tk
from tkinter import scrolledtext
import threading, sqlite3, os, sys, datetime, webbrowser, time
import urllib.request, urllib.error, json
import pystray
from PIL import Image, ImageTk

# ══════════════════════════════════════════════════
#  CONFIG
# ══════════════════════════════════════════════════
GATEWAY_HOST          = "192.168.100.130"
GATEWAY_PORT          = 8000
TERMINAL_SESSION_URL  = f"http://{GATEWAY_HOST}:{GATEWAY_PORT}/api/v1/terminal-session"
POLL_INTERVAL_SECONDS = 3
FIDS_HOST            = "127.0.0.1"
FIDS_PORT            = 5000
FIDS_URL             = f"http://{FIDS_HOST}:{FIDS_PORT}"

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
FONT      = ("Courier New", 11)
FONT_B    = ("Courier New", 11, "bold")
FONT_LG   = ("Courier New", 13, "bold")

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
        req = urllib.request.urlopen(TERMINAL_SESSION_URL, timeout=3)
        return json.loads(req.read().decode())
    except Exception:
        return None

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
        self.root.geometry("1100x700")
        self.root.minsize(800, 500)
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

        # ── STATUS BAR (top, very thin) ──────────
        bar = tk.Frame(self.root, bg=BAR_BG, pady=6)
        bar.pack(fill="x", side="top")

        try:
            logo_src = Image.open(ICON_PNG).convert("RGBA")
            logo_src.thumbnail((26, 26), Image.LANCZOS)
            self._logo_img = ImageTk.PhotoImage(logo_src)
            tk.Label(bar, image=self._logo_img,
                     bg=BAR_BG).pack(side="left", padx=(10, 6))
        except Exception:
            pass

        tk.Label(bar, text="AeroGuard ZTNA",
                 fg=FG, bg=BAR_BG, font=FONT_B).pack(side="left", padx=(0, 6))

        tk.Label(bar, text="|", fg=FG_DIM,
                 bg=BAR_BG, font=FONT).pack(side="left")

        self.operator_lbl = tk.Label(
            bar, text=f" {self.session['user']} ",
            fg=BG, bg=FG, font=("Courier New", 9, "bold"))
        self.operator_lbl.pack(side="left", padx=(6, 8))

        self.gw_lbl = tk.Label(bar, text=" GATEWAY: OPEN ",
                                fg=BG, bg=FG_GREEN,
                                font=("Courier New", 9, "bold"))
        self.gw_lbl.pack(side="left", padx=2)

        self.db_lbl = tk.Label(bar, text=" DB: -- ",
                                fg=BG, bg=FG_DIM,
                                font=("Courier New", 9, "bold"))
        self.db_lbl.pack(side="left", padx=2)

        self.fids_lbl = tk.Label(bar, text=" FIDS: -- ",
                                  fg=BG, bg=FG_DIM,
                                  font=("Courier New", 9, "bold"))
        self.fids_lbl.pack(side="left", padx=2)

        self.clock_lbl = tk.Label(bar, text="",
                                   fg=FG_DIM, bg=BAR_BG,
                                   font=("Courier New", 9))
        self.clock_lbl.pack(side="right", padx=10)
        self._tick()

        # ── SEPARATOR ───────────────────────────
        tk.Frame(self.root, bg=FG_DIM, height=1).pack(fill="x")

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
        tk.Frame(self.root, bg=FG_DIM, height=1).pack(fill="x")

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
        self.clock_lbl.config(
            text=datetime.datetime.now().strftime("%Y-%m-%d  %H:%M:%S  "))
        self.root.after(1000, self._tick)

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
            self.root.after(0, lambda: self.db_lbl.config(
                text=" DB: OK ", bg=FG_GREEN))
        else:
            self.wl(f"  [DB]    airport_system.db ............. NOT FOUND", "err")
            self.root.after(0, lambda: self.db_lbl.config(
                text=" DB: ERR ", bg=FG_RED))

        # FIDS check async
        self.wl(f"  [FIDS]  Connecting to {FIDS_URL} ...", "dim")

        def _chk():
            data, err = fids_get("/api/summary")
            if data:
                self.root.after(0, lambda: (
                    self.wl("  [FIDS]  Dashboard ..................... ONLINE", "ok"),
                    self.fids_lbl.config(text=" FIDS: OK ", bg=FG_GREEN),
                    self.wl(),
                    self.wl("  Gateway is OPEN. Type  help  to see all commands.", "cyan"),
                    self.wl()
                ))
            else:
                self.root.after(0, lambda: (
                    self.wl("  [FIDS]  Dashboard ..................... OFFLINE", "warn"),
                    self.fids_lbl.config(text=" FIDS: OFF ", bg=FG_ORANGE),
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

        root.withdraw()                 # silent from the first frame
        try:
            root.iconbitmap(ICON_ICO)
        except Exception:
            pass

        self._start_tray()
        self._schedule_poll()

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
        self.tray.menu = pystray.Menu(
            pystray.MenuItem("Show Terminal", self._show, default=True),
            pystray.MenuItem(f"Status: {text}", None, enabled=False),
            pystray.MenuItem("Exit", self._quit),
        )

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
        if active and self.terminal is None:
            self.root.after(0, lambda: self._grant(data))
        elif not active and self.terminal is not None:
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
        for w in self.root.winfo_children():    # clear any leftover widgets
            w.destroy()                          # from a prior revoked session
        self.terminal = AeroGuardTerminal(self.root, session)
        self._set_tray_status(f"Active — {session['user']}")
        self._bring_to_front()

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
