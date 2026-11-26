# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "digest" unless defined?(Digest)

module Kitchen
  module Driver
    module ParallelsVolumes
      MOUNT_SHARE = <<~'SH'.freeze
        set -eu
        mountpoint -q "$2" && exit 0
        mkdir -p -- "$2"
        if [ -x /usr/bin/prl_fsd ]; then
          /usr/bin/prl_fsd "$2" -o "allow_other,big_writes,fsname=$1,subtype=prl_fsd$3" "--sf=$1"
        else
          mount -t prl_fs -o "defaults$3" "$1" "$2"
        fi
      SH

      private

      def volume_configuration
        folders = config[:synced_folders].filter_map { |entry| shared_folder(entry) }
        disks = config[:additional_disks].map { |entry| additional_disk(entry) }
        unless folders.map { |folder| folder[:target] }.uniq.size == folders.size &&
            disks.map { |disk| disk[:name] }.uniq.size == disks.size
          raise ActionFailed, "Use unique synced folder destinations and additional disk names"
        end

        { folders: folders, disks: disks }
      end

      def shared_folder(entry)
        unless entry.is_a?(Array) && (2..3).cover?(entry.size) && entry.first(2).all?(String)
          raise ActionFailed, "Each synced_folders entry needs a host path, a guest path, and optional YAML options"
        end

        source, target, options = entry
        options ||= {}
        unless options.is_a?(Hash) && (options.keys - %i{type create disabled readonly mount_options}).empty? &&
            [nil, "parallels", :parallels].include?(options[:type])
          raise ActionFailed, "Synced folders use Parallels shares. Use YAML options such as {create: true, readonly: true}"
        end
        return if options[:disabled]

        target = File.expand_path(target, "/") if target.start_with?("/")
        unless target.start_with?("/") && target != "/"
          raise ActionFailed, "Synced folder guest paths must be absolute paths other than /"
        end

        source = File.expand_path(source.gsub("%{instance_name}", instance.name), config[:kitchen_root])
        mount_options = options.fetch(:mount_options, [])
        unless mount_options.is_a?(Array) && mount_options.all? { |option| option.is_a?(String) && !option.match?(/\A[fd]mode/) }
          raise ActionFailed, "Synced folder mount_options must be a list of Parallels mount options"
        end

        {
          name: "kitchen-#{Digest::SHA256.hexdigest(target)[0, 16]}",
          source: source,
          target: target,
          create: options[:create],
          readonly: options[:readonly],
          mount_options: mount_options.reject { |option| option == "_netdev" },
        }
      end

      def additional_disk(entry)
        unless entry.is_a?(Hash) && entry[:name].is_a?(String) && /\A[a-zA-Z0-9_-]+\z/.match?(entry[:name]) &&
            entry[:size_gb].is_a?(Integer) && entry[:size_gb] > 0
          raise ActionFailed, "Each additional_disks entry needs a simple name and a positive integer size_gb"
        end

        entry
      end

      def configure_hardware(uuid, volumes, imported:)
        return if !imported && volumes[:folders].empty? && volumes[:disks].empty?

        info = read_json(prlctl("list", uuid, "--info", "--json"), "prlctl list --info").first
        refresh_shared_macs(uuid, info.fetch("Hardware", {})) if imported
        add_shared_folders(uuid, volumes[:folders], info)
        add_disks(uuid, volumes[:disks], info)
      end

      def refresh_shared_macs(uuid, hardware)
        hardware.each do |name, device|
          next unless /\Anet\d+\z/.match?(name) && device["type"] == "shared"

          prlctl("set", uuid, "--device-set", name, "--mac", "auto")
        end
      end

      def add_shared_folders(uuid, folders, info)
        return if folders.empty?

        prlctl("set", uuid, "--shf-host", "on", "--shf-host-defined", "off", "--shf-host-automount", "off")
        shares = info.fetch("Host Shared Folders", {})
        (shares.keys - ["enabled"] - folders.map { |folder| folder[:name] }).each do |name|
          prlctl("set", uuid, "--shf-host-del", name)
        end
        folders.each do |folder|
          FileUtils.mkdir_p(folder[:source]) if folder[:create]
          raise ActionFailed, "Synced folder not found: #{folder[:source]}" unless File.directory?(folder[:source])

          action = shares.key?(folder[:name]) ? "--shf-host-set" : "--shf-host-add"
          prlctl("set", uuid, action, folder[:name], "--path", folder[:source], "--mode", folder[:readonly] ? "ro" : "rw")
        end
      end

      def add_disks(uuid, disks, info)
        images = info.fetch("Hardware", {}).values.filter_map { |device| device["image"] }
        disks.each do |disk|
          path = File.join(info.fetch("Home"), "kitchen-#{disk[:name]}.hdd")
          next if images.include?(path)

          prlctl("set", uuid, "--device-add", "hdd", "--image", path, "--size", (disk[:size_gb] * 1024).to_s, "--type", "expand")
        end
      end

      def mount_shared_folders(uuid, folders)
        folders.each do |folder|
          options = folder[:mount_options].dup
          options << "ro" if folder[:readonly]
          options = options.map { |option| ",#{option}" }.join
          guest_command(uuid, "/bin/sh", "-c", MOUNT_SHARE, "kitchen-mount", folder[:name], folder[:target], options)
        end
      end
    end
  end
end
