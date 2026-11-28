# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "kitchen/driver/parallels"

describe "kitchen-parallels package" do
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
      assert_includes calls, ["unregister", "clone-id"]
      refute calls.any? { |command, id| %w{delete unregister stop start set}.include?(command) && id == state[:parallels_uuid] }
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
      refute calls.any? { |command, _| command == "clone" }
    end
  end

  it "unregisters an incomplete clone without publishing an artifact" do
    with_package_vm(complete: false) do |driver, state, root, calls|
      assert_match(/missing config.pvs/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      assert_includes calls, ["unregister", "clone-id"]
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
      assert_includes calls, ["unregister", "clone-id"]
      refute_path_exists File.join(root, "default-ubuntu.box")
    end
  end

  it "unregisters an owned clone after Parallels reports a clone failure" do
    with_package_vm(clone_failure: true) do |driver, state, root, calls|
      assert_match(/Clone failed/, assert_raises(Kitchen::ActionFailed) { driver.package(state) }.message)
      assert_includes calls, ["unregister", "clone-id"]
      refute_path_exists File.join(root, "default-ubuntu.box")
      assert_empty Dir.glob(".parallels-package-*", base: root)
    end
  end

  def with_package_vm(status: "stopped", complete: true, missing_extent: false, clone_failure: false)
    Dir.mktmpdir do |root|
      driver = Kitchen::Driver::Parallels.new(kitchen_root: root)
      driver.finalize_config!(Struct.new(:name, :logger).new("default-ubuntu", Logger.new(File::NULL)))
      token = SecureRandom.uuid
      state = { parallels_token: token, parallels_uuid: token, parallels_name: "kitchen-source", parallels_key_injected: false }
      source = { "uuid" => token, "name" => "kitchen-source", "status" => status }
      source_bundle = File.join(root, "source.pvm")
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
            info = {
              "State" => args[1] == token ? status : clone["status"],
              "Home" => bundle,
              "Hardware" => { "hdd0" => { "image" => File.join(bundle, "disk.hdd") } },
            }
            JSON.generate([info])
          else
            JSON.generate([source, clone].compact)
          end
        when "clone"
          name = args[args.index("--name") + 1]
          clone_bundle = File.join(args[args.index("--dst") + 1], "#{name}.pvm")
          create_bundle(clone_bundle, complete: complete)
          clone = { "uuid" => "clone-id", "name" => name, "status" => "stopped" }
          File.unlink(File.join(clone_bundle, "disk.hdd", "second.hds")) if missing_extent
          if clone_failure
            clone["status"] = "suspended"
            raise Kitchen::ActionFailed, "Clone failed after registration"
          end
        when "unregister"
          clone = nil
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
