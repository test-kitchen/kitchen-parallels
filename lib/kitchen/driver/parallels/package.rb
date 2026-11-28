# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "find" unless defined?(Find)
require "rexml/document" unless defined?(REXML::Document)

module Kitchen
  module Driver
    module ParallelsPackage
      def package(state)
        unless state[:parallels_token] && state[:parallels_uuid]
          raise ActionFailed, "Create the Kitchen instance before packaging it"
        end

        verify_package_source(state)

        output = File.join(config[:kitchen_root], "#{instance.name}.box")
        raise ActionFailed, "Package already exists: #{output}" if File.exist?(output) || File.symlink?(output)

        source = package_vm_list.find { |vm| vm["uuid"] == state[:parallels_uuid] }
        unless source && source["name"] == state[:parallels_name] && source["status"] == "stopped"
          raise ActionFailed, "Shut down the managed Parallels VM before packaging it"
        end

        source_uuid = source.fetch("uuid")
        details = package_vm_info(source_uuid)
        unless File.dirname(File.realpath(details.fetch("Home"))) == File.realpath(instance_directory(state))
          raise ActionFailed, "Could not confirm the Parallels VM belongs to the verified archive import"
        end

        disks = package_disks(details)
        stage = Dir.mktmpdir(".parallels-package-", File.dirname(output))
        name = "kitchen-package-#{SecureRandom.uuid}"
        bundle = File.join(stage, "#{name}.pvm")
        packaging_clone(source_uuid, name, stage, bundle, disks) { stage = nil }
        verify_package_source(state)
        validate_package_bundle(bundle)
        backup = File.join(bundle, "config.pvs.backup")
        File.unlink(backup) if File.file?(backup)
        File.write(File.join(stage, "metadata.json"), JSON.generate(provider: "parallels"))
        archive = File.join(stage, "package.box")
        command("/usr/bin/tar", "-cf", archive, "-C", stage, "metadata.json", File.basename(bundle))
        File.chmod(0o600, archive)
        File.link(archive, output)
        info("Packaged #{instance.name} to #{output}")
        output
      rescue Errno::EEXIST
        raise ActionFailed, "Package already exists: #{output}"
      rescue SystemCallError => e
        raise ActionFailed, "Could not package the Parallels VM: #{e.message}"
      ensure
        FileUtils.remove_entry_secure(stage) if stage
      end

      private

      def verify_package_source(state)
        persisted = refuse_package_with_injected_key(state)
        digest = state[:parallels_package_source_sha256]
        provenance_keys = %i{parallels_token parallels_uuid parallels_name parallels_import parallels_package_source_sha256}
        if digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) && state[:parallels_import] == true &&
            persisted.values_at(*provenance_keys) == state.values_at(*provenance_keys)
          return
        end

        raise ActionFailed, "Cannot establish Parallels package source provenance. " \
          "Create a fresh instance from a reviewed .box archive with driver.package_source_sha256."
      end

      def package_vm_info(uuid)
        details = package_vm_details(uuid)
        unless details["State"] == "stopped"
          raise ActionFailed, "Parallels VM #{uuid} must be stopped to package it"
        end

        details
      end

      def package_vm_details(uuid)
        entries = read_json(prlctl("list", uuid, "--info", "--json"), "prlctl list --info")
        if entries.is_a?(Array) && entries.one? && entries.first.is_a?(Hash)
          details = entries.first
          home = details["Home"]
          return details if details["ID"] == uuid && home.is_a?(String) && home.start_with?("/") && !home.include?("\0")
        end

        raise ActionFailed, "Invalid Parallels VM details for #{uuid}"
      end

      def package_disks(details)
        home = File.realpath(details.fetch("Home"))
        hardware = details["Hardware"]
        unless hardware.is_a?(Hash) && hardware.values.all?(Hash)
          raise ActionFailed, "Invalid Parallels hardware metadata"
        end

        if hardware.any? { |name, device| name.match?(/\Acdrom\d+\z/) && (device["state"] != "disconnected" || device["image"] != "") }
          raise ActionFailed, "Remove optical media from the Parallels VM before packaging"
        end

        unless details["External boot device"] == "" && details["Restore Image"] == "" &&
            hardware.keys.all? { |name| name.match?(/\A(?:cpu|memory|video|memory_quota|usb|(?:hdd|cdrom|net|sound)\d+)\z/) }
          raise ActionFailed, "Cannot verify portable Parallels hardware and boot devices"
        end

        disks = hardware.select { |name, _| name.match?(/\Ahdd\d+\z/) }
        if disks.empty?
          raise ActionFailed, "Cannot package a Parallels VM without a virtual hard disk"
        end

        disks.each_value do |disk|
          image = disk["image"]
          unless image.is_a?(String) && !image.include?("\0") && File.directory?(image) && File.realpath(image).start_with?("#{home}/")
            raise ActionFailed, "Cannot package a missing or external Parallels virtual hard disk"
          end

          validate_disk_extents(image)
        end
        disks.keys.sort
      end

      def validate_disk_extents(image)
        descriptor = File.join(image, "DiskDescriptor.xml")
        unless File.file?(descriptor) && !File.symlink?(descriptor)
          raise ActionFailed, "Cannot package a Parallels virtual hard disk without its descriptor"
        end

        document = REXML::Document.new(File.read(descriptor))
        extents = document.elements.to_a("Parallels_disk_image/StorageData/Storage/Image")
        return if !extents.empty? && extents.all? { |extent| local_disk_extent?(image, extent.elements["File"]&.text) }

        raise ActionFailed, "Cannot package a Parallels virtual hard disk with missing or external extents"
      rescue REXML::ParseException
        raise ActionFailed, "Cannot read the Parallels virtual hard disk descriptor"
      end

      def local_disk_extent?(image, extent)
        return false unless extent && !extent.include?("\0") && File.basename(extent) == extent && extent.end_with?(".hds")

        path = File.join(image, extent)
        File.file?(path) && !File.symlink?(path) && File.size?(path)
      end

      def packaging_clone(source_uuid, name, stage, bundle, disks)
        prlctl("clone", source_uuid, "--name", name, "--dst", stage)
        clone_uuid = package_clone_uuid(source_uuid, name, bundle)
        raise ActionFailed, "Parallels did not register the package clone" unless clone_uuid

        details = package_vm_info(clone_uuid)
        unless package_disks(details) == disks
          raise ActionFailed, "The Parallels package clone is missing virtual hard disks"
        end

        scrub_package_sharing(clone_uuid, details)
      ensure
        begin
          clone_uuid ||= package_clone_uuid(source_uuid, name, bundle)
          if clone_uuid
            prlctl("unregister", clone_uuid)
            if package_vm_list.any? { |vm| vm["uuid"].casecmp?(clone_uuid) || vm["name"] == name }
              raise ActionFailed, "The package clone is still registered"
            end
          end
        rescue ActionFailed, SystemCallError, ArgumentError => e
          yield
          raise ActionFailed, "Could not clean up the Parallels package clone #{name}. " \
            "Staging retained at #{stage}: #{e.message}"
        end
      end

      def scrub_package_sharing(uuid, details)
        shares = details["Host Shared Folders"]
        raise ActionFailed, "Invalid Parallels host share metadata" unless shares.is_a?(Hash)

        (shares.keys - ["enabled"]).each { |share| prlctl("set", uuid, "--shf-host-del", share) }
        prlctl("set", uuid, "--shf-host", "off", "--shf-host-defined", "off", "--shf-host-automount", "off",
          "--shared-profile", "off", "--smart-mount", "off", "--shared-cloud", "off", "--sync-ssh-ids", "off")

        settings = package_vm_details(uuid)
        unless settings["Host Shared Folders"] == { "enabled" => false } &&
            settings["Host defined sharing"] == "Off" &&
            ["Shared Profile", "SmartMount"].all? { |key| settings[key].is_a?(Hash) && settings[key]["enabled"] == false } &&
            settings.dig("Miscellaneous Sharing", "Shared cloud") == "off" &&
            settings.dig("Advanced", "Public SSH keys synchronization") == "off"
          raise ActionFailed, "Could not verify that Parallels host sharing was disabled"
        end
      rescue TypeError
        raise ActionFailed, "Invalid Parallels host share metadata"
      end

      def package_vm_list
        entries = vm_list
        unless entries.is_a?(Array) && entries.all? { |entry| valid_package_vm_entry?(entry) } &&
            entries.map { |entry| entry["uuid"].downcase }.uniq.size == entries.size
          raise ActionFailed, "Invalid Parallels VM inventory"
        end

        entries
      end

      def valid_package_vm_entry?(entry)
        entry.is_a?(Hash) && entry["uuid"].is_a?(String) &&
          entry["uuid"].match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i) &&
          entry["name"].is_a?(String) && !entry["name"].empty?
      end

      def package_clone_uuid(source_uuid, name, bundle)
        entries = package_vm_list.select { |vm| vm["name"] == name }
        return if entries.empty? && Dir.empty?(File.dirname(bundle))

        if entries.one?
          uuid = entries.first.fetch("uuid")
          unless uuid.casecmp?(source_uuid) || File.symlink?(bundle)
            home = package_vm_details(uuid).fetch("Home")
            return uuid if File.realpath(home) == File.realpath(bundle)
          end
        end

        raise ActionFailed, "Could not confirm ownership of the Parallels package clone #{name}"
      end

      def validate_package_bundle(bundle)
        config_path = File.join(bundle, "config.pvs")
        unless File.directory?(bundle) && File.file?(config_path) && File.size?(config_path)
          raise ActionFailed, "Parallels package clone is missing config.pvs"
        end

        Find.find(bundle) do |path|
          entry = File.lstat(path)
          unless entry.directory? || entry.file?
            raise ActionFailed, "Unsafe file in Parallels package clone: #{path}"
          end
        end
      end
    end
  end
end
