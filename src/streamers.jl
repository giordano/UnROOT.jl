struct StreamerInfo
    streamer
    dependencies
end

struct Streamers
    tkey::TKey
    refs::Dict{Int32, Any}
    elements::Vector{StreamerInfo}
end

Base.length(s::Streamers) = length(s.elements)

function Base.show(io::IO, s::Streamers)
    for streamer_info in s.elements
        println(io, "$(streamer_info.streamer.fName)")
        # streamer = streamer_info.streamer
        # print(io, "$(streamer.fName): fType = $(streamer.fType), ")
        # print(io, "fTypeName: $(streamer.fTypeName)")
    end
end


# Structures required to read streamers
struct TStreamerInfo
    fName
    fTitle
    fCheckSum
    fClassVersion
    fElements
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerInfo})
    preamble = Preamble(io, T)
    fName, fTitle = nametitle(io)
    fCheckSum = readtype(io, UInt32)
    fClassVersion = readtype(io, Int32)
    fElements = readobjany!(io, tkey, refs)
    endcheck(io, preamble)
    T(fName, fTitle, fCheckSum, fClassVersion, fElements)
end

safename(s::AbstractString) = replace(s, "::" => "_3a3a_")

function initialise_streamer(s::StreamerInfo)
    # FIXME Abstract is not needed when switched to autogenerated streamers
    base = Symbol(safename(s.streamer.fName))
    supername = Symbol(:Abstract, base)
    if !isdefined(@__MODULE__, supername)
        @debug "Defining abstract type $supername"
        @eval abstract type $(supername) <: ROOTStreamedObject end
    end

    name = Symbol(base, Symbol("_$(s.streamer.fClassVersion)"))
    if !isdefined(@__MODULE__, name)
        @debug "  creating versioned struct '$name <: $supername'"
        @eval struct $(name) <: $(supername) end
        # FIXME create the stream!() functions somewhere here...
        # println(name)
        # @eval struct $name <: ROOTStreamedObject
        #     data::Dict{Symbol, Any}
        # end
    else
        @debug "Not defining $name since it already has a bootstrapped version"
    end
end


"""
    function Streamers(io)

Reads all the streamers from the ROOT source.
"""
function Streamers(io)
    refs = Dict{Int32, Any}()

    start = position(io)
    tkey = unpack(io, TKey)

    if iscompressed(tkey)
        seekstart(io, tkey)
        compression_header = unpack(io, CompressionHeader)
        compression_algo = String(compression_header.algo)
        @debug "Compressed stream ($compression_algo) at $(start)"
        @show compression_header

        if compression_algo == "L4"
            println("Skipping L4 stream with $(tkey.fObjlen) bytes")
            # stream = IOBuffer(read(LZ4SafeDecompressorStream(io; block_size=tkey.fObjlen), tkey.fObjlen))
        end
        if compression_algo == "ZL"
            stream = IOBuffer(read(ZlibDecompressorStream(io), tkey.fObjlen))
        end
    else
        @debug "Unompressed stream at $(start)"
        stream = io
    end
    preamble = Preamble(stream, Streamers)
    skiptobj(stream)

    name = readtype(stream, String)
    size = readtype(stream, Int32)
    streamer_infos = Vector{StreamerInfo}()
    @debug "Found $size streamers, continue with parsing."
    for i ∈ 1:size
        obj = readobjany!(stream, tkey, refs)
        if typeof(obj) == TStreamerInfo
            @debug "  processing streamer info for '$(obj.fName)' (v$(obj.fClassVersion))"
            @debug "    number of dependencies: $(length(obj.fElements.elements))"
            dependencies = Set()
            for element in obj.fElements.elements
                if typeof(element) == TStreamerBase
                    @debug "      + adding dependency '$(element.fName)'"
                    push!(dependencies, element.fName)
                else
                    @debug "      - skipping dependency '$(element.fName)' with type '$(typeof(element))'"
                end
            end
            @debug "      => finishing dependency readout for: $(obj.fName)"
            push!(streamer_infos, StreamerInfo(obj, dependencies))
        else
            @debug "  not a TStreamerInfo but '$(typeof(obj))', skipping."
        end
        # FIXME why not just skip a byte?
        skip(stream, readtype(stream, UInt8))
    end

    endcheck(stream, preamble)

    streamer_infos = topological_sort(streamer_infos)

    for streamer_info in streamer_infos
        initialise_streamer(streamer_info)
    end

    Streamers(tkey, refs, streamer_infos)
end

