; HOPBOX(택배상자) 윈도우 설치 파일
; iscc /DArch=x64 /DSource=<게시 폴더> /DAppVersion=1.0.0 /DOutput=<출력 폴더> hopbox.iss
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6B0F7C1E-5D2A-4C1B-9E44-0B6A1F7C2D11}
AppName=HOPBOX 택배상자
AppVersion={#AppVersion}
AppPublisher=ESeungJun
AppPublisherURL=https://github.com/ESeungJun/hopbox
DefaultDirName={localappdata}\Programs\Hopbox
DefaultGroupName=HOPBOX
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#Output}
OutputBaseFilename=Hopbox-Windows-{#Arch}-Setup
SetupIconFile=..\Hopbox.Windows\Assets\app.ico
UninstallDisplayIcon={app}\Hopbox.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startup"; Description: "로그인할 때 자동으로 실행"; GroupDescription: "추가 설정:"

[Files]
Source: "{#Source}\Hopbox.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\HOPBOX 택배상자"; Filename: "{app}\Hopbox.exe"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Hopbox"; ValueData: """{app}\Hopbox.exe"""; Tasks: startup; Flags: uninsdeletevalue
; 설치 때 고르지 않고 앱 메뉴에서 켠 자동 실행도 제거할 때 지운다
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Hopbox"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\Hopbox.exe"; Description: "택배상자 실행"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM Hopbox.exe /F"; Flags: runhidden; RunOnceId: "StopHopbox"
