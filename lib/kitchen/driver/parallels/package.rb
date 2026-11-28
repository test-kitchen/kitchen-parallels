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

        refuse_package_with_injected_key(state)

        output = File.join(config[:kitchen_root], "#{instance.name}.box")
        raise ActionFailed, "Package already exists: #{output}" if File.exist?(output) || File.symlink?(output)

        source = find_vm(state)
        unless source && source.fetch("name") == state[:parallels_name] && source.fetch("status") == "stopped"
          raise ActionFailed, "Shut down the managed Parallels VM before packaging it"
        end

        source_uuid = source.fetch("uuid")
        disks = package_disks(package_vm_info(source_uuid))
        stage = Dir.mktmpdir(".parallels-package-", File.dirname(output))
        name = "kitchen-package-#{SecureRandom.uuid}"
        bundle = File.join(stage, "#{name}.pvm")
        packaging_clone(source_uuid, name, stage, bundle, disks) { stage = nil }
        refuse_package_with_injected_key(state)
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

      def package_vm_info(uuid)
        details = package_vm_details(uuid)
        unless details["State"] == "stopped"
          raise ActionFailed, "Parallels VM #{uuid} must be stopped to package it"
        end

        details
      end

      def package_vm_details(uuid)
        read_json(prlctl("list", uuid, "--info", "--json"), "prlctl list --info").first ||
          raise(ActionFailed, "Parallels VM #{uuid} is no longer registered")
      end

      def package_disks(details)
        home = File.realpath(details.fetch("Home"))
        hardware = details.fetch("Hardware")
        if hardware.any? { |name, device| name.match?(/\Acdrom\d+\z/) && device["state"] == "connected" }
          raise ActionFailed, "Disconnect optical media before packaging the Parallels VM"
        end

        disks = hardware.select { |name, _| name.match?(/\Ahdd\d+\z/) }
        if disks.empty?
          raise ActionFailed, "Cannot package a Parallels VM without a virtual hard disk"
        end

        disks.each_value do |disk|
          image = disk["image"]
          unless image && File.directory?(image) && File.realpath(image).start_with?("#{home}/")
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

        (details.fetch("Host Shared Folders", {}).keys - ["enabled"]).each do |share|
          prlctl("set", clone_uuid, "--shf-host-del", share)
        end
      ensure
        begin
          clone_uuid ||= package_clone_uuid(source_uuid, name, bundle)
          prlctl("unregister", clone_uuid) if clone_uuid
        rescue ActionFailed, SystemCallError => e
          yield
          raise ActionFailed, "Could not clean up the Parallels package clone #{name}. " \
            "Staging retained at #{stage}: #{e.message}"
        end
      end

      def package_clone_uuid(source_uuid, name, bundle)
        entry = vm_list.find { |vm| vm["name"] == name }
        return unless entry

        uuid = entry.fetch("uuid")
        if uuid == source_uuid || File.symlink?(bundle) ||
            File.realpath(package_vm_details(uuid).fetch("Home")) != File.realpath(bundle)
          raise ActionFailed, "Could not confirm ownership of the Parallels package clone #{name}"
        end

        uuid
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
