# aeroguard_terminal.spec
# Run:  pyinstaller aeroguard_terminal.spec --noconfirm --clean

block_cipher = None

a = Analysis(
    ['aeroguard_terminal.py'],
    pathex=['.'],
    binaries=[],
    datas=[('assets', 'assets')],
    hiddenimports=[
        'tkinter', 'tkinter.scrolledtext', 'tkinter.font',
        'threading', 'urllib.request', 'urllib.error',
        'sqlite3', 'json', 'webbrowser',
        'pystray', 'pystray._win32', 'PIL', 'PIL.Image', 'PIL.ImageTk',
    ],
    hookspath=[],
    runtime_hooks=[],
    excludes=[],
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='AeroGuard_Terminal',
    debug=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,      # no black console window — GUI only
    icon='assets/aeroguard.ico',
)
