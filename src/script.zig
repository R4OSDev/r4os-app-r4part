//! Bounded scripts borrow a complete, preloaded file, never a live disk handle.
const std = @import("std");
pub const max_bytes = 64 * 1024;
pub const max_line = 512;
pub fn path(args: []const u8) !?[]const u8 {
    const end = std.mem.indexOfAny(u8, args, " \t") orelse args.len;
    if (!std.ascii.eqlIgnoreCase(args[0..end], "/S")) return null;
    var value = std.mem.trim(u8, args[end..], " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1] else if (std.mem.indexOfAny(u8, value, " \t") != null) return error.ScriptSyntax;
    if (value.len == 0 or value.len > 511 or std.mem.indexOfScalar(u8, value, '"') != null or
        std.mem.indexOfScalar(u8, value, 0) != null) return error.ScriptSyntax;
    return value;
}
pub const Script = struct {
    bytes: []const u8,
    position: usize = 0,
    line_number: usize = 0,
    pub fn init(bytes: []const u8) !Script {
        if (bytes.len > max_bytes) return error.ScriptTooLarge;
        const content = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
        if (!std.unicode.utf8ValidateSlice(content)) return error.ScriptEncoding;
        for (content) |value| if ((value < 32 and value != '\r' and value != '\n' and value != '\t') or value == 127)
            return error.ScriptEncoding;
        // Preflight every line, including lines after EXIT, before any command.
        var check = Script{ .bytes = content };
        while (try check.next() != null) {}
        return .{ .bytes = content };
    }
    /// Empty lines and REM comments do not consume a pending confirmation.
    pub fn next(self: *Script) !?[]const u8 {
        while (self.position < self.bytes.len) {
            const start = self.position;
            const length = std.mem.indexOfScalar(u8, self.bytes[start..], '\n') orelse self.bytes.len - start;
            self.position = @min(self.bytes.len, start + length + 1);
            self.line_number += 1;
            var raw = self.bytes[start..][0..length];
            if (std.mem.endsWith(u8, raw, "\r")) raw = raw[0 .. raw.len - 1];
            if (raw.len > max_line) return error.LineTooLong;
            if (std.mem.indexOfScalar(u8, raw, '\r') != null) return error.ScriptEncoding;
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0) continue;
            if (line.len >= 3 and std.ascii.eqlIgnoreCase(line[0..3], "REM") and
                (line.len == 3 or line[3] == ' ' or line[3] == '\t')) continue;
            return line;
        }
        return null;
    }
};

test "script bounds, BOM, comments, exact invocation and EOF confirmations" {
    const t = std.testing;
    try t.expectEqualStrings("C:\\WITH SPACE\\PART.TXT", (try path("/s \"C:\\WITH SPACE\\PART.TXT\"")).?);
    try t.expect(try path("LIST DISK") == null);
    for ([_][]const u8{ "/S", "/S a b", "/S \"a\" b", "/S \"\"", "/S a\"" }) |args|
        try t.expectError(error.ScriptSyntax, path(args));
    var script = try Script.init("\xef\xbb\xbfREM Test\r\n\n SELECT DISK 1\r\nCLEAN\nREM explicit answer\nYES DISK 1");
    try t.expectEqualStrings("SELECT DISK 1", (try script.next()).?);
    try t.expectEqual(@as(usize, 3), script.line_number);
    try t.expectEqualStrings("CLEAN", (try script.next()).?);
    try t.expectEqualStrings("YES DISK 1", (try script.next()).?);
    try t.expect(try script.next() == null);
    try t.expect(try script.next() == null);
    var missing = try Script.init("CLEAN\n");
    try t.expectEqualStrings("CLEAN", (try missing.next()).?);
    try t.expect(try missing.next() == null);
    try t.expectError(error.ScriptEncoding, Script.init("CLEAN\x00YES DISK 1"));
    try t.expectError(error.ScriptEncoding, Script.init("\xff\xfe"));
    try t.expectError(error.ScriptEncoding, Script.init("CLEAN\rYES DISK 1"));
    try t.expectError(error.LineTooLong, Script.init("EXIT\n" ++ "x" ** 513));
    try t.expectError(error.ScriptTooLarge, Script.init("\n" ** (max_bytes + 1)));
}
