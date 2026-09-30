#ifndef AppVersion
#define AppVersion "1.0.0"
#endif

#define AppName "Bloxity Client"
#define AppExeName "BloxityClient.exe"

[Setup]
AppId={{A589D8D8-2EAA-44AE-B2B7-74ADFE558F08}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Bloxity
DefaultDirName={localappdata}\Programs\Bloxity
DefaultGroupName=Bloxity
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\dist
OutputBaseFilename=BloxityClientSetup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
Uninstallable=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\build\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Bloxity\Bloxity"; Filename: "{app}\{#AppExeName}"

[Registry]
Root: HKCU; Subkey: "Software\Classes\bloxity"; ValueType: string; ValueName: ""; ValueData: "URL:Bloxity Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\bloxity"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\bloxity\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#AppExeName}"; Parameters: "{code:GetLaunchParameters}"; Flags: nowait postinstall

[Code]
function GetLaunchParameters(Param: String): String;
var
  JoinUri: String;
begin
  JoinUri := ExpandConstant('{param:JOINURI|}');
  if JoinUri = '' then
    Result := ''
  else
    Result := '"' + JoinUri + '"';
end;
