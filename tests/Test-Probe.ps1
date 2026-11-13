$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot '..\src\Probe.cs')
$script:count = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
$probe = [EthernetFirst.Probe]
Assert ($null -ne $probe.GetMethod('CheckHttps')) 'CheckHttps must exist before HTTPS health monitoring can be used'

# Exercise the production DNS decoder with independently constructed DNS wire packets.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading.Tasks;
public static class DnsFixture {
    static void U16(MemoryStream s, int n) { s.WriteByte((byte)(n >> 8)); s.WriteByte((byte)n); }
    static void Name(MemoryStream s, string name) {
        foreach (string label in name.Split('.')) { byte[] b = Encoding.ASCII.GetBytes(label); s.WriteByte((byte)b.Length); s.Write(b,0,b.Length); }
        s.WriteByte(0);
    }
    public static byte[] Answer(bool ipv6, bool cname, bool unrelated) {
        using (var s = new MemoryStream()) {
            U16(s,0x1234); U16(s,0x8180); U16(s,1); U16(s,cname?2:1); U16(s,0); U16(s,0);
            Name(s,"health.test"); U16(s,ipv6?28:1); U16(s,1);
            if (cname) {
                U16(s,0xc00c); U16(s,5); U16(s,1); s.Write(new byte[4],0,4); U16(s,8);
                s.WriteByte(5); s.Write(Encoding.ASCII.GetBytes("alias"),0,5); U16(s,0xc013);
            }
            if (unrelated) Name(s,"other.test");
            else if(cname) { s.WriteByte(5); s.Write(Encoding.ASCII.GetBytes("alias"),0,5); U16(s,0xc013); }
            else U16(s,0xc00c);
            U16(s,ipv6?28:1); U16(s,1); s.Write(new byte[4],0,4);
            byte[] ip=IPAddress.Parse(ipv6?"2001:db8::9":"192.0.2.9").GetAddressBytes(); U16(s,ip.Length); s.Write(ip,0,ip.Length);
            return s.ToArray();
        }
    }
    public static byte[] ForwardPointerAnswer() {
        using (var s = new MemoryStream()) {
            U16(s,0x1234); U16(s,0x8180); U16(s,1); U16(s,1); U16(s,0); U16(s,0);
            U16(s,0xc022); U16(s,1); U16(s,1);
            U16(s,0xc022); U16(s,1); U16(s,1); s.Write(new byte[4],0,4); U16(s,4);
            s.Write(new byte[] {1,2,3,4},0,4);
            Name(s,"health.test");
            return s.ToArray();
        }
    }
    public static byte[] OpaqueDataPointerAnswer() {
        using (var s = new MemoryStream()) {
            U16(s,0x1234); U16(s,0x8180); U16(s,1); U16(s,2); U16(s,0); U16(s,0);
            Name(s,"health.test"); U16(s,1); U16(s,1);
            U16(s,0xc00c); U16(s,16); U16(s,1); s.Write(new byte[4],0,4); U16(s,13);
            Name(s,"health.test"); // Opaque TXT bytes, not an encoded domain-name field.
            U16(s,0xc029); U16(s,1); U16(s,1); s.Write(new byte[4],0,4); U16(s,4);
            s.Write(new byte[] {1,2,3,4},0,4);
            return s.ToArray();
        }
    }
}
public sealed class UntrustedTlsFixture : IDisposable {
    readonly TcpListener listener;
    readonly X509Certificate2 certificate;
    readonly RSA rsa;
    TcpClient accepted;
    public volatile bool Accepted;
    public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
    readonly Task serving;
    public UntrustedTlsFixture() {
        rsa=RSA.Create(2048);
        var request=new CertificateRequest("CN=wrong.invalid",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
        certificate=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5),DateTimeOffset.UtcNow.AddDays(1));
        listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
        serving=Task.Run(async delegate {
            try {
                accepted=await listener.AcceptTcpClientAsync(); Accepted=true;
                using(accepted) using(var ssl=new SslStream(accepted.GetStream(),false)) {
                    await ssl.AuthenticateAsServerAsync(certificate,false,SslProtocols.Tls12,false);
                    byte[] response=Encoding.ASCII.GetBytes("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
                    await ssl.WriteAsync(response,0,response.Length);
                }
            } catch(Exception) { }
        });
    }
    public void Dispose() {
        listener.Stop(); if(accepted!=null)accepted.Close();
        try { serving.Wait(2000); } catch(Exception) { }
        certificate.Dispose(); rsa.Dispose();
    }
}
public sealed class BoundDnsFixture : IDisposable {
    readonly UdpClient server;
    readonly Task serving;
    public volatile bool Received;
    public string Source;
    public int QueryType;
    public BoundDnsFixture() {
        server=new UdpClient(new IPEndPoint(IPAddress.Parse("127.0.0.2"),53));
        serving=Task.Run(async delegate {
            try {
                var query=await server.ReceiveAsync();
                byte[] q=query.Buffer;
                Source=query.RemoteEndPoint.Address.ToString();
                QueryType=(q[q.Length-4]<<8)|q[q.Length-3];
                Received=true;
                using(var response=new MemoryStream()) {
                    response.Write(q,0,q.Length);
                    response.Position=2; response.WriteByte(0x81); response.WriteByte(0x80);
                    response.Position=6; response.WriteByte(0); response.WriteByte(1);
                    response.Position=response.Length;
                    byte[] rr={0xc0,0x0c,0,1,0,1,0,0,0,0,0,4,127,0,0,1};
                    response.Write(rr,0,rr.Length);
                    byte[] bytes=response.ToArray();
                    await server.SendAsync(bytes,bytes.Length,query.RemoteEndPoint);
                }
            } catch(Exception) { }
        });
    }
    public void Dispose() { server.Close(); try { serving.Wait(2000); } catch(Exception) { } }
}
public sealed class HangingTlsFixture : IDisposable {
    readonly TcpListener listener;
    readonly Task serving;
    TcpClient accepted;
    public volatile bool Accepted, Closed;
    public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
    public HangingTlsFixture() {
        listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
        serving=Task.Run(async delegate {
            try {
                accepted=await listener.AcceptTcpClientAsync(); Accepted=true;
                using(accepted) {
                    byte[] bytes=new byte[4096];
                    while(await accepted.GetStream().ReadAsync(bytes,0,bytes.Length)!=0) { }
                }
            } catch(Exception) { }
            finally { Closed=true; }
        });
    }
    public bool WaitForClose() { try { serving.Wait(1000); } catch(Exception) { } return Closed; }
    public void Dispose() { listener.Stop(); if(accepted!=null)accepted.Close(); try { serving.Wait(2000); } catch(Exception) { } }
}
'@
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$dns = $probe.GetMethod('ParseDnsResponse', $flags)
$http = $probe.GetMethod('HeadersAre204', $flags)
function Parse-Dns([byte[]]$Bytes, [int]$Id=0x1234, [string]$Name='health.test', [System.Net.Sockets.AddressFamily]$Family=[System.Net.Sockets.AddressFamily]::InterNetwork) {
    $dns.Invoke($null, [object[]]@($Bytes,$Id,$Name,$Family))
}
function Invalid-Dns([byte[]]$Bytes, [int]$Id=0x1234, [string]$Name='health.test') {
    try { $null=Parse-Dns $Bytes $Id $Name; return $false }
    catch [System.Management.Automation.MethodInvocationException] { return $true }
}
$answer=Parse-Dns ([DnsFixture]::Answer($false,$false,$false))
Assert ($answer.Addresses.Count -eq 1 -and $answer.Addresses[0].ToString() -eq '192.0.2.9') 'Decode compressed IPv4 answer'
$answer=Parse-Dns ([DnsFixture]::Answer($false,$true,$false))
Assert ($answer.Addresses.Count -eq 1 -and $answer.CanonicalName -eq 'alias.test') 'Follow compressed CNAME before accepting its address'
$answer=Parse-Dns ([DnsFixture]::Answer($true,$true,$false)) 0x1234 'health.test' ([Net.Sockets.AddressFamily]::InterNetworkV6)
Assert ($answer.Addresses.Count -eq 1 -and $answer.Addresses[0].ToString() -eq '2001:db8::9') 'Decode IPv6 only for IPv6 question'
$answer=Parse-Dns ([DnsFixture]::Answer($false,$false,$true))
Assert ($answer.Addresses.Count -eq 0) 'Unrelated DNS answers cannot satisfy requested hostname'
Assert (Invalid-Dns ([DnsFixture]::Answer($false,$false,$false)) 0x9999) 'Reject DNS transaction-ID mismatch'
Assert (Invalid-Dns ([DnsFixture]::Answer($false,$false,$false)) 0x1234 'different.test') 'Reject DNS question mismatch'
$bad=[DnsFixture]::Answer($false,$false,$false); $bad[2]=0x83
Assert (Invalid-Dns $bad) 'Reject truncated DNS responses rather than accepting partial addresses'
$bad=[DnsFixture]::Answer($false,$false,$false); $bad[3]=0x83
Assert (Invalid-Dns $bad) 'Reject DNS error RCODE'
$bad=[DnsFixture]::Answer($false,$false,$false); $bad[12]=0xc0; $bad[13]=12
Assert (Invalid-Dns $bad) 'Reject cyclic DNS compression pointers'
$bad=[DnsFixture]::Answer($false,$false,$false)
Assert (Invalid-Dns $bad[0..($bad.Length-2)]) 'Reject truncated resource data'
$cnameOnly=[DnsFixture]::Answer($false,$true,$false)
$cnameOnly=$cnameOnly[0..48]; $cnameOnly[7]=1
$answer=Parse-Dns $cnameOnly
Assert ($answer.Addresses.Count -eq 0 -and $answer.CanonicalName -eq 'alias.test') 'CNAME-only reply supplies the next explicit-DNS question'
$bad=[DnsFixture]::Answer($false,$true,$false); $bad[40]=7
Assert (Invalid-Dns $bad) 'CNAME encoded length must match its resource record'
$bad=[DnsFixture]::Answer($false,$false,$false); $bad[3]=0; $bad[2]=1
Assert (Invalid-Dns $bad) 'Reject a DNS query masquerading as a reply'
function Response([string]$Text) {
    $bytes=[Text.Encoding]::ASCII.GetBytes($Text)
    $http.Invoke($null,[object[]]@($bytes,$bytes.Length))
}
Assert (Response "HTTP/1.1 204 No Content`r`nConnection: close`r`n`r`n") 'Accept HTTP 204 headers'
Assert (Response "HTTP/1.0 204 No Content`r`nContent-Length: 0`r`n`r`n") 'Accept explicit zero-length 204'
Assert (-not (Response "HTTP/1.1 200 OK`r`nContent-Length: 0`r`n`r`n")) 'Captive-portal HTTP 200 is not healthy'
Assert (-not (Response "HTTP/1.1 302 Found`r`nLocation: https://example.com`r`n`r`n")) 'Do not follow redirects'
Assert (-not (Response "HTTP/1.1 500 Error`r`n`r`n")) 'Server errors are not healthy'
Assert (-not (Response "HTTP/1.1 204 No Content`r`nContent-Length: 3`r`n`r`nabc")) 'Reject a claimed 204 with a body'
Assert (-not (Response "HTTP/1.1 204 No Content`r`n")) 'Require complete response headers'
Assert (-not (Response "HTTP/1.1 2040 No Content`r`n`r`n")) 'Require the exact HTTP status code'
Assert (-not (Response "HTTP/1.1 204 No Content`r`nTransfer-Encoding: chunked`r`n`r`n")) 'Reject transfer encoding on a claimed empty response'
Assert (-not (Response "HTTP/1.1 204 No Content`r`nContent-Length : 3`r`n`r`n")) 'Reject whitespace in a header field name'
Assert (-not (Response "HTTP/1.1 204 No Content`nInjected: value`r`n`r`n")) 'Reject bare line feeds in HTTP headers'

