# zig-xml

zig-xml is an XML library for Zig, currently supporting Zig 0.12.0 and the
latest master at the time of writing.

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

Below are some benchmarking results as of August 14, 2023, using Zig
`0.12.0-dev.906+2d7d037c4`, as performed on my laptop. The results were obtained
by executing [poop](https://github.com/andrewrk/poop) on the benchmark
implementations.

### GTK 4 GIR

This is a 5.7MB XML file containing GObject introspection metadata for GTK 4. In
the output below, libxml2 is used as the baseline. The three benchmarks
`reader`, `token_reader`, and `scanner` test the three APIs provided by this
library, and the mxml and yxml libraries are also included for comparison.

```
Benchmark 1 (78 runs): zig-out/bin/libxml2 Gtk-4.0.gir
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          64.2ms ± 1.87ms    55.5ms … 70.1ms          4 ( 5%)        0%
  peak_rss           14.6MB ± 76.4KB    14.4MB … 14.7MB          0 ( 0%)        0%
  cpu_cycles          196M  ± 1.03M      194M  …  200M           3 ( 4%)        0%
  instructions        409M  ± 43.1       409M  …  409M           0 ( 0%)        0%
  cache_references   5.44M  ±  325K     5.08M  … 6.97M           5 ( 6%)        0%
  cache_misses       66.0K  ± 5.36K     55.0K  … 91.0K           3 ( 4%)        0%
  branch_misses       874K  ± 3.80K      868K  …  890K           1 ( 1%)        0%

Benchmark 2 (30 runs): zig-out/bin/reader Gtk-4.0.gir
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           170ms ± 1.59ms     167ms …  173ms          0 ( 0%)        💩+164.2% ±  1.2%
  peak_rss           7.29MB ± 73.8KB    7.08MB … 7.34MB          0 ( 0%)        ⚡- 50.0% ±  0.2%
  cpu_cycles          583M  ± 2.88M      579M  …  590M           0 ( 0%)        💩+196.9% ±  0.4%
  instructions       1.38G  ± 32.2      1.38G  … 1.38G           0 ( 0%)        💩+237.2% ±  0.0%
  cache_references    751K  ±  135K      580K  … 1.12M           0 ( 0%)        ⚡- 86.2% ±  2.2%
  cache_misses       17.5K  ± 5.41K     12.9K  … 34.5K           3 (10%)        ⚡- 73.5% ±  3.5%
  branch_misses      1.06M  ± 10.9K     1.05M  … 1.11M           2 ( 7%)        💩+ 21.5% ±  0.3%

Benchmark 3 (38 runs): zig-out/bin/token_reader Gtk-4.0.gir
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           135ms ± 1.59ms     132ms …  138ms          0 ( 0%)        💩+110.4% ±  1.1%
  peak_rss           7.31MB ± 54.2KB    7.21MB … 7.34MB          8 (21%)        ⚡- 49.8% ±  0.2%
  cpu_cycles          462M  ± 2.20M      459M  …  467M           0 ( 0%)        💩+135.5% ±  0.3%
  instructions       1.14G  ± 21.0      1.14G  … 1.14G           0 ( 0%)        💩+179.9% ±  0.0%
  cache_references    237K  ± 7.40K      225K  …  255K           0 ( 0%)        ⚡- 95.6% ±  1.9%
  cache_misses       10.1K  ± 1.29K     8.16K  … 13.2K           0 ( 0%)        ⚡- 84.8% ±  2.7%
  branch_misses       815K  ±  919       813K  …  816K           3 ( 8%)        ⚡-  6.8% ±  0.1%

Benchmark 4 (103 runs): zig-out/bin/scanner Gtk-4.0.gir
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          48.6ms ± 1.82ms    45.8ms … 55.2ms          4 ( 4%)        ⚡- 24.3% ±  0.8%
  peak_rss           7.27MB ± 87.8KB    7.08MB … 7.34MB          0 ( 0%)        ⚡- 50.1% ±  0.2%
  cpu_cycles          152M  ± 3.48M      151M  …  177M           5 ( 5%)        ⚡- 22.4% ±  0.4%
  instructions        472M  ± 19.9       472M  …  472M           0 ( 0%)        💩+ 15.6% ±  0.0%
  cache_references    209K  ± 1.80K      207K  …  222K           4 ( 4%)        ⚡- 96.2% ±  1.2%
  cache_misses       7.95K  ±  179      7.59K  … 8.50K           0 ( 0%)        ⚡- 88.0% ±  1.6%
  branch_misses       511K  ±  874       510K  …  518K          13 (13%)        ⚡- 41.6% ±  0.1%

Benchmark 5 (63 runs): zig-out/bin/mxml Gtk-4.0.gir
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          80.2ms ± 2.44ms    76.0ms … 87.9ms          3 ( 5%)        💩+ 24.9% ±  1.1%
  peak_rss           7.44MB ± 56.3KB    7.34MB … 7.47MB         15 (24%)        ⚡- 48.9% ±  0.2%
  cpu_cycles          262M  ± 2.95M      258M  …  281M           1 ( 2%)        💩+ 33.4% ±  0.4%
  instructions        762M  ± 56.7K      762M  …  762M           3 ( 5%)        💩+ 86.4% ±  0.0%
  cache_references    401K  ±  473K      272K  … 3.08M          10 (16%)        ⚡- 92.6% ±  2.4%
  cache_misses       14.2K  ± 2.62K     12.0K  … 31.1K           2 ( 3%)        ⚡- 78.5% ±  2.2%
  branch_misses      1.02M  ± 99.5K      998K  … 1.79M           4 ( 6%)        💩+ 16.3% ±  2.5%

Benchmark 6 (196 runs): zig-out/bin/yxml Gtk-4.0.gir
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          25.4ms ± 1.03ms    23.9ms … 34.3ms          3 ( 2%)        ⚡- 60.4% ±  0.5%
  peak_rss           7.29MB ± 77.0KB    7.08MB … 7.34MB          0 ( 0%)        ⚡- 50.0% ±  0.1%
  cpu_cycles         71.0M  ± 1.03M     70.5M  … 84.2M           5 ( 3%)        ⚡- 63.8% ±  0.1%
  instructions        236M  ± 20.1       236M  …  236M           0 ( 0%)        ⚡- 42.2% ±  0.0%
  cache_references    202K  ±  805       201K  …  210K           7 ( 4%)        ⚡- 96.3% ±  0.8%
  cache_misses       8.00K  ±  215      7.64K  … 9.57K           4 ( 2%)        ⚡- 87.9% ±  1.1%
  branch_misses       239K  ±  787       238K  …  248K          21 (11%)        ⚡- 72.7% ±  0.1%
```

## License

zig-xml is free software, released under the [Zero Clause BSD
License](https://spdx.org/licenses/0BSD.html), as found in the `LICENSE` file of
this repository. This license places no restrictions on your use, modification,
or redistribution of the library: providing attribution is appreciated, but not
required.
