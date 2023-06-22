//! An XML library, currently supporting reading XML.
//!
//! Most applications will want to start with `Reader` and investigate the
//! other parser options if they want to avoid dynamic memory allocation or
//! want better performance at the expense of ease of use.
//!
//! There are three parsers available, with increasing levels of abstraction,
//! ease of use, and standard conformance. The documentation for each parser
//! provides more detailed information on its functionality.
//!
//! 1. `Scanner` - the lowest-level parser. A state machine that accepts
//!    Unicode codepoints one by one and returns "tokens" referencing ranges of
//!    input data.
//! 2. `TokenReader` - a mid-level parser that improves on `Scanner` by
//!    buffering input so that returned tokens can use UTF-8-encoded byte
//!    slices rather than ranges. It also uses a `std.io.Reader` and a decoder
//!    (see `encoding`) rather than forcing the user to pass codepoints
//!    directly.
//! 3. `Reader` - a general-purpose streaming parser which can handle
//!    namespaces. Helper functions are available to parse some or all of a
//!    document into a `Node`, which acts as a minimal DOM abstraction.

const std = @import("std");
const testing = std.testing;

pub const encoding = @import("encoding.zig");

pub const Scanner = @import("Scanner.zig");

pub const tokenReader = @import("token_reader.zig").tokenReader;
pub const TokenReader = @import("token_reader.zig").TokenReader;
pub const TokenReaderOptions = @import("token_reader.zig").TokenReaderOptions;
pub const Token = @import("token_reader.zig").Token;

pub const reader = @import("reader.zig").reader;
pub const readDocument = @import("reader.zig").readDocument;
pub const Reader = @import("reader.zig").Reader;
pub const ReaderOptions = @import("reader.zig").ReaderOptions;
pub const QName = @import("reader.zig").QName;
pub const Event = @import("reader.zig").Event;

pub const Node = @import("node.zig").Node;
pub const OwnedValue = @import("node.zig").OwnedValue;

test {
    testing.refAllDecls(@This());
}
