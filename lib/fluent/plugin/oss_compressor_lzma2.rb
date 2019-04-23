module Fluent
  module Plugin
    class OSSOutput
      # This class uses xz command to compress chunks.
      class LZMA2Compressor < Compressor
        OSSOutput.register_compressor('lzma2', self)

        config_param :command_parameter, :string, default: '-qf0'

        def configure(conf)
          super
          check_command('xz', 'LZMA2')
        end

        def ext
          'xz'.freeze
        end

        def content_type
          'application/x-xz'.freeze
        end

        def compress(chunk, file)
          path = if @buffer_type == 'file'
                   chunk.path
                 else
                   out = Tempfile.new('chunk-xz-out-')
                   out.binmode
                   chunk.write_to(out)
                   out.close
                   out.path
                 end

          res = system "xz #{@command_parameter} -c #{path} > #{file.path}"
          unless res
            log.warn "failed to execute xz command, status = #{$?}"
            raise Fluent::Exception, "failed to execute xz command, status = #{$?}"
          end
        ensure
          out.close(true) rescue nil unless @buffer_type == 'file'
        end
      end
    end
  end
end
