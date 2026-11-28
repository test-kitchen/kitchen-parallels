# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "kitchen/driver/parallels"

describe "kitchen-parallels package" do
  PACKAGE_CLONE_ID = "778de327-950a-4515-a77a-9928c7322c9e".freeze
  it "refuses to export an instance with Kitchen-injected SSH access" do
    Dir.mktmpdir do |root|
      driver = Kitchen::Driver::Parallels.new(kitchen_root: root)
      driver.finalize_config!(Struct.new(:name, :logger).new("default-ubuntu", Logger.new(File::NULL)))
      error = assert_raises(Kitchen::ActionFailed) do
        uuid = SecureRandom.uuid
        driver.package(parallels_token: uuid, parallels_uuid: uuid, parallels_generated_key: true)
      end
      assert_match(/Kitchen-injected SSH key/, error.message)
      refute_path_exists File.join(root, "default-ubuntu.box")
    end
  end

  it "packages a stopped instance as a private box and unregisters only its clone" do
    with_package_vm do |driver, state, root, calls|
      output = driver.package(state)
      assert_equal File.join(root, "default-ubuntu.box"), output
      assert_equal 0o600, File.stat(output).mode & 0o777
      Dir.mktmpdir do |destination|
        box = Kitchen::Box::LocalArchive.new(output, provider: "parallels")
        assert_equal({ "provider" => "parallels" }, box.extract(destination) { |*args| assert system(*args) })
        assert_path_exists Dir.glob(File.join(destination, "*.pvm", "config.pvs")).fetch(0)
      end
      assert_includes calls, ["unregister", PACKAGE_CLONE_ID]
      refute(calls.any? { |command, id| %w{delete unregister stop start set}.include?(command) && id == state[:parallels_uuid] })
      assert_empty Dir.glob(".parallels-package-*", base: root)
    end
  end

  it "preserves an existing output and refuses a running VM" do
    with_package_vm(status: "running") do |driver, state, root, calls|
      output = File.join(root, "default-ubuntu.box")
      File.write(output, "previous package")
      assert_match(/already exists/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      assert_equal "previous package", File.read(output)
      assert_empty calls

      File.unlink(output)
      assert_match(/Shut down/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      refute_path_exists output
      refute(calls.any? { |command, _| command == "clone" })
    end
  end

  it "unregisters an incomplete clone without publishing an artifact" do
    with_package_vm(complete: false) do |driver, state, root, calls|
      assert_match(/missing config.pvs/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      assert_includes calls, ["unregister", PACKAGE_CLONE_ID]
      refute_path_exists File.join(root, "default-ubuntu.box")
      assert_empty Dir.glob(".parallels-package-*", base: root)
    end
  end

  it "refuses a stopped instance whose SSH injection history is unknown" do
    with_package_vm do |driver, state, root, calls|
      state.delete(:parallels_key_injected)
      assert_match(/SSH injection history/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      refute_path_exists File.join(root, "default-ubuntu.box")
      assert_empty calls
    end
  end

  it "rejects a disk with a missing extent even when another extent is present" do
    with_package_vm(missing_extent: true) do |driver, state, root, calls|
      assert_match(/missing or external extents/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      assert_includes calls, ["unregister", PACKAGE_CLONE_ID]
      refute_path_exists File.join(root, "default-ubuntu.box")
    end
  end

  it "unregisters an owned clone after Parallels reports a clone failure" do
    with_package_vm(clone_failure: true) do |driver, state, root, calls|
      assert_match(/Clone failed/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      assert_includes calls, ["unregister", PACKAGE_CLONE_ID]
      refute_path_exists File.join(root, "default-ubuntu.box")
      assert_empty Dir.glob(".parallels-package-*", base: root)
    end
  end

  it "refuses a source_vm clone despite its local SSH injection flag" do
    with_package_vm do |driver, state, root, calls|
      state[:parallels_import] = false
      state.delete(:parallels_package_source_sha256)
      Kitchen::StateFile.new(root, "default-ubuntu").write(state)
      assert_match(/source provenance/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      assert_empty calls
    end
  end

  it "preserves the staging bundle when registration cannot be established" do
    %i{invalid_list invalid_details renamed}.each do |metadata|
      with_package_vm(metadata: metadata) do |driver, state, root, calls|
        assert_match(/Staging retained/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
        refute(calls.any? { |command, _| command == "unregister" })
        assert_equal 1, Dir.glob(File.join(root, ".parallels-package-*", "*.pvm", "config.pvs")).size
        refute_path_exists File.join(root, "default-ubuntu.box")
      end
    end
  end

  it "refuses a disconnected optical drive that still references an image" do
    with_package_vm(optical_image: "/host/installer.iso") do |driver, state, _, calls|
      assert_match(/Remove optical media/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      refute(calls.any? { |command, _| command == "clone" })
    end
  end

  it "rejects a clone that retains global host sharing" do
    with_package_vm(retain_sharing: true) do |driver, state, root, calls|
      assert_match(/host sharing was disabled/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      assert(calls.any? { |command, _, *args| command == "set" && args.include?("--shf-host-defined") })
      refute_path_exists File.join(root, "default-ubuntu.box")
    end
  end

  it "keeps the clone bundle if unregistration cannot be verified" do
    with_package_vm(metadata: :still_registered) do |driver, state, root, calls|
      assert_match(/Staging retained/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      assert_includes calls, ["unregister", PACKAGE_CLONE_ID]
      assert_equal 1, Dir.glob(File.join(root, ".parallels-package-*", "*.pvm", "config.pvs")).size
      refute_path_exists File.join(root, "default-ubuntu.box")
    end
  end

  it "requires the provenance record from the saved import" do
    with_package_vm do |driver, state, root, calls|
      state[:parallels_package_source_sha256] = "b" * 64
      assert_match(/source provenance/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      refute_path_exists File.join(root, "default-ubuntu.box")
      assert_empty calls
    end
  end

  it "rejects an unverified archive before registration" do
    Dir.mktmpdir do |root|
      source = File.join(root, "base.box")
      File.write(source, "unexpected archive bytes")
      driver = Kitchen::Driver::Parallels.new(kitchen_root: root, box: source, package_source_sha256: "a" * 64)
      instance = Struct.new(:name, :logger, :transport).new("default-ubuntu", Logger.new(File::NULL), { name: "ssh" })
      driver.finalize_config!(instance)
      inventory = ["list", "--all", "--full", "--output", "uuid,status,ip_configured,mac,name", "--json"]
      cli = lambda do |*args|
        assert_equal inventory, args
        "[]"
      end
      error = assert_raises(Kitchen::ActionFailed) do
        driver.stub(:prlctl, cli) do
          driver.create({})
        end
      end
      assert_match(/does not match driver.package_source_sha256/, error.message)
      refute Kitchen::StateFile.new(root, "default-ubuntu").read.key?(:parallels_package_source_sha256)
    end
  end

  def with_package_vm(status: "stopped", complete: true, missing_extent: false, clone_failure: false,
    metadata: nil, optical_image: nil, retain_sharing: false)
    Dir.mktmpdir do |root|
      driver = Kitchen::Driver::Parallels.new(kitchen_root: root)
      driver.finalize_config!(Struct.new(:name, :logger).new("default-ubuntu", Logger.new(File::NULL)))
      token = SecureRandom.uuid
      state = {
        parallels_token: token, parallels_uuid: token, parallels_name: "kitchen-source", parallels_key_injected: false,
        parallels_import: true, parallels_package_source_sha256: "a" * 64
      }
      Kitchen::StateFile.new(root, "default-ubuntu").write(state)
      source = { "uuid" => token, "name" => "kitchen-source", "status" => status }
      source_bundle = File.join(root, ".kitchen", "parallels-#{token}", "source.pvm")
      create_bundle(source_bundle)
      clone = nil
      clone_bundle = nil
      calls = []
      cli = lambda do |*args|
        calls << args
        case args.first
        when "list"
          if args.include?("--info")
            bundle = args[1] == token ? source_bundle : clone_bundle
            return JSON.generate([{ "Home" => [] }]) if args[1] == PACKAGE_CLONE_ID && metadata == :invalid_details

            info = {
              "ID" => args[1],
              "External boot device" => "",
              "Restore Image" => "",
              "Host Shared Folders" => { "enabled" => false },
              "Host defined sharing" => retain_sharing ? "Home" : "Off",
              "Shared Profile" => { "enabled" => false },
              "SmartMount" => { "enabled" => false },
              "Miscellaneous Sharing" => { "Shared cloud" => "off" },
              "Advanced" => { "Public SSH keys synchronization" => "off" },
              "State" => args[1] == token ? status : clone["status"],
              "Home" => bundle,
              "Hardware" => { "hdd0" => { "image" => File.join(bundle, "disk.hdd") } },
            }
            if optical_image
              info["Hardware"]["cdrom0"] = { "image" => optical_image, "state" => "disconnected" }
            end
            JSON.generate([info])
          else
            return JSON.generate([source, nil]) if clone && metadata == :invalid_list

            JSON.generate([source, clone].compact)
          end
        when "clone"
          name = args[args.index("--name") + 1]
          clone_bundle = File.join(args[args.index("--dst") + 1], "#{name}.pvm")
          create_bundle(clone_bundle, complete: complete)
          clone = { "uuid" => PACKAGE_CLONE_ID, "name" => metadata == :renamed ? "renamed" : name, "status" => "stopped" }
          File.unlink(File.join(clone_bundle, "disk.hdd", "second.hds")) if missing_extent
          if clone_failure
            clone["status"] = "suspended"
            raise Kitchen::ActionFailed, "Clone failed after registration"
          end
        when "set"
          nil
        when "unregister"
          clone = nil unless metadata == :still_registered
        else
          flunk "Unexpected Parallels command: #{args.inspect}"
        end
      end
      driver.stub(:prlctl, cli) { yield driver, state, root, calls }
    end
  end

  def create_bundle(bundle, complete: true)
    disk = File.join(bundle, "disk.hdd")
    FileUtils.mkdir_p(disk)
    File.write(File.join(disk, "DiskDescriptor.xml"), <<~XML)
      <Parallels_disk_image>
        <StorageData>
          <Storage>
            <Image><File>disk.hds</File></Image>
            <Image><File>second.hds</File></Image>
          </Storage>
        </StorageData>
      </Parallels_disk_image>
    XML
    File.write(File.join(disk, "disk.hds"), "extent")
    File.write(File.join(disk, "second.hds"), "second extent")
    File.write(File.join(bundle, "config.pvs"), "<config/>") if complete
  end
end
