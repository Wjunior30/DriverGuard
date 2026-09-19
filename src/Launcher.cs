using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("DriverGuard")]
[assembly: AssemblyProduct("DriverGuard")]
[assembly: AssemblyDescription("Protege seus drivers e avisa quando algo der errado")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace DG
{
    // Usado pela interface (DriverGuard.ps1) para a barra de título escura, sem compilar nada ao abrir.
    public static class Dwm
    {
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            if (args.Length > 0 && args[0] == "--uninstall") return Uninstaller.Run(dir);

            string ps1 = Path.Combine(dir, "DriverGuard.ps1");
            if (!File.Exists(ps1))
            {
                MessageBox.Show("Arquivo DriverGuard.ps1 não encontrado em:\n" + dir + "\n\nReinstale o DriverGuard.",
                    "DriverGuard", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            string extra = "";
            foreach (string a in args) extra += " " + (a.Contains(" ") ? "\"" + a + "\"" : a);

            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"" + extra);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = dir;
            Process.Start(psi);
            return 0;
        }
    }

    public static class Uninstaller
    {
        public static int Run(string dir)
        {
            if (MessageBox.Show("Desinstalar o DriverGuard?", "DriverGuard",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return 0;
            bool wipe = MessageBox.Show(
                "Apagar também o backup do driver de vídeo e as configurações?\n\nEscolha \"Não\" para manter o backup caso reinstale depois.",
                "DriverGuard", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;

            KillRunning();
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
            {
                if (k != null) k.DeleteValue("DriverGuard", false);
            }
            Registry.CurrentUser.DeleteSubKeyTree(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\DriverGuard", false);
            TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "DriverGuard.lnk"));
            TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "DriverGuard.lnk"));

            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string installDir = Path.Combine(local, @"Programs\DriverGuard");
            string dataDir = Path.Combine(local, "DriverGuard");
            string cmd = "/c ping 127.0.0.1 -n 3 >nul";
            // só apaga a pasta se for a pasta de instalação oficial (nunca a pasta de desenvolvimento)
            if (string.Equals(dir.TrimEnd('\\'), installDir, StringComparison.OrdinalIgnoreCase))
                cmd += " & rmdir /s /q \"" + installDir + "\"";
            if (wipe) cmd += " & rmdir /s /q \"" + dataDir + "\"";

            var psi = new ProcessStartInfo("cmd.exe", cmd);
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            psi.WorkingDirectory = Path.GetTempPath();
            Process.Start(psi);
            MessageBox.Show("DriverGuard removido.", "DriverGuard", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }

        static void TryDelete(string f)
        {
            try { if (File.Exists(f)) File.Delete(f); } catch { }
        }

        public static void KillRunning()
        {
            try
            {
                using (var s = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'"))
                {
                    foreach (ManagementObject o in s.Get())
                    {
                        object cl = o["CommandLine"];
                        if (cl != null && cl.ToString().IndexOf("DriverGuard.ps1", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            try { Process.GetProcessById(Convert.ToInt32(o["ProcessId"])).Kill(); } catch { }
                        }
                    }
                }
            }
            catch { }
        }
    }
}
