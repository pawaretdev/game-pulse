' Launch the ROOC Monitor GUI with no console window at all.
' Last Run() argument is 0 (hidden) so no PowerShell console ever appears.
' Side effect: nCmdShow=0 also suppresses every WPF window in the process, so
' the script calls Force-Show before each ShowDialog to bring them back up.
' Keep this file ASCII with no BOM - VBScript refuses to compile a BOM.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File """ & here & "\ROOC-Monitor-WPF.ps1""", 0, False
