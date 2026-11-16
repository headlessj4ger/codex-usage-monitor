Option Explicit
Dim shell, files, baseDir, powershell, command
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
baseDir = files.GetParentFolderName(WScript.ScriptFullName)
powershell = shell.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
command = """" & powershell & """ -NoProfile -STA -WindowStyle Hidden -File """ & baseDir & "\launch.ps1"" -Quiet"
shell.Run command, 0, False
