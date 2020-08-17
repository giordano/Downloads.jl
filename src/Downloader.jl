module Downloader

export add_download, download

using LibCURL

const CURL_VERSION = unsafe_string(curl_version())
const USER_AGENT = "$CURL_VERSION julia/$VERSION"

mutable struct Curl
    multi::Ptr{Cvoid}
    timer::Ptr{Cvoid}
end

include("helpers.jl")
include("callbacks.jl")

## setup & teardown ##

function Curl()
    uv_timer_size = Base._sizeof_uv_timer
    timer = ccall(:jl_malloc, Ptr{Cvoid}, (Csize_t,), uv_timer_size)
    uv_timer_init(timer)

    @check curl_global_init(CURL_GLOBAL_ALL)
    multi = curl_multi_init()

    # create object & set finalizer
    curl = Curl(multi, timer)
    finalizer(curl) do curl
        uv_close(curl.timer, cglobal(:jl_free))
        curl_multi_cleanup(curl.multi)
    end
    curl_p = pointer_from_objref(curl)

    # stash curl pointer in timer
    ## TODO: use a member access API
    unsafe_store!(convert(Ptr{Ptr{Cvoid}}, timer), curl_p)

    # set timer callback
    timer_cb = @cfunction(timer_callback, Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))
    @check curl_multi_setopt(multi, CURLMOPT_TIMERFUNCTION, timer_cb)
    @check curl_multi_setopt(multi, CURLMOPT_TIMERDATA, curl_p)

    # set socket callback
    socket_cb = @cfunction(socket_callback,
        Cint, (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    @check curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION, socket_cb)
    @check curl_multi_setopt(multi, CURLMOPT_SOCKETDATA, curl_p)

    return curl
end

function curl_easy_handle(curl::Curl, ch::Channel)
    # init a single curl handle
    easy = curl_easy_init()

    # curl options
    curl_easy_setopt(easy, CURLOPT_TCP_FASTOPEN, true) # failure ok, unsupported
    @check curl_easy_setopt(easy, CURLOPT_NOSIGNAL, true)
    @check curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, true)
    @check curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 10)
    @check curl_easy_setopt(easy, CURLOPT_POSTREDIR, CURL_REDIR_POST_ALL)
    @check curl_easy_setopt(easy, CURLOPT_USERAGENT, USER_AGENT)

    # tell curl where to find HTTPS certs
    certs_file = normpath(Sys.BINDIR, "..", "share", "julia", "cert.pem")
    @check curl_easy_setopt(easy, CURLOPT_CAINFO, certs_file)

    # set write callback
    write_cb = @cfunction(write_callback,
        Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
    @check curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb)

    # associate channel with handle
    ch_p = pointer_from_objref(ch)
    @check curl_easy_setopt(easy, CURLOPT_PRIVATE, ch_p)
    @check curl_easy_setopt(easy, CURLOPT_WRITEDATA, ch_p)

    return easy
end

## API ##

function download(
    curl::Curl,
    url::AbstractString,
    io::IO;
    headers = Union{}[],
)
    ch = Channel{Vector{UInt8}}(Inf)
    easy = curl_easy_handle(curl, ch)
    headers_p = to_curl_slist(headers)
    @check curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headers_p)
    @check curl_easy_setopt(easy, CURLOPT_URL, url)
    @check curl_multi_add_handle(curl.multi, easy)
    for buf in ch
        write(io, buf)
    end
    curl_slist_free_all(headers_p)
    return io
end

end # module
