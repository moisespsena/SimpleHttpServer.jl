# SimpleHttpServer module
#
# Serve HTTP requests and WebSockets in Julia.
#
module SimpleHttpServer

if VERSION < v"0.4.0-dev"
    using Docile
    eval(:(@docstrings(manual = ["../README.md"])))
end

using SimpleHttpCommon
using Compat
using Nettle
using Codecs
using WebSockets
using GnuTLS
using Match
using JSON
import WebSockets: WebSocket, close
import Base: listen, UVError, write
import DataStructures:OrderedDict

const C = SimpleHttpCommon

export HTPHandler,
    Server,
    HTTPServer,
    handle,
    http_handle,
    Request,
    Response,
    headers,
    run,
    listen,
    Iterable,
    readbytes,
    readline,
    readuntil,
    BytesReaderIterator,
    BytesFileIterator,
    LimitedBytesFileIterator,
    FileResponse,
    mh,
    mh_push!

hc_event = SimpleHttpCommon.event

typealias NothingOrUVServer Union(Nothing, Base.UVServer)

type TCPHandler
    handle::Function
    sock::NothingOrUVServer
    events::Dict{String, Function}

    TCPHandler(handle::Function, sock::NothingOrUVServer, events::Dict{String, Function}) = new(handle, sock, events)
    TCPHandler(handle::Function, sock::NothingOrUVServer) = TCPHandler(handle, sock, defaultevents)
    TCPHandler(handle::Function) = TCPHandler(handle, nothing)
end


type Server
    handler::TCPHandler
    error_count::BigInt
    last_client_id::BigInt
    options::Associative{Any, Any}

    Server(handler::TCPHandler, args...) = new(handler, BigInt(0), BigInt(0), Dict{Any,Any}(args))
end


function increase_error(s::Server)
    s.error_count += 1
    return s.error_count
end

function increase_client_id(s::Server)
    s.last_client_id += 1
    return s.last_client_id
end

typealias ClientAddr Union(Nothing, IPv4, IPv6)
typealias ClientHostName Union(Nothing, String)

type Client
    id::BigInt
    server::Server
    sock
    finished::Bool
    addr::ClientAddr
    hostname::ClientHostName

    Client(s::Server, sc, f::Bool) = new(increase_client_id(s), s, sc, f, nothing, nothing)
    Client(s::Server, sc) = Client(s, sc, true)
end

type Error
    id::BigInt
    req::Request
    res
    error
    traceback
end

function print_error(io::IO, e::Error)
    println(io, "[REQUEST_EXCEPTION $(e.id)] BEGIN")
    println(io, "Request error: $(typeof(e.error))")
    println(io, "Request msg: $(e.error)")
    println(io, "Request OPEN: $(isopen(e.req.sock))")
    println(io, "Request: $(e.req)")
    println(io, "")
    showerror(io, e.error, e.traceback)
    println(io, "")
    println(io, "[REQUEST_EXCEPTION $(e.id)] END")
end

function print_respose_iter_error(io::IO, e::Error)
    println(io, "[RESPONSE_ITER_DATA_EXCEPTION $(e.id) BEGIN")
    println(io, "Response: $(e.res)")
    println(io, "")
    showerror(io, e.error, e.traceback)
    println(io, "")
    println(io, "[RESPONSE_ITER_DATA_EXCEPTION $(e.id)] END")
end

function read_ip(sock)
  buffer = Array(Uint8,32)
  bufflen::Int64 = 32

  ccall(:uv_tcp_getpeername,Int64,(Ptr{Void},Ptr{Uint8},Ptr{Int64}), sock.handle,buffer,&bufflen)

  b = buffer[5:8]
  ip = IPv4(b...)
  ip
end

defaultevents = Dict{String, Function}()
defaultevents["error"]  = ( client, err ) -> println( err )
defaultevents["listen"] = ( saddr ) -> println("Listening on $saddr...")
defaultevents["connect"] = ( client ) -> begin
  ip = read_ip(client.sock)
  println("Client connect from: $ip")
  client.addr = ip
end

defaultevents["request_sock_error"] = ( error ) -> begin
    print_error(STDERR, "Sock error: $(error.error)")
end

defaultevents["request_error"] = ( error ) -> begin
    print_error(STDERR, error)
end

defaultevents["post_request_init"] = ( req ) -> begin
    req.events["post_header"] = http_post_header
    req.events["error"] = request_error
    req.events["response_iter_data_error"] = response_iter_data_error
end

defaultevents["response_iter_data_error"] = ( error ) -> begin
    print_respose_iter_error(STDERR, error)
end