"""
    function topological_sort(streamer_infos)

Sort the streamers with respect to their dependencies and keep only those
which are not defined already.

The implementation is based on https://stackoverflow.com/a/11564769/1623645
"""
function topological_sort(streamer_infos)
    @debug "Starting topological sort of streamers"
    provided = Set{String}()
    sorted_streamer_infos = []
    while length(streamer_infos) > 0
        remaining_items = []
        emitted = false
        @debug "  number of remaining streamers to sort: $(length(streamer_infos))"

        for streamer_info in streamer_infos
            # if all(d -> isdefined(@__MODULE__, Symbol(d)) || d ∈ provided, streamer_info.dependencies)
            #     if !isdefined(@__MODULE__, Symbol(streamer_info.streamer.fName)) && aliasfor(streamer_info.streamer.fName) === nothing
            @debug "    processing '$(streamer_info.streamer.fName)' with $(length(streamer_info.dependencies))' dependencies"
            if length(streamer_infos) ==  1 || all(d -> d ∈ provided, streamer_info.dependencies)
                if aliasfor(streamer_info.streamer.fName) === nothing
                    push!(sorted_streamer_infos, streamer_info)
                end
                push!(provided, streamer_info.streamer.fName)
                emitted = true
            else
                push!(remaining_items, streamer_info)
            end
        end

        if !emitted
            for streamer_info in streamer_infos
                filter!(isequal(streamer_info), remaining_items)
            end
        end

        streamer_infos = remaining_items
    end
    @debug "Finished the topological sort of streamers"
    sorted_streamer_infos
end


"""
    function readobjany!(io, tkey::TKey, refs)

The main entrypoint where streamers are parsed and cached for later use.
The `refs` dictionary holds the streamers or parsed data which are reused
when already available.
"""
function readobjany!(io, tkey::TKey, refs)
    beg = position(io) - origin(tkey)
    bcnt = readtype(io, UInt32)
    if Int64(bcnt) & Const.kByteCountMask == 0 || Int64(bcnt) == Const.kNewClassTag
        # New class or 0 bytes
        version = 0
        start = 0
        tag = bcnt
        bcnt = 0
    else
        version = 1
        start = position(io) - origin(tkey)
        tag = readtype(io, UInt32)
    end

    if Int64(tag) & Const.kClassMask == 0
        # reference object
        if tag == 0
            return missing
        elseif tag == 1
            error("Returning parent is not implemented yet")
        elseif !haskey(refs, tag)
            # skipping
            seek(io, origin(tkey) + beg + bcnt + 4)
            return missing
        else
            return refs[tag]
        end

    elseif tag == Const.kNewClassTag
        cname = readtype(io, CString)
        streamer = getfield(@__MODULE__, Symbol(cname))

        if version > 0
            refs[start + Const.kMapOffset] = streamer
        else
            refs[length(refs) + 1] = streamer
        end

        obj = unpack(io, tkey, refs, streamer)

        if version > 0
            refs[beg + Const.kMapOffset] = obj
        else
            refs[length(refs) + 1] = obj
        end

        return obj
    else
        # reference class, new object
        ref = Int64(tag) & ~Const.kClassMask
        haskey(refs, ref) || error("Invalid class reference.")

        streamer = refs[ref]
        obj = unpack(io, tkey, refs, streamer)

        if version > 0
            refs[beg + Const.kMapOffset] = obj
        else
            refs[length(refs) + 1] = obj
        end

        return obj
    end
end



struct TList
    preamble
    name
    size
    objects
end

Base.length(l::TList) = length(l.objects)


function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TList})
    preamble = Preamble(io, T)
    skiptobj(io)

    name = readtype(io, String)
    size = readtype(io, Int32)
    objects = []
    for i ∈ 1:size
        push!(objects, readobjany!(io, tkey, refs))
        skip(io, readtype(io, UInt8))
    end

    endcheck(io, preamble)
    TList(preamble, name, size, objects)
end


struct TObjArray
    name
    low
    elements
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TObjArray})
    preamble = Preamble(io, T)
    skiptobj(io)
    name = readtype(io, String)
    size = readtype(io, Int32)
    low = readtype(io, Int32)
    elements = [readobjany!(io, tkey, refs) for i in 1:size]
    endcheck(io, preamble)
    return TObjArray(name, low, elements)
end


abstract type AbstractTStreamerElement end

@premix @with_kw mutable struct TStreamerElementTemplate
    version
    fOffset
    fName
    fTitle
    fType
    fSize
    fArrayLength
    fArrayDim
    fMaxIndex
    fTypeName
    fXmin
    fXmax
    fFactor
end

@TStreamerElementTemplate mutable struct TStreamerElement end

@pour initparse begin
    fields = Dict{Symbol, Any}()
