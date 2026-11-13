using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

namespace EthernetFirst {
    public static class Persistence {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool MoveFileEx(string source, string destination, uint flags);

        public static void Replace(string source, string destination) {
            // Source is flushed and in the same directory: perform one rename,
            // with replacement and write-through, never delete the baseline first.
            for (int attempt=0; ; attempt++) {
                if (MoveFileEx(source, destination, 0x1 | 0x8)) return;
                int error=Marshal.GetLastWin32Error();
                if (attempt>=99 || (error!=5 && error!=32 && error!=33)) throw new Win32Exception(error);
                Thread.Sleep(5);
            }
        }
    }
}
