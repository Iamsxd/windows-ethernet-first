using System;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;

namespace EthernetFirst {
    public static class Probe {
        // Bind both source and egress interface: a normal TCP test may follow the VPN.
        // 1 = reachable, 0 = failed, -1 = locally blocked/unknown (never force failover).
        public static int Check(int index, string source, string[] targets, int timeoutMs) {
            var jobs = new Task<int>[targets.Length];
            for (int n = 0; n < targets.Length; n++) {
                string target = targets[n];
                jobs[n] = One(index, source, target, timeoutMs);
            }
            Task.WaitAll(jobs);
            foreach (var job in jobs) if (job.Result == 1) return 1;
            foreach (var job in jobs) if (job.Result == -1) return -1;
            return 0;
        }
        private static async Task<int> One(int index, string source, string target, int timeoutMs) {
            var local = IPAddress.Parse(source);
            using (var socket = new Socket(local.AddressFamily, SocketType.Stream, ProtocolType.Tcp)) {
                try {
                    var level = local.AddressFamily == AddressFamily.InterNetwork ? SocketOptionLevel.IP : SocketOptionLevel.IPv6;
                    int value = local.AddressFamily == AddressFamily.InterNetwork ? IPAddress.HostToNetworkOrder(index) : index;
                    socket.SetSocketOption(level, (SocketOptionName)31, value); // IP[V6]_UNICAST_IF
                    socket.Bind(new IPEndPoint(local, 0));
                    var connect = Task.Factory.FromAsync(socket.BeginConnect, socket.EndConnect, new IPEndPoint(IPAddress.Parse(target), 443), null);
                    var completed = await Task.WhenAny(connect, Task.Delay(timeoutMs)).ConfigureAwait(false);
                    if (completed != connect) {
                        // Observe an eventual exception after the socket is closed on timeout.
                        var observation = connect.ContinueWith(t => { var ignored = t.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
                        return 0;
                    }
                    await connect.ConfigureAwait(false);
                    return socket.Connected ? 1 : 0;
                } catch (SocketException ex) { return ex.SocketErrorCode == SocketError.AccessDenied ? -1 : 0; }
                  catch (ObjectDisposedException) { return 0; }
            }
        }
    }
}
