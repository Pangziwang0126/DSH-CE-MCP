// YQ CE-MCP self-extracting installer.
// Built with: csc /target:exe /out:YQ-CE-MCP-Setup.exe /resource:<each file> installer.cs
// Every payload file is embedded as-is; at run time they are unpacked to a temp
// folder and install.ps1 does the real work.

using System;
using System.IO;
using System.Diagnostics;
using System.Reflection;

class YqSetup
{
    static readonly string[] Files = {
        "YQ-CE-MCP.lua",
        "yq-on.ico",
        "yq-off.ico",
        "install.ps1",
        "install.bat",
        "uninstall.ps1",
        "uninstall.bat",
        "bridge.py",
        "mcp.json",
        "README.md",
        "test_mcp.py"
    };

    static int Main(string[] args)
    {
        bool pause = true;
        foreach (string a in args)
        {
            if (a == "--no-pause") pause = false;
        }

        Console.WriteLine("==========================================");
        Console.WriteLine("  YQ CE-MCP  installer");
        Console.WriteLine("  Cheat Engine  <->  DeepSeek Harness");
        Console.WriteLine("==========================================");
        Console.WriteLine();

        string dir = Path.Combine(Path.GetTempPath(),
            "yq-cemcp-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        Directory.CreateDirectory(dir);

        Assembly asm = Assembly.GetExecutingAssembly();
        int unpacked = 0;

        foreach (string name in Files)
        {
            Stream src = asm.GetManifestResourceStream(name);
            if (src == null)
            {
                Console.WriteLine("[!] missing embedded file: " + name);
                continue;
            }
            using (src)
            {
                using (FileStream dst = File.Create(Path.Combine(dir, name)))
                {
                    src.CopyTo(dst);
                }
            }
            unpacked++;
        }

        Console.WriteLine("[+] unpacked " + unpacked + "/" + Files.Length + " files");
        Console.WriteLine();

        if (unpacked != Files.Length)
        {
            Console.WriteLine("[-] package is incomplete, aborting");
            Finish(pause, dir, 1);
            return 1;
        }

        string script = Path.Combine(dir, "install.ps1");
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"");
        psi.UseShellExecute = false;

        int code = 1;
        try
        {
            Process p = Process.Start(psi);
            p.WaitForExit();
            code = p.ExitCode;
        }
        catch (Exception e)
        {
            Console.WriteLine("[-] cannot start PowerShell: " + e.Message);
        }

        Console.WriteLine();
        if (code == 0)
        {
            Console.WriteLine("[+] done. Cheat Engine and DeepSeek Harness are wired together.");
            try { Directory.Delete(dir, true); }
            catch { }   // a locked file is harmless, the folder is under %TEMP%
        }
        else
        {
            Console.WriteLine("[-] installer exited with code " + code);
            Console.WriteLine("    payload kept at: " + dir);
        }

        if (pause)
        {
            Console.WriteLine();
            try
            {
                Console.Write("Press any key to close...");
                Console.ReadKey();
            }
            catch { }   // stdin redirected, nothing to read
            Console.WriteLine();
        }
        return code;
    }

    static void Finish(bool pause, string dir, int code)
    {
        Console.WriteLine("    payload kept at: " + dir);
        if (pause)
        {
            try
            {
                Console.Write("Press any key to close...");
                Console.ReadKey();
            }
            catch { }
            Console.WriteLine();
        }
    }
}
