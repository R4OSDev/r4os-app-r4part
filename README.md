# R4PART

R4PART is the R4OS console tool for partition and volume maintenance. It runs
in the standard Terminal, SSH and the Recovery monitor console. Enter `HELP`
for the supported commands; `EXIT` returns to the caller.

The tool lists actual disks, partitions and volumes, selects stable targets,
edits GPT and primary MBR tables, formats FAT32/NTFS, manages mount letters
and changes IDs, types, GPT attributes and MBR active flags. Every destructive
operation shows its target and requires `YES DISK n [PARTITION n]`.

`SIZE` uses MB (1024 KB); `OFFSET` uses KB. New partition starts align to 1 MB.
Quick/full formatters use the shared SDK and bounded working memory. Physical
I/O always passes through a generation-bound R4SYS storage claim.

`OFFLINE` flushes and unmounts the selected disk/partition. This shared mount
state remains after exit. `ONLINE` mounts the selected partition or supported
partitions of a disk. Reserved/running volumes and open transfers are checked
by the common storage layer. An explicit later mount can bring a volume online.

`EXTEND [SIZE=MB]` grows an offline NTFS volume into adjacent free space,
keeping its start and IDs. It plans bitmap relocation, duplicated metadata
and both boot sectors before writing, then revalidates under an exclusive
claim. A successful mounted target regains its previous letter. Dirty or
unsupported volumes are rejected; interruption after writes begin can require
manual NTFS/partition-table repair. See the SDK maintenance contract.

`SHRINK QUERYMAX` reads the real allocation bitmap and MFT runlists. It
reports the supported maximum reduction and minimum volume size. Existing
file and other metadata clusters remain fixed; the bitmap may move into a
verified free extent. `SHRINK DESIRED=MB` removes exactly that amount; omitting
DESIRED chooses the current maximum. Out-of-range/busy targets reject before
writing. The smaller filesystem is durable before its partition gives away
any tail sectors. File contents and the old drive letter survive success.

`CHECK GPT` inspects both copies and their CRCs, geometry and correspondence.
`REPAIR GPT` restores only a damaged counterpart from one intact copy; it
refuses ambiguous tables and preserves the surviving copy and protective MBR.

`R4PART /S "C:\TEMP\PART.TXT"` preloads a bounded UTF-8 script into RAM.
Each mutation requires its own explicit confirmation line. The first error,
including failed selection or missing confirmation, stops with exit code 1;
success returns 0. `HELP` includes the full contract and examples.

Build in the R4OS workspace using `./Build.sh` on Linux or `Build.bat` on
Windows with PowerShell 7. `Settings.R4S` maps the companion SDK, Contract,
DevKit and output directory. Both starters invoke one `Build.ps1`. `test`
runs the bounded command validation/confirmation component fixture.
The module manifest includes R4PART in Slim, Full and Test images.

The production application has no privileged host-disk access. Guest tests
use disposable QEMU disks; the operator selects real guest targets at runtime.

R4OS source is Apache-2.0. See LICENSE, NOTICE, THIRD_PARTY_NOTICES.md and
DOCUMENTATION.de.txt. SDK metadata provenance remains with its owner.
