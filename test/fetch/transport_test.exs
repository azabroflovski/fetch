defmodule Fetch.TransportTest do
  use ExUnit.Case, async: true

  alias Fetch.{Response, TestServer}

  # Failed TLS handshakes are logged by :ssl.
  @moduletag :capture_log

  @ok "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecure"

  setup_all do
    %{certs: TestServer.certificates(), other_certs: TestServer.certificates()}
  end

  defp reply(response) do
    fn {:ssl, socket} = conn ->
      TestServer.read_request(conn)
      :ssl.send(socket, response)
    end
  end

  describe "DNS and TCP" do
    test "unresolvable host" do
      # .invalid is reserved and never resolves (RFC 6761).
      assert {:error, {:dns, reason}} = Fetch.get("http://fetch-test.invalid/")
      assert reason in [:nxdomain, :timeout]
    end

    test "connection refused" do
      {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert Fetch.get("http://127.0.0.1:#{port}/") == {:error, {:connect, :econnrefused}}
    end
  end

  describe "TLS" do
    test "https request with a trusted CA", %{certs: certs} do
      port = TestServer.start_tls(reply(@ok), certs.cert_key)

      assert {:ok, %Response{status: 200, body: "secure"}} =
               Fetch.get("https://localhost:#{port}/", ssl: [cacerts: certs.cacerts])
    end

    test "IP address host is verified against IP SANs", %{certs: certs} do
      port = TestServer.start_tls(reply(@ok), certs.cert_key)

      assert {:ok, %Response{status: 200}} =
               Fetch.get("https://127.0.0.1:#{port}/", ssl: [cacerts: certs.cacerts])
    end

    test "certificate is verified against the OS trust store by default", %{certs: certs} do
      port = TestServer.start_tls(reply(@ok), certs.cert_key)

      assert {:error, {:tls, {:tls_alert, {:unknown_ca, _}}}} =
               Fetch.get("https://localhost:#{port}/")
    end

    test "certificate from an unknown CA is rejected", %{certs: certs, other_certs: other} do
      port = TestServer.start_tls(reply(@ok), certs.cert_key)

      assert {:error, {:tls, {:tls_alert, {:unknown_ca, _}}}} =
               Fetch.get("https://localhost:#{port}/", ssl: [cacerts: other.cacerts])
    end

    test "certificate for another host name is rejected" do
      certs = TestServer.certificates(["other.test"])
      port = TestServer.start_tls(reply(@ok), certs.cert_key)

      assert {:error, {:tls, {:tls_alert, {:handshake_failure, message}}}} =
               Fetch.get("https://localhost:#{port}/", ssl: [cacerts: certs.cacerts])

      assert to_string(message) =~ "hostname_check_failed"
    end

    test "handshake timeout" do
      # A plain TCP server that never answers the TLS ClientHello.
      port = TestServer.start(fn _conn -> Process.sleep(500) end)

      assert Fetch.get("https://localhost:#{port}/", connect_timeout: 50) ==
               {:error, {:tls, :timeout}}
    end

    test "plain HTTP server behind an https URL" do
      port = TestServer.start(fn {:gen_tcp, socket} -> :gen_tcp.send(socket, @ok) end)

      assert {:error, {:tls, _reason}} = Fetch.get("https://localhost:#{port}/")
    end
  end
end
