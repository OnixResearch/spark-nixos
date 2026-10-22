# Two boxes in VMs, joined by a LAN and a fabric, with the README's cluster firewall: the
# fabric trusted, and openFirewall on the LAN. spark1 also runs a mentat router, the status
# screen and the watchdog. The VMs have no GPU, no GB10 kernel and no RDMA, so nvidia-smi,
# dispramd and the ConnectX MTU path are out of reach here.
{ pkgs, module }:

let
  kindling = import ../packages.nix { inherit pkgs; };

  # A container with Python, for the dispram mount line in dispram/README.md.
  pluginCheck = pkgs.dockerTools.buildImage {
    name = "plugin-check";
    tag = "latest";
    copyToRoot = [
      pkgs.python3
      (pkgs.writeTextDir "check.py" ''
        import importlib.metadata
        import dispram
        plugins = [e.value for e in importlib.metadata.entry_points(group="vllm.general_plugins")]
        print(plugins, dispram.available(), dispram.reserve_bytes())
      '')
    ];
  };

  box = { pkgs, ... }: {
    imports = [ module ];

    virtualisation.interfaces = {
      eno1 = { vlan = 1; assignIP = true; }; # the LAN
      enp1s0f0np0 = { vlan = 2; assignIP = true; }; # the fabric, named like a ConnectX port
    };
    # mentatd finds its peers by broadcast, and announces only on interfaces with a broadcast
    # address. networkd gives static addresses one. Scripted networking does not.
    networking.useNetworkd = true;
    # A default route, so mentatd takes its LAN address as its identity, as on a box.
    networking.defaultGateway = { address = "192.168.1.254"; interface = "eno1"; };
    networking.firewall.trustedInterfaces = [ "enp1s0f0np0" ];

    services.kindling = {
      enable = true;
      openFirewall = true;
      ethernetMtu = 1400;
    };

    # As the hardware module does.
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
      dockerSocket.enable = true;
    };

    environment.etc."spark/mentat.key" = { text = "kindling-vm-test-key"; mode = "0400"; };
    # Every VM's QEMU user network (eth0) has 10.0.2.15, as every Podman host's podman0 has
    # 10.88.0.1. Announced, it led the router to run spark2's tools on spark1.
    environment.etc."spark/node.env".text = ''
      MENTAT_SECRET_FILE=/etc/spark/mentat.key
      MENTAT_ANNOUNCE_IFACES=eno1,enp1s0f0np0
    '';
    environment.systemPackages = [ pkgs.jq ];
  };
