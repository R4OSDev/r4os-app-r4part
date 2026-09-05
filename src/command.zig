const std = @import("std");
pub const Verb = enum { empty, help, exit, list, select, detail, rescan, create, delete, clean, convert, format, assign, remove, online, offline, set_type, attributes, unique_id, active, inactive };
pub const Object = enum { current, disk, partition, volume };
pub const Command = struct {
    verb: Verb = .empty,
    object: Object = .current,
    argument: []const u8 = "",
    size_sectors: ?u64 = null,
    offset_sectors: ?u64 = null,
    type_id: ?[]const u8 = null,
    id: ?[]const u8 = null,
    label: []const u8 = "",
    name: []const u8 = "",
    filesystem: []const u8 = "",
    quick: bool = false,
    all: bool = false,
    letter: u8 = 0,
    attribute_set: ?u64 = null,
    attribute_clear: ?u64 = null,
};
pub const Error = error{ Syntax, UnknownCommand, UnknownOption, DuplicateOption, InvalidNumber, TooManyWords };
pub fn same(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn number(text: []const u8, base: u8) Error!u64 {
    if (text.len == 0 or text[0] == '-' or text[0] == '+') return error.InvalidNumber;
    return std.fmt.parseInt(u64, text, base) catch error.InvalidNumber;
}
pub fn driveLetter(text: []const u8) Error!u8 {
    if (text.len != 1 and !(text.len == 2 and text[1] == ':')) return error.Syntax;
    const letter = std.ascii.toUpper(text[0]);
    if (letter < 'A' or letter > 'Z') return error.Syntax;
    return letter;
}
fn object(text: []const u8) Error!Object {
    for ([_]Object{ .disk, .partition, .volume }) |value| if (same(text, @tagName(value))) return value;
    return error.Syntax;
}

/// All slices borrow the command line, which must outlive execution.
pub fn parse(line: []const u8) Error!Command {
    var words: [16][]const u8 = undefined;
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < line.len) {
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
        if (pos == line.len) break;
        if (count == words.len) return error.TooManyWords;
        const start = pos;
        var quoted = false;
        while (pos < line.len) : (pos += 1) {
            if (line[pos] == '"') quoted = !quoted;
            if (!quoted and (line[pos] == ' ' or line[pos] == '\t')) break;
        }
        if (quoted) return error.Syntax;
        words[count] = line[start..pos];
        count += 1;
    }
    if (count == 0) return .{};
    var result = Command{};
    var start: usize = 1;
    if (same(words[0], "?")) result.verb = .help else {
        var found = false;
        inline for (std.meta.fields(Verb)) |field| {
            if (field.value != @intFromEnum(Verb.empty) and field.value != @intFromEnum(Verb.set_type) and field.value != @intFromEnum(Verb.unique_id) and same(words[0], field.name)) {
                result.verb = @enumFromInt(field.value);
                found = true;
            }
        }
        if (same(words[0], "SET")) {
            result.verb = .set_type;
            found = true;
        }
        if (same(words[0], "UNIQUEID")) {
            result.verb = .unique_id;
            found = true;
        }
        if (!found) return error.UnknownCommand;
    }
    switch (result.verb) {
        .list, .select, .delete, .unique_id => {
            if (count < 2) return error.Syntax;
            result.object = try object(words[1]);
            start = 2;
            if (result.verb == .select) {
                if (count != 3) return error.Syntax;
                result.argument = words[2];
                start = 3;
                if (result.object != .volume) _ = try number(result.argument, 10);
            }
            if (result.verb == .delete and result.object != .partition) return error.Syntax;
            if (result.verb == .unique_id and result.object == .volume) return error.Syntax;
        },
        .detail => if (count > 1) {
            result.object = try object(words[1]);
            start = 2;
        },
        .online, .offline => if (count > 1 and (same(words[1], "DISK") or same(words[1], "VOLUME") or same(words[1], "PARTITION"))) {
            result.object = try object(words[1]);
            start = 2;
        },
        .create => {
            if (count < 3 or !same(words[1], "PARTITION") or
                !(same(words[2], "PRIMARY") or same(words[2], "EFI") or same(words[2], "BIOS"))) return error.Syntax;
            result.object = .partition;
            result.argument = words[2];
            start = 3;
        },
        .convert => {
            if (count < 2 or !(same(words[1], "GPT") or same(words[1], "MBR"))) return error.Syntax;
            result.argument = words[1];
            start = 2;
        },
        .attributes => {
            if (count < 2 or !same(words[1], "GPT")) return error.Syntax;
            start = 2;
        },
        else => {},
    }
    var seen: u16 = 0;
    for (words[start..count]) |word| {
        const separator = std.mem.indexOfScalar(u8, word, '=');
        const key = if (separator) |index| word[0..index] else word;
        var value = if (separator) |index| word[index + 1 ..] else "";
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (std.mem.indexOfScalar(u8, value, '"') != null) return error.Syntax;
        var bit: u4 = undefined;
        if (same(key, "SIZE") and result.verb == .create and separator != null) {
            bit = 0;
            result.size_sectors = std.math.mul(u64, try number(value, 10), 2048) catch return error.InvalidNumber;
            if (result.size_sectors.? == 0) return error.InvalidNumber;
        } else if (same(key, "OFFSET") and result.verb == .create and separator != null) {
            bit = 1;
            result.offset_sectors = std.math.mul(u64, try number(value, 10), 2) catch return error.InvalidNumber;
        } else if (same(key, "TYPE") and result.verb == .create and separator != null) {
            bit = 2;
            result.type_id = value;
        } else if (same(key, "ID") and (result.verb == .create or result.verb == .convert or result.verb == .unique_id or result.verb == .set_type) and separator != null) {
            bit = 3;
            result.id = value;
        } else if (same(key, "NAME") and result.verb == .create and separator != null) {
            bit = 4;
            result.name = value;
        } else if (same(key, "LABEL") and result.verb == .format and separator != null) {
            bit = 5;
            result.label = value;
        } else if (same(key, "FS") and result.verb == .format and separator != null) {
            bit = 6;
            result.filesystem = value;
            if (!same(value, "NTFS") and !same(value, "FAT32")) return error.Syntax;
        } else if (same(key, "QUICK") and result.verb == .format and separator == null) {
            bit = 7;
            result.quick = true;
        } else if (same(key, "FULL") and result.verb == .format and separator == null) {
            bit = 7;
            result.quick = false;
        } else if (same(key, "ALL") and result.verb == .clean and separator == null) {
            bit = 8;
            result.all = true;
        } else if (same(key, "LETTER") and (result.verb == .assign or result.verb == .remove or result.verb == .online) and separator != null) {
            bit = 9;
            result.letter = try driveLetter(value);
        } else if (same(key, "SET") and result.verb == .attributes and separator != null) {
            bit = 10;
            result.attribute_set = try number(value, 0);
        } else if (same(key, "CLEAR") and result.verb == .attributes and separator != null) {
            bit = 11;
            result.attribute_clear = try number(value, 0);
        } else return error.UnknownOption;
        const mask = @as(u16, 1) << bit;
        if (seen & mask != 0) return error.DuplicateOption;
        seen |= mask;
    }
    if (result.verb == .format and result.filesystem.len == 0) return error.Syntax;
    if (result.verb == .set_type and result.id == null) return error.Syntax;
    return result;
}

