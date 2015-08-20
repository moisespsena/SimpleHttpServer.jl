# SimpleHttpServer.jl

This is a basic, non-blocking Simple HTTP server in Julia.

You can write a basic application using just this if you're happy dealing with values representing HTTP requests and responses directly.


##Installation
Use Julia package manager to install this package as follows:
```
Pkg.add("SimpleHttpServer")
```

## Functionality
* binds to any address and port
* supports IPv4 & IPv6 addresses
* supports HTTP, HTTPS and Unix socket transports
* supports WebSockets

You can find many examples of how to use this package in the `examples` folder.

## Example

```julia
using SimpleHttpServer
using Debug
using WebSockets
import WebSockets:read, write

function my_chunked_lines()
    produce("line1\n")
    produce("line2\n")
    produce("line3\n")
end

server = HTTPServer(ws=true) do req::Request
    if req.resource == "/"
        if req.websocket != nothing
            msg = bytestring(WebSockets.read(req.websocket))
            println("Received message: $msg")
            WebSockets.write(req.websocket, "The received message in server is: $msg")
        else
          Response(200, """
<!DOCTYPE HTML>
<html>
   <head>
	
      <script type="text/javascript">
         function WebSocketTest()
         {
            if ("WebSocket" in window)
            {
               // Let us open a web socket
               var ws = new WebSocket(location.href.replace("http", "ws"));
				
               ws.onopen = function() {
                  // Web Socket is connected, send data using send()
                  ws.send("test message send from browser.");
                  alert("Message is sent...");
               };
				
               ws.onmessage = function (evt) { 
                  var received_msg = evt.data;
                  alert("Message is received: [" + received_msg + "]");
               };
				
               ws.onclose = function() { 
                  // websocket is closed.
                  alert("Connection is closed..."); 
               };
            } else {
               // The browser doesn't support WebSocket
               alert("WebSocket NOT supported by your Browser!");
            }
         }
      </script>
		
   </head>
   <body>
   
      <div id="sse">
         <a href="javascript:WebSocketTest()">Run WebSocket</a> |
         <a href="/chunk_function">Chunk Data from Function</a> |
         <a href="/chunk_task">Chunk Data from Task</a> |
         <a href="/chunk_iterable">Chunk Data from Iterable</a>
      </div>
      
   </body>
</html>
          """)
        end
    elseif req.resource == "/chunk_function"
        Response(200, my_chunked_lines)
    elseif req.resource == "/chunk_task"
        Response(200, Task(my_chunked_lines))
    elseif req.resource == "/chunk_iterable"
        Response(200, Iterable(["a", "b", "c"]))
    elseif req.resource == "/error_1"
        c["Key"]
    elseif req.resource == "/error_2"
        Response(200, () -> begin
            produce("gen error")
            produce(d["Key"])
            produce("end gen error")
        end)
    end
end

run(server, port=9100)
# or
run(server, host=IPv4(127,0,0,1), port=9100)
```
If you open up `localhost:9100/` in your browser, you should get a greeting from the server.
