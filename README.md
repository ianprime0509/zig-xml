# zig-xml

zig-xml is an XML library for Zig.

**Warning:** this library is still in early development. It has been reasonably
well-tested at this point, but it is lacking some important features, and its
performance is not ideal. If you need a stable and well-tested XML library,
[zig-libxml2](https://github.com/mitchellh/zig-libxml2) is probably your best
bet (build setup for the popular libxml2 C library).

See the documentation in the code for more information about the available APIs
(start in `xml.zig`). Autodocs are also published to GitHub Pages:
http://ianjohnson.dev/zig-xml/

The library aims to confirm with the following standards:

- [XML 1.0 Fifth Edition](https://www.w3.org/TR/2008/REC-xml-20081126/)
- [XML Namespaces 1.0 Third Edition](https://www.w3.org/TR/2009/REC-xml-names-20091208/)

Other standards (such as XML 1.1 or XML 1.0 prior to the fifth edition) are only
supported insofar as they are compatible with the above standards. In practice,
this should not make much difference, since XML 1.1 is rarely used, and the
differences between XML 1.0 editions are minor (the XML 1.0 fifth edition
standard allows many more characters in names than previous editions, subsuming
the
[only non-harmful feature of XML 1.1](http://www.ibiblio.org/xml/books/effectivexml/chapters/03.html)).

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
  - 🚧 Detailed errors
  - 🚧 Source location tracking
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
- 🚧 XML writer (https://github.com/ianprime0509/zig-xml/issues/10)
- 👎️ XPath, XML Schema, other XML-related stuff

## Examples

See the `examples` directory (these examples are not very good right now but
they do show how to use most of the library).

Another ("real-world") example can be found in the zig-gobject project:
https://github.com/ianprime0509/zig-gobject/blob/main/src/gir.zig

## Tests

There are several tests in the project itself using the standard Zig test
system. These tests can be run using `zig build test`.

There is also a runner for the
[W3C XML Conformance Test Suite](https://www.w3.org/XML/Test/) under
`test/xmlconf.zig`. To build this runner as a standalone executable, run
`zig build install-xmlconf`. If you download the 20130923 version of the test
suite and place the `xmlconf` directory under `test`, you can also use
`zig build run-xmlconf` to run all the test suites the runner can currently
understand. The test suite files are not contained directly in this repository
due to unclear licensing and file size (16MB uncompressed).

At the time of writing, the library passes all the conformance tests it is able
to run (353 of them); the other tests are skipped because they involve doctype
in one way or another or are for XML standards which aren't supported (XML 1.1,
editions of XML 1.0 besides the fifth edition).

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
