using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace CodexSwitch {
    public sealed class RestartEvidence {
        public int Id;
        public long StartTime;
        public bool HasWindow;
        public bool SameUser;
        public bool SameSession;
        public bool Elevated;
        public bool Registered;
        public uint Flags;
        public string Error;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct UniqueProcess {
        public uint Id;
        public System.Runtime.InteropServices.ComTypes.FILETIME Start;
        public static UniqueProcess From(int id, long start) {
            return new UniqueProcess { Id=(uint)id, Start=new System.Runtime.InteropServices.ComTypes.FILETIME {
                dwLowDateTime=(int)(start & 0xffffffff), dwHighDateTime=(int)(start >> 32) } };
        }
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct RestartProcessInfo {
        public UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string AppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=64)] public string ServiceName;
        public int AppType;
        public uint Status;
        public uint Session;
        [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
    }
    public static class RestartNative {
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long created, out long exited, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern int GetApplicationRestartSettings(IntPtr process, StringBuilder command, ref uint size, out uint flags);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int kind, out int value, int size, out int needed);
        delegate bool EnumWindowsProc(IntPtr window, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint id);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] static extern int RmStartSession(out uint session, uint flags, StringBuilder key);
        [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint session);
        [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)] static extern int RmRegisterResources(uint session, uint fileCount, string[] files, uint count, UniqueProcess[] processes, uint serviceCount, string[] services);
        [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint session, out uint needed, ref uint count, [In,Out] RestartProcessInfo[] processes, ref uint rebootReasons);
        [DllImport("rstrtmgr.dll")] static extern int RmShutdown(uint session, uint flags, IntPtr callback);
        [DllImport("rstrtmgr.dll")] static extern int RmRestart(uint session, uint flags, IntPtr callback);

        public static RestartEvidence Inspect(int id) {
            var result = new RestartEvidence { Id=id };
            // GetApplicationRestartSettings requires PROCESS_VM_READ.
            IntPtr process=OpenProcess(0x1010, false, id), token=IntPtr.Zero;
            if (process==IntPtr.Zero) { result.Error="process-unavailable"; return result; }
            try {
                long exit, kernel, user;
                if (!GetProcessTimes(process, out result.StartTime, out exit, out kernel, out user)) throw new Win32Exception();
                if (!OpenProcessToken(process, 8, out token)) throw new Win32Exception();
                using (var identity = new WindowsIdentity(token))
                using (var current = WindowsIdentity.GetCurrent()) { result.SameUser = identity.User.Equals(current.User); }
                int elevated, needed;
                if (!GetTokenInformation(token, 20, out elevated, 4, out needed)) throw new Win32Exception();
                result.Elevated=elevated!=0;
                using (var target=Process.GetProcessById(id))
                using (var current=Process.GetCurrentProcess()) { result.SameSession=target.SessionId==current.SessionId; }
                // Read the registration but never return/store its potentially private arguments.
                uint size=1024, flags;
                var command=new StringBuilder((int)size);
                int hr=GetApplicationRestartSettings(process, command, ref size, out flags);
                if (hr==unchecked((int)0x8007007a) && size<=32768) {
                    command=new StringBuilder((int)size);
                    hr=GetApplicationRestartSettings(process, command, ref size, out flags);
                }
                result.Registered=hr==0;
                result.Flags=flags;
                EnumWindows(delegate(IntPtr window, IntPtr data) {
                    uint owner; GetWindowThreadProcessId(window, out owner);
                    if (owner==(uint)id && IsWindowVisible(window)) result.HasWindow=true;
                    return true;
                }, IntPtr.Zero);
            } catch { result.Error="inspection-failed"; }
            finally { if (token!=IntPtr.Zero) CloseHandle(token); CloseHandle(process); }
            return result;
        }
        public static uint Begin(UniqueProcess[] processes) {
            uint session;
            int code=RmStartSession(out session, 0, new StringBuilder(33));
            if (code!=0) throw new Win32Exception(code, "Restart Manager session failed");
            code=RmRegisterResources(session, 0, null, (uint)processes.Length, processes, 0, null);
            if (code!=0) { RmEndSession(session); throw new Win32Exception(code, "Restart registration failed"); }
            return session;
        }
        public static RestartProcessInfo[] List(uint session) {
            for (int retry=0; retry<5; retry++) {
                uint needed=0, count=0, reasons=0;
                int code=RmGetList(session, out needed, ref count, null, ref reasons);
                if (reasons!=0) throw new InvalidOperationException("Restart Manager requires a system reboot");
                if (code==0) return new RestartProcessInfo[0];
                if (code!=234) throw new Win32Exception(code, "Restart Manager inspection failed");
                var list=new RestartProcessInfo[needed]; count=needed;
                code=RmGetList(session, out needed, ref count, list, ref reasons);
                if (reasons!=0) throw new InvalidOperationException("Restart Manager requires a system reboot");
                if (code==234) continue;
                if (code!=0) throw new Win32Exception(code, "Restart Manager inspection failed");
                Array.Resize(ref list, (int)count);
                return list;
            }
            throw new InvalidOperationException("Restart Manager process list did not stabilize");
        }
        // Never force termination. Windows itself refuses an unregistered target.
        public static int Shutdown(uint session) { return RmShutdown(session, 0x10, IntPtr.Zero); }
        public static int Restart(uint session) { return RmRestart(session, 0, IntPtr.Zero); }
        public static void End(uint session) { RmEndSession(session); }
    }
}