pub fn confirmation(out: []u8, disk: u32, part: ?u32) ![]const u8 {
    return if (part) |number_| std.fmt.bufPrint(out, "YES DISK {d} PARTITION {d}", .{ disk, number_ }) else std.fmt.bufPrint(out, "YES DISK {d}", .{disk});
}
pub fn confirmed(wanted: []const u8, answer: []const u8) bool {
    return same(wanted, std.mem.trim(u8, answer, " \t"));
}

test "destructive commands reject typos, conflicting options, overflow and ambiguous input" {
    const expectError = std.testing.expectError;
    try expectError(error.UnknownOption, parse("CLEAN AL"));
    try expectError(error.DuplicateOption, parse("FORMAT FS=NTFS QUICK FULL"));
    try expectError(error.DuplicateOption, parse("CREATE PARTITION PRIMARY SIZE=32 SIZE=64"));
    try expectError(error.Syntax, parse("FORMAT QUICK"));
    try expectError(error.Syntax, parse("FORMAT FS=NTFS LABEL=\"unfinished"));
    try expectError(error.InvalidNumber, parse("CREATE PARTITION PRIMARY SIZE=18446744073709551615"));
    try expectError(error.UnknownOption, parse("CONVERT GPT FORCE"));
    try expectError(error.UnknownOption, parse("DELETE PARTITION OVERRIDE"));
    const format = try parse("format fs=ntfs label=\"My Data\" quick");
    try std.testing.expectEqualStrings("My Data", format.label);
    const create = try parse("CREATE PARTITION PRIMARY SIZE=32 OFFSET=1024");
    try std.testing.expectEqual(@as(u64, 65536), create.size_sectors.?);
    try std.testing.expectEqual(@as(u64, 2048), create.offset_sectors.?);
    var buffer: [64]u8 = undefined;
    const wanted = try confirmation(&buffer, 2, 3);
    try std.testing.expect(!confirmed(wanted, "YES"));
    try std.testing.expect(!confirmed(wanted, "YES DISK 2 PARTITION 4"));
    try std.testing.expect(confirmed(wanted, "yes disk 2 partition 3"));
}