# Real local TLS with an untrusted, wrong-name certificate: no trust-store changes.
$loopback = Get-NetIPAddress -IPAddress '127.0.0.1' -AddressFamily IPv4 | Select-Object -First 1
Assert ($null -ne $loopback) 'Loopback interface must exist for harmless local socket tests'
$server=[UntrustedTlsFixture]::new()
try {
    $result=[EthernetFirst.Probe]::CheckHttps($loopback.InterfaceIndex,'127.0.0.1',[string[]]@(),[string[]]@("https://127.0.0.1:$($server.Port)/generate_204"),2000)
    Assert ($server.Accepted) 'TLS rejection test must actually reach the local server'
    Assert ($result -eq 0) 'Never accept an untrusted or wrong-hostname TLS certificate'
} finally { $server.Dispose() }
$dnsServer=[BoundDnsFixture]::new(); $server=[UntrustedTlsFixture]::new()
try {
    $result=[EthernetFirst.Probe]::CheckHttps($loopback.InterfaceIndex,'127.0.0.1',[string[]]@('127.0.0.2'),[string[]]@("https://health.test:$($server.Port)/generate_204"),2000)
    Assert ($dnsServer.Received -and $dnsServer.Source -eq '127.0.0.1' -and $dnsServer.QueryType -eq 1) 'Send A queries to the supplied DNS server from the selected source'
    Assert ($server.Accepted -and $result -eq 0) 'Use the explicit DNS answer for direct TLS, retaining strict verification'
} finally { $server.Dispose(); $dnsServer.Dispose() }
$server=[HangingTlsFixture]::new()
try {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $result=[EthernetFirst.Probe]::CheckHttps($loopback.InterfaceIndex,'127.0.0.1',[string[]]@(),[string[]]@("https://127.0.0.1:$($server.Port)/generate_204"),200)
    $watch.Stop()
    Assert ($server.Accepted -and $result -eq 0 -and $watch.ElapsedMilliseconds -lt 1500) 'A silent TLS peer cannot exceed the overall deadline'
    Assert ($server.WaitForClose()) 'A timed-out TLS probe disposes its connection'
} finally { $server.Dispose() }
$watch=[Diagnostics.Stopwatch]::StartNew()
$result=[EthernetFirst.Probe]::CheckHttps($loopback.InterfaceIndex,'127.0.0.1',[string[]]@('127.0.0.1'),[string[]]@('https://health.test/generate_204','https://other.test/generate_204'),200)
$watch.Stop()
Assert ($result -eq 0) 'Unavailable local DNS must fail without using the system resolver'
Assert ($watch.ElapsedMilliseconds -lt 1500) 'Multiple endpoints share one overall deadline'
Assert ([EthernetFirst.Probe]::CheckHttps(1,'not-an-ip',[string[]]@(),[string[]]@('https://example.com'),100) -eq 0) 'Invalid input fails closed without throwing'
Assert ([EthernetFirst.Probe]::CheckHttps($loopback.InterfaceIndex,'127.0.0.1',[string[]]@(),[string[]]@('https://health.test'),100) -eq -1) 'Missing interface DNS is unknown, not evidence of an Internet outage'
Assert ([EthernetFirst.Probe]::CheckHttps($loopback.InterfaceIndex,'127.0.0.1',[string[]]@('::1'),[string[]]@('https://health.test'),100) -eq -1) 'DNS in another address family is unknown, with no system fallback'
Assert ($null -ne $probe.GetMethod('Check')) 'Legacy TCP Check interface remains available'

