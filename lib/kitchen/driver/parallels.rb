# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils" unless defined?(FileUtils)
require "ipaddr" unless defined?(IPAddr)
require "json" unless defined?(JSON)
require "kitchen"
require "kitchen/box/local_archive"
require "kitchen/box/source"
require "kitchen/box/ssh_bootstrap"
require "kitchen/state_file"
require "mixlib/shellout" unless defined?(Mixlib::ShellOut)
require "securerandom" unless defined?(SecureRandom)
require "shellwords" unless defined?(Shellwords)
require "tmpdir" unless defined?(Dir.mktmpdir)
require_relative "parallels/access"
require_relative "parallels/volumes"

module Kitchen
  module Driver
    # Creates disposable Linux VMs using the local Parallels Desktop CLI.
    class Parallels < Base
      kitchen_driver_api_version 2
      plugin_version "0.1.0"

      default_config :source_vm
      default_config :box
      default_config :box_manifest
      default_config :box_cache
      default_config :ip_timeout, 180
      default_config :insert_key do |driver|
        driver[:box].is_a?(Hash) || File.extname(driver[:box].to_s) == ".box"
      end
      default_config :synced_folders, []
      default_config :additional_disks, []

      UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i

      include ParallelsAccess
      include ParallelsVolumes
      include Box::Source

      def create(state)
        validate_config
        volumes = volume_configuration
        prepare_state(state)
        vm = find_vm(state) || create_vm(state)
        state[:parallels_uuid] = vm.fetch("uuid")
        checkpoint(state)
        start_vm(vm, volumes, imported: state[:parallels_import])
        state[:hostname] = wait_for_ip(state[:parallels_uuid])
        configure_ssh(state)
        instance.transport.connection(state).wait_until_ready
        mount_shared_folders(state[:parallels_uuid], volumes[:folders])
      end

      def destroy(state)
        return unless state[:parallels_token]

        vm = find_vm(state)
        if vm
          uuid = vm.fetch("uuid")
          status = vm.fetch("status")
          if status != "stopped"
            prlctl("stop", uuid, status == "suspended" ? "--drop-state" : "--kill")
          end
          prlctl("delete", uuid)
        end
        remove_instance_directory(state)
        release_box_source(state)
      end

      def restore_snapshot(snapshot_id)
        snapshot_id = snapshot_id.delete_prefix("{").delete_suffix("}")
        raise ActionFailed, "Supply a Parallels snapshot UUID" unless UUID.match?(snapshot_id)

        state_file = StateFile.new(config[:kitchen_root], instance.name)
        state = state_file.read
        uuid = state[:parallels_uuid]
        require_stopped_restore_vm(state)

        snapshots = snapshot_inventory(uuid)
        snapshot_key = snapshots.keys.find { |key| key.casecmp?("{#{snapshot_id}}") }
        raise ActionFailed, "Parallels snapshot #{snapshot_id} was not found for #{instance.name}" unless snapshot_key
        unless snapshots.fetch(snapshot_key)["state"] == "poweroff"
          raise ActionFailed, "Restore requires a powered-off snapshot and a shut down VM"
        end

        reset_restore_state(state_file, state) { switch_snapshot(state, snapshot_key) }
      rescue SystemCallError, IOError => e
        raise ActionFailed, "Could not complete restore for #{instance.name}: #{e.message}"
      end

      private

      def require_stopped_restore_vm(state)
        uuid = state[:parallels_uuid]
        token = state[:parallels_token]
        managed_name = managed_vm_name(token)
        vm = find_vm(state) if UUID.match?(uuid.to_s) && UUID.match?(token.to_s) && state[:parallels_name] == managed_name
        unless vm && vm["name"] == managed_name
          raise ActionFailed, "No managed Parallels VM found for #{instance.name}"
        end
        unless vm["status"] == "stopped"
          raise ActionFailed, "Restore requires a powered-off snapshot and a shut down VM"
        end
      end

      def snapshot_inventory(uuid)
        output = prlctl("snapshot-list", uuid, "--json")
        return {} if output.strip.empty?

        snapshots = read_json(output, "prlctl snapshot-list")
        unless snapshots.is_a?(Hash) && snapshots.all? { |key, entry| valid_snapshot_entry?(key, entry) } &&
            snapshots.values.count { |entry| entry["current"] } <= 1
          raise ActionFailed, "Invalid snapshot inventory from prlctl snapshot-list"
        end

        snapshots
      end

      def valid_snapshot_entry?(key, entry)
        key.start_with?("{") && key.end_with?("}") && UUID.match?(key[1...-1]) &&
          entry.is_a?(Hash) && entry["state"].is_a?(String) && !entry["state"].strip.empty? &&
          [true, false].include?(entry.fetch("current", false))
      end

      def reset_restore_state(state_file, state)
        Dir.mktmpdir("parallels-restore-", File.dirname(state_file.path)) do |directory|
          pending_state = StateFile.new(directory, instance.name)
          pending_state.write(state.except(:last_action, :hostname))
          File.chmod(File.stat(state_file.path).mode & 0o777, pending_state.path)
          unless state_file.read == state
            raise ActionFailed, "Kitchen state changed during restore for #{instance.name}"
          end

          require_stopped_restore_vm(state)
          # Publish the reset before the switch so an interrupted restore cannot leave a stale address or stage.
          File.rename(pending_state.path, state_file.path)
          yield
        end
      end

      def switch_snapshot(state, snapshot_key)
        uuid = state.fetch(:parallels_uuid)
        prlctl("snapshot-switch", uuid, "--id", snapshot_key, "--skip-resume")
        current_key = snapshot_inventory(uuid).find { |_, entry| entry["current"] }&.first
        unless current_key&.casecmp?(snapshot_key)
          raise ActionFailed, "Snapshot #{snapshot_key} is not current"
        end

        require_stopped_restore_vm(state)
      rescue ActionFailed => e
        raise ActionFailed, "Could not confirm snapshot restore for #{instance.name}: #{e.message}"
      end

      def managed_vm_name(token)
        "kitchen-#{instance.name}-#{token}"
      end

      def validate_config
        unless config[:source_vm].nil? ^ config[:box].nil?
          raise ActionFailed, "Set exactly one of driver.source_vm or driver.box"
        end

        timeout = config[:ip_timeout]
        unless (timeout.is_a?(Integer) || timeout.is_a?(Float)) && timeout.finite? && timeout > 0
          raise ActionFailed, "driver.ip_timeout must be a positive number of seconds"
        end
      end

      def prepare_state(state)
        importing = !config[:box].nil?
        if state[:parallels_token] && state[:parallels_import] != importing
          raise ActionFailed, "The Parallels source type changed. Run kitchen destroy before creating a new instance."
        end
        return if state[:parallels_token]

        state[:parallels_token] = SecureRandom.uuid
        # The name lets us recover if prlctl succeeds before the UUID is saved.
        state[:parallels_name] = managed_vm_name(state[:parallels_token])
        state[:parallels_import] = importing
        state[:parallels_uuid] = state[:parallels_token] if importing
        checkpoint(state)
      end

      def checkpoint(state)
        StateFile.new(config[:kitchen_root], instance.name).write(state)
      end

      def create_vm(state)
        if state[:parallels_import]
          import_box(state)
        else
          checkpoint(state) if state.delete(:parallels_uuid)
          clone_source(state)
        end
        find_vm(state) || raise(ActionFailed, "Parallels did not register #{state[:parallels_name]}")
      end

      def find_vm(state)
        vm_list.find do |vm|
          if state[:parallels_uuid]
            vm.fetch("uuid") == state[:parallels_uuid]
          else
            vm.fetch("name") == state[:parallels_name]
          end
        end
      end

      def clone_source(state)
        source = config[:source_vm]
        vm = vm_list.find { |entry| entry.fetch("uuid") == source || entry.fetch("name") == source }
        raise ActionFailed, "Parallels source VM #{source.inspect} was not found" unless vm
        unless vm.fetch("status") == "stopped"
          raise ActionFailed, "Shut down the Parallels source VM #{source.inspect} before cloning it"
        end

        prlctl("clone", vm.fetch("uuid"), "--name", state[:parallels_name])
      end

      def import_box(state)
        source = box_source("parallels", state) { checkpoint(state) }
        unless File.directory?(source) && File.extname(source) == ".pvm" ||
            File.file?(source) && File.extname(source) == ".box"
          raise ActionFailed, "driver.box must point to a local Parallels .pvm bundle or .box archive: #{source}"
        end

        remove_instance_directory(state)
        directory = import_directory(state)
        FileUtils.mkdir_p(directory, mode: 0o700)
        bundle = if File.directory?(source)
                   destination = File.join(directory, File.basename(source))
                   command("/usr/bin/ditto", source, destination)
                   destination
                 else
                   unpack_box(source, directory)
                 end
        unless File.file?(File.join(bundle, "config.pvs"))
          raise ActionFailed, "Parallels bundle is missing config.pvs: #{bundle}"
        end

        prlctl("register", bundle, "--uuid", state[:parallels_uuid], "--name", state[:parallels_name])
      end

      def unpack_box(source, directory)
        Box::LocalArchive.new(source, provider: "parallels").extract(directory) { |*arguments| command(*arguments) }
        bundles = Dir.glob("*.pvm", base: directory).map { |path| File.join(directory, path) }
        bundles.select! { |path| File.directory?(path) && !File.symlink?(path) }
        raise ActionFailed, "Expected one Parallels .pvm bundle in #{source}" unless bundles.one?

        bundles.first
      rescue Box::LocalArchive::InvalidBox => e
        raise ActionFailed, e.message
      end

      def import_directory(state)
        token = state.fetch(:parallels_token)
        unless /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.match?(token)
          raise ActionFailed, "Invalid Parallels instance ID in Kitchen state"
        end

        File.join(config[:kitchen_root], ".kitchen", "parallels-#{token}")
      end

      def remove_instance_directory(state)
        directory = import_directory(state)
        FileUtils.remove_entry_secure(directory) if File.exist?(directory)
      end

      def start_vm(vm, volumes, imported:)
        uuid = vm.fetch("uuid")
        return if vm.fetch("status") == "running"

        case vm.fetch("status")
        when "suspended", "paused"
          prlctl("resume", uuid)
        else
          prlctl("set", uuid, "--startup-view", "headless", "--shf-host", "off", "--smart-mount", "off")
          configure_hardware(uuid, volumes, imported: imported)
          prlctl("start", uuid)
        end
      end

      def wait_for_ip(uuid)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        deadline = start + config[:ip_timeout]
        lease_fallback_at = start + [10, config[:ip_timeout] / 2.0].min
        loop do
          vms = vm_list
          vm = vms.find { |entry| entry.fetch("uuid") == uuid }
          raise ActionFailed, "Parallels VM #{uuid} disappeared during boot" unless vm

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          address = reported_ips(vm).find { |value| usable_ipv4?(value) }
          address ||= leased_ipv4(vm) if now >= lease_fallback_at
          if address
            if vms.any? { |entry| entry != vm && entry["status"] == "running" && reported_ips(entry).include?(address) }
              raise ActionFailed, "Multiple running Parallels VMs report #{address}. Use a base image with a unique DHCP identity for each clone."
            end

            return address
          end

          remaining = deadline - now
          raise ActionFailed, "No guest IPv4 address for #{uuid}. Check shared networking and Parallels Tools." if remaining <= 0

          sleep([2, remaining].min)
        end
      end

      def reported_ips(vm)
        vm["ip_configured"].to_s.split(/[\s,]+/)
      end

      def usable_ipv4?(value)
        address = IPAddr.new(value)
        address.ipv4? && address.to_i > 0 && !address.loopback? && !address.link_local?
      rescue IPAddr::InvalidAddressError
        false
      end

      def vm_list
        read_json(prlctl("list", "--all", "--full", "--output", "uuid,status,ip_configured,mac,name", "--json"), "prlctl list")
      end

      def read_json(output, source)
        JSON.parse(output)
      rescue JSON::ParserError => e
        raise ActionFailed, "Invalid JSON from #{source}: #{e.message}"
      end

      def prlctl(*arguments)
        command("prlctl", *arguments)
      end

      def command(*arguments)
        debug("Running #{arguments.inspect}")
        process = Mixlib::ShellOut.new(*arguments, timeout: 600)
        process.run_command
        process.error!
        process.stdout
      rescue Mixlib::ShellOut::ShellCommandFailed, Mixlib::ShellOut::CommandTimeout, SystemCallError => e
        raise ActionFailed, e.message
      end
    end
  end
end
