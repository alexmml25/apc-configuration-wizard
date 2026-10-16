; ============================================================================
;  APC Configuration Manager - setup (Inno Setup 6, same kind of installer as the APC Installation Manager)
;
;  Build (Windows PC with Inno Setup 6): open this file in the Inno Setup Compiler and press Compile,
;  or run   ISCC.exe APC_Configuration_Manager.iss   in this folder. The script reads the Configuration Manager
;  files from the folder one level up and writes  Output\APC_Configuration_Manager_Setup_<version>.exe.
;  Put that .exe on the repository; engineers run it on the VM.
;
;  AppVersion must equal $Script:AppVersion in APC_ConfigWizard.ps1 (tests check it).
;  The [Files] list must match the runtime files in .gitignore's whitelist (tests check it).
;
;  Installs to D:\APC Engineering\Configuration Manager (C: when the VM has no D:). Runs, logs, backups and
;  reports stay in the work folder (D:\APC_Config); uninstall leaves them.
;  An update is refused while the Configuration Manager window is open (it holds the mutex below).
; ============================================================================

#define AppName      "APC Configuration Manager"
#define AppVersion   "1.0.0.0"
#define AppPublisher "Medtronic"
#define AppIcon      "APC Configuration Manager.ico"
#define Src          ".."

[Setup]
AppId={{6B1F3C2A-8E4D-4B7A-9C51-2D7E0A4F9B63}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
DefaultDirName={code:GetDefaultDir}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
OutputDir=Output
OutputBaseFilename=APC_Configuration_Manager_Setup_{#AppVersion}
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\{#AppIcon}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
; APC_ConfigWizard.ps1 holds this mutex while its window is open: setup and uninstall wait until it is closed
AppMutex=APCConfigurationManager,Global\APCConfigurationManager

[InstallDelete]
; An update replaces the module and template folders completely (no stale files from the previous release)
Type: filesandordirs; Name: "{app}\modules"
Type: filesandordirs; Name: "{app}\Templates"

[Files]
Source: "{#Src}\Start-Wizard.cmd";                   DestDir: "{app}";           Flags: ignoreversion
Source: "{#Src}\APC_ConfigWizard.ps1";               DestDir: "{app}";           Flags: ignoreversion
Source: "{#Src}\APC_Config.ps1";                     DestDir: "{app}";           Flags: ignoreversion
Source: "{#Src}\APC_ConfigManifest.json";            DestDir: "{app}";           Flags: ignoreversion
Source: "{#Src}\APC Logo.png";                       DestDir: "{app}";           Flags: ignoreversion
Source: "{#Src}\APC Configuration Manager Icon.png"; DestDir: "{app}";           Flags: ignoreversion
Source: "{#AppIcon}";                                DestDir: "{app}";           Flags: ignoreversion
; modules\800xA is the 800xA kit: copied byte for byte (checked against its SHA256SUMS.txt at run time)
Source: "{#Src}\modules\*";                          DestDir: "{app}\modules";   Flags: ignoreversion recursesubdirs
Source: "{#Src}\Templates\D01555624_C_EN.docx";      DestDir: "{app}\Templates"; Flags: ignoreversion
Source: "{#Src}\Templates\FileFlowTest_CTSCAN1.csv"; DestDir: "{app}\Templates"; Flags: ignoreversion
Source: "{#Src}\Templates\FileFlowTest_CMM1.csv";    DestDir: "{app}\Templates"; Flags: ignoreversion

[Icons]
Name: "{commondesktop}\{#AppName}";                   Filename: "{app}\Start-Wizard.cmd"; WorkingDir: "{app}"; IconFilename: "{app}\{#AppIcon}"
Name: "{commonprograms}\{#AppName}\{#AppName}";       Filename: "{app}\Start-Wizard.cmd"; WorkingDir: "{app}"; IconFilename: "{app}\{#AppIcon}"
Name: "{commonprograms}\{#AppName}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\Start-Wizard.cmd"; WorkingDir: "{app}"; Description: "Start {#AppName}"; Flags: postinstall nowait skipifsilent shellexec unchecked

[Code]
function GetDefaultDir(Param: String): String;
begin
  if DirExists('D:\') then
    Result := 'D:\APC Engineering\Configuration Manager'
  else
    Result := ExpandConstant('{sd}') + '\APC Engineering\Configuration Manager';
end;
