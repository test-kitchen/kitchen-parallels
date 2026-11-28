# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "kitchen"
require "kitchen/driver/parallels"
require "kitchen/transport/winrm"

describe "Parallels Windows instances" do
  def kitchen_instance(root, hostname: nil, **network)
    config = {
      driver: { name: "parallels", source_vm: "windows-template", insert_key: true, **network },
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
      markers = []
      clone_files = []
      other_clone_files = []
      tunnel_files = other_clone_files
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
        when %w{prlctl exec}
          assert_equal "clone", arguments.fetch(2)
          assert_equal %w{powershell.exe -NoProfile -NonInteractive -EncodedCommand}, arguments[3, 4]
          encoded = arguments.fetch(7)
          script = encoded.unpack1("m0").force_encoding("UTF-16LE").encode("UTF-8")
          marker = readiness_marker(script)
          if script.start_with?("New-Item")
            markers << marker
            clone_files << marker
          elsif script.start_with?("Remove-Item")
            assert_includes clone_files, marker
            clone_files.delete(marker)
          else
            flunk "Unexpected guest command: #{script}"
          end
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
      marker_name = method(:readiness_marker)
      connection.define_singleton_method(:execute) do |script|
        if script&.include?("Test-Path")
          unless tunnel_files.include?(marker_name.call(script))
            raise Kitchen::Transport::WinrmFailed.new("The clone marker is missing", 42)
          end
        else
          scripts << script
        end
      end
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
            other_clone_files.concat(markers)
            failure = assert_raises(Kitchen::InstanceFailure) { kitchen_instance(root).create }
            assert_includes failure.cause.message, "tunnel did not reach Parallels clone"
            tunnel_files = clone_files
            kitchen_instance(root).create
            kitchen_instance(root).verify
          end
          kitchen_instance(root).destroy
        end
      end

      assert_equal ["https://127.0.0.1:15986/wsman"] * (retry_create ? 4 : 1), endpoints
      if retry_create
        assert(scripts.any? { |script| script&.include?("converged") })
        assert_includes scripts, "Write-Output 'verified'"
      end
      assert_equal(1, commands.count { |command| command[1] == "clone" })
      assert_equal([%w{prlctl delete clone}], commands.select { |command| command[1] == "delete" })
      assert_empty clone_files
      assert_equal(retry_create ? 3 : 1, markers.uniq.size)
      assert_equal [source], vms
    end
  end

  def readiness_marker(script)
    script[/kitchen-winrm-[0-9a-f-]+/] || flunk("Missing clone marker: #{script}")
  end

  it "rejects a non-loopback WinRM endpoint before touching Parallels" do
    Dir.mktmpdir do |root|
      unexpected_command = ->(*) { flunk "Parallels was called before endpoint validation" }
      Mixlib::ShellOut.stub(:new, unexpected_command) do
        assert_raises(Kitchen::InstanceFailure) { kitchen_instance(root, hostname: "192.0.2.10").create }
      end
    end
  end

  it "rejects Linux-only network options on WinRM before touching Parallels" do
    Dir.mktmpdir do |root|
      unexpected_command = ->(*) { flunk "Parallels was called before network validation" }
      Mixlib::ShellOut.stub(:new, unexpected_command) do
        [
          { network_mode: "shared", static_ip: "192.0.2.10/24" },
          { port_forward: { guest_port: 5986, host_port: 15986 } },
          { network_mode: "bridged", insert_key: false },
        ].each do |network|
          error = assert_raises(Kitchen::InstanceFailure) { kitchen_instance(root, **network).create }
          assert_includes error.cause.message, "Parallels WinRM supports inherited, shared or host-only networking"
        end
      end
    end
  end
end
