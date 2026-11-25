#ifndef MyAppVersion
  #define MyAppVersion "1.3.0"
#endif
#ifndef MyBuildNumber
  #define MyBuildNumber "20261115.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\windows\ValidTeam"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist\windows"
#endif

[Setup]
AppId={{8F9E7A2D-4C53-4B18-9F6A-2A7E93C41B01}
AppName=Valid Team
AppVersion={#MyAppVersion}
AppVerName=Valid Team {#MyAppVersion}
AppPublisher=Valid Studio
AppPublisherURL=https://valid-team.com/
AppSupportURL=https://github.com/valid-studio/valid-team-releases/issues
AppUpdatesURL=https://github.com/valid-studio/valid-team-releases/releases/latest
VersionInfoVersion={#MyAppVersion}.0
VersionInfoProductVersion={#MyAppVersion}
VersionInfoDescription=Valid Team Multi-Agent Desktop Workbench (Build {#MyBuildNumber})
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\ValidTeam
DefaultGroupName=Valid Team
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=ValidTeam-Setup
SetupIconFile=app.ico
UninstallDisplayIcon={app}\ValidTeam.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
CloseApplicationsFilter=*.exe
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\ValidTeam.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\vteam.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\va.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.txt"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{app}\*.exe.old"
Type: files; Name: "{app}\*.exe.*.old"

[Icons]
Name: "{group}\Valid Team"; Filename: "{app}\ValidTeam.exe"
Name: "{group}\Uninstall Valid Team"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Valid Team"; Filename: "{app}\ValidTeam.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ValidTeam.exe"; Description: "Launch Valid Team"; Flags: nowait postinstall skipifsilent

[Code]
procedure StopRunningValidTeamProcesses();
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/F /T /IM ValidTeam.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/F /T /IM vteam.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(400);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopRunningValidTeamProcesses();
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  StopRunningValidTeamProcesses();
  Result := True;
end;
