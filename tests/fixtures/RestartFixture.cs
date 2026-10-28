using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Only tests start this deliberately invisible fixture, from an isolated temp folder.
class RestartFixture : Form {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern int RegisterApplicationRestart(string args, int flags);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr handle);
    [DllImport("kernel32.dll")] static extern uint GetConsoleProcessList([Out] uint[] processes, uint count);
    [DllImport("kernel32.dll")] static extern bool WriteFile(IntPtr file, byte[] bytes, int size, out int written, IntPtr overlapped);
    readonly bool cancel;
    RestartFixture(bool cancelClose, bool tray) {
        cancel=cancelClose; ShowInTaskbar=false; Opacity=0;
        FormBorderStyle=FormBorderStyle.FixedToolWindow;
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (cancel) e.Cancel=true; if (tray) {e.Cancel=true; Hide();} };
    }
    protected override void WndProc(ref Message message) {
        if (message.Msg==0x11) { message.Result=new IntPtr(cancel ? 0 : 1); return; }
        if (message.Msg==0x16 && message.WParam!=IntPtr.Zero) { Environment.Exit(0); }
        base.WndProc(ref message);
    }
    [STAThread] static void Main(string[] args) {
        string directory=AppDomain.CurrentDomain.BaseDirectory;
        File.WriteAllLines(Path.Combine(directory, Process.GetCurrentProcess().Id+".started"),
            new string[] { Environment.CurrentDirectory, String.Join("|",args) });
        if (args.Length>0 && args[0]=="isolated-output") {
            byte[] message=System.Text.Encoding.UTF8.GetBytes("fixture-log-must-not-reach-switch\n");
            int written;
            bool stdout=WriteFile(GetStdHandle(-11), message, message.Length, out written, IntPtr.Zero);
            bool stderr=WriteFile(GetStdHandle(-12), message, message.Length, out written, IntPtr.Zero);
            File.WriteAllLines(Path.Combine(directory, Process.GetCurrentProcess().Id+".stdio"), new string[] {
                GetFileType(GetStdHandle(-10)).ToString(), GetFileType(GetStdHandle(-11)).ToString(), GetFileType(GetStdHandle(-12)).ToString(),
                GetConsoleProcessList(new uint[8], 8).ToString(), stdout.ToString(), stderr.ToString()
            });
        }
        if (args.Length>0 && args[0]=="registered") RegisterApplicationRestart("registered", 0);
        Application.Run(new RestartFixture(args.Length>0 && args[0]=="cancel", args.Length>0 && args[0]=="tray"));
    }
}
