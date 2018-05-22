#!/usr/bin/python
# 0.0.0
from Scripts import *
import os, tempfile, datetime, shutil, time, plistlib, json, sys

class CloverExtractor:
    def __init__(self, **kwargs):
        self.r  = run.Run()
        self.d  = disk.Disk()
        self.dl = downloader.Downloader()
        self.re = reveal.Reveal()
        self.clover_url = "https://api.github.com/repos/dids/clover-builder/releases/latest"
        self.u  = utils.Utils("CloverExtractor")
        self.clover = None
        self.efi    = None
        # Get the tools we need
        self.bdmesg = self.get_binary("bdmesg")
        self.full = False

    def get_version_from_bdmesg(self):
        if not self.bdmesg:
            return None
        # Get bdmesg output - then parse for SelfDevicePath
        bdmesg = self.r.run({"args":[self.bdmesg]})[0]
        if not "Starting Clover revision: " in bdmesg:
            # Not found
            return None
        try:
            # Split to just the contents of that line
            rev = bdmesg.split("Starting Clover revision: ")[1].split("on")[0]
            return rev
        except:
            pass
        return None

    def get_uuid_from_bdmesg(self):
        if not self.bdmesg:
            return None
        # Get bdmesg output - then parse for SelfDevicePath
        bdmesg = self.r.run({"args":[self.bdmesg]})[0]
        if not "SelfDevicePath=" in bdmesg:
            # Not found
            return None
        try:
            # Split to just the contents of that line
            line = bdmesg.split("SelfDevicePath=")[1].split("\n")[0]
            # Get the HD section
            hd   = line.split("HD(")[1].split(")")[0]
            # Get the UUID
            uuid = hd.split(",")[2]
            return uuid
        except:
            pass
        return None

    def get_binary(self, name):
        # Check the system, and local Scripts dir for the passed binary
        found = self.r.run({"args":["which", name]})[0].split("\n")[0].split("\r")[0]
        if len(found):
            # Found it on the system
            return found
        if os.path.exists(os.path.join(os.path.dirname(os.path.realpath(__file__)), name)):
            # Found it locally
            return os.path.join(os.path.dirname(os.path.realpath(__file__)), name)
        # Check the scripts folder
        if os.path.exists(os.path.join(os.path.dirname(os.path.realpath(__file__)), self.script_folder, name)):
            # Found it locally -> Scripts
            return os.path.join(os.path.dirname(os.path.realpath(__file__)), self.script_folder, name)
        # Not found
        return None

    def get_efi(self):
        self.d.update()
        clover = self.get_uuid_from_bdmesg()
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

    def mount_and_copy(self, disk, package, quiet = False):
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
        # Create a temp folder
        temp = tempfile.mkdtemp()
        clover = self.extract_clover(package, temp)
        if not clover:
            print("Error locating CLOVERX64.efi in {}!".format(os.path.basename(package)))
            shutil.rmtree(temp)
            return False
        t_clover_v = self.get_clover_version(clover)
        if not t_clover_v:
            t_clover_v = "Unknown"
        # Copy CLOVERX64.efi to the CLOVER and BOOT folders if they exist
        efi_mount = self.d.get_mount_point(disk)
        if not efi_mount:
            print("EFI at {} not mounted!".format(disk))
            shutil.rmtree(temp)
            return False
        got_clover = os.path.exists(os.path.join(efi_mount, "EFI", "CLOVER", "CLOVERX64.efi"))
        if not got_clover:
            print("CLOVERX64.efi does not exist!")
            shutil.rmtree(temp)
            return False
        got_boot   = os.path.exists(os.path.join(efi_mount, "EFI", "BOOT", "BOOTX64.efi"))
        # Check the got_clover and got_boot versions
        got_clover_v = self.get_clover_version(os.path.join(efi_mount, "EFI", "CLOVER", "CLOVERX64.efi"))
        if not got_clover_v:
            got_clover_v = "Unknown"
        self.qprint("Found CLOVERX64.efi Version: {}".format(got_clover_v), quiet)
        got_boot_v = None
        if got_boot:
            got_boot_v = self.get_clover_version(os.path.join(efi_mount, "EFI", "BOOT", "BOOTX64.efi"))
            if not got_boot_v:
                self.qprint("Unknown BOOTX64.efi version - bypassing in case it's not Clover...", quiet)
            else:
                self.qprint("Found BOOTX64.efi Version: {}".format(got_boot_v), quiet)
        # Remove the old versions first, then copy new versions
        try:
            self.qprint("Removing CLOVERX64.efi version {}...".format(got_clover_v), quiet)
            os.remove(os.path.join(efi_mount, "EFI", "CLOVER", "CLOVERX64.efi"))
            self.qprint("Copying CLOVERX64.efi version {}...".format(t_clover_v), quiet)
            shutil.copy(clover, os.path.join(efi_mount, "EFI", "CLOVER", "CLOVERX64.efi"))
            if got_boot and got_boot_v:
                self.qprint("Removing BOOTX64.efi version {}...".format(got_boot_v), quiet)
                os.remove(os.path.join(efi_mount, "EFI", "BOOT", "BOOTX64.efi"))
                self.qprint("Copying BOOTX64.efi version {}...".format(t_clover_v), quiet)
                shutil.copy(clover, os.path.join(efi_mount, "EFI", "BOOT", "BOOTX64.efi"))
        except Exception as e:
            print(str(e))
            shutil.rmtree(temp)
            return False
        # Unmount if EFI wasn't mounted
        if not mounted:
            self.qprint("Unmounting {}...".format(disk), quiet)
            out = self.d.unmount_partition(disk)
            if not out[2] == 0:
                print(out[1])
                return False
            self.qprint(out[0].strip("\n"), quiet)
        # Success!
        shutil.rmtree(temp)
        return True

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

        out = self.r.run({"args":["pkgutil", "--expand", package, os.path.join(temp, "pkg")]})        
        if out[2] != 0:
            os.chdir(cwd)
            print("pkgutil", out[1])
            return False
        
        if not os.path.isdir(os.path.join(temp, "pkg", "EFIFolder.pkg")):
            os.chdir(cwd)
            print("EFIFolder.pkg not found")
            return False
        
        os.chdir(os.path.join(temp, "pkg", "EFIFolder.pkg"))
        out = self.r.run({"args":["tar", "xvf", "Payload"]})
        if out[2] != 0:
            print("tar", out[1])
            os.chdir(cwd)
            return False
        os.chdir(cwd)
        target = os.path.join(temp, "pkg", "EFIFolder.pkg", "EFI", "CLOVER", "CLOVERX64.efi")
        if not os.path.exists(target):
            print("CLOVERX64.efi not found")
            return False
        return target

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
        t_folder = os.path.join(os.path.dirname(os.path.realpath(__file__)), "Clover")
        t_path   = os.path.join(t_folder, info["name"])
        if os.path.exists(t_path):
            # Already exists - just return it
            return t_path
        if not os.path.isdir(t_folder):
            os.mkdir(t_folder)
        out = self.dl.stream_to_file(info["url"], t_path)
        if not out:
            print("Something went wrong!")
            print(" ")
            self.u.grab("Press [enter] to return to main...")
            return None
        self.u.head("Downloaded {}".format(info["name"]))
        print("")
        if not quiet:
            self.re.reveal(t_path)
            self.u.grab("Done!", timeout=5)
        return t_path

    def auto_update(self, info, disk):
        # Downloads clover, then auto installs to the target drive
        package = self.download_clover(info, True)
        if not package:
            self.u.head("Error Downloading Clover!")
            print(" ")
            print("Something went wrong!")
            print(" ")
            self.u.grab("Press [enter] to return...")
            return
        self.mount_and_copy(disk, package)
        print(" ")
        self.u.grab("Press [enter] to return...")

    def main(self):
        while True:
            self.u.head("Clover Extractor")
            print(" ")
            j = self.get_dl_info()
            clover = self.get_uuid_from_bdmesg()
            vers   = self.get_version_from_bdmesg()
            self.d.update()
            if vers:
                print("Booted:  {}".format(vers))
            if j:
                print("Latest:  {} (powered by Dids)".format(j["name"]))
            if vers or j:
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
            print(" ")
            print("Auto Download and Install to:")
            print("B. Boot Drive's EFI")
            if clover:
                print("C. Booted Clover's EFI")
            print(" ")
            print("D. Download Newest Clover (Dids' Repo)")
            print(" ")
            print("Q. Quit")
            print(" ")
            menu = self.u.grab("Please select an option:  ")
            if not len(menu):
                continue
            
            if menu.lower() == "q":
                self.u.custom_quit()
            elif menu.lower() == "d":
                self.get_newest()
            elif menu.lower() == "p":
                self.clover = self.get_clover_package()
            elif menu.lower() == "e":
                self.efi = self.get_efi()
            elif menu.lower() == "b":
                self.auto_update(j, self.d.get_efi("/"))
            elif menu.lower() == "c" and clover:
                self.auto_update(j, self.d.get_efi(clover))
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
                self.mount_and_copy(self.efi, self.clover)
                print(" ")
                self.u.grab("Press [enter] to return...")

    def quiet_copy(self, args):
        # Iterate through the args
        arg_pairs = zip(*[iter(args)]*2)
        for pair in arg_pairs:
            efi = self.d.get_efi(pair[1])
            if efi:
                try:
                    self.mount_and_copy(self.d.get_efi(pair[1]), pair[0], True)
                except Exception as e:
                    print(str(e))

if __name__ == '__main__':
    c = CloverExtractor()
    # Check for args
    if len(sys.argv) > 1:
        pass
        # We got command line args!
        # CloverExtractor.command /path/to/clover.pkg disk#s# /path/to/other/clover.pkg disk#s#
        c.quiet_copy(sys.argv[1:])
    else:
        c.main()
