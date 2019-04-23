module Fluent
  module Plugin
    class OSSOutput
      # This class uses gzip command to compress chunks.
      class GzipCommandCompressor < Compressor
        OSSOutput.register_compressor('gzip_command', self)

        config_param :command_parameter, :string, default: ''

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

        def compress(chunk, file)
          path = if @buffer_type == 'file'
                   chunk.path
                 else
                   out = Tempfile.new('chunk-gzip-out-')
                   out.binmode
                   chunk.write_to(out)
                   out.close
                   out.path
                 end

          res = system "gzip #{@command_parameter} -c #{path} > #{file.path}"

          unless res
            log.warn "failed to execute gzip command. Fallback to GzipWriter. status = #{$?}"
            begin
              file.truncate(0)
              gw = Zlib::GzipWriter.new(file)
              chunk.write_to(gw)
              gw.close
            ensure
              gw.close rescue nil
            end
          end

        ensure
          out.close(true) rescue nil unless @buffer_type == 'file'
        end
      end
    end
  end
end
