# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

module Kitchen
  module Driver
    module ParallelsAccess
      DHCP_LEASES = "/Library/Preferences/Parallels/parallels_dhcp_leases".freeze

      private

      def refuse_package_with_injected_key(state)
        key = File.join(instance_directory(state), "ssh_key")
        persisted = StateFile.new(config[:kitchen_root], instance.name).read
        evidence = [state, persisted].any? { |record| record[:parallels_generated_key] || record[:parallels_key_injected] }
        if evidence || File.exist?(key) || File.symlink?(key)
          raise ActionFailed, "Cannot safely remove the Kitchen-injected SSH key from a stopped VM. " \
            "Create a fresh instance with driver.insert_key disabled and supply your own SSH credentials."
        end

        if [state, persisted].all? { |record| record[:parallels_key_injected] == false }
          return persisted
        end

        raise ActionFailed, "Cannot establish the SSH injection history of this Parallels instance. " \
          "Create a fresh instance with driver.insert_key disabled and supply your own SSH credentials."
      end

      def configure_ssh(state)
        transport = instance.transport
        if !config[:insert_key] || transport[:ssh_key] || transport[:password]
          state.delete(:ssh_key) if state.delete(:parallels_generated_key)
          state.delete(:username) if state.delete(:parallels_generated_user)
          return
        end

        user = transport[:username]
        user = "vagrant" if user == "root" || user.nil?
        unless state[:parallels_key_injected]
          state[:parallels_key_injected] = true
          checkpoint(state)
        end
        path = Box::SshBootstrap.install(instance_directory(state), runner: method(:command)) do |arguments|
          guest_command(state.fetch(:parallels_uuid), "runuser", "-u", user, "--", "/bin/sh", *arguments)
        end
        state[:ssh_key] = path
        state[:username] = user
        state[:parallels_generated_key] = true
        state[:parallels_generated_user] = true
      end

      def leased_ipv4(vm)
        macs = vm.fetch("mac", "").downcase.delete(":-").split
        return if macs.empty? || vm["status"] != "running"

        File.foreach(DHCP_LEASES).filter_map do |line|
          lease = /\A\s*([\d.]+)="(\d+),(\d+),([0-9a-f]+),[^"]*"/i.match(line)
          next unless lease

          address, expiry, duration, mac = lease.captures
          next unless macs.include?(mac.downcase) && expiry.to_i > Time.now.to_i && usable_ipv4?(address)

          [expiry.to_i - duration.to_i, address]
        end.max&.last
      rescue Errno::EACCES, Errno::ENOENT, Errno::EPERM
        nil
      end

      def guest_command(uuid, *arguments)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        begin
          prlctl("exec", uuid, Shellwords.join(arguments))
        rescue ActionFailed => e
          raise unless e.message.include?("Unable to open new session in this virtual machine") &&
            Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

          sleep 2
          retry
        end
      end
    end
  end
end
