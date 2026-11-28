# kitchen-parallels

Run Test Kitchen against disposable Linux VMs on Parallels Desktop. The driver uses
`prlctl` on the Mac and Kitchen's SSH transport to connect to the guest.

## Requirements

- Ruby 3.1 or newer and Test Kitchen 4.2 or newer.
- Parallels Desktop with full CLI access in the current macOS user session.
- A prepared Linux guest for the Mac's CPU architecture, with Parallels Tools,
  shared networking, SSH and an account suitable for your provisioner.
- Local disk space for each instance's VM files.

Run one instance at a time from a base image that shares its DHCP client ID
across copies. For concurrent instances, prepare the guest to obtain an address
using the NIC's MAC address or another unique DHCP client ID.

## Install from this checkout

Run `bundle install` in this checkout to install Test Kitchen and the
provisioners for the Apache smoke tests. Set `TEST_KITCHEN_PATH` to use a
compatible local Test Kitchen checkout. To run the unit suite and require the
linked clone and lifecycle lock tests to be available, use a hook-enabled
checkout and run:

```sh
TEST_KITCHEN_PATH=/path/to/test-kitchen bundle install
TEST_KITCHEN_PATH=/path/to/test-kitchen REQUIRE_INSTANCE_LIFECYCLE=1 bundle exec rake test
```

Run `bundle exec rake test` with the released-core bundle to check the
compatibility path.

To use this driver from another project, add `kitchen-parallels` to its
Gemfile. Bundler installs a compatible Test Kitchen version.

## Use a box from disk or a mounted NAS

```yaml
driver:
  name: parallels

provisioner:
  name: shell
  command: uname -m

platforms:
  - name: ubuntu-24.04
    driver:
      box: /Volumes/nfs/bentox_boxes/ubuntu-24.04-202510.26.0-parallels-arm64.box
  - name: debian-12
    driver:
      box: /Volumes/nfs/bentox_boxes/debian-12-202510.26.0-parallels-arm64.box

suites:
  - name: default
```

Kitchen uses its SSH transport by default on Linux. For a Bento `.box`, the
driver installs a fresh SSH key for the `vagrant` user through Parallels Tools,
removes the known Vagrant bootstrap keys from that guest and keeps the private
key with the instance until destroy. Set `transport.ssh_key` or
`transport.password` to use explicit credentials, or set `insert_key: false`
to use the transport configuration as written. Standalone `.pvm` bundles and
registered VMs use your configured credentials by default.

Use only trusted, self-contained images. A `.box`
must contain one top-level `.pvm` bundle and a `metadata.json` declaring
`"provider": "parallels"`. A standalone `.pvm` directory also works as the
`box` value. To use a new image, put it on disk or mount its share, point
`box` at it, then run `kitchen create`. Kitchen extracts or copies the image
into its local `.kitchen` directory and registers that copy in Parallels.

To use an already registered VM, set `source_vm` to its name or UUID in place
of `box`. Shut down the registered source first. By default, Parallels creates
a full clone and Kitchen boots the clone.

### Linked clones from a snapshot

Set `source_snapshot` to opt in to a linked clone. Use a stopped, registered
source VM with self-contained disks and an existing snapshot taken while
the guest was shut down. Run `prlctl snapshot-list <source_vm>` to find the
snapshot UUID. The host needs a Parallels Desktop edition that supports linked
clones.

```yaml
driver:
  name: parallels
  source_vm: ubuntu-base
  source_snapshot: "{7b485669-5347-4592-809c-a9274908bc18}"
```

Use SSH credentials that work in the snapshot. A linked clone depends on the
source VM bundle and snapshot for its lifetime. Keep both in place and leave
the clone bundle in its Kitchen instance directory. Run `kitchen destroy`
before switching between full and linked clones or choosing a different
snapshot. Kitchen removes the clone and its files and leaves the source VM
and snapshot intact.

Linked clones require Test Kitchen with the public
`Driver::Base#with_instance_lifecycle` hook, including when tearing down
previously saved linked state. Test Kitchen 4.2.1 supports full clones and
box imports in projects without saved linked state. Kitchen loads all instances
before filtering by name, so keep using the hook-enabled version for the whole
project until all linked clones have been destroyed.

With a hook-enabled core, the driver locks each instance across action
selection, lifecycle hooks, and state changes. Use the same hook-enabled
version for every Kitchen process sharing the workspace. Keep the
`.parallels.lock` sidecar in place. The driver rejects recursive transitions
on the same instance from the same thread. A lifecycle hook must never start
and wait for another Kitchen process or thread targeting its locked instance.

If the saved UUID is absent from Parallels, Kitchen can recover the clone by
its generated name after verifying that its bundle is inside the instance
directory. If Kitchen cannot verify a linked clone registration, stop all Kitchen
processes using the workspace. Back up the instance state YAML and inspect
`prlctl list --all --json` and `prlctl list <uuid> --info --json` against
the saved UUID, generated name and bundle under `.kitchen/parallels-<token>`.
If you can verify the linked clone, restore its generated name in Parallels
and retry `kitchen destroy`. If its directory holds only unregistered
files, move the directory aside after confirming that no Parallels VM uses
it, then retry destroy. If ownership is unclear, preserve the state and
files for investigation.

