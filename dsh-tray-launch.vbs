' Launch the persistent WinForms tray host without creating a console window.
' The tray host, not this launcher, owns and monitors the dsh web process.
Option Explicit

Dim sh, fso, scriptDir, trayScript, command
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
trayScript = scriptDir & "\dsh-tray.ps1"

If Not fso.FileExists(trayScript) Then
  MsgBox "Missing tray script: " & trayScript, vbCritical, "dsh Tray"
  WScript.Quit 1
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & trayScript & """"
sh.Run command, 0, False
WScript.Quit 0
