# zig-xml

zig-xml is an XML library for Zig.

**Warning:** this library is still in early development. Bugs and breaking
changes are highly likely. If you need a stable and well-tested XML library,
[zig-libxml2](https://github.com/mitchellh/zig-libxml2) is probably your best
bet (build setup for the popular libxml2 C library).

See the documentation in the code for more information about the available APIs
(start in `xml.zig`).

## Feature overview

Key for the list:

- ✅ Supported
- 🚧 Partially supported
- ❌ Unsupported, but planned
- ❓️ Unsupported, maybe planned (long-term)
- 👎️ Unsupported, not planned

Features:

- ✅ Streaming parser (three options are available, `Reader` is the most
  general-purpose but also the slowest)
  - ✅ Core XML 1.0 language minus `DOCTYPE`
  - ✅ Well-formedness checks not involving DTD (varying degrees of lesser
    support in `TokenReader` and `Scanner`)
  - ✅ End-of-line and attribute value normalization (in `Reader` and
    `TokenReader` only, optional)
  - ✅ Namespace support (in `Reader` only, optional)
  - ❌ Detailed errors (https://github.com/ianprime0509/zig-xml/issues/14)
  - ❌ Source location tracking
    (https://github.com/ianprime0509/zig-xml/issues/12)
  - ❌ `DOCTYPE` (just parsing, not doing anything with it)
    (https://github.com/ianprime0509/zig-xml/issues/9)
  - ❓️ Non-validating `DOCTYPE` handling (entity expansion, further attribute
    value normalization for non-`CDATA` types) (no external DTD content)
  - ❓️ Hooks for loading external DTD content
  - ❓️ XML 1.1
  - 👎️ Validation
- 🚧 DOM parser (current `Node` abstraction is limited and read-only)
- ✅ Unicode
  - ✅ UTF-8
  - ✅ UTF-16
  - ✅ UTF-8 vs UTF-16 auto-detection (`DefaultDecoder`)
  - ❌ US-ASCII (this is for support of US-ASCII as its own encoding; note that
    all ASCII can be treated as UTF-8)
  - ❌ ISO 8859-1
  - ❓️ Other encodings besides these
  - ✅ User-definable additional encodings (meaning even though this library
    doesn't provide other encodings out of the box, you can write them yourself)
- ❌ XML writer (https://github.com/ianprime0509/zig-xml/issues/10)
- 👎️ XPath, XML Schema, other XML-related stuff

## Examples

See the `examples` directory (these examples are not very good right now but
they do show how to use most of the library).

## Fuzzing

This library has some basic support for fuzz testing, taking its basic method
from the article
[Fuzzing Zig Code Using AFL++](https://www.ryanliptak.com/blog/fuzzing-zig-code/).
To start fuzzing, you will need
[AFL++](https://github.com/AFLplusplus/AFLplusplus), specifically
`afl-clang-lto` and `afl-fuzz`, in your path. Then, you can run
`zig build fuzz`. To resume a prior fuzzing session, pass `-Dresume=true`.

You can also run `zig build install-fuzz` to just build the fuzz executable and
then run it with `afl-fuzz` separately.

Finally, if any crashes are identified during fuzzing, they can be replayed by
feeding the crash input back to `zig build fuzz-reproduce`, which will yield an
error trace for further debugging.

## Benchmarking and performance

**TL;DR:** `Reader` and `TokenReader` are relatively slow compared to other
popular libraries. `Scanner` is faster (on a similar level as yxml), but
comparatively doesn't do very much.

There is a benchmarking setup in the `bench` directory. The benchmark is for
parsing through an entire XML file without doing any additional processing. The
XML file is loaded completely into memory first, then the parser is executed on
it until it completes.

Below are some benchmarking results as of commit
`e9809855f7ee3403efa1fdc5f9010182f47361d0`, as performed on my laptop. The
results were obtained by executing [poop](https://github.com/andrewrk/poop) on
the benchmark implementations.

### GTK 4 GIR

This is a 7.6MiB XML file containing GObject introspection metadata for GTK 4.

| Implementation             | Execution time  | Memory usage    |
| -------------------------- | --------------- | --------------- |
| zig-xml (`Reader`)         | 242ms ± 5.50ms  | 9.12MB ± 66.5KB |
| zig-xml (`TokenReader`)    | 169ms ± 13.4ms  | 9.07MB ± 97.9KB |
| zig-xml (`Scanner`)        | 40.2ms ± 2.25ms | 9.09MB ± 97.0KB |
| libxml2 (`xmlreader.h`)    | 74.0ms ± 3.16ms | 10.4MB ± 104KB  |
| mxml (`mxmlSAXLoadString`) | 97.1ms ± 1.63ms | 9.12MB ± 64.9KB |
| yxml                       | 36.2ms ± 999us  | 9.09MB ± 92.3KB |

## License

zig-xml is free and open source software, released under the
[MIT license](https://opensource.org/license/MIT/) as found in the `LICENSE`
file of this repository.
