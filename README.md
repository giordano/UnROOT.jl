# UnROOT.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://tamasgal.github.io/UnROOT.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://tamasgal.github.io/UnROOT.jl/dev)
[![Build Status](https://github.com/tamasgal/UnROOT.jl/workflows/CI/badge.svg)](https://github.com/tamasgal/UnROOT.jl/actions)
[![Codecov](https://codecov.io/gh/tamasgal/UnROOT.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/tamasgal/UnROOT.jl)

UnROOT.jl is a (WIP) reader for the [CERN ROOT](https://root.cern) file format
written entirely in pure Julia, without depending on the official ROOT libraries or Python.
In contrast to the C++ ROOT framework, this package focuses only on I/O. (read-only as of now)

While the ROOT documentation does not contain a detailed description of the
binary structure, the format can be triangulated by other packages like

- [uproot3](https://github.com/scikit-hep/uproot) (Python)
- [groot](https://godoc.org/go-hep.org/x/hep/groot#hdr-File_layout) (Go)
- [root-io](https://github.com/cbourjau/alice-rs/tree/master/root-io) (Rust)
- [Laurelin](https://github.com/spark-root/laurelin) (Java)

Here's a detailed [from-scratch walk through](https://jiling.web.cern.ch/jiling/dump/ROOT_Fileformat.pdf) 
on reading a jagged branch from .root file, recommdned for first time contributors or just want to learn
about .root file format.

Three's also a [discussion](https://github.com/scikit-hep/uproot/issues/401) reagarding the ROOT binary format
documentation on uproot's issue page.

## Status
The project is in early prototyping phase and contributions are very
welcome.

We support reading all scalar branch and jagged branch of "basic" types, as
a metric, UnROOT can already read all branches of CMS' NanoAOD:

``` julia
julia> t = ROOTFile("test/samples/NanoAODv5_sample.root")
ROOTFile("test/samples/NanoAODv5_sample.root") with 2 entries and 21 streamers.

# example of a flat branch
julia> array(t, "Events/HLT_Mu3_PFJet40")
1000-element BitVector:
 0
 1
 0
 0
 0
 
# example of a jagged branch
julia> array(t, "Events/Electron_dxy")
1000-element Vector{Vector{Float32}}:
 [0.00037050247]
 [-0.009819031]
 []
 [-0.0015697479]
```

If you have custom C++ struct inside you branch, reading raw data is also possible. 
The raw data consists of two vectors: the bytes
and the offsets and are available using the
`UnROOT.array(f::ROOTFile, path; raw=true)` method. This data can
be reinterpreted using a custom type with the method
`UnROOT.splitup(data, offsets, T::Type; skipbytes=0)`.

You can then define suitable Julia `type` and `readtype` method for parsing these data.
Here is it in action, with the help of the `type`s from `custom.jl`, and some data from the KM3NeT experiment:

``` julia
julia> using UnROOT

julia> f = ROOTFile("test/samples/km3net_online.root")
ROOTFile("test/samples/km3net_online.root") with 10 entries and 41 streamers.

julia> data, offsets = array(f, "KM3NET_EVENT/KM3NET_EVENT/snapshotHits"; raw=true)
2058-element Array{UInt8,1}:
 0x00
 0x03
   ⋮
   
julia> UnROOT.splitup(data, offsets, UnROOT.KM3NETDAQHit)
4-element Vector{Vector{UnROOT.KM3NETDAQHit}}:
 [UnROOT.KM3NETDAQHit(1073742790, 0x00, 9, 0x60)......
```

This is what happens behind the scenes with some additional debug output:

``` julia
julia> using UnROOT

julia> f = ROOTFile("test/samples/tree_with_histos.root")
Compressed stream at 1509
ROOTFile("test/samples/tree_with_histos.root") with 1 entry and 4 streamers.

julia> keys(f)
1-element Array{String,1}:
 "t1"

julia> keys(f["t1"])
Compressed datastream of 1317 bytes at 1509 (TKey 't1' (TTree))
2-element Array{String,1}:
 "mynum"
 "myval"

julia> f["t1"]["mynum"]
Compressed datastream of 1317 bytes at 6180 (TKey 't1' (TTree))
UnROOT.TBranch
  cursor: UnROOT.Cursor
  fName: String "mynum"
  fTitle: String "mynum/I"
  fFillColor: Int16 0
  fFillStyle: Int16 1001
  fCompress: Int32 101
  fBasketSize: Int32 32000
  fEntryOffsetLen: Int32 0
  fWriteBasket: Int32 1
  fEntryNumber: Int64 25
  fIOFeatures: UnROOT.ROOT_3a3a_TIOFeatures
  fOffset: Int32 0
  fMaxBaskets: UInt32 0x0000000a
  fSplitLevel: Int32 0
  fEntries: Int64 25
  fFirstEntry: Int64 0
  fTotBytes: Int64 170
  fZipBytes: Int64 116
  fBranches: UnROOT.TObjArray
  fLeaves: UnROOT.TObjArray
  fBaskets: UnROOT.TObjArray
  fBasketBytes: Array{Int32}((10,)) Int32[116, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  fBasketEntry: Array{Int64}((10,)) [0, 25, 0, 0, 0, 0, 0, 0, 0, 0]
  fBasketSeek: Array{Int64}((10,)) [238, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  fFileName: String ""


julia> seek(f.fobj, 238)
IOStream(<file test/samples/tree_with_histos.root>)

julia> basketkey = UnROOT.unpack(f.fobj, UnROOT.TKey)
UnROOT.TKey64(116, 1004, 100, 0x6526eafb, 70, 0, 238, 100, "TBasket", "mynum", "t1")

julia> s = UnROOT.datastream(f.fobj, basketkey)
Compressed datastream of 100 bytes at 289 (TKey 'mynum' (TBasket))
IOBuffer(data=UInt8[...], readable=true, writable=false, seekable=true, append=false, size=100, maxsize=Inf, ptr=1, mark=-1)

julia> [UnROOT.readtype(s, Int32) for _ in 1:f["t1"]["mynum"].fEntries]
Compressed datastream of 1317 bytes at 6180 (TKey 't1' (TTree))
25-element Array{Int32,1}:
  0
  1
  2
  3
  4
  5
  6
  7
  8
  9
 10
 10
 10
 10
 10
```

## Main challenges

- ROOT data is generally stored as big endian and is a
  self-descriptive format, i.e. so-called streamers are stored in the files
  which describe the actual structure of the data in the corresponding branches.
  These streamers are read during runtime and need to be used to generate
  Julia structs and `unpack` methods on the fly.
- Performance is very important for a low level I/O library.


## Low hanging fruits

Pick one ;)

- [x] Parsing the file header
- [x] Read the `TKey`s of the top level dictionary
- [x] Reading the available trees
- [ ] Reading the available streamers
- [x] Reading a simple dataset with primitive streamers
- [x] Reading of raw basket bytes for debugging
- [ ] Automatically generate streamer logic
- [ ] Parsing `TNtuple`

## Acknowledgements

Special thanks to Jim Pivarski ([@jpivarski](https://github.com/jpivarski))
from the [Scikit-HEP](https://github.com/scikit-hep) project, who is the
main author of [uproot](https://github.com/scikit-hep/uproot), a native
Python library to read and write ROOT files, which was and is a great source
of inspiration and information for reverse engineering the ROOT binary
structures.
