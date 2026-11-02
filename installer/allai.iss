; Windows kurulum programı (Inno Setup). Sürüm komut satırından verilir: iscc /DAppVersion=1.0.0 allai.iss
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6B0F2C74-3D1E-4A59-9C2B-7E5A1F0D8A41}
AppName=AllAI
AppVersion={#AppVersion}
AppPublisher=AllAI
DefaultDirName={autopf}\AllAI
DefaultGroupName=AllAI
UninstallDisplayIcon={app}\allai.exe
OutputDir=..\build
OutputBaseFilename=AllAI-Setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\AllAI"; Filename: "{app}\allai.exe"
Name: "{autodesktop}\AllAI"; Filename: "{app}\allai.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"

[Run]
Filename: "{app}\allai.exe"; Description: "Launch AllAI"; Flags: nowait postinstall skipifsilent

; Kaldırınca uygulamanın bıraktığı veriler de silinir (ayarlar, oturumlar, önbellek).
[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\app.allai"
Type: filesandordirs; Name: "{localappdata}\app.allai"
Type: filesandordirs; Name: "{userappdata}\AllAI"
Type: filesandordirs; Name: "{localappdata}\AllAI"
