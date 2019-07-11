#!/usr/bin/env python
# 0.0.0
from Scripts import *
import os, tempfile, datetime, shutil, time, plistlib, json, sys

class CloverExtractor:
    def __init__(self, **kwargs):
        self.script_folder = "Scripts"
        self.r  = run.Run()
        self.d  = disk.Disk()
        self.dl = downloader.Downloader()
        self.re = reveal.Reveal()
        # Keep our source local
        self.c_source = os.path.join(os.path.dirname(os.path.realpath(__file__)), self.script_folder, "src")
        # Make sure the src folder exists
        if not os.path.exists(self.c_source):
            os.mkdir(self.c_source)
        self.c  = cloverbuild.CloverBuild(source=self.c_source)
        self.clover_url = "https://api.github.com/repos/dids/clover-builder/releases/latest"
        self.clover_repo = "https://svn.code.sf.net/p/cloverefiboot/code"
        self.u  = utils.Utils("CloverExtractor")
        self.clover = None
        self.efi    = None
        self.clover_sources = ["udk2018"]
        self.tool_sources   = ["opt","tools"]
        # Get the tools we need
        self.settings_file = os.path.join("Scripts", "settings.json")
        self.full = False
        cwd = os.getcwd()
        os.chdir(os.path.dirname(os.path.realpath(__file__)))
        if self.settings_file and os.path.exists(self.settings_file):
            self.settings = json.load(open(self.settings_file))
        else:
            self.settings = {
                # Default settings here
                "select_efi_drivers" : True,
                "debug" : False
            }
        self.c.debug = self.settings.get("debug",False)
        os.chdir(cwd)

    def flush_settings(self):
        if self.settings_file:
            cwd = os.getcwd()
            os.chdir(os.path.dirname(os.path.realpath(__file__)))
            json.dump(self.settings, open(self.settings_file, "w"))
            os.chdir(cwd)

    def get_version_from_bdmesg(self):
        # Get bdmesg output - then parse for SelfDevicePath
        bd = bdmesg.bdmesg()
        if not "Starting Clover revision: " in bd:
            # Not found
            return None
        try:
            # Split to just the contents of that line
            rev = bd.split("Starting Clover revision: ")[1].split("on")[0]
            return rev
        except:
            pass
        return None

    def get_efi(self):
        self.d.update()
        clover = bdmesg.get_clover_uuid()
        i = 0
        disk_string = ""
        if not self.full:
            clover_disk = self.d.get_parent(clover)
            mounts = self.d.get_mounted_volume_dicts()
            for d in mounts:
                i += 1
                disk_string += "{}. {} ({})".format(i, d["name"], d["identifier"])
                if self.d.get_parent(d["identifier"]) == clover_disk:
                # if d["disk_uuid"] == clover:
                    disk_string += " *"
                disk_string += "\n"
        else:
            mounts = self.d.get_disks_and_partitions_dict()
            disks = mounts.keys()
            for d in disks:
                i += 1
                disk_string+= "{}. {}:\n".format(i, d)
                parts = mounts[d]["partitions"]
                part_list = []
                for p in parts:
                    p_text = "        - {} ({})".format(p["name"], p["identifier"])
                    if p["disk_uuid"] == clover:
                        # Got Clover
                        p_text += " *"
                    part_list.append(p_text)
                if len(part_list):
                    disk_string += "\n".join(part_list) + "\n"
        height = len(disk_string.split("\n"))+13
        if height < 24:
            height = 24
        self.u.resize(80, height)
        self.u.head()
        print(" ")
        print(disk_string)
        if not self.full:
            print("S. Switch to Full Output")
        else:
            print("S. Switch to Slim Output")
        print("B. Select the Boot Drive's EFI")
        if clover:
            print("C. Select the Booted Clover's EFI")
        print("")
        print("M. Main")
        print("Q. Quit")
        print(" ")
        print("(* denotes the booted Clover)")

        menu = self.u.grab("Pick the drive containing your EFI:  ")
        if not len(menu):
            return self.get_efi()
        if menu.lower() == "q":
            self.u.custom_quit()
        elif menu.lower() == "m":
            return None
        elif menu.lower() == "s":
            self.full ^= True
            return self.get_efi()
        elif menu.lower() == "b":
            return self.d.get_efi("/")
        elif menu.lower() == "c" and clover:
            return self.d.get_efi(clover)
        try:
            disk_iden = int(menu)
            if not (disk_iden > 0 and disk_iden <= len(mounts)):
                # out of range!
                self.u.grab("Invalid disk!", timeout=3)
                return self.get_efi()
            if type(mounts) is list:
                # We have the small list
                disk = mounts[disk_iden-1]["identifier"]
            else:
                # We have the dict
                disk = mounts.keys()[disk_iden-1]
        except:
            disk = menu
        iden = self.d.get_identifier(disk)
        name = self.d.get_volume_name(disk)
        if not iden:
            self.u.grab("Invalid disk!", timeout=3)
            return self.get_efi()
        # Valid disk!
        return self.d.get_efi(iden)

    def qprint(self, message, quiet):
        if not quiet:
            print(message)

    def mount_and_copy(self, disk, package, archive = False, quiet = False):
        # Mounts the passed disk and extracts the package target to the destination
        self.d.update()
        if not quiet:
            self.u.head("Extracting {} to {}...".format(os.path.basename(package), disk))
            print("")
        if self.d.is_mounted(disk):
            mounted = True
        else:
            mounted = False
        # Mount the EFI if needed
        if not mounted:
            self.qprint("Mounting {}...".format(disk), quiet)
            out = self.d.mount_partition(disk)
            if not out[2] == 0:
                print(out[1])
                return False
            self.qprint(out[0].strip("\n"), quiet)
            print(" ")
        # Create a temp folder
        temp = tempfile.mkdtemp()
        results = self.extract_clover(package, temp)
        efi_drivers,binaries = results
        clover = next((efi_drivers[x]["path"] for x in efi_drivers if os.path.basename(x.lower()) == "cloverx64.efi"), None)
        print(" ")
        if not clover:
            print("Error locating CLOVERX64.efi in {}!".format(os.path.basename(package)))
            self.cleanup(temp, disk, mounted, quiet)
            return False
        efi_mount = self.d.get_mount_point(disk)
        if not efi_mount:
            print("EFI at {} not mounted!".format(disk))
            self.cleanup(temp, disk, mounted, quiet)
            return False

        # Copy Clover
        try:
            c_out = self.copy_clover(clover, efi_mount, archive, quiet)
        except Exception as e:
            print(str(e))
            c_out = False    
        if self.settings.get("select_efi_drivers", True):
            # Check our clover version and ensure the EFI is setup correctly
            t_clover_v = self.get_clover_version(clover)
            self.ensure_for_version(efi_mount, t_clover_v)
            # Copy EFI Drivers
            try:
                self.copy_efi_drivers(efi_drivers, efi_mount, quiet)
            except Exception as e:
                print(str(e))

        # Check for local binaries
        if len(binaries):
            bin_path = os.path.join("/","usr","local","bin")
            to_copy = []
            for x in binaries:
                if os.path.exists(os.path.join(bin_path,x)):
                    to_copy.append(x)
            if not len(to_copy):
                print("\nNo clover-related binaries found in /usr/local/bin - nothing to update.")
            else:
                print("\nFound {} clover-related binar{} in /usr/local/bin - replacing...\n".format(len(to_copy), "y" if len(to_copy) == 1 else "ies"))
                # Replace the binaries
                for f in to_copy:
                    print(" Replacing {}...".format(f))
                    # os.remove(os.path.join(bin_path,f))
                    out = self.r.run({"args":["rm","-f",os.path.join(bin_path,f)],"sudo":True})
                    if out[2] != 0:
                        print(out[1])
                        continue
                    # shutil.copy(binaries[f]["path"], os.path.join(bin_path,f))
                    out = self.r.run({"args":["cp",binaries[f]["path"],os.path.join(bin_path,f)],"sudo":True})
                    if out[2] != 0:
                        print(out[1])
                        continue

        # Clean up
        self.cleanup(temp, disk, mounted, quiet)
        return c_out

    def copy_clover(self, clover, efi_mount, archive, quiet):
        c_path = os.path.join(efi_mount, "EFI", "CLOVER")
        b_path = os.path.join(efi_mount, "EFI", "BOOT")
        
        out = True

        t_clover_v = self.get_clover_version(clover)
        if not t_clover_v:
            t_clover_v = "Unknown"
        
        # Copy CLOVERX64.efi to the CLOVER and BOOT folders if they exist
        got_clover = os.path.exists(os.path.join(c_path, "CLOVERX64.efi"))
        got_boot   = os.path.exists(os.path.join(b_path, "BOOTX64.efi"))
        if not got_clover:
            print("CLOVERX64.efi does not exist!")
            out = False
        # Check the got_clover and got_boot versions
        got_clover_v = self.get_clover_version(os.path.join(c_path, "CLOVERX64.efi"))
        if not got_clover_v:
            got_clover_v = "Unknown"
        self.qprint("     Found CLOVERX64.efi version: {}".format(got_clover_v), quiet)
        got_boot_v = None
        if got_boot:
            got_boot_v = self.get_clover_version(os.path.join(b_path, "BOOTX64.efi"))
            if not got_boot_v:
                self.qprint("   Unknown BOOTX64.efi version - bypassing in case it's not Clover...", quiet)
            else:
                self.qprint("     Found BOOTX64.efi version: {}".format(got_boot_v), quiet)
        if archive:
            # Rename the old version to its version number
            try:
                self.qprint("  Renaming CLOVERX64.efi to CLOVERX64_r{}.efi".format(got_clover_v), quiet)
                old_path = os.path.join(c_path, "CLOVERX64.efi")
                new_path = os.path.join(c_path, "CLOVERX64_r{}.efi".format(got_clover_v))
                if os.path.exists(new_path):
                    # Already exists, overwrite it
                    self.qprint("CLOVERX64_r{}.efi already exists - removing...".format(got_clover_v), quiet)
                    os.remove(new_path)
                os.rename(
                    os.path.join(c_path, "CLOVERX64.efi"),
                    os.path.join(c_path, "CLOVERX64_r{}.efi".format(got_clover_v))    
                )
                if got_boot and got_boot_v:
                    self.qprint("  Renaming BOOTX64.efi to BOOTX64_r{}.efi".format(got_boot_v), quiet)
                    old_path = os.path.join(b_path, "BOOTX64.efi")
                    new_path = os.path.join(b_path, "BOOTX64_r{}.efi".format(got_boot_v))
                    if os.path.exists(new_path):
                        # Already exists, overwrite it
                        self.qprint("BOOTX64_r{}.efi already exists - removing...".format(got_boot_v), quiet)
                        os.remove(new_path)
                    os.rename(
                        os.path.join(b_path, "BOOTX64.efi"),
                        os.path.join(b_path, "BOOTX64_r{}.efi".format(got_boot_v))    
                    )
            except Exception as e:
                print(str(e))
                out = False
        else:
            # Remove the old versions first, then copy new versions
            try:
                self.qprint("  Removing CLOVERX64.efi version: {}...".format(got_clover_v), quiet)
                os.remove(os.path.join(c_path, "CLOVERX64.efi"))
                if got_boot and got_boot_v:
                    self.qprint("  Removing BOOTX64.efi version: {}...".format(got_boot_v), quiet)
                    os.remove(os.path.join(b_path, "BOOTX64.efi"))
            except Exception as e:
                print(str(e))
                out = False
        try:
            self.qprint("   Copying CLOVERX64.efi version: {}...".format(t_clover_v), quiet)
            shutil.copy(clover, os.path.join(c_path, "CLOVERX64.efi"))
            if got_boot and got_boot_v:
                self.qprint("   Copying BOOTX64.efi version: {}...".format(t_clover_v), quiet)
                shutil.copy(clover, os.path.join(b_path, "BOOTX64.efi"))
        except Exception as e:
            print(str(e))
            out = False
        return out

    def ensure_for_version(self, efi_path, clover_version):
        # 4983 added BiosDrivers and UEFIDrivers at the CLOVER dir
        try:
            clover_version = int(clover_version)
        except:
            return # We don't know what Clover this is - just... deal with it...
        if clover_version < 4983:
            # We need to ensure that we migrate drivers/UEFI or UEFIDrivers to drivers64UEFI
            # and drivers/BIOS or BiosDrivers to drivers64
            targetUEFI = os.path.join(efi_path, "EFI", "CLOVER", "drivers64UEFI")
            targetBIOS = os.path.join(efi_path, "EFI", "CLOVER", "drivers64")
            sourceUEFI = [
                os.path.join(efi_path,"EFI","CLOVER","drivers","UEFI"),
                os.path.join(efi_path,"EFI","CLOVER","UEFIDrivers")
            ]
            sourceBIOS = [
                os.path.join(efi_path,"EFI","CLOVER","drivers","BIOS"),
                os.path.join(efi_path,"EFI","CLOVER","BiosDrivers")
            ]
        elif clover_version >= 4983 and clover_version < 4986:
            targetUEFI = os.path.join(efi_path, "EFI", "CLOVER", "UEFIDrivers")
            targetBIOS = os.path.join(efi_path, "EFI", "CLOVER", "BiosDrivers")
            sourceUEFI = [
                os.path.join(efi_path,"EFI","CLOVER","drivers","UEFI"),
                os.path.join(efi_path,"EFI","CLOVER","drivers64UEFI")
            ]
            sourceBIOS = [
                os.path.join(efi_path,"EFI","CLOVER","drivers","BIOS"),
                os.path.join(efi_path,"EFI","CLOVER","drivers64")
            ]
        else:
            # Assume we only use the drivers/UEFI and drivers/BIOS folders
            targetUEFI = os.path.join(efi_path, "EFI", "CLOVER", "drivers", "UEFI")
            targetBIOS = os.path.join(efi_path, "EFI", "CLOVER", "drivers", "BIOS")
            sourceUEFI = [
                os.path.join(efi_path,"EFI","CLOVER","UEFIDrivers"),
                os.path.join(efi_path,"EFI","CLOVER","drivers64UEFI")
            ]
            sourceBIOS = [
                os.path.join(efi_path,"EFI","CLOVER","BiosDrivers"),
                os.path.join(efi_path,"EFI","CLOVER","drivers64")
            ]
        # Verify that our targets exist
        if not os.path.exists(targetUEFI):
            # Iterate our sources and clone if they exist
            for x in sourceUEFI:
                if os.path.exists(x):
                    # Create the target - and copy the contents
                    os.makedirs(targetUEFI)
                    for y in os.listdir(x):
                        path = os.path.join(x,y)
                        try:
                            shutil.copy(path,targetUEFI)
                        except Exception as e:
                            print("Failed to copy {}: {}".format(y,e))
                    # Assume we copied what was needed - bail
                    break
        if not os.path.exists(targetBIOS):
            # Iterate our sources and clone if they exist
            for x in sourceBIOS:
                if os.path.exists(x):
                    # Create the target - and copy the contents
                    os.makedirs(targetBIOS)
                    for y in os.listdir(x):
                        path = os.path.join(x,y)
                        try:
                            shutil.copy(path,targetBIOS)
                        except Exception as e:
                            print("Failed to copy {}: {}".format(y,e))
                    # Assume we copied what was needed - bail
                    break
        

    def copy_efi_drivers(self, efi_list, efi_path, quiet):
        for d in ["drivers64", "drivers32", "drivers64UEFI", "drivers32UEFI", "drivers/UEFI", "drivers/BIOS"]:
            d64 = os.path.join(efi_path, "EFI", "CLOVER", d)
            if not os.path.exists(d64):
                # Nothing to do here
                continue
            # Get the defaults
            installed = sorted([x for x in os.listdir(d64) if x.lower().endswith(".efi") and not x.startswith(".")])
            to_copy = []
            for x in installed:
                for y in efi_list:
                    # Replace if the values match with or without the "-64" suffix - but only replace once
                    if x.lower().replace("-64","") == y.lower().replace("-64","") and not any(z for z in to_copy if z["find"] == x):
                        # Add it
                        to_copy.append({"find":x, "replace":y})
                        break
            # to_copy   = sorted([x for x in efi_list if installed_mapped.get(x.lower(), None)])

            if not len(installed):
                # Nothing to replace
                continue

            if not len(to_copy):
                print("\nFound 0 of {} efi driver{} in {} - skipping...\n".format(len(installed), "" if len(installed) == 1 else "s", d))
                continue

            print("\nFound {} of {} efi driver{} in {} - replacing...\n".format(len(to_copy), len(installed), "" if len(installed) == 1 else "s", d))

            for f in to_copy:
                print(" Replacing {}...".format(f["find"]))
                os.remove(os.path.join(d64, f["find"]))
                shutil.copy(efi_list[f["replace"]]["path"], os.path.join(d64, f["find"]))
                if f["find"].lower() != f["replace"].lower():
                    print("  - {} --> {}".format(f["replace"], f["find"]))

    def cleanup(self, temp, disk, mount_status, quiet):
        shutil.rmtree(temp)
        if not mount_status:
            print(" ")
            self.qprint("Unmounting {}...".format(disk), quiet)
            out = self.d.unmount_partition(disk)
            if not out[2] == 0:
                print(out[1])
                return False
            self.qprint(out[0].strip("\n"), quiet)

    def get_clover_version(self, f):
        # Attempts to get the clover version via binary string searching
        #
        # Hex for "Clover revision: "
        if not f:
            return None
        vers_hex = "Clover revision: ".encode("utf-8")
        vers_add = len(vers_hex)
        with open(f, "rb") as f:
            s = f.read()
        location = s.find(vers_hex)
        if location == -1:
            return None
        location += vers_add
        version = ""
        while True:
            try:
                vnum = s[location].decode("utf-8")
                numtest = int(vnum)
                version += vnum
            except:
                break
            location += 1
        if not len(version):
            return None
        return version

    def extract_clover(self, package, temp):
        # Extracts the passed clover package and returns the path to the CLOVERX64.efi
        # Returns None on failure
        cwd = os.getcwd()
        os.chdir(os.path.dirname(os.path.realpath(temp)))

        out = self.r.run({"args":["/usr/sbin/pkgutil", "--expand", package, os.path.join(temp, "pkg")]})        
        if out[2] != 0:
            os.chdir(cwd)
            print("pkgutil", out[1])
            return False

        # Iterate all packages - and extract them all
        c = os.getcwd()
        e = os.path.join(c, "efi_drivers")
        b = os.path.join(c, "binaries")
        el = {} # The EFI driver list
        bn = {} # The binary list
        if not os.path.exists(e):
            os.mkdir(e)
        if not os.path.exists(b):
            os.mkdir(b)
        # Extract the Utils.pkg separately if we need to update the local
        # /usr/local/bin
        if os.path.exists(os.path.join(temp,"pkg","Utils.pkg")):
            os.chdir(os.path.join(temp, "pkg", "Utils.pkg"))
            print("Extracting Utils.pkg...")
            try:
                out = self.r.run({"args":["/usr/bin/tar", "xvf", "Payload"]})
            except:
                out = ("", "Failed to extract Utils.pkg", 1)
            if out[2] != 0:
                print(out[1])
            else:
                bin_path = os.path.join(temp,"pkg","Utils.pkg","usr","local","bin")
                if os.path.exists(bin_path):
                    # Gather the binaries
                    for x in os.listdir(bin_path):
                        os.rename(os.path.join(bin_path,x), os.path.join(b,x))
                        bn[x] = { "path" : os.path.join(b,x), "show" : True, "selected" : True }
        # Iterate the packages and extract the efi drivers
        for pkg in [x for x in sorted(os.listdir(os.path.join(temp, "pkg"))) if x.lower().endswith(".pkg")]:
            os.chdir(os.path.join(temp, "pkg", pkg))
            if not pkg.lower() == "efifolder.pkg" and not self.settings.get("select_efi_drivers", True):
                # We only want Clover
                continue
            print("Extracting {}...".format(pkg))
            try:
                out = self.r.run({"args":["/usr/bin/tar", "xvf", "Payload"]})
            except:
                out = ("", "Failed to extract {}".format(pkg), 1)
            if out[2] != 0:
                print(out[1])
                continue
            # Check for Clover
            if os.path.exists(os.path.join(temp, "pkg", pkg, "EFI", "CLOVER", "CLOVERX64.efi")):
                os.rename(os.path.join(temp, "pkg", pkg, "EFI", "CLOVER", "CLOVERX64.efi"), os.path.join(e, "CLOVERX64.efi"))
                el["CLOVERX64.efi"] = { "path" : os.path.join(e, "CLOVERX64.efi"), "show" : False, "selected" : False }
            # Check for other EFI drivers
            for e_file in [x for x in os.listdir(os.path.join(temp, "pkg", pkg)) if x.lower().endswith(".efi")]:
                os.rename(os.path.join(temp, "pkg", pkg, e_file), os.path.join(e, e_file))
                el[e_file] = { "path" : os.path.join(e, e_file), "show" : True, "selected" : False }
        os.chdir(c)

        if not len(el):
            print("No efi drivers found!")
        if not len(bn):
            print("No binaries found!")

        return (el,bn)

    def get_clover_package(self):
        # Returns a clover package
        self.u.head("Clover Package")
        print(" ")
        print("M. Main")
        print("Q. Quit")
        print(" ")
        pk = self.u.grab("Please drag and drop a clover install package here:  ")
        if pk.lower() == "m":
            return None
        if pk.lower() == "q":
            self.u.custom_quit()
        out = self.u.check_path(pk)
        if out:
            return out
        return self.get_clover_package()

    def get_dl_info(self):
        # Returns the latest download package and info in a
        # dictionary:  { "url" : dl_url, "info" : update_info }
        json_data = self.dl.get_string(self.clover_url, False)
        if not json_data or not len(json_data):
            return None
        try:
            j = json.loads(json_data)
        except:
            return None
        dl_link = next((x.get("browser_download_url", None) for x in j.get("assets", []) if x.get("browser_download_url", "").lower().endswith(".pkg")), None)
        if not dl_link:
            return None
        return { "url" : dl_link, "name" : os.path.basename(dl_link), "info" : j.get("body", None) }

    def get_clover_info(self):
        # Returns the latest Clover version
        clover_data = self.dl.get_string(self.clover_repo, False)
        try:
            c = clover_data.lower().split("revision ")[1].split(":")[0]
        except:
            c = "Unknown"
        return c

    def check_clover_folder(self):
        t_folder = os.path.join(os.path.dirname(os.path.realpath(__file__)), "Clover")
        if not os.path.isdir(t_folder):
            os.mkdir(t_folder)
        return t_folder

    def get_newest(self):
        # Checks the latest available clover package and downloads it
        self.u.head("Gathering Data...")
        print(" ")
        j = self.get_dl_info()
        if not j:
            print("Error retrieving info!")
            print(" ")
            self.u.grab("Press [enter] to return...")
            return
        # Show the version and description
        self.u.head("Latest Clover Package")
        print(" ")
        print("Latest:  {}".format(os.path.basename(j["url"])))
        if j["info"]:
            print("Changes: {}".format(j["info"]))
        print(" ")
        print("D. Download")
        print("M. Main")
        print("Q. Quit")
        print(" ")
        menu = self.u.grab("Please select an option:  ")
        if not len(menu):
            self.get_newest()
            return
        if menu.lower() == "q":
            self.u.custom_quit()
        if menu.lower() == "m":
            return
        if menu.lower() == "d":
            self.download_clover(j)
            return
        self.get_newest()

    def download_clover(self, info, quiet = False):
        # Actually downloads clover
        if not info:
            return None
        self.u.head("Downloading {}".format(info["name"]))
        print("")
        t_folder = self.check_clover_folder()
        t_path   = os.path.join(t_folder, info["name"])
        if os.path.exists(t_path):
            # Already exists - just return it
            if not quiet:
                self.re.reveal(t_path)
            return t_path
        out = self.dl.stream_to_file(info["url"], t_path)
        if not out:
            print("Something went wrong!")
            print(" ")
            if not quiet:
                self.u.grab("Press [enter] to return to main...")
            return None
        self.u.head("Downloaded {}".format(info["name"]))
        print("")
        if not quiet:
            self.re.reveal(t_path)
            self.u.grab("Done!", timeout=5)
        return t_path

    def build_clover(self):
        # Builds clover from soure - or attempts to...
        self.u.head("Building Clover")
        print("")
        out = self.c.build_clover()
        if not out:
            print("Looks like something went wrong building Clover...")
            return None
        # Let's copy clover into our Clover folder
        t_folder = self.check_clover_folder()
        c_name = os.path.basename(out)
        o_path = os.path.join(t_folder, c_name)
        shutil.copy(out, o_path)
        return o_path

    def auto_build(self, disk, archive):
        # Builds clover, then auto installs to the target drive
        package = self.build_clover()
        if not package:
            self.u.head("Error Building Clover!")
            print("")
            print("Something went wrong!")
            print("")
            self.u.grab("Press [enter] to return...")
            return
        self.mount_and_copy(disk, package, archive)
        print(" ")
        self.u.grab("Press [enter] to return...")

    def auto_update(self, info, disk, archive):
        # Downloads clover, then auto installs to the target drive
        package = self.download_clover(info, True)
        if not package:
            self.u.head("Error Downloading Clover!")
            print(" ")
            print("Something went wrong!")
            print(" ")
            self.u.grab("Press [enter] to return...")
            return
        self.mount_and_copy(disk, package, archive)
        print(" ")
        self.u.grab("Press [enter] to return...")

    def efi_driver_menu(self):
        self.u.resize(80, 24)
        self.u.head("EFI Drivers")
        to_build = []
        print("")
        count = 0
        for d in self.c.efi_drivers:
            count += 1
            print("{}. {}".format(count, d.get("path", "Unknown")))
        print("")
        print("A. Build All")
        print("M. Main Menu")
        print("Q. Quit")
        print("")
        menu = self.u.grab("Please select an option:  ")
        if not len(menu):
            self.efi_driver_menu()
            return
        if menu[0].lower() == "m":
            return
        elif menu[0].lower() == "q":
            self.u.custom_quit()
        elif menu[0].lower() == "a":
            to_build = self.c.efi_drivers
        try:
            m = int(menu)
            if m > 0 and m <= len(self.c.efi_drivers):
                to_build.append(self.c.efi_drivers[m-1])
        except:
            pass
        if len(to_build):
            self.u.head("Building EFI Drivers")
            print("")
            count = 0
            success = 0
            for d in to_build:
                count += 1
                print("Building {} of {}\n".format(count, len(to_build)))
                out = self.c.build_efi_driver(d, "sa")
                print("")
                if not out:
                    continue
                success += 1
                # Copy to the Clover folder
                t_folder = self.check_clover_folder()
                for o in out:
                    c_name = os.path.basename(o)
                    o_path = os.path.join(t_folder, c_name)
                    shutil.copy(o, o_path)
            if success > 0:
                print("Revealing output...")
                print("")
                self.r.run({"args":["open",self.check_clover_folder()]})
            print("Done.")
            print("")
            self.u.grab("Press [enter] to return...")
            return
        self.efi_driver_menu()

    def clean_sources(self, folders = []):
        # Lowercase the folder list
        folders = [x.lower() for x in folders]
        self.u.resize(80, 24)
        self.u.head("Wiping Source Folders")
        print("")
        cwd = os.getcwd()
        os.chdir(self.c_source)
        print("Iterating Sources:\n")
        for x in sorted(os.listdir(self.c_source)):
            print(" - {}".format(x))
            if x.lower() in folders:
                print(" --> Removing...")
                try:
                    if os.path.isdir(x):
                        shutil.rmtree(x,ignore_errors=True)
                    else:
                        os.remove(x)
                    print(" ----> Removed.")
                except Exception as e:
                    print(" ----> Error removing!")
                    print(" ------> {}".format(str(e)))
        os.chdir(cwd)

    def main(self):
        while True:
            self.u.head("Clover Extractor")
            print(" ")
            height = 35
            j = self.get_dl_info()
            c = self.get_clover_info()
            clover = bdmesg.get_clover_uuid()
            vers   = self.get_version_from_bdmesg()
            self.d.update()
            if c:
                height += 1
                print("Latest Clover:     {}".format(c))
            if vers:
                height += 1
                print("Currently Booted:  {}".format(vers))
            if j:
                height += 1
                print("Latest From Dids:  {}".format(j["name"]))
            if vers or j or c:
                height += 1
                print(" ")
            if self.clover == None or not os.path.exists(self.clover):
                print("Package: None")
            else:
                print("Package: {}".format(os.path.basename(self.clover)))
            if self.efi == None:
                print("EFI:     None")
            else:
                print("EFI:     {}".format(self.efi))
            print(" ")
            print("P. Select Package")
            print("E. Select EFI")
            print("X. Extract Clover")
            print("")
            print("F. Build EFI Drivers")
            print("")
            print("Auto Download and Install to:")
            print("  B. Boot Drive's EFI")
            if clover:
                height += 1
                print("  C. Booted Clover's EFI")
            print(" ")
            print("Build From Source and Install to:")
            print("  BB. Boot Drive's EFI")
            if clover:
                height += 1
                print("  BC. Booted Clover's EFI")
            print("")
            print("D. Download Newest Clover (Dids' Repo)")
            print("CC. Compile Clover From Source")
            print("")
            print("T. Toggle Drivers64UEFI Updates (currently {})".format("Enabled" if self.settings.get("select_efi_drivers", True) else "Disabled"))
            print("U. Toggle Debugging (currently {})".format("Enabled" if self.settings.get("debug",False) else "Disabled"))
            print("")
            print("W.  Wipe All Source Folders")
            print("WC. Wipe Only Clover Source Folders")
            print("WE. Wipe Only EFI Driver Source Folders")
            print("WT. Wipe Only Clover Tools Source Folders")
            print("")
            print("Q. Quit")
            print("")
            print("Add A to X, B, C, BB, or BC (eg. ABC) to also archive")
            self.u.resize(80, height)
            menu = self.u.grab("Please select an option:  ")
            archive = False
            if len(menu) == 2 and "a" in menu.lower():
                menu = menu.replace("A", "").replace("a", "")
                archive = True
            
            if not len(menu):
                continue

            self.u.resize(80, 24)
            if menu.lower() == "q":
                self.u.custom_quit()
            elif menu.lower() == "d":
                self.get_newest()
            elif menu.lower() == "p":
                self.clover = self.get_clover_package()
            elif menu.lower() == "e":
                self.efi = self.get_efi()
            elif menu.lower() == "f":
                self.efi_driver_menu()
            elif menu.lower() == "w":
                self.clean_sources(os.listdir(self.c_source))
            elif menu.lower() == "we":
                self.clean_sources([x for x in os.listdir(self.c_source) if x.lower() not in self.clover_sources and x.lower() not in self.tool_sources])
            elif menu.lower() == "wc":
                self.clean_sources(self.clover_sources)
            elif menu.lower() == "wt":
                self.clean_sources(self.tool_sources)
            elif menu.lower() == "cc":
                out = self.build_clover()
                if out:
                    self.re.reveal(out)
            elif menu.lower() == "bb":
                self.auto_build(self.d.get_efi("/"), archive)
            elif menu.lower() == "bc":
                self.auto_build(self.d.get_efi(clover), archive)
            elif menu.lower() == "b":
                self.auto_update(j, self.d.get_efi("/"), archive)
            elif menu.lower() == "c" and clover:
                self.auto_update(j, self.d.get_efi(clover), archive)
            elif menu.lower() == "t":
                self.settings["select_efi_drivers"] = not self.settings.get("select_efi_drivers", True)
                self.flush_settings()
            elif menu.lower() == "u":
                self.settings["debug"] = not self.settings.get("debug",False)
                self.c.debug = self.settings["debug"]
                self.flush_settings()
            elif menu.lower() == "x":
                if not self.clover or not os.path.exists(self.clover):
                    self.clover = self.get_clover_package()
                    if not self.clover:
                        continue
                if not self.efi:
                    self.efi = self.get_efi()
                    if not self.efi:
                        continue
                # If we made it here, we have both parts
                self.mount_and_copy(self.efi, self.clover, archive)
                print(" ")
                self.u.grab("Press [enter] to return...")

    def quiet_copy(self, args):
        # Iterate through the args
        arg_pairs = zip(*[iter(args)]*2)
        built = None
        latest = None
        for pair in arg_pairs:
            efi = self.d.get_efi(pair[1])
            if efi:
                try:
                    # Check for build
                    pkg = pair[0]
                    if pkg.lower() == "build":
                        if not built:
                            # We haven't built it yet (or it failed?)
                            built = self.build_clover()
                        pkg = built
                    elif pkg.lower() == "download":
                        if not latest:
                            # We haven't gathered info on it yet
                            latest = self.get_dl_info()
                        pkg = self.download_clover(latest, True)
                    self.mount_and_copy(self.d.get_efi(pair[1]), pkg, False, True)
                except Exception as e:
                    print(str(e))

if __name__ == '__main__':
    c = CloverExtractor()
    # Check for args
    if len(sys.argv) > 1:
        # We got command line args!
        # CloverExtractor.command (w|we|wt|wc) /path/to/clover.pkg disk#s# /path/to/other/clover.pkg disk#s#
        # If the first item is w, we, wt, or wc, clear the appropriate sources
        # If the path is "build" - we build clover
        # If the path is "download" - we attempt to download the latest Dids clover
        if sys.argv[1].lower() in ["w","we","wc"] and len(sys.argv) > 2:
            args = sys.argv[2:]
            w = sys.argv[1].lower()
            if w == "w":
                c.clean_sources(os.listdir(c.c_source))
            elif w == "we":
                c.clean_sources([x for x in os.listdir(c.c_source) if x.lower() not in c.clover_sources and x.lower() not in c.tool_sources])
            elif w == "wc":
                c.clean_sources(c.clover_sources)
            elif w == "wt":
                c.clean_sources(c.tool_sources)
        else:
            args = sys.argv[1:]
        c.quiet_copy(args)
    else:
        c.main()
