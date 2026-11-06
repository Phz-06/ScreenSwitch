using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading;
using System.Diagnostics;

sealed class Relay : IDisposable
{
    public const int Port = 43862;
    const int TagLength = 32;
    readonly TcpListener listener;
    readonly byte[] key;
    readonly Func<byte, byte> executeCommand;
    volatile bool stopping;

    public Relay(IPAddress address, byte[] key, Func<byte, byte> executeCommand)
    {
        this.key = key;
        this.executeCommand = executeCommand;
        // 绑定在 IPAddress.Any 以便适应多网卡与动态 IP，但内部严格限制只接受私有局域网 IP
        IPAddress bind = address ?? IPAddress.Any;
        listener = new TcpListener(bind, Port);
        try { listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true); } catch { }
        listener.Start(8);
        new Thread(Listen) { IsBackground = true, Name = "ScreenSwitch LAN relay" }.Start();
    }

    public static bool IsPrivateIPv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork) return false;
        byte[] ip = address.GetAddressBytes();
        return ip[0] == 10 || (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) ||
               (ip[0] == 192 && ip[1] == 168);
    }

    public static IPAddress GetPreferredPrivateIP()
    {
        try
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(a => a.OperationalStatus == OperationalStatus.Up &&
                            a.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .SelectMany(a => a.GetIPProperties().UnicastAddresses)
                .Select(e => e.Address)
                .Where(IsPrivateIPv4)
                .OrderByDescending(ip => {
                    byte[] b = ip.GetAddressBytes();
                    if (b[0] == 192 && b[1] == 168) return 3;
                    if (b[0] == 10) return 2;
                    return 1;
                })
                .FirstOrDefault() ?? IPAddress.Loopback;
        }
        catch { return IPAddress.Loopback; }
    }

    public static byte[] NewKey()
    {
        byte[] bytes = new byte[TagLength];
        using (var random = new RNGCryptoServiceProvider()) random.GetBytes(bytes);
        return bytes;
    }

    void Listen()
    {
        while (!stopping)
        {
            try
            {
                using (TcpClient client = listener.AcceptTcpClient())
                {
                    var remote = client.Client.RemoteEndPoint as IPEndPoint;
                    if (remote != null && IsPrivateIPv4(remote.Address)) Handle(client);
                }
            }
            catch (IOException) { }
            catch (SocketException) { if (stopping) return; Thread.Sleep(100); }
            catch (ObjectDisposedException) { return; }
        }
    }

    void Handle(TcpClient client)
    {
        var stream = client.GetStream();
        stream.WriteTimeout = 1500;

        byte[] challenge = NewKey();
        stream.Write(challenge, 0, challenge.Length);
        byte[] request = new byte[TagLength + 1];
        var timer = Stopwatch.StartNew();
        int offset = 0;
        while (offset < request.Length)
        {
            int remaining = 2000 - (int)timer.ElapsedMilliseconds;
            if (remaining <= 0) return;
            stream.ReadTimeout = remaining;
            int read = stream.Read(request, offset, request.Length - offset);
            if (read == 0) return;
            offset += read;
        }

        byte command = request[0];
        byte[] message = new byte[TagLength + 2];
        Buffer.BlockCopy(challenge, 0, message, 0, TagLength);
        message[TagLength] = command;

        using (var hmac = new HMACSHA256(key))
        {
            byte[] expected = hmac.ComputeHash(message, 0, TagLength + 1);
            int difference = 0;
            for (int i = 0; i < TagLength; i++) difference |= expected[i] ^ request[i + 1];
            if (difference != 0 || command > 3 || stopping) return;

            byte status = executeCommand(command);
            message[TagLength + 1] = status;
            byte[] reply = new byte[TagLength + 1];
            reply[0] = status;
            Buffer.BlockCopy(hmac.ComputeHash(message), 0, reply, 1, TagLength);
            stream.Write(reply, 0, reply.Length);
        }
    }

    public void Dispose()
    {
        stopping = true;
        try { listener.Stop(); } catch { }
    }
}
