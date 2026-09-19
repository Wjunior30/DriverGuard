using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("DriverGuard - Instalador")]
[assembly: AssemblyProduct("DriverGuard")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace DG
{
    static class Setup
    {
        const string Title = "DriverGuard — Instalador";

        [STAThread]
        static int Main()
        {
            string target = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\DriverGuard");
            string msg = "Instalar o DriverGuard 1.0 neste PC?\n\n" +
                         "•  Não precisa de administrador\n" +
                         "•  Não instala nenhum driver sem você confirmar\n" +
                         "•  Pode ser removido em Configurações → Apps\n\n" +
                         "Pasta: " + target;
            if (MessageBox.Show(msg, Title, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return 0;

            string exe = Path.Combine(target, "DriverGuard.exe");
            bool watch = false;
            try
            {
                KillRunning();
                Directory.CreateDirectory(target);
                Extract("DriverGuard.ps1", target);
                Extract("DriverGuard.exe", target);
                Extract("DriverGuard.ico", target);

                Shortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "DriverGuard.lnk"), exe, target);
                Shortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "DriverGuard.lnk"), exe, target);

                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\DriverGuard"))
                {
                    k.SetValue("DisplayName", "DriverGuard");
                    k.SetValue("DisplayVersion", "1.0.0");
                    k.SetValue("Publisher", "DriverGuard");
                    k.SetValue("DisplayIcon", Path.Combine(target, "DriverGuard.ico"));
                    k.SetValue("InstallLocation", target);
                    k.SetValue("UninstallString", "\"" + exe + "\" --uninstall");
                    k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
                    k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                    k.SetValue("EstimatedSize", (int)(DirSize(target) / 1024), RegistryValueKind.DWord);
                }
                using (RegistryKey r = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (r != null && r.GetValue("DriverGuard") != null)
                    {
                        r.SetValue("DriverGuard", "\"" + exe + "\" -Watch");
                        watch = true;
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Erro na instalação:\n\n" + ex.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }

            if (watch) Process.Start(exe, "-Watch");
            if (MessageBox.Show("DriverGuard instalado!\n\nAtalhos criados na Área de Trabalho e no Menu Iniciar.\n\nAbrir agora?",
                    Title, MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
                Process.Start(exe);
            return 0;
        }

        static void Extract(string name, string dir)
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            using (FileStream f = File.Create(Path.Combine(dir, name)))
            {
                s.CopyTo(f);
            }
        }

        static void Shortcut(string lnk, string exe, string dir)
        {
            Type t = Type.GetTypeFromProgID("WScript.Shell");
            object sh = Activator.CreateInstance(t);
            object sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, sh, new object[] { lnk });
            Type st = sc.GetType();
            st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { exe });
            st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { dir });
            st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { exe + ",0" });
            st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "DriverGuard" });
            st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
        }

        static long DirSize(string d)
        {
            long n = 0;
            foreach (string f in Directory.GetFiles(d, "*", SearchOption.AllDirectories)) n += new FileInfo(f).Length;
            return n;
        }

        static void KillRunning()
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
