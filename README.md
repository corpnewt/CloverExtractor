# CloverExtractor
Small py script to extract CLOVERX64.efi from an install package and copy it to a target drive's EFI partition.

***

## To install:

Do the following one line at a time in Terminal:

    git clone https://github.com/corpnewt/CloverExtractor
    cd CloverExtractor
    chmod +x CloverExtractor.command
    
Then run with either `./CloverExtractor.command` or by double-clicking *CloverExtractor.command*

***

## Usage:

Starting the script with no arguments will open it in interactive mode.

If you want it to auto extract & copy, you can pass pairs of arguments to it like so (assumes you have Clover.pkg on the Desktop, and plan to extract it to the boot drive's EFI):

    ./CloverExtractor.command ~/Desktop/Clover.pkg /
    
You can also pass multiple sets of argument pairs to extract multiple Clover packages to EFIs.  With our above example, if we also wanted to extract that same package to `disk5`'s EFI, we could do:

    ./CloverExtractor.command ~/Desktop/Clover.pkg / ~/Desktop/Clover.pkg disk5

***

## Thanks To:

* Slice, apianti, vit9696, Download Fritz, Zenith432, STLVNUB, JrCs,cecekpawon, Needy, cvad, Rehabman, philip_petev, ErmaC and the rest of the Clover crew for Clover and bdmesg
