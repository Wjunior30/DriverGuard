using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("HollowDrivers - Instalador")]
[assembly: AssemblyProduct("HollowDrivers")]

namespace DG
{
    static class Setup
    {
        const string Title = "HollowDrivers — Instalador";
        const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\HollowDrivers";

        // /silent = atualização automática feita pelo próprio app (sem perguntas, reabre o app no fim)
        [STAThread]
        static int Main(string[] args)
        {
            bool silent = Array.Exists(args, a => a.Equals("/silent", StringComparison.OrdinalIgnoreCase));
            string target = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\HollowDrivers");
            string exe = Path.Combine(target, "HollowDrivers.exe");
            string installed = InstalledVersion();
            bool legacyInstalled = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\DriverGuard") != null;

            if (!silent && !Confirm(installed, target)) return 0;

            bool watch = false;
            try
            {
                KillRunning();
                Directory.CreateDirectory(target);
                Extract("HollowDrivers.ps1", target);
                Extract("HollowDrivers.exe", target);
                Extract("HollowDrivers.ico", target);

                Shortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "HollowDrivers.lnk"), exe, target);
                Shortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "HollowDrivers.lnk"), exe, target);

                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(UninstallKey))
                {
                    k.SetValue("DisplayName", "HollowDrivers");
                    k.SetValue("DisplayVersion", Ver.V);
                    k.SetValue("Publisher", "HollowDrivers");
                    k.SetValue("DisplayIcon", Path.Combine(target, "HollowDrivers.ico"));
                    k.SetValue("InstallLocation", target);
                    k.SetValue("UninstallString", "\"" + exe + "\" --uninstall");
                    k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
                    k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                    k.SetValue("EstimatedSize", (int)(DirSize(target) / 1024), RegistryValueKind.DWord);
                }
                using (RegistryKey r = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                {
                    if (r != null)
                    {
                        watch = r.GetValue("HollowDrivers") != null || r.GetValue("DriverGuard") != null;
                        if (watch) r.SetValue("HollowDrivers", "\"" + exe + "\" -Watch");
                        if (legacyInstalled) r.DeleteValue("DriverGuard", false);
                    }
                }
                if (legacyInstalled)
                {
                    Registry.CurrentUser.DeleteSubKeyTree(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\DriverGuard", false);
                    TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "DriverGuard.lnk"));
                    TryDelete(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "DriverGuard.lnk"));
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Erro na instalação:\n\n" + ex.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }

            if (watch) Process.Start(exe, "-Watch");
            if (silent)
            {
                Process.Start(exe);
                return 0;
            }
            string done = installed == null
                ? "HollowDrivers " + Ver.V + " instalado!\n\nAtalhos criados na Área de Trabalho e no Menu Iniciar."
                : "HollowDrivers atualizado para a versão " + Ver.V + "!\n\nSeu backup e suas configurações foram mantidos.";
            if (MessageBox.Show(done + "\n\nAbrir agora?", Title, MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
                Process.Start(exe);
            return 0;
        }

        static bool Confirm(string installed, string target)
        {
            string msg;
            MessageBoxIcon icon = MessageBoxIcon.Question;
            int cmp = installed == null ? 1 : Compare(Ver.V, installed);
            if (installed == null)
                msg = "Instalar o HollowDrivers " + Ver.V + " neste PC?\n\n" +
                      "•  Não precisa de administrador\n" +
                      "•  Não instala nenhum driver sem você confirmar\n" +
                      "•  Pode ser removido em Configurações → Apps\n\n" +
                      "Pasta: " + target;
            else if (cmp > 0)
                msg = "Atualizar o HollowDrivers da versão " + installed + " para a " + Ver.V + "?\n\n" +
                      "Seu backup do driver de vídeo e suas configurações serão mantidos.";
            else if (cmp == 0)
                msg = "O HollowDrivers " + Ver.V + " já está instalado.\n\nReinstalar mesmo assim? (útil se algo parou de funcionar)";
            else
            {
                msg = "Você já tem uma versão MAIS NOVA instalada (" + installed + ").\n\n" +
                      "Instalar a versão " + Ver.V + " por cima vai voltar para uma versão mais antiga. Continuar?";
                icon = MessageBoxIcon.Warning;
            }
            return MessageBox.Show(msg, Title, MessageBoxButtons.YesNo, icon) == DialogResult.Yes;
        }

        static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }

        static string InstalledVersion()
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(UninstallKey))
            {
                object v = k == null ? null : k.GetValue("DisplayVersion");
                if (v == null)
                {
                    using (RegistryKey legacy = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\DriverGuard"))
                        v = legacy == null ? null : legacy.GetValue("DisplayVersion");
                }
                return v == null ? null : v.ToString();
            }
        }

        static int Compare(string a, string b)
        {
            Version va, vb;
            if (!Version.TryParse(a, out va) || !Version.TryParse(b, out vb)) return string.CompareOrdinal(a, b);
            return va.CompareTo(vb);
        }

        // O app que acabou de ser fechado pode segurar o arquivo por alguns instantes: tenta de novo por até 15 s.
        static void Extract(string name, string dir)
        {
            for (int i = 0; ; i++)
            {
                try
                {
                    using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
                    using (FileStream f = File.Create(Path.Combine(dir, name)))
                    {
                        s.CopyTo(f);
                    }
                    return;
                }
                catch (IOException)
                {
                    if (i >= 30) throw;
                    System.Threading.Thread.Sleep(500);
                }
                catch (UnauthorizedAccessException)
                {
                    if (i >= 30) throw;
                    System.Threading.Thread.Sleep(500);
                }
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
            st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "HollowDrivers" });
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
                        if (cl != null && (cl.ToString().IndexOf("HollowDrivers.ps1", StringComparison.OrdinalIgnoreCase) >= 0 || cl.ToString().IndexOf("DriverGuard.ps1", StringComparison.OrdinalIgnoreCase) >= 0))
                        {
                            try
                            {
                                Process p = Process.GetProcessById(Convert.ToInt32(o["ProcessId"]));
                                p.Kill();
                                p.WaitForExit(5000);   // espera o processo sair de verdade e soltar os arquivos
                            }
                            catch { }
                        }
                    }
                }
            }
            catch { }
        }
    }
}
