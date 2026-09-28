module DppValidator
  module Transport
    class Timeout < DppValidator::Error; end

    # Non-blocking reads and writes on a socket (plain or TLS) with an
    # absolute deadline.
    module IoDeadline
      module_function

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def deadline(seconds) = now + seconds

      def wait(io, direction, deadline)
        remaining = deadline - now
        raise Timeout, "timed out" if remaining <= 0

        ready = direction == :read ? IO.select([io], nil, nil, remaining) : IO.select(nil, [io], nil, remaining)
        raise Timeout, "timed out" unless ready
      end

      # Returns data, or nil at the end of the stream.
      def read(io, deadline, max = 16_384)
        loop do
          chunk = io.read_nonblock(max, exception: false)
          case chunk
          when :wait_readable then wait(io, :read, deadline)
          when :wait_writable then wait(io, :write, deadline)
          else return chunk
          end
        end
      end

      def write(io, data, deadline)
        data = data.b
        until data.empty?
          written = io.write_nonblock(data, exception: false)
          case written
          when :wait_readable then wait(io, :read, deadline)
          when :wait_writable then wait(io, :write, deadline)
          else data = data.byteslice(written..)
          end
        end
      end
    end
  end
end