function response_iter_data_error(error::Error)
    io = IOBuffer()
    print_respose_iter_error(io, error)
    write_chunk(error.req.sock, takebuf_array(io))
end

function request_error(error::Error, set_res::Function)
    io = IOBuffer()
    print_error(io, error)
    set_res(Response(500, takebuf_array(io)))
end

# copy from: https://github.com/JuliaWeb/WebSockets.jl/blob/master/src/WebSockets.jl
# get key out of request header
get_websocket_key(request::Request) = begin
  return request.headers["Sec-WebSocket-Key"]
end

# copy from: https://github.com/JuliaWeb/WebSockets.jl/blob/master/src/WebSockets.jl
# the protocol requires that a special key
# be processed and sent back with the handshake response
# to prove that received the HTTP request
# and that we *really* know what webSockets means.
function generate_websocket_key(key)
  h = HashState(SHA1)
  update!(h, key*"258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
  bytestring(encode(Base64, digest!(h)))
end


# perform the handshake assuming it's a websocket request
websocket_handshake(req, res) = begin
  key = get_websocket_key(req)
  resp_key = generate_websocket_key(key)

  #TODO: use a proper HTTP response type
  res.status = 101
  res.headers["Upgrade"] = "websocket"
  res.headers["Connection"] = "Upgrade"
  res.headers["Sec-WebSocket-Accept"] = resp_key
  res.data = ""
end

function http_post_header(req::Request, res::Response)
    if !isempty(req.query)
        req.q = parse_qsr(req.query)
    end

    # using web sockets
    if get(req.headers, "Connection", nothing) == "Upgrade"
        hupgrade = get(req.headers, "Upgrade", "")
        if hupgrade == "websocket"
            if get(req.env["server"].options, :ws, true)
                req.websocket = WebSockets.WebSocket(0, req.sock)
                websocket_handshake(req, res)
            else
                throw(HTTPParserHeaderException("Websockts not allowed"))
            end
        else
            throw(HTTPParserHeaderException("Invalid Connection HEADER", "Upgrade: $(hupgrade)"))
        end
    end

    ct = get(req.headers, "Content-Type", "")

    if search(ct, "application/x-www-form-urlencoded").start > 0
        req.p = parse_qsr(C.bodys(req))
    elseif search(ct, "application/json").start > 0
        req.p = JSON.parse(C.bodys(req))
    end
end

handle(h::TCPHandler, c::Client) = h.handle(c)


type HTTPParserHeaderException <: Exception
    message::String
    line::Union(Nothing, String)

    HTTPParserHeaderException(m::String, l::Union(Nothing, String)) = new(m, l)
    HTTPParserHeaderException(m::String) = new(m, nothing)
end


function default_http_processor(client::Client, resource_handler::Function)
    req = Request(client.sock)
    req.env["client"] = client
    req.env["server"] = client.server
    event(client.server, "post_request_init", req)
    res = Response()
    res.req = req
    res_arr = [res]
    write_res = true
    uv_error = false

    try
        try
            parse_http_headers(req)
            hc_event(req, "post_header", req, res)

            # see http://tools.ietf.org/html/rfc7230#section-6.3
            if req.protocol != nothing && get(req.headers, "Connection", nothing) != "close"
                if req.protocol.name == "HTTP" && req.protocol.version >= v"1.1"
                    client.finished = false
                end
            end

            hc_event(req, "pre_handler", req)

            req.finished = client.finished
        catch e
            if isa(e, UVError)
                client.finished = true
                write_res = false
                error = Error(increase_error(client.server), req, res, e, catch_backtrace())
                event(client.server, "request_socket_error", error)
                hc_event(req, "socket_error", error, (new_res) -> begin
                                res_arr[1] = new_res
                            end)
                return
            else
                rethrow()
            end
        end

        if req.websocket != nothing
            write_res = false
            write(req.sock, res)
            resource_handler(req)
            WebSockets.close(req.websocket)
        else
            res2 = resource_handler(req)

            if isa(res2, Response)
                res2.req = req
                res_arr[1] = res2
            end
        end
        hc_event(req, "post_handler", res, (new_res) -> begin
                        res_arr[1] = new_res
                     end)
    catch e
        if isa(e, CloseClientException)
            client.finished = true
            write_res = false
        else
            res = res_arr[1]
            res.status = 500

            error = Error(increase_error(client.server), req, res, e, catch_backtrace())
            event(client.server, "request_error", error)
            hc_event(req, "error", error, (new_res) -> begin
                            res_arr[1] = new_res
                        end)
        end
    finally
        if write_res && isopen(req.sock)
            res = res_arr[1]
            write(req.sock, res)
        end
    end
end

function http_handler(resource_handler::Function)
    callback = client::Client -> default_http_processor(client, resource_handler)
    TCPHandler(callback)
end

Server(handler::Function; args...) = Server(TCPHandler(handler), args...)
HTTPServer(resource_handler::Function; args...) = Server(http_handler(resource_handler), args...)


function event(server::Server, event::String, args...)
    haskey(server.handler.events, event) && server.handler.events[event](args...)
end


@doc "Converts a `Response` to an HTTP response string" ->
function write{T<:IO}(io::T, res::Response)
    write(io, join(["HTTP/1.1", res.status, STATUS_CODES[res.status], "\r\n"], " "))

    it = nothing

    if isa(res.data, Iterable) || isa(res.data, Task)
        it = res.data
    elseif isa(res.data, Function)
        it = Iterable(Task(res.data))
    end

    if it != nothing
        res.headers["Transfer-Encoding"] = "chunked"
    elseif !haskey(res.headers, "Content-Length")
        res.headers["Content-Length"] = string(sizeof(res.data))
    end

    for (header, value) in res.headers
        write(io, @sprintf "%s: %s\r\n" header value)
    end

    for (header, value_list) in res.mheaders
        for value in value_list
            write(io, @sprintf "%s: %s\r\n" header value)
        end
    end

    write(io, "\r\n")

    if it == nothing
        write(io, res.data)
    else
        try
            for data in it.data
                write_chunk(io, data)
            end
        catch e
            bt = catch_backtrace()
            req = res.req
            server = req.env["server"]
            error = Error(increase_error(server), req, res, e, bt)
            event(server, "response_iter_data_error", error)
            hc_event(req, "response_iter_data_error", error)
        end

        write(io, @sprintf "%x\r\n" 0)
        write(io, "\r\n")
        write(io, "\r\n")
    end
end

function listen(server::Server, host::Base.IpAddr, port::Integer)
    server.handler.sock = listen(host, port)
    inet = "$host:$port"
    event(server, "listen", inet)
    return server
end

listen(server::Server, port::Integer) = listen(server, IPv4(0), port)

@unix_only function listen(server::Server, path::String)
    bind(server.handler.sock, path) || throw(ArgumentError("could not listen on path $path"))
    Base.uv_error("listen", Base._listen(server.handler.sock))
    event(server, "listen", path)
    return server
end


function run(server::Server; args...)
    params = Dict(args)

    # parse parameters
    port = get(params, :port, 0)
    host = get(params, :host, IPv4(0))
    use_https = haskey(params, :ssl)
    use_sockets = @unix? (haskey(params, :socket) && !haskey(params, :port)) : false

    server = if use_sockets
        listen(server, params[:socket])  # start server on Unix socket
    else
        listen(server, host, port)       # start server on network socket
    end

    if use_https
        println("HTTPS")
        #handle_https_request(server, params[:ssl])
    else
        handle_http_request(server)
    end
end

@doc """ Handle HTTP request from client """ ->
function handle_http_request(server::Server)
    # handle requests, Base.wait_accept blocks until a connection is made
    while true
        sock = accept(server.handler.sock)
        @async process_sock(server, sock)
    end
end

@doc """ Handle HTTPS request from client """ ->
function handle_https_request(server::Server, cert_store::GnuTLS.CertificateStore)
    while true
        sess = GnuTLS.Session(true)
        set_priority_string!(sess)
        set_credentials!(sess, cert_store)
        client = accept(server.handler.sock)
        try
            associate_stream(sess, client)
            handshake!(sess)
        catch e
            println("Error establishing SSL connection: ", e)
            close(client)
            continue
        end
        sock = accept(server.handler.sock)
        @async process_sock(server, sock)
    end
end


function process_sock(server::Server, sock)
    client = Client(server, sock)
    event(server, "connect", client)

    while isopen(sock)
        try
            handle(server.handler, client)
        catch e
            if isa(e,GnuTLS.GnuTLSException) && e.code == -110
                # Because Chrome is buggy on OS X, ignore E_PREMATURE_TERMINATION
            else
                bt = catch_backtrace()
                err_num = increase_error(server)

                print_error = io -> begin
                    println(io, "[CLIENT_EXCEPTION $err_num] Begin")
                    println(io, "Client: $client")
                    println(io, "Error Type: $(typeof(e))")
                    println(io, "")
                    showerror(io, e, bt)
                    println(io, "")
                    println(io, "[CLIENT_EXCEPTION $err_num] End")
                end

                print_error(STDERR)

                client.finished = true
            end
        finally
            if client.finished
                if isopen(sock)
                    close(sock)
                end

                break
            end
        end
    end

    event(server, "close", client)
end

end # module
