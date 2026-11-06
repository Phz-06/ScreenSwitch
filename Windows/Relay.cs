using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Threading;
using System.Diagnostics;

sealed class Relay : IDisposable
{
    const int Port = 43862;
    const int TagLength = 32;
    readonly TcpListener listener;
    readonly byte[] key;
    readonly Func<byte> switchToWindows;
    volatile bool stopping;

    public Relay(IPAddress address, byte[] key, Func<byte> switchToWindows)
    {
        this.key = key;
        this.switchToWindows = switchToWindows;
        listener = new TcpListener(address, Port);
        listener.ExclusiveAddressUse = true;
        listener.Start(4);
        new Thread(Listen) { IsBackground = true, Name = "ScreenSwitch LAN relay" }.Start();
    }

    public static bool IsPrivateIPv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork) return false;
        byte[] ip = address.GetAddressBytes();
        return ip[0] == 10 || (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) ||
               (ip[0] == 192 && ip[1] == 168);
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
            if (difference != 0 || command > 1 || stopping) return;

            byte status = command == 0 ? (byte)0 : switchToWindows();
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
        listener.Stop();
    }
}