`source_snapshot` requires `source_vm`. To use a box, omit
`source_snapshot` and let Kitchen import it, or register a disposable copy
as the source and take its snapshot first. Parallels detaches external disks
when creating the linked clone. If the guest needs an external disk to boot
or run, prepare a self-contained source before taking the snapshot. If the
installed edition lacks linked clone support, omit `source_snapshot` to
make a full clone of the stopped VM.

```sh
bundle exec kitchen create
bundle exec kitchen converge
bundle exec kitchen destroy
```

The optional `driver.ip_timeout` sets how long the driver waits for a guest
IPv4 address, in seconds. It defaults to 180. The SSH readiness timeout is
configured separately with `transport.max_wait_until_ready`.
The driver checks the address reported by Parallels Tools first and uses
active Parallels DHCP leases for the VM's MAC address as a fallback.

## Shared folders and disks

Add the options under the global driver to share them across platforms, or
under a platform's driver to configure that guest.

```yaml
driver:
  name: parallels
  synced_folders:
    - ["data/%{instance_name}", "/mnt/fixtures", {create: true, readonly: true}]
  additional_disks:
    - name: scratch
      size_gb: 4
```

The driver mounts native Parallels shared folders at the requested guest paths.
The optional YAML map supports `type: parallels`, `create`, `disabled`,
`readonly` and `mount_options`. The extra disks are blank and are deleted with
the VM. Format and mount them in the provisioner if your tests need a filesystem.
Destroy and recreate the instance to apply volume changes.

## Rsync uploads

With `kitchen-sync` installed, set `transport.name: rsync`. It still uses
SSH and the key configured by the driver. The tested `kitchen-sync` 2.2.2.pre
requires `rsync` on both machines, an RSA identity in the host SSH agent and a
provisioner that opens SSH before uploading. With the shell provisioner, use
`script:` to run a script and `data_path:` to supply a directory to transfer.
Use the default SSH transport if you use the shell provisioner's single-command
mode. That mode can reach the upload step before opening a session.

## Using a shared box catalog

To select a named box, set `driver.box_manifest` or `KITCHEN_BOX_MANIFEST`,
then set each platform's `driver.box` to a map with `name` and an exact
`version`. The driver selects the provider and host architecture. Kitchen
copies the archive into its shared local cache and verifies it before import.
Subsequent imports reuse that copy. Set `KITCHEN_BOX_CACHE` or `driver.box_cache`
to choose a cache location. The driver keeps a lease until `kitchen destroy`
succeeds, so the prune preview protects archives used by active instances.

```sh
kitchen box list --manifest /Volumes/nfs/bentox_boxes/manifest.json --architecture arm64
kitchen box doctor --manifest /Volumes/nfs/bentox_boxes/manifest.json --name bento/ubuntu-24.04 --provider parallels --architecture arm64 --checksum
kitchen box prune --dry-run --provider parallels
```

Both commands accept `--json`. Doctor checks paths and sizes by default.
`--checksum` reads the contents of each selected archive. The commands work
outside a Kitchen project.

## Vagrant compatibility

The driver covers local boxes, Linux SSH bootstrap, native shared folders and
blank extra disks. These Vagrant features still need a separate implementation
or a different driver:

- Remote box lookup, downloads, automatic version checks and updates.
- Other hypervisors, Windows and WinRM, port forwarding, bridged and private
  network setup, and static IP configuration.
- Snapshot restore, VM packaging, Vagrantfile hooks, arbitrary
  provider customisation, Vagrant provisioning and guest environment settings.
- NFS, SMB and Vagrant rsync shared folders, host or guest tool management, and
  the Vagrant Chef cache options.

Kitchen tracks each disposable VM in its instance state. If `create` fails
after registration, retry it after fixing the cause or run `kitchen destroy`
to remove the failed instance and its local copy. Destroy the instance before
switching its source image or removing its `.kitchen` state.

## Apache smoke tests

Mount the NAS or set `KITCHEN_BOX_MANIFEST` to a manifest containing the
pinned Bento Ubuntu 24.04 box for your platform. Alternatively, set
`KITCHEN_PARALLELS_UBUNTU_BOX` to a local box archive. Install Cinc Workstation
with `cinc-cli` on `PATH` for the Cinc suite.

Run these commands from the driver checkout:

```sh
bundle install
bundle exec ruby examples/apache2/run.rb test cinc --destroy always
bundle exec ruby examples/apache2/run.rb test puppet --destroy always
bundle exec ruby examples/apache2/run.rb test ansible --destroy always
```

Each suite creates its own VM, provisions Apache, verifies the service is
enabled and returns HTTP 200, and destroys the VM. Cinc and Ansible also
check that a second apply makes no changes. Puppet and Ansible install their
runtimes from the Ubuntu package repositories before applying the examples.
