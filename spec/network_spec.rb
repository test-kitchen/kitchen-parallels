# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
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

  it "waits for the requested host-only address rather than an earlier reported address" do
    with_network_driver({ mode: "host-only", static_ip: "10.37.129.10/24" }, network_mode: "host-only", static_ip: "10.37.129.10/24") do |driver, state, vm|
      vm["ip_configured"] = "10.37.129.9,10.37.129.10"
      vm["status"] = "stopped"
      settings = []
      command = lambda do |*args|
        case args[1]
        when "list" then JSON.generate([vm])
        when "set" then settings << args.drop(3)
        when "start" then vm["status"] = "running"
        else flunk("Unexpected command: #{args.inspect}")
        end
      end

      driver.stub(:command, command) { driver.create(state) }
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
      vm = { "uuid" => token, "status" => "running", "ip_configured" => "10.37.129.10" }

      driver.stub(:instance, instance) { yield driver, state, vm }
    end
  end
end
