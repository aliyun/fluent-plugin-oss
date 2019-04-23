module Fluent
  module Plugin
    class OSSInput
      # This class uses lzop command to decompress chunks.
      class LZODecompressor < Decompressor
        OSSInput.register_decompressor('lzo', self)

        config_param :command_parameter, :string, default: '-qdc'

        def configure(conf)
          super
          check_command('lzop', 'LZO')
        end

        def ext
          'lzo'.freeze
        end

        def content_type
          'application/x-lzop'.freeze
        end

        def decompress(io)
          path = io.path

          out, err, status = Open3.capture3("lzop #{@command_parameter} #{path}")
          if status.success?
            out
          else
            raise err.to_s.chomp
          end
        end
      end
    end
  end
end