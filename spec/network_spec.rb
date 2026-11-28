# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "open3"
require "kitchen/driver/parallels"

describe Kitchen::Driver::Parallels do
  it "rejects forwarding on a host-only network before touching Parallels" do
    driver = Kitchen::Driver::Parallels.new(box: "fixture.box", network_mode: "host-only",
      port_forward: { host_port: 22022, guest_port: 22 })
    state = {}

    error = assert_raises(Kitchen::ActionFailed) { driver.create(state) }
    assert_match(/requires.*shared/, error.message)
    assert_empty state
  end

  it "retries Netplan discovery and applies the profile once while the address settles" do
    driver = Kitchen::Driver::Parallels.new
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    execute = lambda do |_uuid, readiness_deadline:, &arguments|
      assert_equal deadline, readiness_deadline
      _, _, shell, flags, command_flag, script, name, cidr = arguments.call(30)
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p("#{root}/eth0/device")
        File.write("#{root}/eth0/type", "1\n")
        commands = <<~'SH'
          elapsed=0
          sleep() {
            elapsed=$((elapsed + 1))
            [ "$elapsed" -lt 6 ]
          }
          networkctl() {
            [ "$elapsed" -gt 0 ] || return 1
            [ "$elapsed" -ge 2 ] || return 0
            echo '  Network File: /run/systemd/network/10-netplan-uplink.network'
          }
          netplan() { echo "$*"; }
          ip() {
            [ "$elapsed" -ge 4 ] || return 1
            echo '2: eth0 inet 10.37.129.10/24 scope global eth0'
          }
        SH
        output, errors, status = Open3.capture3(shell, flags, command_flag, commands + script.sub("/sys/class/net", root), name, cidr)
        assert status.success?, errors
        assert_equal [
          "set --origin-hint 99-kitchen-static ethernets.uplink={dhcp4: false, addresses: [10.37.129.10/24]}",
          "apply",
        ], output.lines.map(&:strip)
      end
    end

    driver.stub(:guest_command, execute) do
      driver.send(:configure_static_guest, "vm", "10.37.129.10/24", deadline)
    end
  end

  it "rejects invalid static IPv4 settings before touching Parallels" do
    [nil, "host-only", "host-only", "host-only", "host-only"].zip(
      %w{10.37.129.10/24 10.37.129.10 10.37.129.10/33 127.0.0.1/24 999.37.129.10/24}
    ).each do |mode, cidr|
      driver = Kitchen::Driver::Parallels.new(box: "fixture.box", network_mode: mode, static_ip: cidr)
      state = {}

      error = assert_raises(Kitchen::ActionFailed) { driver.create(state) }
      assert_match(/static_ip requires/, error.message)
      assert_empty state
    end
  end

  it "waits for the requested host-only address rather than an earlier reported address" do
    with_network_driver({ mode: "host-only", static_ip: "10.37.129.10/24" }, network_mode: "host-only", static_ip: "10.37.129.10/24") do |driver, state, vm|
      vm["ip_configured"] = "10.37.129.9,10.37.129.10"
      vm["status"] = "stopped"
      settings = []
      guest_attempts = 0
      starts = 0
      command = lambda do |*args|
        case args[1]
        when "list" then JSON.generate([vm])
        when "set" then settings << args.drop(3)
        when "start"
          starts += 1
          vm["status"] = "running"
        when "exec"
          assert_equal "running", vm["status"]
          assert_equal state[:parallels_uuid], args[2]
          assert_match(%r{10\.37\.129\.10/24\z}, args.fetch(3))
          guest_attempts += 1
          raise Kitchen::ActionFailed, "Guest adapter still uses DHCP" if guest_attempts == 1
        else flunk("Unexpected command: #{args.inspect}")
        end
      end

      driver.stub(:command, command) do
        error = assert_raises(Kitchen::ActionFailed) { driver.create(state) }
        assert_match(/still uses DHCP/, error.message)
        refute state.key?(:hostname)
        driver.create(state)
      end
      assert_equal 1, starts
      assert_equal 2, guest_attempts
      assert_includes settings, %w{--device-set net0 --type host-only}
      assert_includes settings, %w{--device-set net0 --ipadd 10.37.129.10/24}
      assert_equal "10.37.129.10", state[:hostname]
    end
  end

  it "recovers a forward after an uncertain add and preserves foreign rules during destroy" do
    forward = { host_port: 22022, guest_port: 22 }
    with_network_driver({ mode: "shared", forward: forward }, port_forward: forward) do |driver, state, vm|
      token = state.fetch(:parallels_token)
      rule_name = "kitchen-#{token}"
      foreign = { "source port" => 22023, "destination IP/VM id" => "{foreign}", "destination port" => 22 }
      rules = { "foreign" => foreign }
      adds = 0
      command = lambda do |*args|
        case args
        when ["prlsrvctl", "net", "list", "--json"]
          JSON.generate([{ "Network ID" => "Shared", "Type" => "shared", "NAT server" => { "TCP rules" => rules } }])
        when ["prlsrvctl", "net", "set", "Shared", "--nat-tcp-add", "#{rule_name},22022,{#{token}},22"]
          adds += 1
          rules[rule_name] = { "source port" => 22022, "destination IP/VM id" => "{#{token}}", "destination port" => 22 }
          raise Kitchen::ActionFailed, "Connection lost after adding rule"
        when ["prlsrvctl", "net", "set", "Shared", "--nat-tcp-del", rule_name]
          rules.delete(rule_name)
        else
          assert_equal "prlctl", args.first
          case args[1]
          when "list" then JSON.generate([vm])
          when "stop" then assert_equal [token, "--kill"], args.drop(2)
          when "delete" then assert_equal [token], args.drop(2)
          else flunk("Unexpected command: #{args.inspect}")
          end
        end
      end

      driver.stub(:command, command) do
        assert_raises(Kitchen::ActionFailed) { driver.create(state) }
        driver.create(state)
        assert_equal 1, adds
        driver.destroy(state)
      end
      assert_equal({ "foreign" => foreign }, rules)
    end
  end

  it "retains cleanup state on inventory failures and destroys after Shared is confirmed absent" do
    forward = { host_port: 22022, guest_port: 22 }
    with_network_driver({ mode: "shared", forward: forward }, port_forward: forward) do |driver, state, vm|
      token = state.fetch(:parallels_token)
      state[:parallels_forward_attempted] = true
      inventory = nil
      commands = []
      command = lambda do |*args|
        commands << args
        case args
        when %w{prlsrvctl net list --json}
          raise Kitchen::ActionFailed, "Inventory command failed" unless inventory

          inventory
        when ["prlctl", "stop", token, "--kill"], ["prlctl", "delete", token]
          nil
        else
          flunk("Unexpected command: #{args.inspect}") unless args.take(2) == %w{prlctl list}
          JSON.generate([vm])
        end
      end

      driver.stub(:command, command) do
        lock = Minitest::Mock.new
        lock.expect(:flock, false, [File::LOCK_EX])
        unavailable_lock = ->(*_args, &block) { block.call(lock) }
        File.stub(:open, unavailable_lock) do
          error = assert_raises(Kitchen::ActionFailed) { driver.destroy(state) }
          assert_match(/Cannot lock/, error.message)
        end
        lock.verify
        assert_empty commands
        assert state[:parallels_forward_attempted]

        [nil, "{", "[{}]", '[{"Network ID":"Shared","Type":"shared","NAT server":[]}]'].each do |output|
          inventory = output
          commands.clear
          assert_raises(Kitchen::ActionFailed) { driver.destroy(state) }
          assert state[:parallels_forward_attempted]
          assert_equal [%w{prlsrvctl net list --json}], commands
        end

        inventory = '[{"Network ID":"Host-Only","Type":"host-only"}]'
        error = assert_raises(Kitchen::ActionFailed) { driver.create(state) }
        assert_match(/Shared network is unavailable/, error.message)
        Dir.stub(:tmpdir, "/unused-tmpdir") { driver.destroy(state) }
        assert_includes commands, ["prlctl", "delete", token]
        refute state.key?(:parallels_forward_attempted)
        assert File.file?(File.join(Etc.getpwuid(Process.uid).dir, ".kitchen-parallels-nat.lock"))
      end
    end
  end

  def with_network_driver(network, **options)
    Dir.mktmpdir do |root|
      driver = Kitchen::Driver::Parallels.new(box: "fixture.box", insert_key: false, kitchen_root: root, **options)
      transport = Object.new
      def transport.connection(_state)
        self
      end

      def transport.wait_until_ready; end

      instance = Struct.new(:name, :transport).new("network", transport)
      token = "7ef7d82b-de62-477b-a5f9-3f0669fd569c"
      state = { parallels_token: token, parallels_uuid: token, parallels_import: true, parallels_network: network }
      vm = { "uuid" => token, "name" => "kitchen-network-#{token}", "status" => "running", "ip_configured" => "10.37.129.10" }

      account = Struct.new(:dir).new(root)
      Etc.stub(:getpwuid, account) do
        driver.stub(:instance, instance) { yield driver, state, vm }
      end
    end
  end
end
