# zig-xml

zig-xml is an XML library for Zig. It is intended to be as correct and efficient
as possible, providing APIs at varying levels of abstraction to best suit the
needs of different users.

**Warning:** this library is still in early development. Bugs and breaking
changes are highly likely.

## Reading XML

The lowest-level API for reading XML is `Scanner`. The design of `Scanner` is
heavily inspired by [yxml](https://dev.yorhel.nl/yxml): it accepts Unicode
codepoints one by one and returns `Token`s which reference the input using
positional ranges. As such, it has a very low memory footprint compared to
higher-level APIs, but is more difficult to use.

A higher-level API is `Reader`. A `Reader` wraps a `Scanner` internally along
with a buffer and some other metadata (such as the current element nesting
structure) to provide a nicer API at the expense of higher memory use and more
copying. A `Reader` returns `Event`s, which are similar to `Token`s but use
actual UTF-8-encoded slices for text content rather than positional ranges. It
is also able to handle several well-formedness checks (such as matching start
and end tags) and normalization requirements (such as converting `\r\n` to `\n`)
which `Scanner` is not able to handle due to its design.

The highest-level API is `Node`, which provides an abstraction similar to a
read-only DOM. `Node`s can be obtained from a `Reader` for portions of a
document: for example, a convenient method of processing an XML file with a
`dataset` root element containing millions of `datum` children would be to use a
`Reader` to parse through the XML file until a `datum` start tag is encountered,
parse the `datum` element content as a `Node`, process it, and proceed again
with the `Reader` until the next `datum`.

## Writing XML

**TODO:** https://github.com/ianprime0509/zig-xml/issues/10

## Examples

See the `examples` directory (these examples are not very good right now but
they do show how to use most of the library).

## License

zig-xml is free and open source software, released under the
[MIT license](https://opensource.org/license/MIT/) as found in the `LICENSE`
file of this repository.
