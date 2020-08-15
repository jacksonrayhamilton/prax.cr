module Prax
  module Middlewares
    class ProxyMiddleware < Base
      def call(handler, &block)
        app = handler.app
        app.start unless app.started?
        app.restart if app.needs_restart?

        #Prax.logger.debug { "connecting to: #{app.name}" }
        app.connect { |server| proxy(handler, server) }
      end

      # TODO: stream response when Content-Length header isn't set (eg: Connection: close)
      # TODO: stream both sides (ie. support websockets)
      def proxy(handler, server)
        request, client = handler.request, handler.client
        Prax.logger.debug { "#{request.method} #{request.uri}" }

        Prax.logger.debug { "sending request from client to server" }
        server << "#{request.method} #{request.uri} #{request.http_version}\r\n"
        proxy_headers(request, handler.tcp_socket, handler.ssl?).each(&.to_s(server))
        server << "\r\n"

        if (len = request.content_length) > 0
          copy_stream(client, server, len)
        end
        Prax.logger.debug { "done sending request from client to server" }

        Prax.logger.debug { "returning response from server to client" }
        response = Parser.new(server).parse_response
        response.to_s(client)

        if response.header("Transfer-Encoding") == "chunked"
          stream_chunked_response(server, client)
        elsif (len = response.content_length) > 0
          copy_stream(server, client, len)
        elsif response.header("Connection") == "close"
          copy_stream(server, client)
        else
          copy_stream(server, client)
        end
        Prax.logger.debug { "done returning response from server to client" }
      end

      # FIXME: should dup the headers to avoid altering the request
      def proxy_headers(request, socket, ssl)
        request.headers.replace("Connection", "close")
        request.headers.prepend("X-Forwarded-For", socket.remote_address.address)
        request.headers.replace("X-Forwarded-Host", request.header("Host").try(&.value).to_s)
        request.headers.replace("X-Forwarded-Proto", ssl ? "https" : "http")
        request.headers.prepend("X-Forwarded-Server", socket.local_address.address)
        request.headers
      end

      def stream_chunked_response(server, client)
        loop do
          break unless line = server.gets(chomp: false)
          client << line
          count = line.to_i(16, whitespace: true)
          copy_stream(server, client, count + 2) # chunk + CRLF
          break if count == 0
        end
      end

      private def copy_stream(input, output, len)
        buffer = uninitialized UInt8[2048]

        Prax.logger.debug { "copying stream" }
        while len > 0
          Prax.logger.debug { "about to read bytes" }
          count = input.read(buffer.to_slice[0, Math.min(len, buffer.size)])
          Prax.logger.debug { "read #{count.inspect} bytes" }
          break if count == 0

          output.write(buffer.to_slice[0, count])
          Prax.logger.debug { "wrote #{count.inspect} bytes" }
          len -= count
        end
        Prax.logger.debug { "finished copying stream" }
      end

      private def copy_stream(input, output)
        buffer = uninitialized UInt8[2048]

        Prax.logger.debug { "copying stream" }
        loop do
          Prax.logger.debug { "about to read bytes" }
          count = input.read(buffer.to_slice[0, buffer.size])
          Prax.logger.debug { "read #{count.inspect} bytes" }
          break if count == 0
          output.write(buffer.to_slice[0, count])
          Prax.logger.debug { "wrote #{count.inspect} bytes" }
        end
        Prax.logger.debug { "finished copying stream" }
      end
    end
  end
end
