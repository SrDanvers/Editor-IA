using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

namespace EditorIA
{
    internal static class Launcher
    {
        private static void ExtractResource(string resource, string filename, string folder)
        {
            string path = Path.Combine(folder, filename);
            // Always refresh bundled scripts so an updated EXE never starts an older version.
            // The user's media and settings live elsewhere and are not replaced.
            using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
            {
                if (input == null) throw new FileNotFoundException("Recurso nao encontrado no EXE: " + resource);
                using (FileStream output = File.Create(path))
                {
                    input.CopyTo(output);
                }
            }
        }

        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            try
            {
                string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                string workDir = exeDir;
                bool writable = true;
                string marker = Path.Combine(exeDir, ".editoria-write-test");
                try
                {
                    File.WriteAllText(marker, "ok");
                    File.Delete(marker);
                }
                catch { writable = false; }

                if (!writable)
                {
                    workDir = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "EditorIA", "1.3");
                    Directory.CreateDirectory(workDir);
                }

                ExtractResource("EditorIA.Main", "EditorIA.ps1", workDir);
                ExtractResource("EditorIA.Start", "Iniciar_EditorIA.ps1", workDir);

                // Se uma pasta com musicas for mantida ao lado do EXE, usa essa pasta.
                // O script procura $PSScriptRoot\Musicas por padrao.
                if (workDir != exeDir)
                {
                    string musicSource = Path.Combine(exeDir, "Musicas");
                    string musicDest = Path.Combine(workDir, "Musicas");
                    if (Directory.Exists(musicSource) && !Directory.Exists(musicDest))
                    {
                        Directory.CreateDirectory(musicDest);
                    }
                }

                string starter = Path.Combine(workDir, "Iniciar_EditorIA.ps1");
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "WindowsPowerShell\\v1.0\\powershell.exe");
                if (!File.Exists(psi.FileName)) psi.FileName = "powershell.exe";
                psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File \"" + starter + "\"";
                psi.WorkingDirectory = workDir;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                using (Process p = Process.Start(psi))
                {
                    if (p == null) throw new Exception("PowerShell nao iniciou.");
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Nao foi possivel abrir o Editor IA.\n\n" + ex.Message +
                    "\n\nExtraia o ZIP completo e abra novamente.",
                    "Editor IA - Erro ao iniciar",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