end

function parsefields!(io, fields, T::Type{TStreamerElement})
    preamble = Preamble(io, T)
    fields[:version] = preamble.version
    fields[:fOffset] = 0
    fields[:fName], fields[:fTitle] = nametitle(io)
    fields[:fType] = readtype(io, Int32)
    fields[:fSize] = readtype(io, Int32)
    fields[:fArrayLength] = readtype(io, Int32)
    fields[:fArrayDim] = readtype(io, Int32)

    n = preamble.version == 1 ? readtype(io, Int32) : 5
    fields[:fMaxIndex] = [readtype(io, Int32) for _ in 1:n]

    fields[:fTypeName] = readtype(io, String)

    if fields[:fType] == 11 && (fields[:fTypeName] == "Bool_t" || fields[:fTypeName] == "bool")
        fields[:fType] = 18
    end

    fields[:fXmin] = 0.0
    fields[:fXmax] = 0.0
    fields[:fFactor] = 0.0

    if preamble.version == 3
        fields[:fXmin] = readtype(io, Float64)
        fields[:fXmax] = readtype(io, Float64)
        fields[:fFactor] = readtype(io, Float64)
    end

    endcheck(io, preamble)
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerElement})
    @initparse
    parsefields!(io, fields, T)
    T(;fields...)
end


@TStreamerElementTemplate mutable struct TStreamerBase
    fBaseVersion
end

function parsefields!(io, fields, T::Type{TStreamerBase})
    preamble = Preamble(io, T)
    parsefields!(io, fields, TStreamerElement)
    fields[:fBaseVersion] = fields[:version] >= 2 ? readtype(io, Int32) : 0
    endcheck(io, preamble)
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerBase})
    @initparse
    parsefields!(io, fields, T)
    T(;fields...)
end


@TStreamerElementTemplate mutable struct TStreamerBasicType end

function parsefields!(io, fields, ::Type{TStreamerBasicType})
    parsefields!(io, fields, TStreamerElement)

    if Const.kOffsetL < fields[:fType] < Const.kOffsetP
        fields[:fType] -= Const.kOffsetP
    end
    basic = true
    if fields[:fType] ∈ (Const.kBool, Const.kUChar, Const.kChar)
        fields[:fSize] = 1
    elseif fields[:fType] in (Const.kUShort, Const.kShort)
        fields[:fSize] = 2
    elseif fields[:fType] in (Const.kBits, Const.kUInt, Const.kInt, Const.kCounter)
        fields[:fSize] = 4
    elseif fields[:fType] in (Const.kULong, Const.kULong64, Const.kLong, Const.kLong64)
        fields[:fSize] = 8
    elseif fields[:fType] in (Const.kFloat, Const.kFloat16)
        fields[:fSize] = 4
    elseif fields[:fType] in (Const.kDouble, Const.kDouble32)
        fields[:fSize] = 8
    elseif fields[:fType] == Const.kCharStar
        fields[:fSize] = sizeof(Int)
    else
        basic = false
    end

    if basic && fields[:fArrayLength] > 0
        fields[:fSize] *= fields[:fArrayLength]
    end

end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerBasicType})
    @initparse
    preamble = Preamble(io, T)
    parsefields!(io, fields, T)
    endcheck(io, preamble)
    T(;fields...)
end


@TStreamerElementTemplate mutable struct TStreamerBasicPointer
    fCountVersion
    fCountName
    fCountClass
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerBasicPointer})
    @initparse
    preamble = Preamble(io, T)
    parsefields!(io, fields, TStreamerElement)
    fields[:fCountVersion] = readtype(io, Int32)
    fields[:fCountName] = readtype(io, String)
    fields[:fCountClass] = readtype(io, String)
    endcheck(io, preamble)
    T(;fields...)
end

@TStreamerElementTemplate mutable struct TStreamerLoop
    fCountVersion
    fCountName
    fCountClass
end

components(::Type{TStreamerLoop}) = [TStreamerElement]

function parsefields!(io, fields, ::Type{TStreamerLoop})
    fields[:fCountVersion] = readtype(io, Int32)
    fields[:fCountName] = readtype(io, String)
    fields[:fCountClass] = readtype(io, String)
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TStreamerLoop})
    @initparse
    preamble = Preamble(io, T)
    for component in components(T)
        parsefields!(io, fields, component)
    end
    parsefields!(io, fields, T)
    endcheck(io, preamble)
    T(;fields...)
end

abstract type AbstractTStreamSTL end

@TStreamerElementTemplate mutable struct TStreamerSTL <: AbstractTStreamSTL
    fSTLtype
    fCtype
end

