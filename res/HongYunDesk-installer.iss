; 宏运桌面 Windows 安装器脚本（Inno Setup 6）
; 与官方 RustDesk 共存的关键：独立 AppId / 安装目录 / 快捷方式名
; 用法：在 Windows 机器上完成 build.py --flutter 后，把本脚本与
;   build 后的 rustdesk-{version}-install.exe（或展开后的完整目录）一起交给 ISCC.exe 编译：
;   ISCC.exe HongYunDesk-installer.iss

#define MyAppName "宏运桌面"
#define MyAppNameEn "HongYunDesk"
; !! 独立 AppId：与官方 RustDesk 不同，保证并存安装互不覆盖
#define MyAppId "{{8B3C6F2A-9D4E-4B7A-A1C5-HONGYUNDESK1}"
#define MyAppVersion "1.0.0"
#define MyAppExeName "hongyundesk.exe"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
DefaultDirName={autopf}\HongYunDesk
DefaultGroupName={#MyAppName}
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputBaseFilename=HongYunDesk-{#MyAppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
; 关闭升级检测等官方行为
SetupLogging=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Files]
; 方式 A：打包 build.py 产出的自解压安装器，安装时释放并执行
Source: "rustdesk-*-install.exe"; DestDir: "{app}\bin"; DestName: "{#MyAppExeName}"; Flags: ignoreversion
; 方式 B（可选）：若直接打包 flutter+cargo 产物目录，改为：
; Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\bin\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\bin\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"

[Run]
; --install 会注册服务（服务名=宏运桌面，与官方 RustDesk 服务不冲突）并完成自启配置
Filename: "{app}\bin\{#MyAppExeName}"; Parameters: "--install"; Flags: runhidden waituntilterminated
Filename: "{app}\bin\{#MyAppExeName}"; Description: "立即启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; 卸载时注销服务（--uninstall 由程序自身处理服务移除）
Filename: "{app}\bin\{#MyAppExeName}"; Parameters: "--uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "DelService"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\bin"
