# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "open3"
require "socket"
require "kitchen/driver/parallels"

describe "Parallels boxes through the Kitchen CLI" do
  def box_archive(root, version)
    source = File.join(root, version)
    bundle = File.join(source, "fixture.pvm")
    archive = File.join(root, "#{version}.box")
    FileUtils.mkdir_p(bundle)
    File.write(File.join(source, "metadata.json"), '{"provider":"parallels"}')
    File.write(File.join(bundle, "config.pvs"), version)
    assert system("/usr/bin/tar", "-cf", archive, "-C", source, "metadata.json", "fixture.pvm")
    File.binread(archive)
  end

  def serve_boxes(routes)
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    thread = Thread.new do
      loop do
        client = server.accept
        begin
          path = client.gets.split.fetch(1)
          requests << path
          client.each_line { |line| break if line == "\r\n" }
          body = routes.fetch(path)
          client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
          client.write(body)
        ensure
          client.close
        end
      end
    end
    yield "http://127.0.0.1:#{server.addr.fetch(1)}", requests
  ensure
    thread&.kill
    thread&.join
    server&.close
  end

  def entry(location, version, archive, provider: "parallels", architecture: Kitchen::Box::Catalog.host_architecture)
    {
      name: "fixture/guest", version: version, provider: provider, architecture: architecture,
      **location, bytes: archive.bytesize, sha256: Digest::SHA256.hexdigest(archive)
    }
  end

  before do
    @root = Dir.mktmpdir("parallels-box-cli")
    @catalog = File.join(@root, "catalog")
    @manifest = File.join(@catalog, "boxes.json")
    @bin = File.join(@root, "bin")
    FileUtils.mkdir_p([@bin, @catalog])
    executable = File.join(@bin, "prlctl")
    File.write(executable, "#!#{RbConfig.ruby}\n" + <<~'RUBY')
      require "json"
      case ARGV.first
      when "list"
        puts File.exist?("vm.json") ? File.read("vm.json") : "[]"
      when "register"
        abort "fixture registration failed" if File.exist?("fail-register")

        File.open("imports", "a") { |log| log.puts File.read(File.join(ARGV.fetch(1), "config.pvs")) }
        vm = { uuid: ARGV.fetch(3), name: ARGV.fetch(5), status: "running", ip_configured: "10.0.0.2" }
        File.write("vm.json", JSON.generate([vm]))
      when "stop"
        # The next command deletes the VM.
      when "delete"
        File.delete("vm.json")
      else
        abort "unexpected prlctl command: #{ARGV.inspect}"
      end
    RUBY
    File.chmod(0o700, executable)
  end

  after do
    FileUtils.remove_entry(@root)
  end

  def configure(box)
    File.write(File.join(@root, "kitchen.yml"), YAML.dump(
      "driver" => {
        "name" => "parallels",
        "box" => box,
        "box_manifest" => "catalog/boxes.json",
        "box_cache" => File.join(@root, "cache"),
        "insert_key" => false,
      },
      "transport" => { "name" => "dummy" },
      "provisioner" => { "name" => "shell" },
      "platforms" => [{ "name" => "guest" }],
      "suites" => [{ "name" => "default" }]
    ))
  end

  def pin(version)
    configure("name" => "fixture/guest", "version" => version)
  end

  def kitchen(action, success: true)
    environment = {
      "PATH" => [@bin, ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
      "KITCHEN_GLOBAL_YAML" => File.join(@root, "unused.yml"),
      "KITCHEN_LOCAL_YAML" => File.join(@root, "unused.yml"),
      "KITCHEN_YAML" => File.join(@root, "kitchen.yml"),
    }
    output, status = Open3.capture2e(environment, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__),
      Gem.bin_path("test-kitchen", "kitchen"), action, chdir: @root)
    log = File.join(@root, ".kitchen", "logs", "default-guest.log")
    output += File.read(log) if !status.success? && File.file?(log)
    assert_equal success, status.success?, output
    output
  end

  def imports
    path = File.join(@root, "imports")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def state
    Kitchen::StateFile.new(@root, "default-guest")
  end

  describe "remote catalogs" do
    before do
      unless Kitchen::Box::Catalog.method_defined?(:copy_archive)
        skip "Remote catalogs require Test Kitchen with URL support (set TEST_KITCHEN_PATH to a compatible checkout)"
      end
    end

    it "selects the exact provider, architecture and version after a config reload" do
      first = box_archive(@root, "1")
      second = box_archive(@root, "2")
      serve_boxes("/1" => first, "/2" => second) do |base, requests|
        File.write(@manifest, JSON.generate([
          entry({ url: "#{base}/2" }, "1", second, provider: "virtualbox"),
          entry({ url: "#{base}/2" }, "1", second, architecture: "other"),
          entry({ url: "#{base}/2" }, "2", second),
          entry({ url: "#{base}/1" }, "1", first),
        ]))

        pin("1")
        kitchen("create")
        kitchen("destroy")
        assert_equal "/1", requests.pop(true)

        pin("2")
        kitchen("create")
        kitchen("destroy")
        assert_equal "/2", requests.pop(true)
        assert_equal %w{1 2}, imports
        assert_empty requests
      end
    end

    it "rejects a corrupt download before registering the box" do
      archive = box_archive(@root, "1")
      serve_boxes("/1" => "\0" * archive.bytesize) do |base, requests|
        File.write(@manifest, JSON.generate([entry({ url: "#{base}/1" }, "1", archive)]))
        pin("1")

        assert_match(/SHA-256/, kitchen("create", success: false))
        assert_equal "/1", requests.pop(true)
        assert_empty imports
        assert_empty Dir.glob("#{@root}/cache/*/{archive.box,download-*}")
        kitchen("destroy")
      end
    end

    it "reuses the persisted lease and cached archive after registration fails" do
      archive = box_archive(@root, "1")
      serve_boxes("/1" => archive) do |base, requests|
        record = entry({ url: "#{base}/1" }, "1", archive)
        File.write(@manifest, JSON.generate([record]))
        pin("1")
        failure = File.join(@root, "fail-register")
        FileUtils.touch(failure)

        assert_match(/fixture registration failed/, kitchen("create", success: false))
        assert_empty imports
        lease = state.read.fetch(:box_cache_lease)
        assert_equal record.fetch(:sha256), lease.fetch(:digest)
        lease_dir = File.join(@root, "cache", lease.fetch(:digest), "leases")
        assert_equal [lease.fetch(:token)], Dir.children(lease_dir)
        assert_equal "/1", requests.pop(true)

        File.delete(failure)
        kitchen("create")
        assert_equal lease, state.read.fetch(:box_cache_lease)
        assert_equal [lease.fetch(:token)], Dir.children(lease_dir)
        assert_equal ["1"], imports

        kitchen("destroy")
        refute_path_exists state.path
        assert_empty Dir.children(lease_dir)

        kitchen("create")
        kitchen("destroy")
        assert_equal %w{1 1}, imports
        assert_empty requests
        assert_empty Dir.children(lease_dir)
      end
    end
  end

  it "imports a relative local archive path without a catalog or lease" do
    box_archive(@root, "1")
    configure("1.box")

    kitchen("create")
    assert_equal ["1"], imports
    refute state.read.key?(:box_cache_lease)
    kitchen("destroy")
  end

  it "imports a relative file entry from a local catalog" do
    archive = box_archive(@catalog, "1")
    record = entry({ file: "1.box" }, "1", archive)
    File.write(@manifest, JSON.generate([record]))
    pin("1")

    kitchen("create")
    assert_equal ["1"], imports
    assert_equal record.fetch(:sha256), state.read.fetch(:box_cache_lease).fetch(:digest)
    kitchen("destroy")
  end
end
