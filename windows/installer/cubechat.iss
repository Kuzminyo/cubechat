; Inno Setup script for the Cubechat Windows installer.
;
; Build:
;   1. Install Inno Setup 6 from https://jrsoftware.org/isinfo.php
;   2. Compile with the GUI or the CLI:
;        ISCC.exe windows\installer\cubechat.iss
;   3. Output lands at build\windows\installer\cubechat-setup.exe
;
; You must have built the Flutter Release first:
;   flutter build windows --release
; (the script reads from build\windows\x64\runner\Release)

#define AppName "Cubechat"
#define AppVersion "0.1.0"
#define AppPublisher "Cubechat"
#define AppExe "cubechat.exe"
; Repository default — installer assumes you ran ISCC from the repo root.
#define SourceDir "..\..\build\windows\x64\runner\Release"

[Setup]
; A stable AppId so upgrades replace the existing install in-place.
AppId={{C8B4C0DE-CBE7-4E15-A6F2-CB07A1C09BE7}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\..\build\windows\installer
OutputBaseFilename=cubechat-setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Match the Flutter app's dark brand background.
WizardImageBackColor=$0D1406
; Allow both x64 and ARM64 Windows 10/11 hosts.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "ukrainian"; MessagesFile: "compiler:Languages\Ukrainian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Bundle every file from the Flutter Release output.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; \
  Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; \
  Flags: nowait postinstall skipifsilent
