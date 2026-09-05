const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const tools = r4os.storage_tools;
const table = tools.partition;
const command = @import("command.zig");
const Input = @import("input.zig").Input;
const Command = command.Command;
const script = @import("script.zig");
const GuestTarget = r4os.storage_tools_guest.Target;
const State = struct {
    sys: r4os.r4sys.Context,
    input: Input = .{},
    disk: ?abi.StorageDeviceInfo = null,
    part: ?abi.StoragePartitionInfo = null,
    volume: ?abi.StorageVolumeInfo = null,
    work: []u8,
    native_error: i32 = 0,
    progress: tools.io.Progress = .{},
    last_progress: u64 = 0,
    identifier_counter: u64 = 0,
    exit_requested: bool = false,
    batch: ?script.Script = null,

    fn storage(self: *State) r4os.storage.Context {
        return .{ .sys = &self.sys };
    }
    fn print(self: *State, comptime fmt: []const u8, args: anytype) void {
        var text: [1024]u8 = undefined;
        self.sys.write(std.fmt.bufPrint(&text, fmt, args) catch "R4PART: output too long\r\n");
    }
    fn check(self: *State, value: i32, expected: i32) !void {
        if (value == expected) return;
        self.native_error = value;
        return error.Storage;
    }
    fn inventory(self: *State) !abi.StorageInventory {
        var result: abi.StorageInventory = .{};
        try self.check(self.storage().inventory(&result), 0);
        return result;
    }
    fn readDisk(self: *State, slot: u32) !abi.StorageDeviceInfo {
        const inv = try self.inventory();
        var disk: abi.StorageDeviceInfo = .{};
        try self.check(self.storage().device(inv.generation, slot, &disk), 1);
        return disk;
    }
    fn selectedDisk(self: *State) !abi.StorageDeviceInfo {
        const old = self.disk orelse return error.SelectDisk;
        const fresh = self.readDisk(old.reference.slot) catch |err| {
            self.clear();
            return err;
        };
        if (!std.meta.eql(old.reference, fresh.reference) or old.layout_generation != fresh.layout_generation or
            !std.mem.eql(u8, &old.disk_guid, &fresh.disk_guid) or old.sector_count != fresh.sector_count)
        {
            self.clear();
            return error.SelectionChanged;
        }
        return fresh;
    }
    fn clear(self: *State) void {
        self.disk = null;
        self.part = null;
        self.volume = null;
    }
    fn readPart(self: *State, disk: abi.StorageDeviceInfo, number: u32) !abi.StoragePartitionInfo {
        const inv = try self.inventory();
        for (0..disk.partition_slots) |i| {
            var part: abi.StoragePartitionInfo = .{};
            try self.check(self.storage().partition(inv.generation, &disk.reference, @intCast(i), &part), 1);
            if (part.target.partition_number == number) return part;
        }
        return error.SelectPartition;
    }
    fn selectedPart(self: *State) !abi.StoragePartitionInfo {
        const disk = try self.selectedDisk();
        const old = self.part orelse return error.SelectPartition;
        const part = try self.readPart(disk, old.target.partition_number);
        if (!std.meta.eql(old.target, part.target)) {
            self.clear();
            return error.SelectionChanged;
        }
        return part;
    }
    fn refreshOwned(self: *State, reference: abi.StorageDeviceRef, number: ?u32) !void {
        self.clear();
        const disk = try self.readDisk(reference.slot);
        if (!std.meta.eql(reference, disk.reference)) return error.SelectionChanged;
        self.disk = disk;
        if (number) |n| self.part = self.readPart(disk, n) catch null;
    }
    fn loadTable(self: *State, target: *GuestTarget) !*table.Plan {
        const plan = try self.sys.allocator().create(table.Plan);
        errdefer self.sys.allocator().destroy(plan);
        plan.* = try table.Plan.read(target.device(null), self.work);
        return plan;
    }
    fn whole(self: *State) !GuestTarget {
        return .{ .storage = self.storage(), .target = r4os.storage.Context.wholeDevice(try self.selectedDisk()) };
    }
    fn region(self: *State) !GuestTarget {
        return .{ .storage = self.storage(), .target = (try self.selectedPart()).target };
    }
    fn finish(self: *State, target: *GuestTarget, keep_unmounted: bool, number: ?u32) !void {
        const rc = target.release(keep_unmounted);
        if (rc != 0) {
            self.native_error = rc;
            self.clear();
            return error.CompletionFailed;
        }
        try self.refreshOwned(target.target.device, number);
    }
    fn failedClose(self: *State, target: *GuestTarget) void {
        if (target.claim == 0) return;
        const rc = target.release(true);
        self.clear();
        if (rc != 0) self.print("R4PART: cleanup failed code={d}; target remains uncertain.\r\n", .{rc});
    }
    fn executionDevice(self: *State, target: *GuestTarget) tools.io.Device {
        self.progress = .{};
        self.last_progress = self.sys.ticks();
        var device = target.device(&self.progress);
        device.cancel_context = self;
        device.continue_fn = continueWork;
        return device;
    }
    fn continueWork(raw: ?*anyopaque, phase: tools.io.Phase, written: u64) bool {
        const self: *State = @ptrCast(@alignCast(raw.?));
        if (self.input.cancelled(&self.sys)) return false;
        const now = self.sys.ticks();
        if (now -| self.last_progress >= self.sys.ticksFromMilliseconds(1000)) {
            self.print("Working: {s}, {d} MB written\r\n", .{ @tagName(phase), written / 2048 });
            self.last_progress = now;
        }
        return true;
    }
    fn confirm(self: *State, action: []const u8, target: abi.StorageTarget) !void {
        const disk = try self.selectedDisk();
        self.print("\r\n{s}\r\nDisk {d}: {s} {s}, {d} MB, GUID {s}\r\n", .{ action, disk.reference.slot, span(&disk.name), span(&disk.model), disk.sector_count / 2048, table.guid.format(disk.disk_guid) });
        if (target.kind == abi.storage_target_partition)
            self.print("Partition {d}: first LBA {d}, sectors {d}, GUID {s}\r\n", .{ target.partition_number, target.first_lba, target.sector_count, table.guid.format(target.partition_guid) });
        self.sys.write("Existing data in the indicated target may be lost.\r\n");
        var expected_buf: [80]u8 = undefined;
        const expected = try command.confirmation(&expected_buf, disk.reference.slot, if (target.kind == abi.storage_target_partition) target.partition_number else null);
        self.print("Type {s} to continue: ", .{expected});
        var answer: [128]u8 = undefined;
        const line = try self.nextLine(&answer) orelse return error.MissingConfirmation;
        if (!command.confirmed(expected, line)) return error.Cancelled;
        // The subsequent claim validates the same complete generation-bound
        // target. A confirmation never authorises a replacement device.
    }
    fn nextLine(self: *State, out: []u8) !?[]const u8 {
        if (self.batch) |*batch| {
            const line = try batch.next() orelse return null;
            self.print("[line {d}] {s}\r\n", .{ batch.line_number, line });
            return line;
        }
        return self.input.line(&self.sys, out);
    }
    fn runScript(self: *State, path: []const u8) !void {
        var path_z: [512:0]u8 = .{0} ** 512;
        @memcpy(path_z[0..path.len], path);
        const bytes = try self.sys.allocator().alloc(u8, script.max_bytes + 1);
        defer self.sys.allocator().free(bytes);
        const got = self.sys.fileRead(&path_z, bytes);
        if (got < 0) return error.ScriptRead;
        self.batch = try script.Script.init(bytes[0..@intCast(got)]);
        defer self.batch = null;
        errdefer self.print("Script stopped at line {d}.\r\n", .{self.batch.?.line_number});
        while (!self.exit_requested) {
            const line = try self.nextLine(&.{}) orelse break;
            const cmd = try command.parse(line);
            try self.execute(cmd);
        }
    }
    fn gpt(self: *State, repair: bool) !void {
        var target = try self.whole();
        const inspection = try tools.gpt_repair.Report.read(self.sys.allocator(), self.executionDevice(&target));
        defer inspection.deinit();
        for (&inspection.copies, 0..) |*copy, i| self.print("GPT {s}: {s}\r\n", .{
            if (i == 0) "primary" else "backup", if (copy.reason) |err| @errorName(err) else "valid",
        });
        if (inspection.mbr_reason) |err| self.print("Protective MBR: {s}\r\n", .{@errorName(err)});
        self.print("GPT status: {s}\r\n", .{@tagName(inspection.status)});
        if (inspection.status == .healthy) return;
        _ = try inspection.repairable();
        if (!repair) return error.GptRepairRequired;
        try self.confirm("REPAIR GPT: restore the damaged copy from its intact counterpart", target.target);
        try self.check(target.acquire(), 0);
        errdefer self.failedClose(&target);
        try inspection.repair(self.executionDevice(&target), self.work);
        try self.finish(&target, false, null);
        self.sys.write("GPT repair verified; surviving copy and protective MBR preserved.\r\n");
    }
    fn freshGuid(self: *State) [16]u8 {
        self.identifier_counter +%= 1;
        var value: [16]u8 = undefined;
        if (!r4os.web_crypto.fillSecureRandom(&value)) {
            // An identifier, not a cryptographic secret. The fallback combines
            // the monotonic counter, execution address and timestamp counter.
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            asm volatile ("rdtsc"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
            );
            const seed = [_]u64{ self.sys.ticks(), @as(u64, hi) << 32 | lo, @intFromPtr(self), self.identifier_counter };
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(std.mem.asBytes(&seed), &digest, .{});
            @memcpy(&value, digest[0..16]);
        }
        value[7] = (value[7] & 15) | 0x40;
        value[8] = (value[8] & 63) | 0x80;
        return value;
    }
    fn listDisks(self: *State) !void {
        const inv = try self.inventory();
        self.sys.write("Disk  Size MB   Free MB   Table  Device / model / bus\r\n");
        for (0..inv.device_slots) |slot| {
            var disk: abi.StorageDeviceInfo = .{};
            const rc = self.storage().device(inv.generation, @intCast(slot), &disk);
            if (rc == 0) continue;
            try self.check(rc, 1);
            if (disk.flags & abi.storage_device_ram != 0) continue;
            var adapter = GuestTarget{ .storage = self.storage(), .target = r4os.storage.Context.wholeDevice(disk) };
            const plan = self.loadTable(&adapter) catch null;
            defer if (plan) |p| self.sys.allocator().destroy(p);
            var free: ?u64 = null;
            if (plan) |p| {
                var ranges: [129]table.Range = undefined;
                const n = p.freeRanges(&ranges) catch 0;
                free = 0;
                for (ranges[0..n]) |range_| free.? += range_.count;
            }
            self.print(" {d}   {d}    ", .{ slot, disk.sector_count / 2048 });
            if (free) |n| self.print("{d}", .{n / 2048}) else self.sys.write("?");
            self.print("   {s}   {s} {s} [{s}]\r\n", .{ scheme(disk.flags), span(&disk.name), span(&disk.model), bus(disk.bus) });
            if (disk.reason[0] != 0) self.print("     {s}\r\n", .{span(&disk.reason)});
        }
        if (inv.flags & abi.storage_inventory_partial != 0) self.sys.write("Inventory is partial; incomplete targets cannot be edited.\r\n");
    }
    fn listParts(self: *State) !void {
        const disk = try self.selectedDisk();
        const inv = try self.inventory();
        self.sys.write("Partition  Start MB   Size MB   Filesystem   Name\r\n");
        for (0..disk.partition_slots) |i| {
            var part: abi.StoragePartitionInfo = .{};
            try self.check(self.storage().partition(inv.generation, &disk.reference, @intCast(i), &part), 1);
            var name: [72]u8 = undefined;
            self.print(" {d}    {d}    {d}    {s}    {s}\r\n", .{ part.target.partition_number, part.target.first_lba / 2048, part.target.sector_count / 2048, filesystem(part.filesystem), partitionName(&name, part.name) });
        }
    }
    fn listVolumes(self: *State) !void {
        const inv = try self.inventory();
        self.sys.write("Volume  Letter  Size MB  Free MB  Filesystem  Name\r\n");
        for (0..inv.volume_slots) |slot| {
            var vol: abi.StorageVolumeInfo = .{};
            const rc = self.storage().volume(inv.generation, @intCast(slot), &vol);
            if (rc == 0) continue;
            try self.check(rc, 1);
            const drive = if (slot < 26) self.sys.driveInfo(@intCast(slot)) else null;
            self.print(" {d}    {c}    {d}    ", .{ slot, @as(u8, if (vol.letter == 0) '-' else @intCast(vol.letter)), vol.target.sector_count / 2048 });
            if (drive) |d| self.print("{d}    {s}    {s}", .{ d.free_bytes / (1024 * 1024), filesystem(vol.filesystem), span(&d.name) }) else self.print("?    {s}", .{filesystem(vol.filesystem)});
            self.print("{s}\r\n", .{if (vol.flags & abi.storage_volume_required != 0) " [running / protected]" else ""});
        }
    }
    fn select(self: *State, cmd: Command) !void {
        errdefer self.clear();
        switch (cmd.object) {
            .disk => {
                const number = try smallNumber(cmd.argument, 10);
                const disk = try self.readDisk(number);
                if (disk.flags & abi.storage_device_ram != 0) return error.Protected;
                self.clear();
                self.disk = disk;
                self.print("Disk {d} selected.\r\n", .{number});
            },
            .partition => {
                const part = try self.readPart(try self.selectedDisk(), try smallNumber(cmd.argument, 10));
                self.part = part;
                self.volume = null;
                self.print("Partition {d} selected.\r\n", .{part.target.partition_number});
            },
            .volume => {
                const letter = command.driveLetter(cmd.argument) catch 0;
                const number: u32 = if (letter != 0) letter - 'A' else try smallNumber(cmd.argument, 10);
                const inv = try self.inventory();
                var vol: abi.StorageVolumeInfo = .{};
                try self.check(self.storage().volume(inv.generation, number, &vol), 1);
                const disk = try self.readDisk(vol.target.device.slot);
                self.clear();
                self.disk = disk;
                self.volume = vol;
                if (vol.target.kind == abi.storage_target_partition) self.part = try self.readPart(disk, vol.target.partition_number);
                self.print("Volume {d} selected.\r\n", .{number});
            },
            else => return error.Syntax,
        }
    }
    fn detail(self: *State, wanted: command.Object) !void {
        const disk = try self.selectedDisk();
        const object = if (wanted == .current) (if (self.volume != null) command.Object.volume else if (self.part != null) command.Object.partition else command.Object.disk) else wanted;
        self.print("Disk {d}: {s} {s}\r\nBus: {s}; driver: {s}; sectors: {d} x {d}\r\nGUID: {s}; layout generation: {d}\r\nTable: {s}; status: {s}\r\n", .{ disk.reference.slot, span(&disk.name), span(&disk.model), bus(disk.bus), span(&disk.driver), disk.sector_count, disk.sector_bytes, table.guid.format(disk.disk_guid), disk.layout_generation, scheme(disk.flags), span(&disk.reason) });
        if (object == .partition or (object == .volume and self.part != null)) {
            const part = try self.selectedPart();
            self.print("Partition {d}: first LBA {d}, sectors {d}\r\nID: {s}\r\nType: {s}; MBR type: {x}\r\nAttributes: 0x{x}; filesystem: {s}\r\n", .{ part.target.partition_number, part.target.first_lba, part.target.sector_count, table.guid.format(part.target.partition_guid), table.guid.format(part.type_guid), part.mbr_type, part.attributes, filesystem(part.filesystem) });
        }
        if (object == .volume) try self.listVolumes() else if (object == .disk) try self.listParts();
    }
    fn editTable(self: *State, cmd: Command) !void {
        var target = try self.whole();
        const plan = try self.loadTable(&target);
        defer self.sys.allocator().destroy(plan);
        var selected: ?u32 = if (self.part) |p| p.target.partition_number else null;
        var affected = target.target;
        switch (cmd.verb) {
            .create => {
                var ranges: [129]table.Range = undefined;
                const n = try plan.freeRanges(&ranges);
                var start: ?u64 = null;
                var size: u64 = 0;
                for (ranges[0..n]) |range_| {
                    const first = cmd.offset_sectors orelse std.mem.alignForward(u64, range_.first, 2048);
                    if (first < range_.first or first >= range_.first + range_.count) continue;
                    const available = range_.first + range_.count - first;
                    const length = cmd.size_sectors orelse available;
                    if (length > available) continue;
                    start = first;
                    size = length;
                    break;
                }
                const first = start orelse return error.NoSpace;
                var entry = table.Entry{ .present = true, .first = first, .count = size };
                if (plan.kind == .gpt) {
                    entry.type_guid = if (cmd.type_id) |id| try parseGuid(id) else if (command.same(cmd.argument, "EFI")) table.esp_type else if (command.same(cmd.argument, "BIOS")) table.bios_type else table.basic_type;
                    entry.unique_guid = if (cmd.id) |id| try parseGuid(id) else self.freshGuid();
                    entry.name = try table.asciiName(cmd.name);
                } else if (plan.kind == .mbr and command.same(cmd.argument, "PRIMARY")) {
                    if (cmd.id != null or cmd.name.len != 0) return error.Syntax;
                    entry.mbr_type = if (cmd.type_id) |id| try byteNumber(id, 16) else 7;
                } else return error.UnsupportedTable;
                selected = try plan.add(entry);
                self.print("Planned partition {d}: first LBA {d}, sectors {d} ({d} MB).\r\n", .{ selected.?, first, size, size / 2048 });
            },
            .delete => {
                affected = (try self.selectedPart()).target;
                try plan.remove(affected.partition_number);
                selected = null;
            },
            .convert => {
                const kind: table.Kind = if (command.same(cmd.argument, "GPT")) .gpt else .mbr;
                const fresh = self.freshGuid();
                try plan.convertEmpty(kind, if (cmd.id) |id| (if (kind == .gpt) try parseGuid(id) else fresh) else fresh, if (cmd.id) |id| (if (kind == .mbr) try smallNumber(id, 16) else 1) else @max(@as(u32, 1), std.mem.readInt(u32, fresh[0..4], .little)));
                selected = null;
            },
            .unique_id => {
                if (cmd.id == null) {
                    if (cmd.object == .disk and plan.kind == .mbr) self.print("Disk ID: {x:0>8}\r\n", .{plan.disk_id}) else if (cmd.object == .disk) self.print("Disk ID: {s}\r\n", .{table.guid.format(plan.disk_guid)}) else self.print("Partition ID: {s}\r\n", .{table.guid.format((try self.selectedPart()).target.partition_guid)});
                    return;
                }
                if (cmd.object == .disk) {
                    if (plan.kind == .gpt) plan.disk_guid = try parseGuid(cmd.id.?) else if (plan.kind == .mbr) plan.disk_id = try smallNumber(cmd.id.?, 16) else return error.UnsupportedTable;
                } else {
                    affected = (try self.selectedPart()).target;
                    if (plan.kind != .gpt) return error.UnsupportedTable;
                    (try plan.get(affected.partition_number)).unique_guid = try parseGuid(cmd.id.?);
                }
            },
            .set_type, .attributes, .active, .inactive => {
                affected = (try self.selectedPart()).target;
                const entry = try plan.get(affected.partition_number);
                switch (cmd.verb) {
                    .set_type => if (plan.kind == .gpt) {
                        entry.type_guid = try parseGuid(cmd.id.?);
                    } else {
                        entry.mbr_type = try byteNumber(cmd.id.?, 16);
                    },
                    .attributes => {
                        if (plan.kind != .gpt) return error.UnsupportedTable;
                        if (cmd.attribute_set == null and cmd.attribute_clear == null) {
                            self.print("GPT attributes: 0x{x}\r\n", .{entry.attributes});
                            return;
                        }
                        entry.attributes = (entry.attributes | (cmd.attribute_set orelse 0)) & ~(cmd.attribute_clear orelse 0);
                    },
                    .active, .inactive => {
                        if (plan.kind != .mbr) return error.UnsupportedTable;
                        if (cmd.verb == .active) for (plan.entries[0..4]) |*other| {
                            other.active = false;
                        };
                        entry.active = cmd.verb == .active;
                    },
                    else => unreachable,
                }
            },
            else => return error.Syntax,
        }
        try plan.validate();
        try self.confirm(@tagName(cmd.verb), affected);
        try self.check(target.acquire(), 0);
        defer self.failedClose(&target);
        try plan.commit(self.executionDevice(&target), self.work);
        try self.finish(&target, false, selected);
        if (cmd.verb == .unique_id or cmd.verb == .set_type or cmd.verb == .convert)
            self.sys.write("Identifiers/types changed. Existing boot installation mappings must be revalidated.\r\n");
    }
    fn clean(self: *State, cmd: Command) !void {
        var target = try self.whole();
        try self.confirm(if (cmd.all) "CLEAN ALL: erase the entire disk" else "CLEAN: remove the disk partition tables", target.target);
        try self.check(target.acquire(), 0);
        defer self.failedClose(&target);
        try table.clean(self.executionDevice(&target), cmd.all, self.work);
        try self.finish(&target, true, null);
    }
    fn format(self: *State, cmd: Command) !void {
        var target = try self.region();
        if (target.target.first_lba > std.math.maxInt(u32)) return error.Geometry;
        const label = if (cmd.label.len == 0) "R4OS" else cmd.label;
        const serial = self.freshGuid();
        if (command.same(cmd.filesystem, "FAT32")) {
            const plan = try tools.fat32.Plan.prepare(target.target.sector_count, target.target.first_lba, label, std.mem.readInt(u32, serial[0..4], .little), 0);
            try self.confirm(if (cmd.quick) "FORMAT FAT32 QUICK" else "FORMAT FAT32 FULL", target.target);
            try self.check(target.acquire(), 0);
            defer self.failedClose(&target);
            try plan.execute(self.executionDevice(&target), !cmd.quick, self.work);
            try self.finish(&target, false, target.target.partition_number);
        } else {
            var builder = try tools.ntfs.Builder.init(self.sys.allocator(), target.target.sector_count * 512, label, @intCast(target.target.first_lba), tools.standardNtfsMetadata(), 132_000_000_000_000_000, std.mem.readInt(u64, serial[0..8], .little));
            defer builder.deinit();
            var plan = try builder.prepare();
            defer plan.deinit();
            try self.confirm(if (cmd.quick) "FORMAT NTFS QUICK" else "FORMAT NTFS FULL", target.target);
            try self.check(target.acquire(), 0);
            defer self.failedClose(&target);
            try plan.execute(self.executionDevice(&target), !cmd.quick, self.work);
            try self.finish(&target, false, target.target.partition_number);
        }
    }
    fn resize(self: *State, cmd: Command) !void {
        const part = try self.selectedPart();
        if (part.filesystem != abi.storage_filesystem_ntfs) return error.UnsupportedNtfs;
        var target = try self.whole();
        const layout = try self.loadTable(&target);
        defer self.sys.allocator().destroy(layout);
        const entry = try layout.get(part.target.partition_number);
        if (entry.first != part.target.first_lba or entry.count != part.target.sector_count) return error.SelectionChanged;
        const shrinking = cmd.verb == .shrink;
        const new_sectors = if (shrinking) blk: {
            const query = try tools.ntfs_resize.Plan.prepare(self.sys.allocator(), self.executionDevice(&target), layout, part.target.partition_number, part.target.sector_count, self.work);
            defer query.deinit();
            self.print("Maximum shrink: {d} MB; minimum volume: {d} MB.\r\nLast fixed allocated cluster: {d}; bitmap relocation space: {s}.\r\n", .{
                query.shrink.maximum_sectors / 2048, query.shrink.minimum_sectors / 2048,
                query.shrink.highest_fixed_cluster,  if (query.shrink.bitmap_lcn != null) "available" else "unavailable",
            });
            self.sys.write("Existing file data and other metadata stay at their cluster positions.\r\n");
            if (cmd.query_max) return;
            const desired = cmd.size_sectors orelse query.shrink.maximum_sectors;
            if (desired == 0 or desired > query.shrink.maximum_sectors) return error.ShrinkLimit;
            break :blk try layout.shrink(part.target.partition_number, desired);
        } else try layout.extend(part.target.partition_number, cmd.size_sectors);
        if (part.target.first_lba > std.math.maxInt(u32) or (new_sectors - 1) / 8 > std.math.maxInt(u32)) return error.UnsupportedNtfs;
        const plan = try tools.ntfs_resize.Plan.prepare(self.sys.allocator(), self.executionDevice(&target), layout, part.target.partition_number, part.target.sector_count, self.work);
        defer plan.deinit();
        // Whole-device table changes preserve unrelated mounts. The kernel
        // intentionally does not restore a mount whose old length changed;
        // restore only this successful resize at its previous letter below.
        const inv = try self.inventory();
        var letter: u8 = 0;
        for (0..inv.volume_slots) |i| {
            var volume: abi.StorageVolumeInfo = .{};
            const rc = self.storage().volume(inv.generation, @intCast(i), &volume);
            if (rc == 0) continue;
            try self.check(rc, 1);
            if (std.meta.eql(volume.target, part.target)) letter = @intCast(volume.letter);
        }
        self.print("{s} NTFS: {d} MB -> {d} MB, first LBA stays {d}.\r\n", .{ if (shrinking) "SHRINK" else "EXTEND", part.target.sector_count / 2048, new_sectors / 2048, part.target.first_lba });
        try self.confirm(if (shrinking) "SHRINK: reduce selected NTFS volume and its partition end" else "EXTEND: grow selected NTFS volume into adjacent free space", part.target);
        try self.check(target.acquire(), 0);
        defer self.failedClose(&target);
        try plan.execute(self.executionDevice(&target), layout, self.work);
        try self.finish(&target, false, part.target.partition_number);
        if (letter != 0) {
            const fresh = try self.selectedPart();
            if (fresh.target.first_lba != part.target.first_lba or fresh.target.sector_count != new_sectors or
                !std.mem.eql(u8, &fresh.target.partition_guid, &part.target.partition_guid)) return error.SelectionChanged;
            try self.assign(letter);
        }
    }
    fn assign(self: *State, letter: u8) !void {
        const part = try self.selectedPart();
        var mounted: abi.StorageVolumeRef = .{};
        try self.check(self.storage().mount(&part.target, letter, &mounted), 0);
        try self.refreshOwned(part.target.device, part.target.partition_number);
        self.print("Assigned {c}:\r\n", .{@as(u8, @intCast('A' + mounted.slot))});
    }
    fn remove(self: *State, letter: u8) !void {
        const part = try self.selectedPart();
        const inv = try self.inventory();
        for (0..inv.volume_slots) |i| {
            var vol: abi.StorageVolumeInfo = .{};
            if (self.storage().volume(inv.generation, @intCast(i), &vol) != 1) continue;
            if (!std.meta.eql(vol.target, part.target) or (letter != 0 and vol.letter != letter)) continue;
            if (vol.letter == 'C' or vol.letter == 'R' or vol.letter == 0) return error.Protected;
            try self.check(self.storage().unmount(&vol.reference), 0);
            try self.refreshOwned(part.target.device, part.target.partition_number);
            return;
        }
        return error.NotMounted;
    }
    fn isMounted(self: *State, target: abi.StorageTarget) !bool {
        const inv = try self.inventory();
        for (0..inv.volume_slots) |i| {
            var volume: abi.StorageVolumeInfo = .{};
            const rc = self.storage().volume(inv.generation, @intCast(i), &volume);
            if (rc == 0) continue;
            try self.check(rc, 1);
            if (std.meta.eql(target, volume.target)) return true;
        }
        return false;
    }
    fn offlineTarget(self: *State, object: command.Object) !void {
        var target = if (object == .disk or (object == .current and self.part == null)) try self.whole() else try self.region();
        const inv = try self.inventory();
        for (0..inv.volume_slots) |i| {
            var volume: abi.StorageVolumeInfo = .{};
            const rc = self.storage().volume(inv.generation, @intCast(i), &volume);
            if (rc == 0) continue;
            try self.check(rc, 1);
            if (volume.letter != 'R') continue;
            if (std.meta.eql(volume.target.device, target.target.device) and
                (target.target.kind == abi.storage_target_device or volume.target.partition_number == target.target.partition_number)) return error.Protected;
        }
        try self.check(target.acquire(), 0);
        defer self.failedClose(&target);
        try self.finish(&target, true, if (target.target.kind == abi.storage_target_partition) target.target.partition_number else null);
        self.sys.write("Offline: affected volumes flushed and unmounted. ONLINE mounts them again.\r\n");
    }
    fn online(self: *State, cmd: Command) !void {
        const disk = try self.selectedDisk();
        if (cmd.object != .disk and self.part != null) {
            const part = try self.selectedPart();
            if (!try self.isMounted(part.target)) try self.assign(cmd.letter);
            return;
        }
        if (cmd.letter != 0) return error.Syntax;
        for (0..disk.partition_slots) |i| {
            const inv = try self.inventory();
            var part: abi.StoragePartitionInfo = .{};
            try self.check(self.storage().partition(inv.generation, &disk.reference, @intCast(i), &part), 1);
            if (part.filesystem != abi.storage_filesystem_ntfs and part.filesystem != abi.storage_filesystem_fat32) continue;
            if (try self.isMounted(part.target)) continue;
            var reference: abi.StorageVolumeRef = .{};
            try self.check(self.storage().mount(&part.target, 0, &reference), 0);
            self.print("Partition {d} online as {c}:\r\n", .{ part.target.partition_number, @as(u8, @intCast('A' + reference.slot)) });
        }
        try self.refreshOwned(disk.reference, null);
    }
    fn rescan(self: *State) !void {
        const disk = try self.selectedDisk();
        const number: ?u32 = if (self.part) |p| p.target.partition_number else null;
        try self.check(self.storage().rescan(&disk.reference), 0);
        try self.refreshOwned(disk.reference, number);
    }
    fn execute(self: *State, cmd: Command) !void {
        self.native_error = 0;
        self.progress = .{};
        switch (cmd.verb) {
            .empty => return,
            .help => {
                const text = @embedFile("help.txt");
                self.sys.write(if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text);
            },
            .exit => self.exit_requested = true,
            .list => switch (cmd.object) {
                .disk => try self.listDisks(),
                .partition => try self.listParts(),
                .volume => try self.listVolumes(),
                else => return error.Syntax,
            },
            .select => try self.select(cmd),
            .detail => try self.detail(cmd.object),
            .rescan => try self.rescan(),
            .create, .delete, .convert, .unique_id, .set_type, .attributes, .active, .inactive => try self.editTable(cmd),
            .clean => try self.clean(cmd),
            .format => try self.format(cmd),
            .extend, .shrink => try self.resize(cmd),
            .check => try self.gpt(false),
            .repair => try self.gpt(true),
            .assign => try self.assign(cmd.letter),
            .remove => try self.remove(cmd.letter),
            .offline => try self.offlineTarget(cmd.object),
            .online => try self.online(cmd),
        }
        if (cmd.verb != .help and cmd.verb != .exit) self.sys.write("R4PART: OK\r\n");
    }
    fn report(self: *State, err: anyerror) void {
        self.print("R4PART: ERROR {s}", .{@errorName(err)});
        if (self.native_error != 0) self.print(" ({d}: {s})", .{ self.native_error, storageError(self.native_error) });
        self.sys.write("\r\n");
        if (self.progress.write_attempted) {
            self.print("Write status: phase={s}, completed-sectors={d}, flushed={any}, verified={any}", .{ @tagName(self.progress.phase), self.progress.written_sectors, self.progress.flushed, self.progress.verified });
            if (self.progress.failed_lba) |lba| self.print(", failed relative LBA={d}", .{lba});
            self.print(", backend={d}.\r\n", .{self.progress.native_error});
            if (!self.progress.verified) self.sys.write("The target may be partially changed.\r\n");
        }
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    const sys = app.system();
    const allocator = sys.allocator();
    const state = allocator.create(State) catch return 1;
    defer allocator.destroy(state);
    const work = allocator.alloc(u8, 128 * 1024) catch return 1;
    defer allocator.free(work);
    state.* = .{ .sys = sys, .work = work };
    if (!state.storage().available()) {
        sys.write("R4PART requires the physical storage API.\r\n");
        return 1;
    }
    const args = std.mem.trim(u8, std.mem.span(sys.argsRaw()), " \t");
    if (args.len != 0) {
        const batch_path = script.path(args) catch |err| {
            state.report(err);
            return 1;
        };
        if (batch_path) |path| {
            state.runScript(path) catch |err| {
                state.report(err);
                return 1;
            };
            return 0;
        }
        const cmd = command.parse(if (command.same(args, "/?")) "HELP" else args) catch |err| {
            state.report(err);
            return 1;
        };
        state.execute(cmd) catch |err| {
            state.report(err);
            return 1;
        };
        return 0;
    }
    sys.write("R4PART - R4OS partition tool\r\nType HELP for commands. SIZE/DESIRED use MB; OFFSET uses KB.\r\n");
    var buffer: [512]u8 = undefined;
    while (!state.exit_requested and !state.input.closed) {
        state.native_error = 0;
        state.progress = .{};
        sys.write("R4PART> ");
        const line = state.input.line(&sys, &buffer) catch |err| {
            state.report(err);
            continue;
        } orelse break;
        const cmd = command.parse(line) catch |err| {
            state.report(err);
            continue;
        };
        state.execute(cmd) catch |err| state.report(err);
    }
    return 0;
}
fn span(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}
fn parseGuid(text: []const u8) ![16]u8 {
    const guid = table.guid.parse(text) orelse return error.InvalidGuid;
    if (table.guid.isZero(guid)) return error.InvalidGuid;
    return guid;
}
fn smallNumber(text: []const u8, base: u8) !u32 {
    return std.math.cast(u32, try command.number(text, base)) orelse error.InvalidNumber;
}
fn byteNumber(text: []const u8, base: u8) !u8 {
    return std.math.cast(u8, try command.number(text, base)) orelse error.InvalidNumber;
}
fn scheme(flags: u32) []const u8 {
    return if (flags & abi.storage_device_gpt != 0) "GPT" else if (flags & abi.storage_device_mbr != 0) "MBR" else "none/?";
}
fn filesystem(kind: u32) []const u8 {
    return switch (kind) {
        abi.storage_filesystem_ntfs => "NTFS",
        abi.storage_filesystem_fat32 => "FAT32",
        abi.storage_filesystem_none => "none",
        else => "unknown",
    };
}
fn bus(kind: u32) []const u8 {
    return switch (kind) {
        abi.storage_bus_usb => "USB",
        abi.storage_bus_nvme => "NVMe",
        abi.storage_bus_sata => "SATA",
        abi.storage_bus_ata => "ATA",
        abi.storage_bus_ram => "RAM",
        else => "other",
    };
}
fn partitionName(out: []u8, name: [36]u16) []const u8 {
    var len: usize = 0;
    for (name) |unit| {
        if (unit == 0) break;
        out[len] = if (unit < 128) @intCast(unit) else '?';
        len += 1;
    }
    return out[0..len];
}
fn storageError(code: i32) []const u8 {
    return switch (code) {
        abi.storage_error_busy => "in use or already assigned; close users or REMOVE the existing letter first",
        abi.storage_error_stale => "selection changed; select the target again",
        abi.storage_error_protected => "reserved or running volume",
        abi.storage_error_remount => "remount failed",
        abi.storage_error_io => "device I/O failed",
        abi.storage_error_unsupported => "unsupported layout or operation",
        else => "storage operation rejected",
    };
}
