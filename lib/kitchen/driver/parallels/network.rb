# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "etc" unless defined?(Etc)

module Kitchen
  module Driver
    module ParallelsNetwork
      private

      def network_configuration
        mode, static_ip, forward = config.values_at(:network_mode, :static_ip, :port_forward)
        mode = "shared" if mode.nil? && !forward.nil?
        if !mode.nil? && !%w{shared host-only bridged}.include?(mode)
          raise ActionFailed, "driver.network_mode must be shared, host-only or bridged"
        end
        if mode == "bridged" && config[:insert_key]
          raise ActionFailed, "Bridged networking requires a guest with preconfigured SSH credentials"
        end
        if !static_ip.nil? && (!mode || !static_ip.is_a?(String) ||
            !static_ip.match?(%r{\A[0-9.]+/(?:[1-9]|[12][0-9]|3[0-2])\z}) ||
            !usable_ipv4?(static_ip.split("/").first))
          raise ActionFailed, "driver.static_ip requires an explicit network mode and an IPv4 address with a CIDR prefix"
        end

        unless forward.nil?
          raise ActionFailed, "driver.port_forward requires shared networking" unless mode == "shared"
          unless forward.is_a?(Hash) && forward.keys.sort_by(&:to_s) == %i{guest_port host_port} &&
              forward.values.all? { |port| port.is_a?(Integer) && (1..65535).cover?(port) }
            raise ActionFailed, "driver.port_forward requires integer host_port and guest_port values from 1 to 65535"
          end
        end

        { mode: mode, static_ip: static_ip, forward: forward }.compact
      end

      def configure_network(uuid, network)
        return unless network[:mode]

        prlctl("set", uuid, "--device-set", "net0", "--type", network.fetch(:mode))
        return unless network[:static_ip]

        prlctl("set", uuid, "--device-set", "net0", "--configure", "yes", "--dhcp", "no")
        prlctl("set", uuid, "--device-set", "net0", "--ipadd", network.fetch(:static_ip))
      end

      def configure_static_guest(uuid, cidr)
        guest_command(uuid, "/bin/sh", "-eu", "-c", <<~'SH', "kitchen-static-ip", cidr)
          cidr=$1
          # Explicit networking supports images with a single Ethernet adapter.
          nic=
          for device in /sys/class/net/*/device; do
            path=${device%/device}
            [ -d "$device" ] && [ "$(cat "$path/type")" = 1 ] || continue
            [ -z "$nic" ] || { echo "Static IPv4 requires one Ethernet adapter" >&2; exit 1; }
            nic=${path##*/}
          done
          [ -n "$nic" ] || { echo "No Ethernet adapter for static IPv4" >&2; exit 1; }

          # The Netplan definition ID can differ from the running interface name.
          if command -v netplan >/dev/null && command -v networkctl >/dev/null; then
            definition=$(LC_ALL=C networkctl status --no-pager "$nic" |
              sed -n 's|^ *Network File: /run/systemd/network/10-netplan-\(.*\)\.network$|\1|p')
            if [ -n "$definition" ]; then
              netplan set --origin-hint 99-kitchen-static "ethernets.$definition={dhcp4: false, addresses: [$cidr]}"
              netplan apply
            fi
          fi

          # Parallels can report its configured IP before the guest owns it.
          for attempt in 1 2 3 4 5 6 7 8 9 10; do
            addresses=$(ip -4 -o addr show dev "$nic" scope global)
            if echo "$addresses" | awk -v cidr="$cidr" '
              $4 == cidr { found = 1 }
              /[[:space:]]dynamic[[:space:]]/ { dynamic = 1 }
              END { exit !(found && !dynamic) }
            '; then
              exit 0
            fi
            sleep 1
          done
          echo "Guest adapter $nic did not acquire static IPv4 $cidr without DHCP" >&2
          exit 1
        SH
      end

      def install_port_forward(state)
        name, expected = port_forward_rule(state)
        with_shared_tcp_rules do |rules|
          raise ActionFailed, "Parallels Shared network is unavailable" unless rules
          return if rules[name] == expected

          host_port = expected.fetch("source port")
          if rules.key?(name) || rules.values.any? { |rule| rule["source port"] == host_port }
            raise ActionFailed, "The Parallels TCP forward name or host port is already in use"
          end

          state[:parallels_forward_attempted] = true
          checkpoint(state)
          arguments = [name, host_port, expected.fetch("destination IP/VM id"), expected.fetch("destination port")]
          command("prlsrvctl", "net", "set", "Shared", "--nat-tcp-add", arguments.join(","))
        end
      end

      def remove_port_forward(state)
        return unless state[:parallels_forward_attempted]

        name, expected = port_forward_rule(state)
        with_shared_tcp_rules do |rules|
          if rules && rules[name] == expected
            command("prlsrvctl", "net", "set", "Shared", "--nat-tcp-del", name)
          end
          state.delete(:parallels_forward_attempted)
          checkpoint(state)
        end
      end

      def with_shared_tcp_rules
        # Shared NAT is host-wide. Serialise Kitchen updates across this user's projects.
        path = File.join(Etc.getpwuid(Process.uid).dir, ".kitchen-parallels-nat.lock")
        File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
          raise ActionFailed, "Cannot lock the Parallels Shared network" unless lock.flock(File::LOCK_EX)

          yield shared_tcp_rules
        end
      rescue SystemCallError => e
        raise ActionFailed, "Cannot lock the Parallels Shared network: #{e.message}"
      end

      def port_forward_rule(state)
        forward = state.fetch(:parallels_network).fetch(:forward)
        ["kitchen-#{state.fetch(:parallels_token)}", {
          "source port" => forward.fetch(:host_port),
          "destination IP/VM id" => "{#{state.fetch(:parallels_uuid)}}",
          "destination port" => forward.fetch(:guest_port),
        }]
      end

      def shared_tcp_rules
        networks = read_json(command("prlsrvctl", "net", "list", "--json"), "prlsrvctl net list")
        valid = networks.is_a?(Array) && networks.all? do |network|
          network.is_a?(Hash) && network["Network ID"].is_a?(String) && network["Type"].is_a?(String)
        end
        unless valid
          raise ActionFailed, "Invalid network inventory from prlsrvctl net list"
        end

        shared = networks.find { |network| network["Network ID"] == "Shared" && network["Type"] == "shared" }
        return unless shared

        nat = shared.fetch("NAT server", {})
        rules = nat.fetch("TCP rules", {}) if nat.is_a?(Hash)
        unless rules.is_a?(Hash) && rules.values.all?(Hash)
          raise ActionFailed, "Invalid Shared TCP rules from prlsrvctl net list"
        end

        rules
      end
    end
  end
end
