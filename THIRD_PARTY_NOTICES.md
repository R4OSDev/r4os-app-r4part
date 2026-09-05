# Third-party notices

R4PART's new application source is R4OS Apache-2.0 code. It statically uses
the R4OS SDK's shared partitioning and filesystem formatter. The SDK includes
16 volume-independent NTFS metadata templates copied byte-for-byte from its
existing Windows-generated reference fixture. These are filesystem data,
not Microsoft executable or formatter source code. Their original generation
log, fixture manifest and per-template SHA-256 receipt remain in the SDK.
See `r4os/storage_tools/ntfs_metadata/provenance.json` and the SDK notices.
No Windows executable, proprietary formatter or additional third-party
partitioning program is distributed by this repository.
