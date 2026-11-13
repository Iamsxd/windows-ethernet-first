using System;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace EthernetFirst {
    public static class Probe {
        // All DNS, connect, TLS and HTTP operations in a round share this deadline.
        private sealed class Budget : IDisposable {
            readonly Stopwatch watch = Stopwatch.StartNew();
            readonly int timeout;
            public readonly CancellationTokenSource Cancellation = new CancellationTokenSource();
            public Budget(int milliseconds) { timeout = milliseconds; Cancellation.CancelAfter(milliseconds); }
            public int Remaining { get { return Math.Max(0, timeout - (int)Math.Min(int.MaxValue, watch.ElapsedMilliseconds)); } }
            public void Dispose() { Cancellation.Cancel(); Cancellation.Dispose(); }
        }

        public static int CheckHttps(int index, string source, string[] dnsServers, string[] endpoints, int timeoutMs) {
            IPAddress local;
            if (index < 1 || timeoutMs < 1 || !IPAddress.TryParse(source, out local) || endpoints == null) return 0;
            using (var budget = new Budget(timeoutMs)) {
                var jobs = new List<Task<int>>();
                // A malformed or unexpectedly large configuration cannot create unbounded work.
                for (int n = 0; n < Math.Min(2, endpoints.Length); n++)
                    jobs.Add(HttpsOne(index, local, dnsServers ?? new string[0], endpoints[n], budget));
                bool blocked = false;
                while (jobs.Count != 0) {
                    var finished = Task.WhenAny(jobs).GetAwaiter().GetResult();
                    jobs.Remove(finished);
                    int result = finished.GetAwaiter().GetResult();
                    if (result == 1) {
                        budget.Cancellation.Cancel();
                        Task.WaitAll(jobs.ToArray());
                        return 1;
                    }
                    if (result == -1) blocked = true;
                }
                return blocked ? -1 : 0;
            }
        }

        private sealed class LocalProbeException : Exception {
            public LocalProbeException(Exception inner) : base("Cannot prepare the selected local interface", inner) { }
        }

        private static bool IsLocalFailure(Exception error) {
            for (Exception e = error; e != null; e = e.InnerException) {
                if (e is LocalProbeException) return true;
                var socketError = e as SocketException;
                if (socketError != null && socketError.SocketErrorCode == SocketError.AccessDenied) return true;
            }
            return false;
        }

        private static Socket BoundSocket(int index, IPAddress local, SocketType type, ProtocolType protocol) {
            Socket socket = null;
            try {
                socket = new Socket(local.AddressFamily, type, protocol);
                var level = local.AddressFamily == AddressFamily.InterNetwork ? SocketOptionLevel.IP : SocketOptionLevel.IPv6;
                socket.SetSocketOption(level, (SocketOptionName)31,
                    local.AddressFamily == AddressFamily.InterNetwork ? IPAddress.HostToNetworkOrder(index) : index);
                socket.Bind(new IPEndPoint(local, 0));
                return socket;
            } catch (Exception ex) {
                if (socket != null) socket.Dispose();
                // No network attempt has happened: stale source/interface and unsupported
                // local socket options cannot establish that the Internet is unavailable.
                throw new LocalProbeException(ex);
            }
        }

        private static async Task Timed(Task operation, Budget budget, int maximum) {
            int remaining = Math.Min(budget.Remaining, maximum);
            if (remaining > 0 && !budget.Cancellation.IsCancellationRequested &&
                await Task.WhenAny(operation, Task.Delay(remaining, budget.Cancellation.Token)).ConfigureAwait(false) == operation) {
                await operation.ConfigureAwait(false);
                return;
            }
            // Closing the owning socket aborts pending I/O. Observe any later completion fault.
            var observation = operation.ContinueWith(t => { var ignored = t.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
            throw new TimeoutException();
        }

        private static async Task<int> HttpsOne(int index, IPAddress local, string[] servers, string endpoint, Budget budget) {
            try {
                Uri uri;
                if (!Uri.TryCreate(endpoint, UriKind.Absolute, out uri) || uri.Scheme != "https" ||
                    uri.UserInfo.Length != 0 || uri.Host.Length == 0 || uri.Fragment.Length != 0) return 0;
                string host = uri.IdnHost.Trim('[', ']');
                IPAddress literal;
                IPAddress[] addresses;
                if (IPAddress.TryParse(host, out literal))
                    addresses = literal.AddressFamily == local.AddressFamily ? new IPAddress[] { literal } : new IPAddress[0];
                else addresses = await Resolve(index, local, servers, host, budget).ConfigureAwait(false);
                bool blocked = false;
                foreach (var remote in addresses) {
                    try {
                        using (var socket = BoundSocket(index, local, SocketType.Stream, ProtocolType.Tcp))
                        using (budget.Cancellation.Token.Register(() => socket.Dispose())) {
                            var connect = Task.Factory.FromAsync(socket.BeginConnect, socket.EndConnect, new IPEndPoint(remote, uri.Port), null);
                            await Timed(connect, budget, int.MaxValue).ConfigureAwait(false);
                            using (var stream = new NetworkStream(socket, false))
                            // The default validator enforces both hostname and platform trust; no proxy API is used.
                            using (var tls = new SslStream(stream, false)) {
                                await Timed(tls.AuthenticateAsClientAsync(host, null, SslProtocols.Tls12, false), budget, int.MaxValue).ConfigureAwait(false);
                                string authority = uri.HostNameType == UriHostNameType.IPv6 ? "[" + host + "]" : host;
                                if (!uri.IsDefaultPort) authority += ":" + uri.Port;
                                byte[] request = Encoding.ASCII.GetBytes("GET " + uri.PathAndQuery + " HTTP/1.1\r\nHost: " + authority + "\r\nConnection: close\r\n\r\n");
                                await Timed(tls.WriteAsync(request, 0, request.Length), budget, int.MaxValue).ConfigureAwait(false);
                                byte[] headers = new byte[16384];
                                int used = 0;
                                while (used < headers.Length) {
                                    var read = tls.ReadAsync(headers, used, headers.Length - used);
                                    await Timed(read, budget, int.MaxValue).ConfigureAwait(false);
                                    if (read.Result == 0) break;
                                    used += read.Result;
                                    if (HeaderEnd(headers, used) >= 0) return HeadersAre204(headers, used) ? 1 : 0;
                                }
                            }
                        }
                    } catch (Exception ex) { if (IsLocalFailure(ex)) blocked = true; }
                    if (budget.Remaining == 0 || budget.Cancellation.IsCancellationRequested) break;
                }
                return blocked ? -1 : 0;
            } catch (Exception ex) { return IsLocalFailure(ex) ? -1 : 0; }
        }

        private static async Task<IPAddress[]> Resolve(int index, IPAddress local, string[] servers, string host, Budget budget) {
            bool blocked = false, available = false;
            for (int n = 0; n < Math.Min(2, servers.Length); n++) {
                IPAddress server;
                if (!IPAddress.TryParse(servers[n], out server) || server.AddressFamily != local.AddressFamily) continue;
                available = true;
                string question = host;
                var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                try {
                    for (int depth = 0; depth < 8 && visited.Add(question); depth++) {
                        if (budget.Remaining == 0 || budget.Cancellation.IsCancellationRequested) break;
                        using (var socket = BoundSocket(index, local, SocketType.Dgram, ProtocolType.Udp))
                        using (budget.Cancellation.Token.Register(() => socket.Dispose())) {
                            socket.Connect(new IPEndPoint(server, 53));
                            byte[] random = new byte[2];
                            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(random);
                            int id = (random[0] << 8) | random[1];
                            byte[] query = DnsQuery(question, local.AddressFamily, id);
                            var send = Task.Factory.FromAsync<int>((cb, state) => socket.BeginSend(query, 0, query.Length, SocketFlags.None, cb, state), socket.EndSend, null);
                            await Timed(send, budget, 1000).ConfigureAwait(false);
                            byte[] response = new byte[4096];
                            var receive = Task.Factory.FromAsync<int>((cb, state) => socket.BeginReceive(response, 0, response.Length, SocketFlags.None, cb, state), socket.EndReceive, null);
                            await Timed(receive, budget, 1000).ConfigureAwait(false);
                            byte[] packet = new byte[receive.Result]; Array.Copy(response, packet, packet.Length);
                            var answer = ParseDnsResponse(packet, id, question, local.AddressFamily);
                            if (answer.Addresses.Length != 0) return answer.Addresses;
                            if (String.Equals(answer.CanonicalName, question, StringComparison.OrdinalIgnoreCase)) break;
                            question = answer.CanonicalName;
                        }
                    }
                } catch (Exception ex) { if (IsLocalFailure(ex)) blocked = true; }
            }
            // A missing usable DNS configuration is not evidence that the link is offline.
            if (blocked || !available) throw new SocketException((int)SocketError.AccessDenied);
            return new IPAddress[0];
        }

        private static byte[] DnsQuery(string host, AddressFamily family, int id) {
            using (var stream = new MemoryStream()) {
                Put16(stream, id); Put16(stream, 0x100); Put16(stream, 1);
                Put16(stream, 0); Put16(stream, 0); Put16(stream, 0);
                if (host.Length > 253) throw new FormatException("DNS name too long");
                foreach (string label in host.TrimEnd('.').Split('.')) {
                    if (label.Length < 1 || label.Length > 63) throw new FormatException("Invalid DNS label");
                    byte[] bytes = Encoding.ASCII.GetBytes(label);
                    stream.WriteByte((byte)bytes.Length); stream.Write(bytes, 0, bytes.Length);
                }
                stream.WriteByte(0); Put16(stream, family == AddressFamily.InterNetwork ? 1 : 28); Put16(stream, 1);
                return stream.ToArray();
            }
        }

        private static void Put16(Stream stream, int value) { stream.WriteByte((byte)(value >> 8)); stream.WriteByte((byte)value); }
        private static int Read16(byte[] packet, ref int offset) {
            if (offset < 0 || offset + 2 > packet.Length) throw new FormatException("Truncated DNS field");
            int value = (packet[offset] << 8) | packet[offset + 1]; offset += 2; return value;
        }
        private static string ReadName(byte[] packet, ref int offset, HashSet<int> nameBoundaries) {
            int cursor = offset, resume = -1, steps = 0;
            var seen = new HashSet<int>();
            var name = new StringBuilder();
            while (true) {
                if (cursor >= packet.Length || !seen.Add(cursor) || ++steps > 128) throw new FormatException("Invalid DNS name");
                int boundary = cursor;
                int count = packet[cursor++];
                if ((count & 0xc0) == 0xc0) {
                    if (cursor >= packet.Length) throw new FormatException("Truncated DNS pointer");
                    int target = ((count & 63) << 8) | packet[cursor++];
                    // RFC 1035 compression refers to a prior domain-name occurrence,
                    // never arbitrary header/RDATA bytes or a name later in the packet.
                    if (target >= boundary || !nameBoundaries.Contains(target)) throw new FormatException("Invalid DNS pointer target");
                    nameBoundaries.Add(boundary);
                    if (resume < 0) resume = cursor;
                    cursor = target; continue;
                }
                if (count == 0) { nameBoundaries.Add(boundary); offset = resume < 0 ? cursor : resume; return name.ToString(); }
                if (count > 63 || cursor + count > packet.Length) throw new FormatException("Invalid DNS label");
                nameBoundaries.Add(boundary);
                if (name.Length != 0) name.Append('.');
                for (int n = 0; n < count; n++) {
                    byte c = packet[cursor++];
                    if (c < 33 || c > 126 || c == '.') throw new FormatException("Invalid DNS character");
                    name.Append((char)c);
                }
                if (name.Length > 253) throw new FormatException("DNS name too long");
            }
        }
        private sealed class DnsAnswer {
            public IPAddress[] Addresses;
            public string CanonicalName;
        }
        private sealed class DnsRecord {
            public string Name, Alias;
            public IPAddress Address;
        }
        private static DnsAnswer ParseDnsResponse(byte[] packet, int id, string question, AddressFamily family) {
            int offset = 0;
            if (packet == null || packet.Length < 12 || packet.Length > 4096 || Read16(packet, ref offset) != id) throw new FormatException("Invalid DNS transaction");
            int flags = Read16(packet, ref offset);
            if ((flags & 0x8000) == 0 || (flags & 0x7800) != 0 || (flags & 0x020f) != 0) throw new FormatException("Invalid DNS status");
            int questions = Read16(packet, ref offset), answers = Read16(packet, ref offset);
            int authority = Read16(packet, ref offset), additional = Read16(packet, ref offset);
            if (questions != 1 || answers + authority + additional > 128) throw new FormatException("Invalid DNS counts");
            var nameBoundaries = new HashSet<int>();
            string echoed = ReadName(packet, ref offset, nameBoundaries);
            int type = family == AddressFamily.InterNetwork ? 1 : 28;
            if (!String.Equals(echoed, question.TrimEnd('.'), StringComparison.OrdinalIgnoreCase) ||
                Read16(packet, ref offset) != type || Read16(packet, ref offset) != 1) throw new FormatException("DNS question mismatch");
            var records = new List<DnsRecord>();
            for (int n = 0; n < answers + authority + additional; n++) {
                string name = ReadName(packet, ref offset, nameBoundaries);
                int recordType = Read16(packet, ref offset), recordClass = Read16(packet, ref offset);
                Read16(packet, ref offset); Read16(packet, ref offset); // TTL
                int length = Read16(packet, ref offset), start = offset;
                if (offset + length > packet.Length) throw new FormatException("Truncated DNS data");
                if (recordClass == 1 && recordType == 5) {
                    string alias = ReadName(packet, ref offset, nameBoundaries);
                    if (offset != start + length) throw new FormatException("Invalid CNAME length");
                    if (n < answers) records.Add(new DnsRecord { Name = name, Alias = alias });
                } else if (recordClass == 1 && recordType == type) {
                    if (length != (type == 1 ? 4 : 16)) throw new FormatException("Invalid DNS address length");
                    byte[] address = new byte[length]; Array.Copy(packet, offset, address, 0, length);
                    if (n < answers) records.Add(new DnsRecord { Name = name, Address = new IPAddress(address) });
                }
                offset = start + length;
            }
            if (offset != packet.Length) throw new FormatException("Undeclared trailing DNS data");
            string canonical = question.TrimEnd('.');
            var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (int depth = 0; depth < 9; depth++) {
                if (depth == 8 || !visited.Add(canonical)) throw new FormatException("CNAME chain too long or cyclic");
                string alias = null;
                foreach (var record in records) if (record.Alias != null && String.Equals(record.Name, canonical, StringComparison.OrdinalIgnoreCase)) {
                    if (alias != null && !String.Equals(alias, record.Alias, StringComparison.OrdinalIgnoreCase)) throw new FormatException("Conflicting CNAME");
                    alias = record.Alias;
                }
                if (alias == null) break;
                canonical = alias;
            }
            var addresses = new List<IPAddress>();
            foreach (var record in records)
                if (record.Address != null && String.Equals(record.Name, canonical, StringComparison.OrdinalIgnoreCase) &&
                    !addresses.Contains(record.Address) && addresses.Count < 2) addresses.Add(record.Address);
            return new DnsAnswer { Addresses = addresses.ToArray(), CanonicalName = canonical };
        }

        private static int HeaderEnd(byte[] bytes, int length) {
            for (int n = 3; n < length; n++)
                if (bytes[n - 3] == 13 && bytes[n - 2] == 10 && bytes[n - 1] == 13 && bytes[n] == 10) return n + 1;
            return -1;
        }
        private static bool HeadersAre204(byte[] bytes, int length) {
            if (bytes == null || length < 0 || length > bytes.Length) return false;
            int end = HeaderEnd(bytes, length);
            if (end < 0 || end != length) return false;
            string[] lines = Encoding.ASCII.GetString(bytes, 0, end - 4).Split(new string[] { "\r\n" }, StringSplitOptions.None);
            foreach (string line in lines)
                foreach (char c in line) if ((c < 32 && c != '\t') || c > 126) return false;
            if (!(lines[0].StartsWith("HTTP/1.1 204 ", StringComparison.Ordinal) ||
                  lines[0].StartsWith("HTTP/1.0 204 ", StringComparison.Ordinal))) return false;
            for (int n = 1; n < lines.Length; n++) {
                int colon = lines[n].IndexOf(':');
                if (colon < 1 || Char.IsWhiteSpace(lines[n][0])) return false;
                string name = lines[n].Substring(0, colon), value = lines[n].Substring(colon + 1).Trim();
                foreach (char c in name)
                    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                        "!#$%&'*+-.^_`|~".IndexOf(c) >= 0)) return false;
                if (name.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase)) return false;
                if (name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase) && value != "0") return false;
            }
            return true;
        }
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
