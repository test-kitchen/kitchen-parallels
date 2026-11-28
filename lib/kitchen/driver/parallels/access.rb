# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

module Kitchen
  module Driver
    module ParallelsAccess
      DHCP_LEASES = "/Library/Preferences/Parallels/parallels_dhcp_leases".freeze

      private

      def winrm_loopback_host(volumes)
        host = instance.transport[:hostname] || "127.0.0.1"
        unless ["127.0.0.1", "::1"].include?(host)
          raise ActionFailed, "Parallels WinRM requires transport.hostname to be a loopback address (127.0.0.1 or ::1)"
        end
        unless volumes[:folders].empty?
          raise ActionFailed, "Parallels synced folders are unavailable with WinRM"
        end

        host
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
        path = Box::SshBootstrap.install(import_directory(state), runner: method(:command)) do |arguments|
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
