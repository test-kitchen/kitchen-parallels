# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "open3"
require "fileutils"
require "kitchen"
require "kitchen/state_file"

describe "kitchen-parallels restore" do
  let(:vm_id) { "e54a7a0e-1b45-413d-a79c-1ad86b73b5df" }
  let(:ownership_token) { "56e20084-5f47-4bf1-934b-afdcfcb8b026" }
  let(:snapshot_id) { "42021c3e-24d4-4b32-8665-ad7f268b0eca" }
  let(:instance_name) { "default-ubuntu" }
  let(:vm_name) { "kitchen-#{instance_name}-#{ownership_token}" }

  it "restores a managed VM and makes Kitchen create reconnect" do
    run_restore do |status, output, calls, state, state_mode|
      assert status.success?, output
      _(calls.last).must_equal ["snapshot-switch", vm_id, "--id", "{#{snapshot_id}}", "--skip-resume"]
      _(state.values_at(:last_action, :hostname)).must_equal [nil, nil]
      _(state[:parallels_uuid]).must_equal vm_id
      _(state_mode).must_equal 0o600
    end
  end

  it "leaves the guest and Kitchen state unchanged when a snapshot is missing" do
    run_restore(snapshots: {}) do |status, output, calls, state|
      refute status.success?
      _(output).must_include "snapshot #{snapshot_id} was not found"
      _(calls.map(&:first)).must_equal %w{list snapshot-list}
      _(state.values_at(:last_action, :hostname)).must_equal ["converge", "192.0.2.10"]
    end
  end

  it "refuses to restore a VM whose name does not match the Kitchen ownership token" do
    run_restore(registered_name: "source") do |status, output, calls, state|
      refute status.success?
      _(output).must_include "managed Parallels VM"
      _(calls.map(&:first)).must_equal ["list"]
      _(state[:last_action]).must_equal "converge"
    end
  end

  it "refuses to stop or switch a running guest" do
    run_restore(vm_status: "running") do |status, output, calls, state|
      refute status.success?
      _(output).must_include "shut down"
      _(calls.map(&:first)).must_equal %w{list snapshot-list}
      _(state[:last_action]).must_equal "converge"
    end
  end

  it "preserves the original Kitchen state when Parallels rejects the switch" do
    run_restore(switch_status: 1) do |status, _output, calls, state|
      refute status.success?
      _(calls.map(&:first)).must_equal %w{list snapshot-list snapshot-switch}
      _(state.values_at(:last_action, :hostname, :parallels_token)).must_equal ["converge", "192.0.2.10", ownership_token]
    end
  end

  def run_restore(registered_name: vm_name, vm_status: "stopped", snapshots: { "{#{snapshot_id}}" => { "state" => "poweroff" } }, switch_status: 0)
    Dir.mktmpdir do |root|
      executable = File.expand_path("../exe/kitchen-parallels", __dir__)
      File.write(File.join(root, "kitchen.yml"), <<~YAML)
        driver:
          name: parallels
          source_vm: source
        platforms:
          - name: ubuntu
        suites:
          - name: default
      YAML
      state_file = Kitchen::StateFile.new(root, instance_name)
      state_file.write(parallels_token: ownership_token, parallels_uuid: vm_id, parallels_name: vm_name,
        hostname: "192.0.2.10", last_action: "converge")
      File.chmod(0o600, state_file.path)
      prlctl = File.join(root, "prlctl")
      File.write(prlctl, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        File.open("calls", "a") { |log| log.puts(JSON.generate(ARGV)) }
        case ARGV.first
        when "list" then puts #{JSON.generate([{ uuid: vm_id, name: registered_name, status: vm_status }]).inspect}
        when "snapshot-list" then puts #{JSON.generate(snapshots).inspect}
        when "snapshot-switch" then exit #{switch_status}
        end
      RUBY
      FileUtils.chmod(0o755, prlctl)
      env = { "PATH" => [root, ENV["PATH"]].join(File::PATH_SEPARATOR) }
      output, status = Open3.capture2e(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__),
        executable, "restore", instance_name, snapshot_id, chdir: root)
      calls = File.exist?(File.join(root, "calls")) ? File.readlines(File.join(root, "calls")).map { |line| JSON.parse(line) } : []
      yield status, output, calls, state_file.read, File.stat(state_file.path).mode & 0o777
    end
  end
end
