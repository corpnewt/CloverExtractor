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
        # Setup the Clover repo
        self.c_repo     = kwargs.get("clover_repo", "https://github.com/CloverHackyColor/CloverBootloader")
        self.c_path     = kwargs.get("clover_path", "Clover")
        self.c_path     = os.path.join(self.source, self.c_path)
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

    def update_clover(self):
        # Updates Clover - or clones it if it doesn't exist
        if not os.path.exists(os.path.join(self.c_path, ".git")):
            # Clone!
            print("Checking out a shiny new copy of Clover...")
            out = self.r.run({"args":["git", "clone", self.c_repo, self.c_path], "stream":self.debug})
            if out[2] != 0:
                print("Failed to check out Clover!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                return False
        # Already cloned once - just update
        print("Updating Clover...")
        cwd = os.getcwd()
        os.chdir(self.c_path)
        rev = self.get_clover_revision()
        if not rev:
            print("No Clover revision located!")
            os.chdir(cwd)
            return False
        out = self.r.run([
            {"args":["git","fetch","--all"],"stream":self.debug},
            {"args":["git","reset","--hard","origin/master"],"stream":self.debug},
            {"args":["git","pull","origin","master"],"stream":self.debug}
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
        if not os.path.exists(os.path.join(self.c_path, ".git")):
            return None
        cwd = os.getcwd()
        os.chdir(self.c_path)
        rev = self.r.run({"args":["git","describe","--tags","--abbrev=0"]})[0].strip()
        os.chdir(cwd)
        return rev if rev else None

    def build_efi_driver(self, driver, ret = "out"):
        cwd = os.getcwd()
        os.chdir(self.source)
        try:
            if not all(key in driver for key in ["repo", "path", "out", "name", "run", "lang", "sa"]):
                print("Driver missing info - skipping...")
                raise Exception()
            print("{}...".format(driver["path"]))
            if not os.path.exists(os.path.join(self.source, driver["path"], ".git")):
                # Clone it
                print(" - Checking out a shiny new copy of {}".format(driver["path"]))
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
            if driver.get("commit",None):
                print(" - Resetting to {} commit".format(driver.get("commit")))
                self.r.run({"args":["git", "reset", "--hard", driver.get("commit")],"stream":self.debug})
            # Chmod
            self.r.run({"args":["chmod", "+x", driver["run"]]})
            # Prerun
            if driver.get("prerun",None):
                print(" - Running preliminary tasks...")
                tasks = driver.get("prerun",[])
                if not isinstance(tasks,list):
                    tasks = [tasks]
                for x,y in enumerate(tasks):
                    print(" --> {} of {}:  {}".format(x+1,len(tasks),y.get("name","Unnamed")))
                    out = self.r.run({"args":y.get("run",[])})
                    if out[2] != 0:
                        print(" ----> Failed!")
                        if self.verbose:
                            print(" ------> {}".format(out[1]))
                        raise Exception()
            print(" - Building...")
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
        print("Building EFI drivers...")
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
        os.chdir(cwd)

    def build_clover(self, pkg=True, iso=False):
        # Preliminary updates
        return_dict = {}
        if not self.update_clover():
            # Updates failed :(
            return return_dict
        cwd = os.getcwd()
        os.chdir(self.c_path)
        # Setup UDK
        print("Setting up environment variables...")
        os.chdir(self.c_path)
        # Let's export our paths - save the original values first
        saved_env = [(x,os.environ.get(x,None)) for x in ("TOOLCHAIN_DIR","DIR_MAIN","DIR_TOOLS","DIR_DOWNLOADS","DIR_LOGS","PREFIX","EDK_TOOLS_PATH","PATH","GETTEXT_PREFIX")]
        os.environ["TOOLCHAIN_DIR"] = os.path.join(self.source, "opt", "local")
        os.environ["DIR_MAIN"] = self.source
        os.environ["DIR_TOOLS"] = os.path.join(self.source, "tools")
        os.environ["DIR_DOWNLOADS"] = os.path.join(os.environ["DIR_TOOLS"],"download")
        os.environ["DIR_LOGS"] = os.path.join(os.environ["DIR_TOOLS"],"logs")
        os.environ["PREFIX"] = os.environ["TOOLCHAIN_DIR"]
        os.environ["EDK_TOOLS_PATH"] = os.path.join(self.c_path,"BaseTools")
        # The following is a bit hacky - but it includes the proper path for the "build" command
        os.environ["PATH"] = os.environ["PATH"] + ":" + os.path.join(self.c_path,"BaseTools","BinWrappers","PosixLike")
        # Add the gettext prefix for our tools
        os.environ["GETTEXT_PREFIX"] = os.environ["TOOLCHAIN_DIR"]
        # Source edksetup.sh with BaseTools - may be completely broken currently :/
        out = self.r.run({"args":["bash", "-c", "source edksetup.sh BaseTools"], "stream":self.debug})
        if out[2] != 0:
            print("Failed to setup environment!")
            if self.verbose:
                print(" - {}".format(out[1]))
            os.chdir(cwd)
            return return_dict
        # Build gettext, mtoc, and nasm (if needed)
        if not os.path.exists(os.path.join(self.source, "opt", "local", "bin", "gettext")):
            print(" - Building gettext...")
            out = self.r.run({"args":["bash", "buildgettext.sh"], "stream":self.debug})
            if out[2] != 0:
                print("Failed to build gettext!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                os.chdir(cwd)
                return return_dict
        if not os.path.exists(os.path.join(self.source, "opt", "local", "bin", "mtoc.NEW")):
            print(" - Building mtoc...")
            out = self.r.run({"args":["bash", "buildmtoc.sh"], "stream":self.debug})
            if out[2] != 0:
                print("Failed to build mtoc!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                os.chdir(cwd)
                return return_dict
        if not os.path.exists(os.path.join(self.source, "opt", "local", "bin", "nasm")):
            print(" - Building nasm...")
            out = self.r.run({"args":["bash", "buildnasm.sh"], "stream":self.debug})
            if out[2] != 0:
                print("Failed to build nasm!")
                if self.verbose:
                    print(" - {}".format(out[1]))
                os.chdir(cwd)
                return return_dict
        # Build Clover itself
        print("Building Clover...")
        out = self.r.run([
            {"args":["bash", "ebuild.sh", "-fr","-mc","--no-usb","-D","NO_GRUB_DRIVERS_EMBEDDED","-t","XCODE8"], "stream":self.debug},
            {"args":["bash", "ebuild.sh", "-fr","-D","NO_GRUB_DRIVERS_EMBEDDED","-t","XCODE8"], "stream":self.debug}
        ], True)
        if type(out) is list:
            out = out[-1]
        if out[2] != 0:
            print("Failed to build Clover!")
            if self.verbose:
                print(" - {}".format(out[1]))
            os.chdir(cwd)
            return return_dict
        # Build the EFI drivers
        # Dump the prior values in os.environ
        for x,y in saved_env:
            if y is None:
                os.environ.pop(x,None)
            else:
                os.environ[x] = y
        self.build_efi_drivers()
        # Download EFI drivers
        print("Downloading other EFI drivers...")
        for e in ["NTFS.efi", "HFSPlus_x64.efi"]:
            print(" --> {}".format(e.replace("_x64", "")))
            self.r.run({"args":"curl -sSLk https://github.com/Micky1979/Build_Clover/raw/work/Files/{} > \"{}\"/UEFI/FileSystem/{}".format(e, self.ce_path, e.replace("_x64", "")), "shell":True})
        # Copy over the other EFI drivers
        print("Copying other EFI drivers...")
        for e in ["NTFS.efi", "HFSPlus.efi"]:
            print(" --> {}".format(e))
            shutil.copy(os.path.join(self.ce_path, "UEFI", "FileSystem", e), os.path.join(self.ce_path, "BIOS", "FileSystem", e))
        # Ensure the sym folder exists before we chdir into it
        if not os.path.exists(self.out):
            os.makedirs(self.out)
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
            try:
                pack = out[0].split("Package name: [39;49;00m")[1].split("\n")[0].replace("\n", "").replace("\r", "")
            except:
                pack = None
            os.chdir(self.out)
            if pack != None and os.path.exists(pack):
                print("\nBuilt {}!\n".format(pack))
                return_dict["pkg"] = os.path.join(self.out, pack)
            else:
                print("No Clover pkg found :(")
        os.chdir(self.out)
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
            try:
                pack = "CloverISO-"+out[0].split("CloverISO-")[1].split("\n")[0].replace("\n", "").replace("\r", "")
                iso_file = [x for x in os.listdir(pack) if x.lower().endswith(".iso") and not x.startswith(".")][0]
                pack = os.path.join(self.out,pack,iso_file)
            except:
                pack = None
            if pack != None and os.path.exists(pack):
                print("\nBuilt CloverISO-{}!\n".format(os.path.basename(pack)))
                return_dict["iso"] = pack
            else:
                print("No Clover ISO located :(")
        os.chdir(cwd)
        return return_dict
