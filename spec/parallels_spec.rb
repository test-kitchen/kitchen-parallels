# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "open3"
require "kitchen/data_munger"
require "kitchen/driver/parallels"

describe Kitchen::Driver::Parallels do
  let(:driver) { Kitchen::Driver::Parallels.new({ kitchen_root: Dir.pwd }) }

  it "reports an uncreated VM without calling the provider" do
    driver.stub(:command, ->(*) { flunk "unexpected provider call" }) do
      result = driver.status({})

      _(result.values_at(:live, :state, :source)).must_equal [false, "not_created", "driver"]
    end
  end

  it "uses the saved name to discover the VM even before its ID is saved" do
    command = '[{"uuid":"1234-abcd","status":"running","name":"kitchen-test"}]'
    driver.stub(:command, command) do
      result = driver.status(parallels_name: "kitchen-test")

      _(result.values_at(:live, :state, :resource_id)).must_equal [true, "running", "1234-abcd"]
      _(Time.iso8601(result[:checked_at])).must_be_instance_of Time
    end
  end

  it "distinguishes a missing VM from an unavailable provider" do
    state = { parallels_uuid: "1234-abcd" }
    driver.stub(:command, "[]") do
      _(driver.status(state).values_at(:live, :state)).must_equal [false, "not_created"]
    end
    driver.stub(:command, ->(*) { raise Kitchen::ActionFailed, "host unavailable" }) do
      _(driver.status(state).values_at(:live, :state, :message)).must_equal [nil, "unknown", "host unavailable"]
    end
  end

  it "reports host and source problems without modifying a VM" do
    problems = []
    driver = Kitchen::Driver::Parallels.new(kitchen_root: Dir.pwd, box: "missing.box")
    driver.stub(:command, ->(*) { raise Kitchen::ActionFailed, "host unavailable" }) do
      driver.stub(:warn, ->(message) { problems << message }) do
        _(driver.doctor({})).must_equal true
      end
    end

    _(problems.first).must_equal "host unavailable"
    _(problems.last).must_match(/missing\.box/)
  end

  it "accepts a readable local box and an available provider" do
    Dir.mktmpdir do |root|
      path = File.join(root, "local.box")
      File.write(path, "")
      driver = Kitchen::Driver::Parallels.new(kitchen_root: root, box: "local.box")

      driver.stub(:command, "[]") do
        _(driver.doctor({})).must_equal false
      end
    end
  end

  it "applies configured CPU and memory to the cloned VM before boot" do
    commands = intercept_vm_create(cpus: 3, memory: 2048)

    settings, start = commands.last(2)
    _(settings.first(2)).must_equal %w{set disposable}
    _(settings.each_cons(2).to_a).must_include %w{--cpus 3}
    _(settings.each_cons(2).to_a).must_include %w{--memsize 2048}
    _(start).must_equal %w{start disposable}
  end

  it "sets only the specified hardware options" do
    defaults = %w{set disposable --startup-view headless --shf-host off --smart-mount off}
    _(intercept_vm_create(cpus: 3).last(2).first).must_equal(defaults + %w{--cpus 3})
    _(intercept_vm_create(memory: 2048).last(2).first).must_equal(defaults + %w{--memsize 2048})
    _(intercept_vm_create.last(2).first).must_equal defaults
  end

  it "cold boots suspended imports with hardware overrides and resumes an existing VM on retry" do
    Dir.mktmpdir do |root|
      path = File.join(root, "kitchen.yml")
      box = File.join(root, "source.pvm")
      FileUtils.mkdir_p(box)
      File.write(File.join(box, "config.pvs"), "")
      File.write(path, YAML.dump({
        "driver" => { "name" => "parallels", "box" => box, "cpus" => 3 },
        "platforms" => [{ "name" => "ubuntu" }],
        "suites" => [{ "name" => "default" }],
      }))
      loader = Kitchen::Loader::YAML.new(project_config: path, process_local: false, process_global: false)
      instance = Kitchen::Config.new(loader: loader, kitchen_root: root, log_level: :error).instances.first

      commands = []
      vm = nil
      run = lambda do |*args|
        commands << args
        case args.first
        when "list"
          args.include?("--info") ? "[{}]" : JSON.generate([vm].compact)
        when "register"
          state = Kitchen::StateFile.new(root, instance.name).read
          assert state[:parallels_first_boot], "first boot must be saved before registration"
          vm = { uuid: args[args.index("--uuid") + 1], name: args.last, status: "suspended" }
        end
      end
      copy_bundle = ->(_program, source, destination) { FileUtils.cp_r(source, destination) }
      instance.driver.stub(:command, copy_bundle) do
        instance.driver.stub(:prlctl, run) do
          instance.driver.stub(:wait_for_ip, ->(*) { raise Kitchen::ActionFailed, "boot intercepted" }) do
            2.times do
              error = assert_raises(Kitchen::InstanceFailure) { instance.create }
              _(error.cause.message).must_equal "boot intercepted"
            end

            vm = nil
            error = assert_raises(Kitchen::InstanceFailure) { instance.create }
            _(error.cause.message).must_equal "boot intercepted"
          end
        end
      end

      uuid = vm.fetch(:uuid)
      power_and_settings = commands.select { |command| %w{stop set start resume}.include?(command.first) }
      cold_boot = [
        ["stop", uuid, "--drop-state"],
        ["set", uuid] + %w{--startup-view headless --shf-host off --smart-mount off --cpus 3},
        ["start", uuid],
      ]
      _(power_and_settings).must_equal(cold_boot + [["resume", uuid]] + cold_boot)
    end
  end

  it "rejects invalid hardware values before invoking Parallels" do
    %i{cpus memory}.each do |key|
      [0, -1, 1.5, true, "2"].each do |value|
        commands = intercept_vm_create(expected_error: "driver.#{key} must be a positive integer", key => value)
        _(commands).must_be_empty
      end
    end
  end

  def intercept_vm_create(expected_error: "boot intercepted", **hardware)
    Dir.mktmpdir do |root|
      path = File.join(root, "kitchen.yml")
      File.write(path, YAML.dump({
        "driver" => { "name" => "parallels", "source_vm" => "source", **hardware.transform_keys(&:to_s) },
        "platforms" => [{ "name" => "ubuntu" }],
        "suites" => [{ "name" => "default" }],
      }))
      loader = Kitchen::Loader::YAML.new(project_config: path, process_local: false, process_global: false)
      instance = Kitchen::Config.new(loader: loader, kitchen_root: root, log_level: :error).instances.first

      commands = []
      run = lambda do |program, *args, **|
        _(program).must_equal "prlctl"
        commands << args
        raise Kitchen::ActionFailed, "boot intercepted" if args.first == "start"

        output = [{ uuid: "source-id", name: "source", status: "stopped" }]
        clone = commands.find { |command| command.first == "clone" }
        output << { uuid: "disposable", name: clone.last, status: "stopped" } if clone
        Struct.new(:stdout) do
          def run_command; end
          def error!; end
        end.new(JSON.generate(output))
      end
      Mixlib::ShellOut.stub(:new, run) do
        error = assert_raises(Kitchen::InstanceFailure) { instance.create }
        _(error.cause.message).must_include expected_error
      end
      commands
    end
  end

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
