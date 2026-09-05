const r4os = @import("r4os");
pub const Input = struct {
    pending: [4096]u8 = undefined,
    first: usize = 0,
    end: usize = 0,
    generation: u64 = 0,
    closed: bool = false,

    fn poll(self: *Input, sys: *const r4os.r4sys.Context) void {
        if (self.first == self.end) {
            self.first = 0;
            self.end = 0;
        }
        if (self.end < self.pending.len) {
            const got = sys.consoleRead(self.pending[self.end..]);
            if (got > 0) self.end += @intCast(got);
        }
        if (sys.programShouldClose()) self.closed = true;
    }
    pub fn cancelled(self: *Input, sys: *const r4os.r4sys.Context) bool {
        self.poll(sys);
        for (self.pending[self.first..self.end]) |value| if (value == 3) {
            self.first = self.end;
            return true;
        };
        return self.closed;
    }
    fn byte(self: *Input, sys: *const r4os.r4sys.Context) ?u8 {
        while (true) {
            self.poll(sys);
            if (self.closed) return null;
            if (self.first < self.end) {
                const value = self.pending[self.first];
                self.first += 1;
                return value;
            }
            const rc = sys.consoleInputWait(self.generation, r4os.abi.io_wait_forever, &self.generation);
            if (rc == r4os.abi.console_input_wait_error_closed) {
                self.closed = true;
                return null;
            }
            if (rc < 0) {
                const value = sys.readKey();
                if (value != 0) return value;
                sys.sleepTicks(sys.ticksFromMilliseconds(10));
            }
        }
    }
    pub fn line(self: *Input, sys: *const r4os.r4sys.Context, out: []u8) !?[]const u8 {
        var length: usize = 0;
        var overflow = false;
        while (true) {
            const value = self.byte(sys) orelse return null;
            switch (value) {
                '\r' => {},
                '\n' => {
                    sys.write("\r\n");
                    if (overflow) return error.LineTooLong;
                    return out[0..length];
                },
                3, 27 => {
                    sys.write("^C\r\n");
                    return error.Cancelled;
                },
                8, 127 => if (length != 0 and !overflow) {
                    length -= 1;
                    sys.putc(8);
                },
                else => if (value >= 32 and value <= 126) {
                    if (length == out.len) {
                        overflow = true;
                    } else if (!overflow) {
                        out[length] = value;
                        length += 1;
                        sys.putc(value);
                    }
                },
            }
        }
    }
};
