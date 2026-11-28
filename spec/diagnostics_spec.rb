# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

describe "Kitchen Parallels diagnostics" do
  def with_project
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".kitchen"))
      File.write(File.join(root, "kitchen.yml"), <<~YAML)
        driver:
          name: parallels
          box: local.pvm
        provisioner:
          name: dummy
        platforms:
          - name: linux
        suites:
          - name: default
      YAML
      state = File.join(root, ".kitchen", "default-linux.yml")
      File.write(state, "---\nparallels_uuid: test-vm\nlast_action: create\n")
      provider = File.join(root, "prlctl")
      File.write(provider, <<~'RUBY')
        #!/usr/bin/env ruby
        File.open("provider-calls", "a") { |calls| calls.puts ARGV.join(" ") }
        abort "Parallels provider unavailable" unless ENV["PARALLELS_TEST_INVENTORY"]
        puts ENV.fetch("PARALLELS_TEST_INVENTORY")
      RUBY
      File.chmod(0o755, provider)
      yield root
    end
  end

  def kitchen(root, *args, inventory:)
    env = {
      "KITCHEN_YAML" => File.join(root, "kitchen.yml"),
      "PARALLELS_TEST_INVENTORY" => inventory,
      "PATH" => "#{root}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}",
    }
    Open3.capture3(env, Gem.bin_path("test-kitchen", "kitchen"), *args, chdir: root)
  end

  it "lists running, missing and unavailable VMs without changing instance state" do
    with_project do |root|
      state = File.join(root, ".kitchen", "default-linux.yml")
      original = File.binread(state)
      running = '[{"uuid":"test-vm","status":"running","name":"managed"}]'
      { running => ["running", true], "[]" => ["not_created", false], nil => ["unknown", nil] }.each do |inventory, expected|
        output, errors, process = kitchen(root, "list", "--live", "--json", inventory: inventory)
        _(process.success?).must_equal true, errors
        result = JSON.parse(output).fetch(0).fetch("status")
        _(result.values_at("state", "live")).must_equal expected
      end
      _(File.binread(state)).must_equal original
      _(File.readlines(File.join(root, "provider-calls"), chomp: true).map { |line| line.split.first }).must_equal %w{list list list}
    end
  end

  it "checks host access and the source with Kitchen doctor" do
    with_project do |root|
      Dir.mkdir(File.join(root, "local.pvm"))
      state = File.join(root, ".kitchen", "default-linux.yml")
      original = File.binread(state)
      inventory = { "uuid" => "test-vm", "status" => "running", "name" => "managed" }
      output, errors, process = kitchen(root, "doctor", inventory: [inventory].to_json)
      _(process.success?).must_equal true, output + errors

      Dir.rmdir(File.join(root, "local.pvm"))
      output, errors, process = kitchen(root, "doctor", inventory: nil)
      _(process.exitstatus).must_equal 1
      _(output + errors).must_match(/Parallels provider unavailable/)
      _(File.binread(state)).must_equal original
      _(output + errors).must_match(/readable local Parallels.*local\.pvm/)
      _(File.readlines(File.join(root, "provider-calls"), chomp: true).map { |line| line.split.first }).must_equal %w{list list}
    end
  end

  it "reports malformed VM inventory as an unavailable provider" do
    with_project do |root|
      Dir.mkdir(File.join(root, "local.pvm"))
      inventory = '[{"uuid":"test-vm","name":"managed","status":null}]'
      output, errors, process = kitchen(root, "list", "--live", "--json", inventory: inventory)
      _(process.success?).must_equal true, errors
      result = JSON.parse(output).fetch(0).fetch("status")
      _(result.values_at("state", "live")).must_equal ["unknown", nil]

      output, errors, process = kitchen(root, "doctor", inventory: inventory)
      _(process.exitstatus).must_equal 1
      _(output + errors).must_match(/Invalid VM inventory from prlctl/)
    end
  end

  it "reports a false box setting as an invalid source" do
    with_project do |root|
      config = File.join(root, "kitchen.yml")
      File.write(config, File.read(config).sub("box: local.pvm", "box: false"))

      output, errors, process = kitchen(root, "doctor", inventory: "[]")
      _(process.exitstatus).must_equal 1
      _(output + errors).must_match(/driver\.box must be a local path or a catalog selector/)
    end
  end
end