in
pkgs.testers.runNixOSTest {
  name = "kindling-vm";

  nodes.spark1 = {
    imports = [ box ];
    services.kindling.console.enable = true;
    services.kindling.watchdog.enable = true;
    boot.kernelModules = [ "i6300esb" ];
    virtualisation.qemu.options = [ "-device i6300esb" ];
    virtualisation.diskSize = 4096;
    virtualisation.memorySize = 2048;

    systemd.services.mentat-router = {
      description = "mentat router, as a box in a cluster runs it";
      wantedBy = [ "multi-user.target" ];
      after = [ "mentatd.service" ];
      environment.MENTAT_SECRET_FILE = "/etc/spark/mentat.key";
      serviceConfig = {
        ExecStart = "${kindling.mentatd}/bin/mentatd-serve";
        Restart = "on-failure";
      };
    };
  };
  nodes.spark2 = box;

  testScript = ''
    import json
    from datetime import timedelta

    def minutes(n):
        return timedelta(minutes=n)

    def mcp(m, port, method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        out = m.succeed(
            f"curl -sf -X POST -H 'content-type: application/json' -d '{body}' "
            f"http://127.0.0.1:{port}/mcp"
        )
        return json.loads(out)["result"]

    def tool(m, port, name, arguments):
        return mcp(m, port, "tools/call", {"name": name, "arguments": arguments})["content"][0]["text"]

    start_all()

    # First, so the rest of the test runs with the watchdog disarmed.
    with subtest("spark-watchdog arms the hardware watchdog and disarms on stop"):
        spark1.wait_for_unit("spark-watchdog.service")
        spark1.wait_until_succeeds(
            "journalctl -u spark-watchdog | grep -q 'armed: timeout=60s'", timeout=minutes(2)
        )
        spark1.fail("journalctl -u spark-watchdog | grep -q 'could not set timeout'")
        spark1.succeed("systemctl stop spark-watchdog")
        spark1.succeed("journalctl -u spark-watchdog | grep -q 'disarming on signal'")

    for m in (spark1, spark2):
        m.wait_for_unit("mentatd.service")
        m.wait_for_unit("spark-agent.service")
        m.wait_for_open_port(6380)
        m.wait_for_open_port(8090)

    with subtest("mentatd names itself after the host and takes its LAN address"):
        for m, ip in ((spark1, "192.168.1.1"), (spark2, "192.168.1.2")):
            status = json.loads(m.succeed("curl -sf http://127.0.0.1:6380/status"))
            assert status["hostname"] == m.name, status["hostname"]
            assert status["node_ip"] == ip, status["node_ip"]

    with subtest("the daemons find each other by broadcast and mesh through the firewall"):
        for m, peer in ((spark1, "192.168.1.2"), (spark2, "192.168.1.1")):
            m.wait_until_succeeds(
                "curl -sf http://127.0.0.1:6380/status | jq -e "
                f"'[.peers[] | select(.alive and .node_ip == \"{peer}\")] | length == 1'",
                timeout=minutes(5),
            )

    with subtest("the head daemon holds both boxes' agents"):
        def agents_at_head(last_try):
            # The head holds the cluster's groups. Another daemon lists only the ones it has.
            status = json.loads(spark1.succeed("curl -sf http://127.0.0.1:6380/status"))
            head = status.get("head_node_id")
            if head and head != status["node_id"]:
                ip = status["peers"].get(head, {}).get("node_ip")
                if not ip:
                    return False
                status = json.loads(spark1.succeed(f"curl -sf http://{ip}:6380/status"))
            groups = sorted(status.get("groups", {}))
            if last_try:
                print("groups at the head:", groups)
            return {"agent-spark1", "agent-spark2"} <= set(groups)

        retry(agents_at_head, timeout=minutes(5))

    with subtest("the router merges both agents and runs a tool on the other box"):
        spark1.wait_for_open_port(6381)
        spark1.wait_until_succeeds(
            "curl -sf -X POST -H 'content-type: application/json' "
            "-d '{\"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"tools/list\"}' "
            "http://127.0.0.1:6381/mcp | jq -e '.result.tools[] | select(.name == \"network\") "
            "| .inputSchema.properties.__group.enum | contains([\"agent-spark1\", \"agent-spark2\"])'",
            timeout=minutes(5),
        )
        text = tool(spark1, 6381, "network", {"__group": "agent-spark2"})
        assert text.startswith("[spark2 "), text[:200]
        assert "192.168.1.2" in text, text

    with subtest("the fabric is trusted and the LAN opens only mentat's ports"):
        spark2.succeed(
            "systemd-run --unit=probe-listener "
            "${pkgs.python3}/bin/python3 -m http.server --directory /var/empty 45678"
        )
        spark2.wait_for_open_port(45678)
        spark1.succeed("curl -sf -m 5 -o /dev/null http://192.168.2.2:45678/")
        spark1.fail("curl -sf -m 5 -o /dev/null http://192.168.1.2:45678/")

    with subtest("the MTU unit gives the en* ports the configured MTU"):
        for m in (spark1, spark2):
            for iface in ("eno1", "enp1s0f0np0"):
                m.wait_until_succeeds(
                    f"test $(cat /sys/class/net/{iface}/mtu) = 1400", timeout=minutes(2)
                )

    with subtest("the snapshot gives the agent dmesg, the units and the containers"):
        spark1.succeed("podman load -i ${pluginCheck}")
        spark1.succeed(
            "podman run -d --name model --network host plugin-check "
            "python3 -c 'import time; time.sleep(1e6)'"
        )
        spark1.succeed("systemctl start spark-dmesg-snapshot")
        spark1.succeed("test -s /var/log/spark/dmesg.log")
        spark1.succeed("grep -q mentatd.service /var/log/spark/systemd-units.log")
        spark1.succeed("grep -q model /var/log/spark/docker-ps.log")
        assert "model" in tool(spark1, 8090, "docker_ps", {})

    with subtest("the status screen on tty1 shows the box, its peer and its containers"):
        spark1.wait_for_unit("spark-console.service")
        for pattern in ("spark2 +192\\.168\\.1\\.2 +up", "model +Up"):
            spark1.wait_until_succeeds(
                f"tr -cd '[:print:]' < /dev/vcs1 | grep -Eq '{pattern}'", timeout=minutes(2)
            )
        screen = spark1.succeed("tr -cd '[:print:]' < /dev/vcs1")
        assert "kindling spark OS" in screen and "spark1" in screen, screen
        assert "not found" not in screen, screen

    with subtest("a recipe's dispram mounts work under Podman without dispramd"):
        out = spark1.succeed(
            "podman run --rm --network none "
            "-v /run/dispram:/run/dispram -v /opt/kindling/dispram/python:/opt/dispram:ro "
            "-e PYTHONPATH=/opt/dispram plugin-check python3 /check.py"
        )
        assert out.strip() == "['dispram_vllm:register'] False 0", out
  '';
}