# Regression: local setup cannot establish Internet failure, and DNS names cannot
# be manufactured from forward pointers, undeclared bytes, or opaque RR data.
$invalidIndexResult=[EthernetFirst.Probe]::CheckHttps(2000001,'127.0.0.1',[string[]]@(),[string[]]@('https://127.0.0.1:1/generate_204'),100)
$expiredSourceResult=[EthernetFirst.Probe]::CheckHttps($loopback.InterfaceIndex,'192.0.2.173',[string[]]@(),[string[]]@('https://127.0.0.1:1/generate_204'),100)
$invalidDnsBindingResult=[EthernetFirst.Probe]::CheckHttps(2000001,'127.0.0.1',[string[]]@('127.0.0.2'),[string[]]@('https://health.test/generate_204'),100)
$forwardRejected=Invalid-Dns ([DnsFixture]::ForwardPointerAnswer())
$trailingRejected=Invalid-Dns ([byte[]]([DnsFixture]::Answer($false,$false,$false)+[byte[]]@(0)))
$opaqueRejected=Invalid-Dns ([DnsFixture]::OpaqueDataPointerAnswer())
Write-Output "Regression observations: invalid-index=$invalidIndexResult expired-source=$expiredSourceResult DNS-binding=$invalidDnsBindingResult forward-rejected=$forwardRejected trailing-rejected=$trailingRejected opaque-rejected=$opaqueRejected"
Assert ($invalidIndexResult -eq -1) 'An unavailable interface index is unknown before any TCP packet is sent'
Assert ($expiredSourceResult -eq -1) 'An expired local source address is unknown before any TCP packet is sent'
Assert ($invalidDnsBindingResult -eq -1) 'Local UDP DNS binding failure is unknown'
Assert ($forwardRejected) 'Reject QNAME and RR owner forward pointers into undeclared trailing data'
Assert ($trailingRejected) 'Reject bytes not consumed by the declared DNS sections'
Assert ($opaqueRejected) 'Compression pointers must target a previously parsed domain-name label boundary'
Assert ($null -ne $probe.GetMethod('CheckProfiles')) 'Domestic and foreign profiles must have independent bounded probe results'
$profiles=[EthernetFirst.Probe]::CheckProfiles($loopback.InterfaceIndex,'127.0.0.1',[string[]]@(),[string[]]@(),[string[]]@('https://health.test'),100)
Assert ($profiles.Length -eq 2 -and $profiles[0] -eq 0 -and $profiles[1] -eq -1) 'One profile failing must not overwrite the other profile unknown result'
$profiles=[EthernetFirst.Probe]::CheckProfiles(2000001,'127.0.0.1',[string[]]@(),[string[]]@('https://127.0.0.1/'),[string[]]@('https://127.0.0.1/'),100)
Assert ($profiles[0] -eq -1 -and $profiles[1] -eq -1) 'Local interface failure must remain unknown in both profiles'
Write-Output "PASS $script:count probe tests (DNS, HTTP, strict TLS, bounded time; no adapter changes)"
