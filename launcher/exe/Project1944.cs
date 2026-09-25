// Project 1944 - the launcher executable.
//
// Runs launcher\Cod3Launcher.ps1 inside this process, on the Windows
// PowerShell engine every Windows 10/11 has (System.Management.Automation).
// It deliberately does not start a hidden powershell.exe: an executable whose
// only job is to spawn a hidden PowerShell is exactly what antivirus
// heuristics look for, and it would also give the launcher window
// powershell.exe's icon instead of this program's.
//
// The script decides everything else; this file only finds it, applies the
// same execution policy PLAY-COD3.cmd uses (AllSigned for a signed package,
// otherwise Bypass for this one session - nothing is changed on the machine),
// passes the command line on and reports a failure that the script could not
// report itself.
//
// Built by Build-LauncherExe.ps1 with the C# compiler that ships with the
// .NET Framework; no SDK or Visual Studio needed.

using System;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Project 1944")]
[assembly: AssemblyDescription("Project 1944 - Call of Duty 3 native PC port launcher (unofficial fan project)")]
[assembly: AssemblyProduct("Project 1944")]
[assembly: AssemblyCopyright("Project 1944 contributors, BSD-3-Clause")]
[assembly: AssemblyVersion("2.1.0.0")]
[assembly: AssemblyFileVersion("2.1.0.0")]

internal static class Program
{
    private const string Caption = "Project 1944";

    [STAThread]
    private static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
        string script = FindScript(root);
        if (script == null)
        {
            MessageBox.Show(
                "launcher\\Cod3Launcher.ps1 was not found next to this program.\n\n" +
                "Unpack the whole archive and run Project1944.exe from its folder.",
                Caption, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        // The package root: the folder holding launcher\.
        string packageRoot = Path.GetDirectoryName(Path.GetDirectoryName(script));
        Environment.CurrentDirectory = packageRoot;

        try
        {
            InitialSessionState state = InitialSessionState.CreateDefault();
            // Same rule as PLAY-COD3.cmd: a signed package is verified script
            // by script, an unsigned one can only run under Bypass. Either way
            // only this session is affected.
            bool signed = File.Exists(Path.Combine(packageRoot, "signing-receipt.json"));
            state.ExecutionPolicy = signed
                ? Microsoft.PowerShell.ExecutionPolicy.AllSigned
                : Microsoft.PowerShell.ExecutionPolicy.Bypass;
            // WPF needs a single-threaded apartment, and the window has to live
            // on this thread for the message loop.
            state.ApartmentState = ApartmentState.STA;
            state.ThreadOptions = PSThreadOptions.UseCurrentThread;

            using (Runspace runspace = RunspaceFactory.CreateRunspace(state))
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                // Lets the script know who hosts it (it then leaves the window
                // icon to this program).
                runspace.SessionStateProxy.SetVariable("Project1944Host", Application.ExecutablePath);
                using (PowerShell shell = PowerShell.Create())
                {
                    shell.Runspace = runspace;
                    shell.AddCommand(script);
                    AddArguments(shell, args);
                    shell.Invoke();

                    object code = runspace.SessionStateProxy.GetVariable("LASTEXITCODE");
                    if (shell.HadErrors && shell.Streams.Error.Count > 0 && args.Length == 0)
                    {
                        // The launcher shows its own errors; anything left here
                        // escaped it (a broken or blocked script, say).
                        ErrorRecord first = shell.Streams.Error[0];
                        ShowFailure(first.ToString() + "\n\n" + first.InvocationInfo.PositionMessage);
                        return 1;
                    }
                    return code is int ? (int)code : 0;
                }
            }
        }
        catch (Exception failure)
        {
            ShowFailure(failure.Message);
            return 1;
        }
    }

    private static string FindScript(string root)
    {
        // The exe sits at the package root, next to the launcher folder.
        string candidate = Path.Combine(root, "launcher", "Cod3Launcher.ps1");
        return File.Exists(candidate) ? candidate : null;
    }

    private static void AddArguments(PowerShell shell, string[] args)
    {
        // -Name value, -Switch, or a bare value, as powershell.exe -File takes them.
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (arg.Length > 1 && arg[0] == '-')
            {
                string name = arg.Substring(1).TrimEnd(':');
                if (i + 1 < args.Length && !(args[i + 1].Length > 1 && args[i + 1][0] == '-'))
                {
                    shell.AddParameter(name, args[++i]);
                }
                else
                {
                    shell.AddParameter(name, true);
                }
            }
            else
            {
                shell.AddArgument(arg);
            }
        }
    }

    private static void ShowFailure(string message)
    {
        string log = Path.Combine(Environment.CurrentDirectory, "logs", "launcher-error.log");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(log));
            File.AppendAllText(log, "[" + DateTime.Now.ToString("o") + "] Project1944.exe: " + message + Environment.NewLine);
        }
        catch (Exception)
        {
        }
        MessageBox.Show(
            "The launcher could not start:\n\n" + message +
            "\n\nIf an antivirus blocked it, launcher\\PLAY-COD3.cmd starts the same launcher without this program.",
            Caption, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
