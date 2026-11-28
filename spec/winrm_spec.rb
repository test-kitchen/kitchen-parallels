# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "kitchen"
require "kitchen/driver/parallels"
require "kitchen/transport/winrm"

describe "Parallels Windows instances" do
  def kitchen_instance(root, hostname: nil)
    config = {
      driver: { name: "parallels", source_vm: "windows-template", insert_key: true },
      platforms: [{ name: "windows-11", os_type: "windows", shell_type: "powershell" }],
      transport: { name: "winrm", hostname: hostname, port: 15986, winrm_transport: "ssl" },
      provisioner: { name: "shell", command: "Write-Output 'converged'" },
      verifier: { name: "shell", remote_exec: true, command: "Write-Output 'verified'" },
      suites: [{ name: "default" }],
    }
    loader = Struct.new(:read).new(config)
    Kitchen::Config.new(loader: loader, kitchen_root: root).instances.first
  end

  it "retries a failed create on the same clone, converges, verifies and destroys it" do
    check_winrm_lifecycle(retry_create: true)
  end

  it "destroys a clone immediately after a WinRM readiness failure" do
    check_winrm_lifecycle(retry_create: false)
  end

  def check_winrm_lifecycle(retry_create:)
    Dir.mktmpdir do |root|
      source = { "name" => "windows-template", "uuid" => "source", "status" => "stopped" }
      clone = { "uuid" => "clone", "status" => "stopped", "ip_configured" => "10.37.129.2" }
      vms = [source]
      commands = []
      shellout = lambda do |*arguments, **_options|
        commands << arguments
        case arguments[0, 2]
        when %w{prlctl list}
          output = JSON.generate(vms)
        when %w{prlctl clone}
          assert_equal ["source", "--name"], arguments[2, 2]
          clone["name"] = arguments.fetch(4)
          vms << clone
        when %w{prlctl start}
          clone["status"] = "running"
        when %w{prlctl delete}
          vms.delete(clone)
        end
        Struct.new(:stdout, :run_command, :error!).new(output)
      end

      endpoints = []
      scripts = []
      connection = Kitchen::Transport::Base::Connection.new
      connection.define_singleton_method(:wait_until_ready) do
        raise Kitchen::Transport::WinrmFailed, "Tunnel unavailable" if endpoints.one?
      end
      connection.define_singleton_method(:execute) { |script| scripts << script }
      connection.define_singleton_method(:upload) { |*| }
      connection.define_singleton_method(:close) {}
      connect = lambda do |options, &block|
        endpoints << options.fetch(:endpoint)
        block&.call(connection)
        connection
      end

      Mixlib::ShellOut.stub(:new, shellout) do
        Kitchen::Transport::Winrm::Connection.stub(:new, connect) do
          assert_raises(Kitchen::ActionFailed) { kitchen_instance(root).create }
          if retry_create
            kitchen_instance(root).create
            kitchen_instance(root).verify
          end
          kitchen_instance(root).destroy
        end
      end

      assert_equal ["https://127.0.0.1:15986/wsman"] * (retry_create ? 3 : 1), endpoints
      if retry_create
        assert(scripts.any? { |script| script&.include?("converged") })
        assert_includes scripts, "Write-Output 'verified'"
      end
      assert_equal(1, commands.count { |command| command[1] == "clone" })
      assert_equal([%w{prlctl delete clone}], commands.select { |command| command[1] == "delete" })
      refute(commands.any? { |command| command[1] == "exec" })
      assert_equal [source], vms
    end
  end

  it "rejects a non-loopback WinRM endpoint before touching Parallels" do
    Dir.mktmpdir do |root|
      unexpected_command = ->(*) { flunk "Parallels was called before endpoint validation" }
      Mixlib::ShellOut.stub(:new, unexpected_command) do
        assert_raises(Kitchen::InstanceFailure) { kitchen_instance(root, hostname: "192.0.2.10").create }
      end
    end
  end
end
