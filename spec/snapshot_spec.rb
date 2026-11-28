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
      _(calls.fetch(3)).must_equal ["snapshot-switch", vm_id, "--id", "{#{snapshot_id}}", "--skip-resume"]
      _(calls.map(&:first)).must_equal %w{list snapshot-list list snapshot-switch snapshot-list list}
      _(state.values_at(:last_action, :hostname)).must_equal [nil, nil]
      _(state[:parallels_uuid]).must_equal vm_id
      _(state_mode).must_equal 0o600
    end
  end

  it "leaves the guest and Kitchen state unchanged when a snapshot is missing" do
    run_restore(inventory: " \n") do |status, output, calls, state|
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
      _(calls.map(&:first)).must_equal ["list"]
      _(state[:last_action]).must_equal "converge"
    end
  end

  it "rejects malformed inventories without switching or clearing state" do
    ["{", "[]", JSON.generate("{#{snapshot_id}}" => nil), JSON.generate("{#{snapshot_id}}" => {})].each do |inventory|
      run_restore(inventory: inventory) do |status, output, calls, state|
        refute status.success?
        _(output).must_match(/Invalid .*prlctl snapshot-list/)
        _(calls.map(&:first)).must_equal %w{list snapshot-list}
        _(state[:last_action]).must_equal "converge"
      end
    end
  end

  it "rechecks VM ownership and power state before switching" do
    [{ name: "source" }, { status: "running" }].each do |changed_vm|
      run_restore(changed_vm: changed_vm) do |status, output, calls, state|
        refute status.success?
        _(output).must_match(/managed Parallels VM|shut down/)
        _(calls.map(&:first)).must_equal %w{list snapshot-list list}
        _(state.values_at(:last_action, :hostname)).must_equal ["converge", "192.0.2.10"]
      end
    end
  end

  it "keeps the reset when the switch command reports failure" do
    run_restore(switch_status: 1) do |status, output, calls, state|
      refute status.success?
      _(output).must_include "Could not confirm snapshot restore"
      _(calls.map(&:first)).must_equal %w{list snapshot-list list snapshot-switch}
      _(state.values_at(:last_action, :hostname, :parallels_token)).must_equal [nil, nil, ownership_token]
    end
  end

  it "fails with reset state when the switch returns success without making the snapshot current" do
    run_restore(snapshot_current: false) do |status, output, calls, state|
      refute status.success?
      _(output).must_include "is not current"
      _(calls.map(&:first)).must_equal %w{list snapshot-list list snapshot-switch snapshot-list}
      _(state.values_at(:last_action, :hostname)).must_equal [nil, nil]
    end
  end

  it "fails with reset state when the VM is running after the switch" do
    run_restore(restored_status: "running") do |status, output, _calls, state|
      refute status.success?
      _(output).must_include "Could not confirm snapshot restore"
      _(output).must_include "shut down"
      _(state.values_at(:last_action, :hostname)).must_equal [nil, nil]
    end
  end

  it "keeps the reset when the restore process is killed during the switch" do
    run_restore(interrupt: true) do |status, _output, calls, state|
      _(status.termsig).must_equal Signal.list.fetch("KILL")
      _(calls.map(&:first)).must_equal %w{list snapshot-list list snapshot-switch}
      _(state.values_at(:last_action, :hostname, :parallels_uuid)).must_equal [nil, nil, vm_id]
    end
  end

  it "keeps the original state and avoids switching when the reset cannot be persisted" do
    run_restore(rename_failure: true) do |status, output, calls, state|
      refute status.success?
      _(output).must_include "Could not complete restore"
      _(calls.map(&:first)).must_equal %w{list snapshot-list list}
      _(state.values_at(:last_action, :hostname)).must_equal ["converge", "192.0.2.10"]
    end
  end

  def run_restore(registered_name: vm_name, vm_status: "stopped", inventory: nil, changed_vm: {}, switch_status: 0,
    snapshot_current: true, restored_status: "stopped", interrupt: false, rename_failure: false)
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
      initial_vm = { uuid: vm_id, name: registered_name, status: vm_status }
      snapshots = { "{#{snapshot_id}}" => { "state" => "poweroff" } }
      other_snapshot = "{6ed519b4-b587-4e8d-adc5-cbd9a7da3f0c}"
      snapshots[other_snapshot] = { "state" => "poweroff", "current" => true }
      restored = { "{#{snapshot_id}}" => { "state" => "poweroff", "current" => snapshot_current } }
      restored[other_snapshot] = { "state" => "poweroff", "current" => !snapshot_current }
      prlctl = File.join(root, "prlctl")
      File.write(prlctl, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        require "yaml"
        earlier_calls = File.exist?("calls") ? File.readlines("calls").map { |line| JSON.parse(line).first } : []
        File.open("calls", "a") { |log| log.puts(JSON.generate(ARGV)) }
        switched = earlier_calls.include?("snapshot-switch")
        case ARGV.first
        when "list"
          puts(if switched
                 #{JSON.generate([initial_vm.merge(status: restored_status)]).inspect}
               elsif earlier_calls.include?("list")
                 #{JSON.generate([initial_vm.merge(changed_vm)]).inspect}
               else
                 #{JSON.generate([initial_vm]).inspect}
               end)
        when "snapshot-list"
          puts(switched ? #{JSON.generate(restored).inspect} : #{(inventory || JSON.generate(snapshots)).inspect})
        when "snapshot-switch"
          state = YAML.safe_load_file(#{state_file.path.inspect})
          abort "Kitchen stage and address were still set during the switch" if state.key?("last_action") || state.key?("hostname")
          Process.kill("KILL", Process.ppid) if #{interrupt}
          exit #{switch_status}
        end
      RUBY
      FileUtils.chmod(0o755, prlctl)
      env = { "PATH" => [root, ENV["PATH"]].join(File::PATH_SEPARATOR) }
      ruby_options = ["-I", File.expand_path("../lib", __dir__)]
      if rename_failure
        failure = File.join(root, "rename_failure.rb")
        File.write(failure, <<~RUBY)
          def File.rename(from, to)
            raise Errno::EACCES, to
          end
        RUBY
        ruby_options.push("-r", failure)
      end
      output, status = Open3.capture2e(env, RbConfig.ruby, *ruby_options,
        executable, "restore", instance_name, snapshot_id, chdir: root)
      calls = File.exist?(File.join(root, "calls")) ? File.readlines(File.join(root, "calls")).map { |line| JSON.parse(line) } : []
      yield status, output, calls, state_file.read, File.stat(state_file.path).mode & 0o777
    end
  end
end
