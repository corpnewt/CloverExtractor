import sys, os, shutil, time, json
sys.path.append(os.path.abspath(os.path.dirname(os.path.realpath(__file__))))
import run, reveal

class CloverBuild:

    '''
    Module that builds the Clover bootloader - or rather attempts to.
    Build structure and functions credit to Dids and his clover-builder:

    https://github.com/Dids/clover-builder
    '''

    def __init__(self, **kwargs):
        # Setup the default path - and expand it
        self.source     = kwargs.get("source", "~/src")
        self.source     = os.path.abspath(os.path.expanduser(self.source))
        self.verbose    = kwargs.get("verbose",False)
        if not os.path.exists(self.source):
            os.mkdir(self.source)
        # Setup the UDK repo
        self.udk_repo   = kwargs.get("udk_repo", "https://github.com/tianocore/edk2")
        self.udk_branch = kwargs.get("udk_branch", "UDK2018")
        self.udk_path   = kwargs.get("udk_path", "UDK2018")
        self.udk_path   = os.path.join(self.source, self.udk_path)
        # Setup the Clover repo
        self.c_repo     = kwargs.get("clover_repo", "https://svn.code.sf.net/p/cloverefiboot/code")
        self.c_path     = kwargs.get("clover_path", "Clover")
        self.c_path     = os.path.join(self.udk_path, self.c_path)
        # Setup the out dir
        self.out        = os.path.join(self.c_path, "CloverPackage", "sym")
        # Setup the Clover EFI path
        self.ce_path    = os.path.join(self.c_path, "CloverPackage/CloverV2/EFI/CLOVER/drivers/off")
        # Setup the efi drivers
        # Check if efi_drivers.json exists and load it if so
        self.efi_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "efi_drivers.json")
        self.efi_drivers = []
        if os.path.exists(self.efi_path):
            self.efi_drivers = json.load(open(self.efi_path))
        if not len(self.efi_drivers):
            self.efi_drivers = [
                {
                    "repo" : "https://github.com/acidanthera/AptioFixPkg",
                    "path" : "AptioFixPkg", # Joined with source
                    "out"  : "AptioFixPkg/UDK/Build/AptioFixPkg/RELEASE_XCODE5/X64",
                    "name" : ".efi", # Should copy all the .efi drivers into the package
                    "sa"   : ".zip", # Standalone is zipped in the output folder
                    "run"  : "macbuild.tool",
                    "env"  : {"FORCE_INSTALL":"1"},
                    "lang" : "bash"
                },
                {
                    "repo" : "https://github.com/acidanthera/AppleSupportPkg",
                    "path" : "AppleSupportPkg", # Joined with source
                    "out"  : "AppleSupportPkg/UDK/Build/AppleSupportPkg/RELEASE_XCODE5/X64",
                    "name" : ".efi", # Should copy all the .efi drivers into the package
                    "sa"   : ".zip", # Standalone is zipped in the output folder
                    "run"  : "macbuild.tool",
                    "env"  : {"FORCE_INSTALL":"1"},
                    "lang" : "bash"
                },
                {
                    "repo" : "https://github.com/acidanthera/VirtualSMC",
                    "path" : "VirtualSMC", # Joined with source
                    "out"  : "VirtualSMC/VirtualSmcPkg/UDK/Build/VirtualSmcPkg/RELEASE_XCODE5/X64",
                    "name" : ".efi", # Should copy all the .efi drivers into the package
                    "sa"   : ".efi", # Standalone is an efi driver as well
                    "run"  : "./VirtualSmcPkg/macbuild.tool",
                    "env"  : {"FORCE_INSTALL":"1"},
                    "lang" : "bash"
                }
            ]
        # Setup the companion modules
        self.r          = run.Run()
        self.re         = reveal.Reveal()
        # Debug options
        self.debug      = kwargs.get("debug", False)

    def update_udk(self):
        # Updates UDK2018 - or clones it if it doesn't exist
        if not os.path.exists(os.path.join(self.udk_path, ".git")):
            # Clone!
            print("Checking out a shiny new copy of UDK2018...")
            out = self.r.run({"args":["git", "clone", self.udk_repo, "-b", self.udk_branch, "--depth", "1", self.udk_path], "stream":self.debug})
            if out[2] != 0:
                print("Failed to check out UDK2018!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                return False
        # Already cloned once - just update
        print("Updating UDK2018...")
        cwd = os.getcwd()
        os.chdir(self.udk_path)
        out = self.r.run([
            {"args":["git", "reset", "--hard"],"stream":self.debug},
            {"args":["git", "pull"], "stream":self.debug},
            {"args":["git", "clean", "-fdx", "-e", "Clover/"], "stream":self.debug}
        ], True)
        os.chdir(cwd)
        if type(out) is list:
            out = out[-1]
        if out[2] != 0:
            print("Failed to update UDK2018!")
            if self.verbose:
                print(" - {}".format(out[1]))
            return False
        return True

    def update_clover(self):
        # Updates Clover - or clones it if it doesn't exist
        if not os.path.exists(os.path.join(self.c_path, ".svn")):
            # Clone!
            print("Checking out a shiny new copy of Clover...")
            out = self.r.run({"args":["svn", "co", self.c_repo, self.c_path], "stream":self.debug})
            if out[2] != 0:
                print("Failed to check out Clover!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                return False
        # Already cloned once - just update
        print("Updating Clover...")
        cwd = os.getcwd()
        os.chdir(self.udk_path)
        rev = self.get_clover_revision()
        if not rev:
            print("No Clover revision located!")
            return False
        out = self.r.run([
            # {"args":["svn", "up", "-r{}".format(rev)], "stream":self.debug},
            {"args":["svn", "up", "-rHEAD"], "stream":self.debug},
            {"args":["svn", "revert", "-R", "."], "stream":self.debug},
            {"args":["svn", "cleanup", "--remove-unversioned"], "stream":self.debug}
        ], True)
        os.chdir(cwd)
        if type(out) is list:
            out = out[-1]
        if out[2] != 0:
            print("Failed to update Clover!")
            if self.verbose:
                print(" - {}".format(out[1]))
            return False
        return True

    def get_clover_revision(self):
        # Gets the revision from the Clover dir if exists - otherwise returns None
        if not os.path.exists(os.path.join(self.c_path, ".svn")):
            return None
        cwd = os.getcwd()
        os.chdir(self.c_path)
        out = self.r.run({"args":["svn", "info"]})[0]
        try:
            rev = out.lower().split("revision: ")[1].split("\n")[0]
        except:
            rev = ""
        if not len(rev):
            return None
        return rev

    def build_efi_driver(self, driver, ret = "out"):
        cwd = os.getcwd()
        os.chdir(self.source)
        try:
            if not all(key in driver for key in ["repo", "path", "out", "name", "run", "lang", "sa"]):
                print("Driver missing info - skipping...")
                raise Exception()
            print("Building {}...".format(driver["path"]))
            if not os.path.exists(os.path.join(self.source, driver["path"], ".git")):
                # Clone it
                print("Checking out a shiny new copy of {}".format(driver["path"]))
                out = self.r.run({"args":["git", "clone", driver["repo"]], "stream":self.debug})
                if out[2] != 0:
                    print("Error cloning!")
                    if self.verbose:
                        print(" - {}".format(out[1]))
                    raise Exception()
            # Setup the env if available
            if driver.get("env", None):
                for e in driver["env"]:
                    os.environ[e] = str(driver["env"][e])
            # cd
            os.chdir(driver["path"])
            # Check for updates
            self.r.run({"args":["git", "reset", "--hard"],"stream":self.debug})
            self.r.run({"args":["git", "pull"], "stream":self.debug})
            # Chmod
            self.r.run({"args":["chmod", "+x", driver["run"]]})
            # Run it
            out = self.r.run({"args":[driver["lang"], driver["run"]], "stream":self.debug})
            if out[2] != 0:
                print("Failed to build {}!".format(driver["path"]))
                if self.verbose:
                    print(" - {}".format(out[1]))
                raise Exception()
        except:
            os.chdir(cwd)
            return None
        # Verify our return value
        ret = ret.lower()
        if ret == "name" or ret == "sa":
            # We need to find a list of files
            if not type(driver[ret]) is list:
                driver[ret] = [driver[ret]]
            # Iterate and gather
            out = []
            print(" - Locating...")
            for d in driver[ret]:
                for f in os.listdir(os.path.join(self.source, driver["out"])):
                    if d.startswith(".") and f.lower().endswith(d.lower()) or d.lower() == f.lower():
                        print(" --> {}".format(f))
                        out.append(os.path.join(self.source, driver["out"], f))
            out = None if not len(out) else out
        elif ret == "out":
            out = os.path.join(self.source, driver["out"])
        os.chdir(cwd)
        return out

    def build_efi_drivers(self):
        output = []
        cwd = os.getcwd()
        for driver in self.efi_drivers:
            out = self.build_efi_driver(driver, "name")
            if not out:
                continue
            print(" - Copying...")
            # Copy
            for d in out:
                # Copy the drivers!
                try:
                    dname = os.path.basename(d)
                    # Get destination
                    dest_list = driver.get("inst",{}).get(dname.lower(),[])
                    if not len(dest_list):
                        dest_list = [
                            "[[ce_path]]/BIOS",
                            "[[ce_path]]/UEFI"
                        ]
                    # Replace placeholders
                    dest_full = [x.replace("[[ce_path]]", self.ce_path).replace("[[c_path]]",self.c_path) for x in dest_list]
                    for path in dest_full:
                        # Remove if it already exists
                        dpath = os.path.join(path,dname)
                        if os.path.exists(dpath):
                            os.remove(dpath)
                        shutil.copy(d, dpath)
                    print(" --> {}".format(dname))
                except:
                    print("Failed to copy {}!".format(dname))

    def build_clover(self, pkg=True, iso=False):
        # Preliminary updates
        return_dict = {}
        if not self.update_udk() or not self.update_clover():
            # Updates failed :(
            return return_dict
        # Compile base tools
        print("Compiling base tools...")
        out = self.r.run({"args":["make", "-C", os.path.join(self.udk_path, "BaseTools", "Source", "C")], "stream":self.debug})
        if out[2] != 0:
            print("Failed to compile base tools!")
            if self.verbose:
                print(" - {}".format(out[1]))
            return return_dict
        # Setup UDK
        print("Setting up UDK...")
        cwd = os.getcwd()
        os.chdir(self.udk_path)
        # Let's make sure we set our toolchain directory and main tool dir
        os.environ["TOOLCHAIN_DIR"] = os.path.join(self.source, "opt", "local")
        os.environ["DIR_MAIN"] = self.source
        out = self.r.run({"args":["bash", "-c", "source edksetup.sh"], "stream":self.debug})
        if out[2] != 0:
            print("Failed to setup UDK!")
            if self.verbose:
                print(" - {}".format(out[1]))
            return return_dict
        # Build gettext, mtoc, and nasm (if needed)
        os.chdir(self.c_path)
        if not os.path.exists(os.path.join(self.source, "opt", "local", "bin", "gettext")):
            print(" - Building gettext...")
            out = self.r.run({"args":["bash", "buildgettext.sh"], "stream":self.debug})
            if out[2] != 0:
                print("Failed to build gettext!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                return return_dict
        if not os.path.exists(os.path.join(self.source, "opt", "local", "bin", "mtoc.NEW")):
            print(" - Building mtoc...")
            out = self.r.run({"args":["bash", "buildmtoc.sh"], "stream":self.debug})
            if out[2] != 0:
                print("Failed to build mtoc!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                return return_dict
        if not os.path.exists(os.path.join(self.source, "opt", "local", "bin", "nasm")):
            print(" - Building nasm...")
            out = self.r.run({"args":["bash", "buildnasm.sh"], "stream":self.debug})
            if out[2] != 0:
                print("Failed to build nasm!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                return return_dict
        # Install UDK patches
        print("Installing UDK patches...")
        out = self.r.run({"args":"cp -R \"{}\"/Patches_for_UDK2018/* ../".format(self.c_path), "stream":self.debug, "shell":True})
        if out[2] != 0:
            print("Failed to install UDK patches!")
            return return_dict
        # ApfsDriverLoader is built, and replaced - let's avoid building it here
        print("Patching Clover.dsc to remove ApfsDriverLoader (we build it manually)...")
        apfs_path = "Clover/FileSystems/ApfsDriverLoader/ApfsDriverLoader.inf"
        # Let's patch out their inclusion in Clover.dsc
        with open(os.path.join(self.c_path,"Clover.dsc"),"r") as f:
            clover_dsc = f.read()
        lines = "\n".join([x for x in clover_dsc.split("\n") if not x.strip().lower().startswith(apfs_path.lower())])
        if len(lines) == len(clover_dsc):
            print(" - Did not find ApfsDriverLoader - no changes made")
        else:
            # Line count changed - we edited something
            print(" - Found and omitted ApfsDriverLoader in Clover.dsc")
            with open(os.path.join(self.c_path,"Clover.dsc"),"w") as f:
                f.write(lines)
        print("Cleaning Clover...")
        out = self.r.run([
            {"args":["bash", "ebuild.sh", "-cleanall"], "stream":self.debug},
            {"args":["bash", "ebuild.sh", "-fr"], "stream":self.debug}
        ], True)
        if type(out) is list:
            out = out[-1]
        if out[2] != 0:
            print("Failed to clean Clover!")
            if self.verbose:
                print(" - {}".format(out[1]))
            return return_dict
        # Build the EFI drivers
        self.build_efi_drivers()
        # Download EFI drivers
        print("Downloading other EFI drivers...")
        for e in ["apfs.efi", "NTFS.efi", "HFSPlus_x64.efi"]:
            print(" --> {}".format(e.replace("_x64", "")))
            self.r.run({"args":"curl -sSLk https://github.com/Micky1979/Build_Clover/raw/work/Files/{} > \"{}\"/UEFI/FileSystem/{}".format(e, self.ce_path, e.replace("_x64", "")), "shell":True})
        # Copy over the other EFI drivers
        print("Copying other EFI drivers...")
        for e in ["apfs.efi", "NTFS.efi", "HFSPlus.efi"]:
            print(" --> {}".format(e))
            shutil.copy(os.path.join(self.ce_path, "UEFI", "FileSystem", e), os.path.join(self.ce_path, "BIOS", "FileSystem", e))
        os.chdir(self.out)
        if pkg:
            print("Building Clover install package...")
            print(" - Patching makepkg to avoid opening resulting folder...")
            try:
                new_mpkg = ""
                with open("../makepkg","r") as f:
                    for line in f:
                        if not line.lower().startswith("open"):
                            new_mpkg += line
                with open("../makepkg","w") as f:
                    f.write(new_mpkg)
                print(" --> Patching Complete :)")
            except:
                print(" --> Patching failed :(")
            print(" - Running makepkg...")
            out = self.r.run({"args":["bash", "../makepkg"], "stream":self.debug})
            if out[2] != 0:
                print("Failed to create Clover install package!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                return return_dict
            try:
                pack = out[0].split("Package name: [39;49;00m")[1].split("\n")[0].replace("\n", "").replace("\r", "")
            except:
                pack = None
            if pack != None and os.path.exists(pack):
                print("\nBuilt {}!\n".format(pack))
                return_dict["pkg"] = os.path.join(self.out, pack)
        if iso:
            print("Building Clover ISO...")
            print(" - Patching makeiso to avoid opening resulting folder...")
            try:
                new_miso = ""
                with open("../makeiso","r") as f:
                    for line in f:
                        if not "open sym" in line.lower():
                            new_miso += line
                with open("../makeiso","w") as f:
                    f.write(new_miso)
                print(" --> Patching Complete :)")
            except:
                print(" --> Patching failed :(")
            print(" - Running makeiso...")
            out = self.r.run({"args":["bash", "../makeiso"], "stream":self.debug})
            if out[2] != 0:
                print("Failed to create Clover ISO!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                return return_dict
            try:
                pack = "CloverISO-"+out[0].split("CloverISO-")[1].split("\n")[0].replace("\n", "").replace("\r", "")
                iso_file = [x for x in os.listdir(pack) if x.lower().endswith(".iso") and not x.startswith(".")][0]
                pack = os.path.join(self.out,pack,iso_file)
            except:
                pack = None
            if pack != None and os.path.exists(pack):
                print("\nBuilt CloverISO-{}!\n".format(os.path.basename(pack)))
                return_dict["iso"] = pack
        return return_dict
