module Fluent
  module Plugin
    class OSSOutput
      # This class uses lzop command to compress chunks.
      class LZOCompressor < Compressor
        OSSOutput.register_compressor('lzo', self)

        config_param :command_parameter, :string, default: '-qf1'

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

        def compress(chunk, file)
          path = if @buffer_type == 'file'
                   chunk.path
                 else
                   out = Tempfile.new('chunk-lzo-out-')
                   out.binmode
                   chunk.write_to(out)
                   out.close
                   out.path
                 end

          res = system "lzop #{@command_parameter} -c #{path} > #{file.path}"
          unless res
            log.warn "failed to execute lzop command, status = #{$?}"
            raise Fluent::Exception, "failed to execute lzop command, status = #{$?}"
          end
        ensure
          out.close(true) rescue nil unless @buffer_type == 'file'
        end
      end
    end
  end
end
