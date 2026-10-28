using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexSwitch {
    // Launch recipes live only in memory. Never serialize command lines.
    public sealed class LaunchRecipe {
        public int Id;
        public long StartTime;
        public string Executable;
        public string Arguments;
        public string WorkingDirectory;
        public bool Console;
    }
    public static class FallbackNative {
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle, out long start, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsWow64Process(IntPtr process, out bool wow64);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process, int kind, IntPtr buffer, int size, out int returned);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
        delegate bool EnumProc(IntPtr window, IntPtr state);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr state);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint id);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);

        static IntPtr OpenExact(int id, long expected, uint access) {
            IntPtr handle=OpenProcess(access | 0x1000, false, id);
            if (handle==IntPtr.Zero) throw new InvalidOperationException("Process is unavailable");
            long start, exit, kernel, user;
            if (!GetProcessTimes(handle, out start, out exit, out kernel, out user) || start!=expected || exit!=0) {
                CloseHandle(handle); throw new InvalidOperationException("Process identity changed");
            }
            return handle;
        }
        public static bool Alive(int id, long expected) {
            // Do not treat access denied as an exited process and accidentally launch a duplicate.
            IntPtr handle=OpenProcess(0x1000, false, id);
            if (handle==IntPtr.Zero) {
                int code=Marshal.GetLastWin32Error();
                if (code==87) return false;
                throw new Win32Exception(code, "Process liveness could not be inspected");
            }
            try {
                long start, exit, kernel, user;
                if (!GetProcessTimes(handle, out start, out exit, out kernel, out user)) throw new Win32Exception();
                return start==expected && exit==0;
            } finally { CloseHandle(handle); }
        }
        static byte[] Read(IntPtr process, long address, int size) {
            byte[] buffer=new byte[size]; IntPtr read;
            if (address==0 || !ReadProcessMemory(process, new IntPtr(address), buffer, new IntPtr(size), out read) || read.ToInt64()!=size)
                throw new InvalidOperationException("Original working directory is unavailable");
            return buffer;
        }
        static long Pointer(byte[] bytes, int offset, int width) {
            return width==8 ? BitConverter.ToInt64(bytes, offset) : (long)BitConverter.ToUInt32(bytes, offset);
        }
        // Read only CurrentDirectory from RTL_USER_PROCESS_PARAMETERS, never the environment.
        // Layout is Windows-specific; bounds/read checks fail before any shutdown if unavailable.
        static string CurrentDirectory(IntPtr process) {
            bool wow;
            if (!IsWow64Process(process, out wow)) throw new Win32Exception();
            if (IntPtr.Size!=8 && Environment.Is64BitOperatingSystem)
                throw new InvalidOperationException("Use 64-bit PowerShell to capture working directories");
            int width=wow ? 4 : IntPtr.Size;
            IntPtr info=Marshal.AllocHGlobal(IntPtr.Size*6);
            try {
                int returned; long peb;
                if (wow && IntPtr.Size==8) {
                    if (NtQueryInformationProcess(process, 26, info, IntPtr.Size, out returned)!=0) throw new InvalidOperationException("Process layout unavailable");
                    peb=Marshal.ReadIntPtr(info).ToInt64();
                } else {
                    if (NtQueryInformationProcess(process, 0, info, IntPtr.Size*6, out returned)!=0) throw new InvalidOperationException("Process layout unavailable");
                    peb=Marshal.ReadIntPtr(info, IntPtr.Size).ToInt64();
                }
                long parameters=Pointer(Read(process, peb+(width==8 ? 0x20 : 0x10), width), 0, width);
                byte[] directory=Read(process, parameters+(width==8 ? 0x38 : 0x24), width==8 ? 16 : 8);
                int length=BitConverter.ToUInt16(directory, 0);
                if (length==0 || length>32766 || length%2!=0) throw new InvalidOperationException("Working directory layout unavailable");
                string path=Encoding.Unicode.GetString(Read(process, Pointer(directory, width==8 ? 8 : 4, width), length));
                if (!Path.IsPathRooted(path) || !Directory.Exists(path)) throw new InvalidOperationException("Original working directory no longer exists");
                return path;
            } finally { Marshal.FreeHGlobal(info); }
        }
        public static string ArgumentTail(string command) {
            if (String.IsNullOrWhiteSpace(command)) throw new InvalidOperationException("Original command line is unavailable");
            int i=0; bool quoted=false;
            while (i<command.Length && Char.IsWhiteSpace(command[i])) i++;
            for (; i<command.Length; i++) {
                if (command[i]=='"') quoted=!quoted;
                else if (!quoted && Char.IsWhiteSpace(command[i])) break;
            }
            if (quoted) throw new InvalidOperationException("Original command line is malformed");
            return command.Substring(i).TrimStart();
        }
        public static LaunchRecipe Capture(int id, long start, string executable, string command, bool console) {
            IntPtr process=OpenExact(id, start, 0x410);
            try {
                if (!Path.IsPathRooted(executable) || !File.Exists(executable)) throw new InvalidOperationException("Original executable is unavailable");
                return new LaunchRecipe { Id=id, StartTime=start, Executable=executable,
                    Arguments=ArgumentTail(command), WorkingDirectory=CurrentDirectory(process), Console=console };
            } finally { CloseHandle(process); }
        }
        public static void Close(int id, long start, bool console) {
            IntPtr process=OpenExact(id, start, console ? 1u : 0u);
            try {
                if (console) {
                    if (!TerminateProcess(process, 0)) throw new Win32Exception();
                } else {
                    int count=0; bool failed=false;
                    EnumWindows(delegate(IntPtr window, IntPtr state) {
                        uint owner; GetWindowThreadProcessId(window, out owner);
                        if (owner==(uint)id && IsWindowVisible(window)) {
                            count++; if (!PostMessage(window, 0x10, IntPtr.Zero, IntPtr.Zero)) failed=true;
                        }
                        return true;
                    }, IntPtr.Zero);
                    if (count==0 || failed) throw new InvalidOperationException("Application close request failed");
                }
            } finally { CloseHandle(process); }
        }
        public static int Launch(LaunchRecipe recipe) {
            if (recipe.Console) return LaunchConsole(recipe);
            // Use the Windows Shell's normal executable-open path, like Explorer.
            // Preserve launch context without creating a command shell or redirecting logs.
            var info=new ProcessStartInfo(recipe.Executable, recipe.Arguments) {
                WorkingDirectory=recipe.WorkingDirectory, UseShellExecute=true, Verb="open"
            };
            using (Process process=Process.Start(info)) {
                if (process==null) throw new InvalidOperationException("Windows Shell did not return a restarted process");
                return process.Id;
            }
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo {
            public int Size; public string Reserved, Desktop, Title;
            public int X,Y,XSize,YSize,XChars,YChars,Fill,Flags;
            public short Show, ReservedSize; public IntPtr ReservedPtr, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process, Thread; public int Id, ThreadId; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr environment, string cwd, ref StartupInfo startup, out ProcessInfo process);
        static int LaunchConsole(LaunchRecipe recipe) {
            var startup=new StartupInfo(); startup.Size=Marshal.SizeOf(startup); ProcessInfo result;
            var command=new StringBuilder("\""+recipe.Executable+"\" "+recipe.Arguments);
            if (!CreateProcess(recipe.Executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x10, IntPtr.Zero, recipe.WorkingDirectory, ref startup, out result))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Console restart failed");
            CloseHandle(result.Thread); CloseHandle(result.Process); return result.Id;
        }
    }
}
