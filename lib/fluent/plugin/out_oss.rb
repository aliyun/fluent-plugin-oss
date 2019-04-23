require 'fluent/plugin/output'
require 'aliyun/oss'
require 'aliyun/sts'

# This is Fluent OSS Output Plugin
# Usage:
# In order to write output data to OSS, you should add configurations like below
# <match pattern>
#   @type oss
#   endpoint              <OSS endpoint to connect to>
#   bucket                <Your bucket name>
#   access_key_id         <Your access key id>
#   access_key_secret     <Your access secret key>
#   path                  <Path prefix of the files on OSS>
#   key_format            %{path}%{time_slice}_%{index}.%{file_extension}
# if you want to use ${tag} or %Y/%m/%d/ like syntax in path/key_format,
# need to specify tag for ${tag} and time for %Y/%m/%d in <buffer> argument.
#   <buffer tag,time>
#     @type file
#     path /var/log/fluent/oss
#     timekey 3600 # 1 hour partition
#     timekey_wait 10m
#     timekey_use_utc true # use utc
#   </buffer>
#   <format>
#     @type json
#   </format>
# </match>
module Fluent
  # Fluent OSS Plugin
  module Plugin
    # OSSOutput class implementation
    class OSSOutput < Output
      Fluent::Plugin.register_output('oss', self)

      helpers :compat_parameters, :formatter, :inject

      desc 'OSS endpoint to connect to'
      config_param :endpoint, :string
      desc 'Your bucket name'
      config_param :bucket, :string
      desc 'Your access key id'
      config_param :access_key_id, :string
      desc 'Your access secret key'
      config_param :access_key_secret, :string
      desc 'Path prefix of the files on OSS'
      config_param :path, :string, default: 'fluent/logs'
      config_param :upload_crc_enable, :bool, default: true
      config_param :download_crc_enable, :bool, default: true
      desc 'Timeout for open connections'
      config_param :open_timeout, :integer, default: 10
      desc 'Timeout for read response'
      config_param :read_timeout, :integer, default: 120

      desc 'OSS SDK log directory'
      config_param :oss_sdk_log_dir, :string, default: '/var/log/td-agent'

      desc 'The format of OSS object keys'
      config_param :key_format, :string, default: '%{path}/%{time_slice}_%{index}_%{thread_id}.%{file_extension}'
      desc 'Archive format on OSS'
      config_param :store_as, :string, default: 'gzip'
      desc 'Create OSS bucket if it does not exists'
      config_param :auto_create_bucket, :bool, default: false
      desc 'Overwrite already existing path'
      config_param :overwrite, :bool, default: false
      desc 'Check bucket if exists or not'
      config_param :check_bucket, :bool, default: true
      desc 'Check object before creation'
      config_param :check_object, :bool, default: true
      desc 'The length of `%{hex_random}` placeholder(4-16)'
      config_param :hex_random_length, :integer, default: 4
      desc '`sprintf` format for `%{index}`'
      config_param :index_format, :string, default: '%d'
      desc 'Given a threshold to treat events as delay, output warning logs if delayed events were put into OSS'
      config_param :warn_for_delay, :time, default: nil

      DEFAULT_FORMAT_TYPE = 'out_file'.freeze

      config_section :format do
        config_set_default :@type, DEFAULT_FORMAT_TYPE
      end

      config_section :buffer do
        config_set_default :chunk_keys, ['time']
        config_set_default :timekey, (60 * 60 * 24)
      end

      MAX_HEX_RANDOM_LENGTH = 16

      def configure(conf)
        compat_parameters_convert(conf, :buffer, :formatter, :inject)

        super

        raise Fluent::ConfigError, 'Invalid oss endpoint' if @endpoint.nil?

        if @hex_random_length > MAX_HEX_RANDOM_LENGTH
          raise Fluent::ConfigError, 'hex_random_length parameter must be '\
                "less than or equal to #{MAX_HEX_RANDOM_LENGTH}"
        end

        unless @index_format =~ /^%(0\d*)?[dxX]$/
          raise Fluent::ConfigError, 'index_format parameter should follow '\
                '`%[flags][width]type`. `0` is the only supported flag, '\
                'and is mandatory if width is specified. '\
                '`d`, `x` and `X` are supported types'
        end

        begin
          @compressor = COMPRESSOR_REGISTRY.lookup(@store_as).new(buffer_type: @buffer_config[:@type], log: log)
        rescue StandardError => e
          log.warn "'#{@store_as}' not supported. Use 'text' instead: error = #{e.message}"
          @compressor = TextCompressor.new
        end

        @compressor.configure(conf)

        @formatter = formatter_create

        process_key_format

        unless @check_object
          if config.has_key?('key_format')
            log.warn "set 'check_object false' and key_format is "\
                    'specified. Check key_format is unique in each '\
                    'write. If not, existing file will be overwritten.'
          else
            log.warn "set 'check_object false' and key_format is "\
                    'not specified. Use '\
                    "'%{path}/%{time_slice}_%{hms_slice}_%{thread_id}.%{file_extension}' "\
                    'for key_format'
            @key_format = '%{path}/%{time_slice}_%{hms_slice}_%{thread_id}.%{file_extension}'
          end
        end

        @configured_time_slice_format = conf['time_slice_format']
        @values_for_oss_object_chunk = {}
        @time_slice_with_tz = Fluent::Timezone.formatter(
          @timekey_zone,
          @configured_time_slice_format || timekey_to_timeformat(@buffer_config['timekey']))
      end

      def timekey_to_timeformat(timekey)
        case timekey
        when nil          then ''
        when 0...60       then '%Y%m%d-%H_%M_%S' # 60 exclusive
        when 60...3600    then '%Y%m%d-%H_%M'
        when 3600...86400 then '%Y%m%d-%H'
        else                   '%Y%m%d'
        end
      end

      def multi_workers_ready?
        true
      end

      def initialize
        super
        @compressor = nil
        @uuid_flush_enabled = false
      end

      def start
        @oss_sdk_log_dir += '/' unless @oss_sdk_log_dir.end_with?('/')
        Aliyun::Common::Logging.set_log_file(@oss_sdk_log_dir + Aliyun::Common::Logging::DEFAULT_LOG_FILE)
        create_oss_client unless @oss

        ensure_bucket if @check_bucket
        super
      end

      def format(tag, time, record)
        r = inject_values_to_record(tag, time, record)
        @formatter.format(tag, time, r)
      end

      def write(chunk)
        index = 0
        metadata = chunk.metadata
        time_slice = if metadata.timekey.nil?
                       ''.freeze
                     else
                       @time_slice_with_tz.call(metadata.timekey)
                     end

        @values_for_oss_object_chunk[chunk.unique_id] ||= {
          '%{hex_random}' => hex_random(chunk)
        }

        if @check_object
          exist_key = nil
          begin
            values_for_oss_key = {
              '%{path}' => @path,
              '%{thread_id}' => Thread.current.object_id.to_s,
              '%{file_extension}' => @compressor.ext,
              '%{time_slice}' => time_slice,
              '%{index}' => sprintf(@index_format, index)
            }.merge!(@values_for_oss_object_chunk[chunk.unique_id])

            values_for_oss_key['%{uuid_flush}'.freeze] = uuid_random if @uuid_flush_enabled

            key = @key_format.gsub(/%{[^}]+}/) do |matched_key|
              values_for_oss_key.fetch(matched_key, matched_key)
            end
            key = extract_placeholders(key, chunk)
            key = key.gsub(/%{[^}]+}/, values_for_oss_key)

            if (index > 0) && (key == exist_key)
              if @overwrite
                log.warn "#{key} already exists, but will overwrite"
                break
              else
                raise "duplicated path is generated. use %{index} in key_format: path = #{key}"
              end
            end

            index += 1
            exist_key = key
          end while @bucket_handler.object_exists?(key)
        else
          hms_slice = Time.now.utc.strftime('%H%M%S')
          hms_slice = Time.now.strftime('%H%M%S') if @local_time

          values_for_oss_key = {
            '%{path}' => @path,
            '%{thread_id}' => Thread.current.object_id.to_s,
            '%{file_extension}' => @compressor.ext,
            '%{time_slice}' => time_slice,
            '%{hms_slice}' => hms_slice
          }.merge!(@values_for_oss_object_chunk[chunk.unique_id])

          values_for_oss_key['%{uuid_flush}'.freeze] = uuid_random if @uuid_flush_enabled

          key = @key_format.gsub(/%{[^}]+}/) do |matched_key|
            values_for_oss_key.fetch(matched_key, matched_key)
          end
          key = extract_placeholders(key, chunk)
          key = key.gsub(/%{[^}]+}/, values_for_oss_key)
        end

        out_file = Tempfile.new('oss-fluent-')
        out_file.binmode
        begin
          @compressor.compress(chunk, out_file)
          out_file.rewind
          log.info "out_oss: write chunk #{dump_unique_id_hex(chunk.unique_id)} with metadata #{chunk.metadata} to oss://#{@bucket}/#{key}, size #{out_file.size}"

          start = Time.now.to_i
          @bucket_handler.put_object(key, file: out_file, content_type: @compressor.content_type)

          log.debug "out_oss: write oss://#{@bucket}/#{key} used #{Time.now.to_i - start} seconds, size #{out_file.length}"
          @values_for_oss_object_chunk.delete(chunk.unique_id)

          if @warn_for_delay
            if Time.at(chunk.metadata.timekey) < Time.now - @warn_for_delay
              log.warn "out_oss: delayed events were put to oss://#{@bucket}/#{key}"
            end
          end
        ensure
          out_file.close(true) rescue nil
        end
      end

      def create_oss_client
        @oss = Aliyun::OSS::Client.new(
          endpoint: @endpoint,
          access_key_id: @access_key_id,
          access_key_secret: @access_key_secret,
          download_crc_enable: @download_crc_enable,
          upload_crc_enable: @upload_crc_enable,
          open_timeout: @open_timeout,
          read_timeout: @read_timeout
        )
      end

      def process_key_format
        if @key_format.include?('%{uuid_flush}')
          # verify uuidtools
          begin
            require 'uuidtools'
          rescue LoadError
            raise Fluent::ConfigError, 'uuidtools gem not found.'\
                  ' Install uuidtools gem first'
          end

          begin
            uuid_random
          rescue => e
            raise Fluent::ConfigError, "generating uuid doesn't work. "\
                  "Can't use %{uuid_flush} on this environment. #{e}"
          end

          @uuid_flush_enabled = true
        end
      end

      def uuid_random
        ::UUIDTools::UUID.random_create.to_s
      end

      def hex_random(chunk)
        unique_hex = Fluent::UniqueId.hex(chunk.unique_id)
        # unique_hex is like (time_sec, time_usec, rand) => reversing gives more randomness
        unique_hex.reverse!
        unique_hex[0...@hex_random_length]
      end

      def ensure_bucket
        unless @oss.bucket_exist?(@bucket)
          if @auto_create_bucket
            log.info "creating bucket #{@bucket} on #{@endpoint}"
            @oss.create_bucket(@bucket)
          else
            raise "the specified bucket does not exist: bucket = #{@bucket}"
          end
        end

        @bucket_handler = @oss.get_bucket(@bucket)
      end

      # Compression base class.
      class Compressor
        include Fluent::Configurable

        attr_reader :log

        def initialize(opts = {})
          super()
          @buffer_type = opts[:buffer_type]
          @log = opts[:log]
        end

        def configure(conf)
          super
        end

        def ext; end

        def content_type; end

        def compress(chunk, file); end

        private

        def check_command(command, encode = nil)
          require 'open3'

          encode = command if encode.nil?
          begin
            Open3.capture3("#{command} -V")
          rescue Errno::ENOENT
            raise Fluent::ConfigError,
                  "'#{command}' utility must be in PATH for #{encode} compression"
          end
        end
      end

      # Gzip compression.
      class GzipCompressor < Compressor
        def ext
          'gz'.freeze
        end

        def content_type
          'application/x-gzip'.freeze
        end

        def compress(chunk, file)
          out = Zlib::GzipWriter.new(file)
          chunk.write_to(out)
          out.finish
        ensure
          begin
            out.finish
          rescue StandardError
            nil
          end
        end
      end

      # Text output format.
      class TextCompressor < Compressor
        def ext
          'txt'.freeze
        end

        def content_type
          'text/plain'.freeze
        end

        def compress(chunk, file)
          chunk.write_to(file)
        end
      end

      # Json compression.
      class JsonCompressor < TextCompressor
        def ext
          'json'.freeze
        end

        def content_type
          'application/json'.freeze
        end
      end

      COMPRESSOR_REGISTRY = Fluent::Registry.new(:oss_compressor_type,
                                                 'fluent/plugin/oss_compressor_')
      {
        'gzip' => GzipCompressor,
        'json' => JsonCompressor,
        'text' => TextCompressor
      }.each do |name, compressor|
        COMPRESSOR_REGISTRY.register(name, compressor)
      end

      def self.register_compressor(name, compressor)
        COMPRESSOR_REGISTRY.register(name, compressor)
      end
    end
  end
end