@TStreamerElementTemplate mutable struct TStreamerSTLstring <: AbstractTStreamSTL
    fSTLtype
    fCtype
end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, ::Type{T}) where T <: AbstractTStreamSTL
    @initparse
    if T == TStreamerSTLstring
        wrapper_preamble = Preamble(io, T)
    end
    preamble = Preamble(io, T)
    parsefields!(io, fields, TStreamerElement)

    fields[:fSTLtype] = readtype(io, Int32)
    fields[:fCtype] = readtype(io, Int32)

    if fields[:fSTLtype] == Const.kSTLmultimap || fields[:fSTLtype] == Const.kSTLset
        if startswith(fields[:fTypeName], "std::set") || startswith(fields[:fTypeName], "set")
            fields[:fSTLtype] = Const.kSTLset
        elseif startswith(fields[:fTypeName], "std::multimap") || startswith(fields[:fTypeName], "multimap")
            fields[:fSTLtype] = Const.kSTLmultimap
        end
    end

    endcheck(io, preamble)
    if T == TStreamerSTLstring
        endcheck(io, wrapper_preamble)
    end
    T(;fields...)
end


const TObjString = String

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{TObjString})
    preamble = Preamble(io, T)
    skiptobj(io)
    value = readtype(io, String)
    endcheck(io, preamble)
    T(value)
end


abstract type AbstractTStreamerObject end

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, ::Type{T}) where T<:AbstractTStreamerObject
    @initparse
    preamble = Preamble(io, T)
    parsefields!(io, fields, TStreamerElement)
    endcheck(io, preamble)
    T(;fields...)
end

@TStreamerElementTemplate mutable struct TStreamerObject <: AbstractTStreamerObject end
@TStreamerElementTemplate mutable struct TStreamerObjectAny <: AbstractTStreamerObject end
@TStreamerElementTemplate mutable struct TStreamerObjectAnyPointer <: AbstractTStreamerObject end
@TStreamerElementTemplate mutable struct TStreamerObjectPointer <: AbstractTStreamerObject end
@TStreamerElementTemplate mutable struct TStreamerString <: AbstractTStreamerObject end



abstract type ROOTStreamedObject end

# function stream(io, ::Type{T}) where {T<:ROOTStreamedObject}
#     fields = Dict{Symbol, Any}()
#     preamble = Preamble(io, T)
#     stream!(io, fields, T{preamble.version})
#     endcheck(io, preamble)
#     T(fields)
# end

function stream!(io, fields, ::Type{T}) where {T<:ROOTStreamedObject}
    preamble = Preamble(io, T)
    streamer_name = Symbol(T, "_$(preamble.version)")
    # @show streamer_name
    mod, typename = split(String(streamer_name), ".")
    # @show mod typename
    streamer = getfield(@__MODULE__, Symbol(typename))
    # @show streamer
    readfields!(io, fields, streamer)
    endcheck(io, preamble)
end


function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, ::Type{T}) where {T<:ROOTStreamedObject}
    cursor = Cursor(position(io), io, tkey, refs)
    @initparse
    preamble = Preamble(io, T)
    streamer_name = Symbol(T, "_$(preamble.version)")
    mod, typename = split(String(streamer_name), ".")
    streamer = getfield(@__MODULE__, Symbol(typename))
    readfields!(cursor, fields, streamer)
    streamer(;cursor=cursor, fields...)
end



# function stream!(io, fields, ::Type{T{V}}) where {V, T<:ROOTStreamedObject}
#     println("Don't know how to stream $T")
# end


struct TObject <: ROOTStreamedObject end
parsefields!(io, fields, ::Type{TObject}) = skiptobj(io)

struct TString <: ROOTStreamedObject end
unpack(io, tkey::TKey, refs::Dict{Int32, Any}, ::Type{TString}) = readtype(io, String)

struct Undefined <: ROOTStreamedObject
    skipped_bytes
end

Base.show(io::IO, u::Undefined) = print(io, "$(typeof(u)) ($(u.skipped_bytes) bytes)")

function unpack(io, tkey::TKey, refs::Dict{Int32, Any}, T::Type{Undefined})
    preamble = Preamble(io, T)
    bytes_to_skip = preamble.cnt - 6
    skip(io, bytes_to_skip)
    endcheck(io, preamble)
    Undefined(bytes_to_skip)
end

const TArrayD = Vector{Float64}
const TArrayI = Vector{Int32}

function readtype(io, T::Type{Vector{U}}) where U <: Union{Integer, AbstractFloat}
    size = readtype(io, eltype(T))
    [readtype(io, eltype(T)) for _ in 1:size]
end

