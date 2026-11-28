# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "open3"
require "timeout"
require "kitchen/data_munger"
require "kitchen/driver/parallels"

if ENV["REQUIRE_INSTANCE_LIFECYCLE"] == "1" && !Kitchen::Driver::Base.public_method_defined?(:with_instance_lifecycle)
  abort "The supported-core suite requires Driver::Base#with_instance_lifecycle"
end

describe Kitchen::Driver::Parallels do
  let(:driver) { Kitchen::Driver::Parallels.new({ kitchen_root: Dir.pwd }) }

  it "bootstraps keys by default for box archives and preserves existing PVM credentials" do
    _(Kitchen::Driver::Parallels.new(box: "bento.box")[:insert_key]).must_equal true
    _(Kitchen::Driver::Parallels.new(box: "custom.pvm")[:insert_key]).must_equal false
    _(Kitchen::Driver::Parallels.new(box: "bento.box", insert_key: false)[:insert_key]).must_equal false
  end

  it "replaces both public Vagrant keys and preserves unrelated keys on a retry" do
    access = Kitchen::Box::SshBootstrap
    rsa, ed = access::INSECURE_RSA, access::INSECURE_ED25519
    replacement = "ssh-ed25519 replacement kitchen"
    retained = "restrict ssh-ed25519 unrelated a-user"

    Dir.mktmpdir do |home|
      FileUtils.mkdir_p(File.join(home, ".ssh"))
      keys = File.join(home, ".ssh", "authorized_keys")
      File.write(keys, "ssh-rsa #{rsa} vagrant\nssh-ed25519 #{ed} vagrant\n#{retained}\n")
      2.times do
        _, stderr, status = Open3.capture3({ "HOME" => home }, "/bin/sh", "-c", access::INSTALL_KEY,
          "kitchen-key", rsa, ed, "replacement", replacement)
        assert status.success?, stderr
      end

      _(File.readlines(keys, chomp: true)).must_equal [retained, replacement]
      _(File.stat(keys).mode & 0o777).must_equal 0o600
    end
  end

  it "only considers current DHCP leases for the running VM's exact MAC address" do
    now = Time.now.to_i
    rows = [
      %Q{10.0.0.2="#{now - 1},10,001c422a8e5f,last"},
      %Q{10.0.0.3="#{now + 100},10,001c422a8e50,last"},
      %Q{10.0.0.4="#{now + 20},10,001c422a8e5f,last"},
      %Q{10.0.0.5="#{now + 10},10,001c422a8e5f,last"},
    ]
    File.stub(:foreach, rows.each) do
      _(driver.send(:leased_ipv4, { "status" => "running", "mac" => "00:1C:42:2A:8E:5F" })).must_equal "10.0.0.4"
      _(driver.send(:leased_ipv4, { "status" => "stopped", "mac" => "00:1C:42:2A:8E:5F" })).must_be_nil
    end
  end

  it "checks volume options before creating a VM" do
    invalid_share = Kitchen::Driver::Parallels.new(synced_folders: [["data", "/mnt/data", { type: "nfs" }]])
    invalid_disk = Kitchen::Driver::Parallels.new(additional_disks: [{ name: "../scratch", size_gb: 1 }])

    assert_raises(Kitchen::ActionFailed) { invalid_share.send(:volume_configuration) }
    assert_raises(Kitchen::ActionFailed) { invalid_disk.send(:volume_configuration) }
  end

  def lifecycle_hook_available?
    Kitchen::Driver::Base.public_method_defined?(:with_instance_lifecycle)
  end

  it "protects new linked clones and saved linked state on released core" do
    skip "Requires core without the lifecycle hook" if lifecycle_hook_available?

    Dir.mktmpdir do |root|
      instance = Struct.new(:name).new("default-linux")
      snapshot = "7b485669-5347-4592-809c-a9274908bc18"
      driver = Kitchen::Driver::Parallels.new(kitchen_root: root, source_vm: "base", source_snapshot: snapshot)
      driver.finalize_config!(instance)
      state = {}
      assert_includes assert_raises(Kitchen::ActionFailed) { driver.create(state) }.message, "linked clones require Test Kitchen"
      assert_empty state
      refute File.exist?(File.join(root, ".kitchen"))

      state_file = Kitchen::StateFile.new(root, instance.name)
      state = { parallels_snapshot: snapshot, parallels_token: "saved-token", last_action: "create" }
      state_file.write(state)
      default_driver = Kitchen::Driver::Parallels.new(kitchen_root: root, source_vm: "base")
      assert_includes assert_raises(Kitchen::UserError) { default_driver.finalize_config!(instance) }.message, "linked clones require Test Kitchen"
      assert_includes assert_raises(Kitchen::ActionFailed) { default_driver.destroy(state) }.message, "linked clones require Test Kitchen"
      assert_equal state, state_file.read
    end
  end

  it "rejects a recursive transition and releases the lock after failure" do
    skip "Requires core with the lifecycle hook" unless lifecycle_hook_available?

    Dir.mktmpdir do |root|
      state_path = File.join(root, ".kitchen", "default-linux.yml")
      instance = Struct.new(:name, :state_path).new("default-linux", state_path)
      driver = Kitchen::Driver::Parallels.new(kitchen_root: root, source_vm: "base")
      driver.finalize_config!(instance)

      error = assert_raises(Kitchen::ActionFailed) do
        driver.with_instance_lifecycle do
          driver.with_instance_lifecycle { flunk "Recursive transition ran" }
        end
      end
      assert_includes error.message, "nested Parallels lifecycle transition"
      File.open("#{state_path}.parallels.lock", "r+") do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
      end
      result = driver.with_instance_lifecycle { :complete }
      assert_equal :complete, result
    end
  end

  it "serializes first create and destroy across Kitchen processes through the final state write" do
    skip "Requires core with the lifecycle hook" unless lifecycle_hook_available?

    Dir.mktmpdir do |root|
      File.write(File.join(root, "kitchen.yml"), <<~YAML)
        driver:
          name: parallels
          source_vm: base
        provisioner:
          name: shell
        platforms:
          - name: linux
        suites:
          - name: default
      YAML

      Dir.chdir(root) do
        ready, signal = IO.pipe
        resume, release = IO.pipe
        creator = fork do
          release.close
          instance = Kitchen::Config.new.instances.first
          instance.driver.define_singleton_method(:create) do |state|
            state[:parallels_token] = "first-create"
            signal.puts "creating"
            resume.gets
          end
          instance.create
          exit! 0
        end
        signal.close
        resume.close
        assert_equal "creating\n", Timeout.timeout(10) { ready.gets }

        instance = Kitchen::Config.new.instances.first
        lock_path = "#{instance.state_path}.parallels.lock"
        File.open(lock_path, "r+") do |lock|
          refute lock.flock(File::LOCK_EX | File::LOCK_NB)
          refute File.exist?(instance.state_path)
          received = nil
          instance.driver.define_singleton_method(:destroy) { |state| received = state.dup }
          release.puts "finish"
          instance.destroy
          assert_equal %w{first-create create}, received.values_at(:parallels_token, :last_action)
          refute File.exist?(instance.state_path)
          assert_equal lock.stat.ino, File.stat(lock_path).ino
        end
        _, result = Process.wait2(creator)
        creator = nil
        assert result.success?
      ensure
        [ready, signal, resume, release].each { |pipe| pipe&.close unless pipe&.closed? }
        Process.wait(creator) if creator
      end
    end
  end

  it "recovers and destroys only the linked clone after registration is interrupted" do
    skip "Requires core with the lifecycle hook" unless lifecycle_hook_available?

    Dir.mktmpdir do |root|
      snapshot = "7b485669-5347-4592-809c-a9274908bc18"
      source = { "name" => "base", "uuid" => "source-uuid", "status" => "stopped" }
      clone = nil
      clone_home = nil
      reported_home = nil
      connection = Object.new
      def connection.wait_until_ready; end
      transport = Object.new
      transport.define_singleton_method(:connection) { |_state| connection }
      driver = Kitchen::Driver::Parallels.new(kitchen_root: root, source_vm: "base", source_snapshot: snapshot.upcase)
      instance = Struct.new(:name, :transport, :logger).new("default-linux", transport, Kitchen.logger)
      state = {}
      commands = lambda do |*args|
        if args == %w{prlctl list clone-uuid --info --json}
          next [{ "Home" => reported_home }].to_json
        end

        case args.first(2)
        when %w{prlctl list}
          [source, clone].compact.to_json
        when %w{prlctl clone}
          directory = File.join(root, ".kitchen", "parallels-#{state.fetch(:parallels_token)}")
          _(args).must_equal ["prlctl", "clone", "source-uuid", "--name", state.fetch(:parallels_name),
            "--linked", "--id", "{#{snapshot}}", "--dst", directory, "--detach-external-hdd", "yes"]
          assert File.directory?(directory)
          clone_home = File.join(directory, "clone.pvm")
          FileUtils.mkdir_p(clone_home)
          clone = { "name" => state.fetch(:parallels_name), "uuid" => "clone-uuid",
                    "status" => "running", "ip_configured" => "10.0.0.2" }
          raise Kitchen::ActionFailed, "interrupted after registration"
        when %w{prlctl stop}
          _(args.drop(2)).must_equal ["clone-uuid", "--kill"]
          persisted = Kitchen::StateFile.new(root, "default-linux").read
          assert_equal "clone-uuid", persisted[:parallels_uuid]
        when %w{prlctl delete}
          _(args.drop(2)).must_equal ["clone-uuid"]
          clone = nil
        else
          flunk "Unexpected command: #{args.inspect}"
        end
      end
      driver.stub(:instance, instance) do
        driver.stub(:command, commands) do
          error = assert_raises(Kitchen::ActionFailed) { driver.create(state) }
          assert_includes error.message, "interrupted after registration"
          state = Kitchen::StateFile.new(root, "default-linux").read
          assert_equal snapshot, state[:parallels_snapshot]
          reported_home = File.join(root, "unrelated.pvm")
          FileUtils.mkdir_p(reported_home)
          assert_includes assert_raises(Kitchen::ActionFailed) { driver.destroy(state) }.message, "Cannot verify ownership"
          directory = File.dirname(clone_home)
          File.rename(directory, "#{directory}.saved")
          File.symlink(root, directory)
          assert_includes assert_raises(Kitchen::ActionFailed) { driver.destroy(state) }.message, "Cannot verify ownership"
          File.unlink(directory)
          File.rename("#{directory}.saved", directory)
          reported_home = File.join(directory, "alias.pvm")
          File.symlink(clone_home, reported_home)
          assert_includes assert_raises(Kitchen::ActionFailed) { driver.destroy(state) }.message, "Cannot verify ownership"
          File.unlink(reported_home)
          reported_home = clone_home
          driver.create(state)
          _(state.values_at(:parallels_uuid, :hostname)).must_equal ["clone-uuid", "10.0.0.2"]
          state[:parallels_uuid] = "stale-uuid"
          Kitchen::StateFile.new(root, "default-linux").write(state)
          clone["name"] = "renamed"
          error = assert_raises(Kitchen::ActionFailed) { driver.destroy(state) }
          assert_includes error.message, "manual recovery"
          assert File.directory?(clone_home)
          assert_equal "stale-uuid", Kitchen::StateFile.new(root, "default-linux").read[:parallels_uuid]
          clone["name"] = state.fetch(:parallels_name)
          driver.destroy(state)
          assert_nil clone
          assert_empty Dir.glob(File.join(root, ".kitchen", "parallels-*"))
        end
      end
    end
  end

  it "rejects snapshots with a box and requires a snapshot UUID with a registered source" do
    box = Kitchen::Driver::Parallels.new(box: "base.box", source_snapshot: "7b485669-5347-4592-809c-a9274908bc18")
    source = Kitchen::Driver::Parallels.new(source_vm: "base", source_snapshot: "snapshot-name")
    state = {}

    assert_includes assert_raises(Kitchen::ActionFailed) { box.create(state) }.message, "requires driver.source_vm"
    assert_includes assert_raises(Kitchen::ActionFailed) { source.create(state) }.message, "snapshot UUID"
    assert_empty state
  end

  it "requires teardown before switching an existing full clone to a linked clone" do
    skip "Requires core with the lifecycle hook" unless lifecycle_hook_available?

    driver = Kitchen::Driver::Parallels.new(source_vm: "base", source_snapshot: "7b485669-5347-4592-809c-a9274908bc18")
    existing = { parallels_token: "existing", parallels_import: false }

    error = assert_raises(Kitchen::ActionFailed) { driver.create(existing) }
    assert_includes error.message, "Run kitchen destroy"
  end

  it "keeps the box path in the platform's driver config" do
    data = Kitchen::DataMunger.new({
      driver: { name: "parallels" },
      platforms: [
        { name: "ubuntu", driver: { box: "ubuntu.box" } },
        { name: "debian", driver: { box: "debian.box" } },
      ],
      suites: [{ name: "default" }],
    }, { kitchen_root: Dir.pwd, test_base_path: "test", log_level: :info })

    _(data.driver_data_for("default", "ubuntu").values_at(:name, :box)).must_equal ["parallels", "ubuntu.box"]
    _(data.driver_data_for("default", "debian").values_at(:name, :box)).must_equal ["parallels", "debian.box"]
  end
end

describe Kitchen::Box::LocalArchive do
  it "extracts provider metadata for another driver without evaluating the Vagrantfile" do
    Dir.mktmpdir do |root|
      source = File.join(root, "source")
      archive = File.join(root, "fixture.box")
      target = File.join(root, "target")
      FileUtils.mkdir_p([source, target])
      File.write(File.join(source, "metadata.json"), '{"provider":"virtualbox"}')
      File.write(File.join(source, "Vagrantfile"), "raise 'Do not evaluate this file'")
      assert system("/usr/bin/tar", "-cf", archive, "-C", source, "metadata.json", "Vagrantfile")

      extract = ->(*args) { assert system(*args) }
      _(Kitchen::Box::LocalArchive.new(archive, provider: "virtualbox").extract(target, &extract)).must_equal({ "provider" => "virtualbox" })
      assert_raises(Kitchen::Box::LocalArchive::InvalidBox) do
        Kitchen::Box::LocalArchive.new(archive, provider: "parallels").extract(target, &extract)
      end
    end
  end
end
