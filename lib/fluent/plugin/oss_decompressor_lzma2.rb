module Fluent
  module Plugin
    class OSSInput
      # This class uses xz command to decompress chunks.
      class LZMA2Decompressor < Decompressor
        OSSInput.register_decompressor('lzma2', self)

        config_param :command_parameter, :string, default: '-qdc'

        def configure(conf)
          super
          check_command('xz', 'LZMA')
        end

        def ext
          'xz'.freeze
        end

        def content_type
          'application/x-xz'.freeze
        end

        def decompress(io)
          path = io.path

          out, err, status = Open3.capture3("xz #{@command_parameter} #{path}")
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
