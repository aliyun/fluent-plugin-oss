module Fluent
  module Plugin
    class OSSInput
      # This class uses gzip command to decompress chunks.
      class GzipCommandDecompressor < Decompressor
        OSSInput.register_decompressor('gzip_command', self)

        config_param :command_parameter, :string, default: '-dc'

        def configure(conf)
          super
          check_command('gzip')
        end

        def ext
          'gz'.freeze
        end

        def content_type
          'application/x-gzip'.freeze
        end

        def decompress(io)
          path = io.path

          out, err, status = Open3.capture3("gzip #{@command_parameter} #{path}")
          if status.success?
            out
          else
            log.warn "failed to execute gzip command, #{err.to_s.gsub("\n",'')}, fallback to GzipReader."

            begin
              io.rewind
              Zlib::GzipReader.wrap(io)
            end
          end
        end
      end
    end
  end
end
