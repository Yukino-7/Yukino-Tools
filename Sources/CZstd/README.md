# Zstandard decoder

Vendored from [Zstandard v1.5.7](https://github.com/facebook/zstd/tree/v1.5.7),
under its BSD license (see `LICENSE`). Only the decoder is compiled; the app
does not depend on a system library, executable, or network access to read logs.
The license is also copied into each app bundle's Resources directory.

`include/zstd.h` and `include/zstd_errors.h` are the unmodified upstream public headers. `zstddeclib.c` is
the upstream single-file decoder generated from the v1.5.7 source archive:

```sh
cd zstd-1.5.7/build/single_file_libs
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

The decoder streams concatenated frames and validates frame checksums. The
Swift reader limits the decoder history window to 128 MiB and sends decoded
chunks directly to the metadata parser without writing conversation text to disk.
