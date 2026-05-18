# Windows distribution

Two ways to ship Cubechat to a Windows user.

## Option A — portable ZIP (works today, no installer)

After running `flutter build windows --release`, the output is a
self-contained folder of EXE + DLLs + assets at:

```
build\windows\x64\runner\Release\
```

The CI / build pipeline also drops a ready-to-share archive at:

```
build\windows\cubechat-windows.zip
```

(13 MB compressed; ~32 MB extracted.)

User experience:
1. Download the zip
2. Right-click → Extract All
3. Open the extracted folder → double-click `cubechat.exe`

No installation, no admin rights, no registry entries. Removing it is a
single folder delete. Good for early testing.

## Option B — real installer (`cubechat-setup.exe`)

A signed wizard installer with Start menu + optional desktop shortcut,
proper Programs-and-Features entry, language picker (English / Ukrainian).

### One-time setup on the build machine

1. Install **Inno Setup 6** from https://jrsoftware.org/isinfo.php
   (free, ~3 MB, runs on Win 7+).

### Build the installer

```powershell
# 1. Build the Flutter Release (if you haven't already)
flutter build windows --release

# 2. Compile the installer
&"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows\installer\cubechat.iss
```

Output lands at:

```
build\windows\installer\cubechat-setup.exe
```

That's a single ~13 MB EXE you can ship. The user runs it, clicks Next a
few times, and gets a proper installation with Start menu shortcut.

### What the installer does

- Default install path: `%LOCALAPPDATA%\Programs\Cubechat\` (no admin
  rights required because we use `PrivilegesRequired=lowest`)
- Optional desktop shortcut (unchecked by default — opt-in)
- Start menu entry under "Cubechat"
- Uninstaller registered in Windows Settings → Apps
- Upgrade in place: if a previous version is installed, the new one
  replaces it without duplicate entries (matched by AppId GUID in the
  `.iss` script).

To re-version: edit `AppVersion` in `cubechat.iss` and recompile.
