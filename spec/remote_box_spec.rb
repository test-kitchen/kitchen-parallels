# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "socket"
require "kitchen/driver/parallels"

describe "Parallels remote boxes" do
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

  def entry(base, version, archive, provider: "parallels", architecture: Kitchen::Box::Catalog.host_architecture)
    {
      name: "fixture/guest", version: version, provider: provider, architecture: architecture,
      url: "#{base}/#{version}", bytes: archive.bytesize, sha256: Digest::SHA256.hexdigest(archive)
    }
  end

  it "verifies a pinned provider and architecture before import, reuses its cache, and switches versions explicitly" do
    unless Kitchen::Box::Catalog.method_defined?(:copy_archive)
      skip "Remote catalogs require Test Kitchen with URL support (set TEST_KITCHEN_PATH to a compatible checkout)"
    end

    Dir.mktmpdir do |root|
      first = box_archive(root, "1")
      second = box_archive(root, "2")
      routes = { "/1" => "\0" * first.bytesize, "/2" => second }
      serve_boxes(routes) do |base, requests|
        catalog = File.join(root, "catalog")
        cache = File.join(root, "cache")
        FileUtils.mkdir(catalog)
        manifest = File.join(catalog, "boxes.json")
        File.write(manifest, JSON.generate([
          entry(base, "1", second, provider: "virtualbox"),
          entry(base, "1", second, architecture: "other"),
          entry(base, "2", second),
          entry(base, "1", first),
        ]))
        connection = Minitest::Mock.new
        transport = Struct.new(:session) do
          def connection(_state)
            session
          end
        end.new(connection)
        instance = Struct.new(:name, :transport, :platform, :logger).new("remote", transport, nil, Kitchen.logger)
        build_driver = lambda do |version|
          Kitchen::Driver::Parallels.new(
            kitchen_root: root, box_manifest: manifest, box_cache: cache,
            box: { name: "fixture/guest", version: version }, insert_key: false
          ).finalize_config!(instance)
        end
        3.times { connection.expect(:wait_until_ready, nil) }

        vm = nil
        imported = []
        commands = lambda do |*args|
          case args.take(2)
          when %w{prlctl list}
            JSON.generate([vm].compact)
          when %w{prlctl register}
            imported << File.read(File.join(args.fetch(2), "config.pvs"))
            vm = { "uuid" => args.fetch(4), "status" => "running", "ip_configured" => "10.0.0.2" }
          when %w{prlctl stop}
            vm["status"] = "stopped"
          when %w{prlctl delete}
            vm = nil
          else
            assert system(*args)
          end
        end

        driver = build_driver.call("1")
        driver.stub(:command, commands) do
          state = {}
          error = assert_raises(Kitchen::ActionFailed) { driver.create(state) }
          assert_match(/SHA-256/, error.message)
          assert_empty imported
          assert_empty Dir.glob("#{cache}/*/{archive.box,download-*}")
          assert_equal "/1", requests.pop(true)

          routes["/1"] = first
          driver.create(state)
          driver.destroy(state)
          assert_equal "/1", requests.pop(true)
          refute state.key?(:box_cache_lease)

          routes.delete("/1")
          state = {}
          driver.create(state)
          driver.destroy(state)
          assert_empty requests
        end

        driver = build_driver.call("2")
        driver.stub(:command, commands) do
          state = {}
          driver.create(state)
          driver.destroy(state)
          assert_equal "/2", requests.pop(true)
          assert_equal %w{1 1 2}, imported
          assert_empty Dir.glob("#{cache}/*/download-*")
        end
        connection.verify
      end
    end
  end
end
