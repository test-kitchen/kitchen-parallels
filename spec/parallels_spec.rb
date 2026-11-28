# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "open3"
require "kitchen/data_munger"
require "kitchen/driver/parallels"

describe Kitchen::Driver::Parallels do
  let(:driver) { Kitchen::Driver::Parallels.new({ kitchen_root: Dir.pwd }) }

  it "bootstraps keys by default for box archives and preserves existing PVM credentials" do
    _(Kitchen::Driver::Parallels.new(box: "bento.box")[:insert_key]).must_equal true
    _(Kitchen::Driver::Parallels.new(box: "custom.pvm")[:insert_key]).must_equal false
    _(Kitchen::Driver::Parallels.new(box: "bento.box", insert_key: false)[:insert_key]).must_equal false
  end

  it "uses transport credentials without bootstrapping and discards only generated state" do
    [{ ssh_key: "/explicit/key" }, { password: "fixture-password" }, {}].each do |transport|
      options = { box: "fixture.box" }
      options[:insert_key] = false if transport.empty?
      configured = Kitchen::Driver::Parallels.new(**options)
      instance = Struct.new(:transport).new(transport)
      generated = {
        hostname: "10.211.55.3", ssh_key: "/generated/key", username: "vagrant",
        parallels_generated_key: true, parallels_generated_user: true
      }
      existing = { ssh_key: "/previous/key", username: "custom" }
      original = existing.dup
      no_install = ->(*) { flunk("Unexpected SSH key bootstrap") }

      configured.stub(:instance, instance) do
        Kitchen::Box::SshBootstrap.stub(:install, no_install) do
          configured.send(:configure_ssh, generated)
          configured.send(:configure_ssh, existing)
        end
      end

      assert_equal({ hostname: "10.211.55.3" }, generated)
      assert_equal original, existing
    end
  end

  it "leaves SSH connection state untouched when key installation fails" do
    configured = Kitchen::Driver::Parallels.new(box: "fixture.box")
    instance = Struct.new(:transport).new({ username: "vagrant" })
    state = { hostname: "10.211.55.3" }
    original = state.dup
    failed_install = ->(*) { raise Kitchen::ActionFailed, "SSH bootstrap failed" }

    configured.stub(:instance, instance) do
      configured.stub(:import_directory, "/fixture") do
        Kitchen::Box::SshBootstrap.stub(:install, failed_install) do
          error = assert_raises(Kitchen::ActionFailed) { configured.send(:configure_ssh, state) }
          assert_equal "SSH bootstrap failed", error.message
        end
      end
    end

    assert_equal original, state
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
