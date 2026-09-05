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

Build in the R4OS workspace using `./Build.sh` on Linux or `Build.bat` on
Windows with PowerShell 7. `Settings.R4S` maps the companion SDK, Contract,
DevKit and output directory. Both starters invoke one `Build.ps1`. `test`
runs the bounded command validation/confirmation component fixture.
The module manifest includes R4PART in Slim, Full and Test images.

The production application has no privileged host-disk access. Guest tests
use disposable QEMU disks; the operator selects real guest targets at runtime.

R4OS source is Apache-2.0. See LICENSE, NOTICE, THIRD_PARTY_NOTICES.md and
DOCUMENTATION.de.txt. SDK metadata provenance remains with its owner.
