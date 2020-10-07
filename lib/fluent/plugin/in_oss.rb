require 'fluent/plugin/input'
require 'aliyun/oss'
require 'aliyun/sts'
require 'base64'
require 'fluent/plugin/mns/request'
require 'fluent/plugin/mns/message'
require 'json'
require 'zlib'

# This is Fluent OSS Input Plugin
module Fluent
  # Fluent OSS Plugin
  module Plugin
    # OSSInput class implementation
    class OSSInput < Input
      Fluent::Plugin.register_input('oss', self)

      helpers :compat_parameters, :parser, :thread

      DEFAULT_PARSE_TYPE = 'none'.freeze

      desc 'OSS endpoint to connect to'
      config_param :endpoint, :string
      desc 'Your bucket name'
      config_param :bucket, :string
      desc 'Your access key id'
      config_param :access_key_id, :string, secret: true
      desc 'Your access secret key'
      config_param :access_key_secret, :string, secret: true
      config_param :upload_crc_enable, :bool, default: true
      config_param :download_crc_enable, :bool, default: true
      desc 'Timeout for open connections'
      config_param :open_timeout, :integer, default: 10
      desc 'Timeout for read response'
      config_param :read_timeout, :integer, default: 120

      desc 'OSS SDK log directory'
      config_param :oss_sdk_log_dir, :string, default: '/var/log/td-agent'

      desc 'Archive format on OSS'
      config_param :store_as, :string, default: 'gzip'

      desc 'Flush to down streams every `flush_batch_lines` lines'
      config_param :flush_batch_lines, :integer, default: 1000

      desc 'Sleep interval between two flushes to downstream'
      config_param :flush_pause_milliseconds, :integer, default: 1

      desc 'Store OSS Objects to local or memory before parsing'
      config_param :store_local, :bool, default: true

      config_section :mns, required: true, multi: false do
        desc 'MNS endpoint to connect to'
        config_param :endpoint, :string
        desc 'MNS queue to poll messages'
        config_param :queue, :string
        desc 'MNS max waiting time to receive messages'
        config_param :wait_seconds, :integer, default: nil
        desc 'Poll messages interval from MNS'
        config_param :poll_interval_seconds, :integer, default: 30
      end

      def initialize
        super
        @decompressor = nil
      end

      desc 'Tag string'
      config_param :tag, :string, default: 'input.oss'

      config_section :parse do
        config_set_default :@type, DEFAULT_PARSE_TYPE
      end

      def configure(conf)
        super

        raise Fluent::ConfigError, 'Invalid oss endpoint' if @endpoint.nil?

        raise Fluent::ConfigError, 'Invalid mns endpoint' if @mns.endpoint.nil?

        raise Fluent::ConfigError, 'Invalid mns queue' if @mns.queue.nil?

        @decompressor = DECOMPRESSOR_REGISTRY.lookup(@store_as).new(log: log)
        @decompressor.configure(conf)

        parser_config = conf.elements('parse').first
        @parser = parser_create(conf: parser_config, default_type: DEFAULT_PARSE_TYPE)

        @flush_pause_milliseconds *= 0.001
      end

      def multi_workers_ready?
        true
      end

      def start
        @oss_sdk_log_dir += '/' unless @oss_sdk_log_dir.end_with?('/')
        Aliyun::Common::Logging.set_log_file(@oss_sdk_log_dir + Aliyun::Common::Logging::DEFAULT_LOG_FILE)
        create_oss_client unless @oss

        check_bucket
        super

        @running = true
        thread_create(:in_oss, &method(:run))
      end

      def check_bucket
        unless @oss.bucket_exist?(@bucket)
          raise "The specified bucket does not exist: bucket = #{@bucket}"
        end

        @bucket_handler = @oss.get_bucket(@bucket)
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

      def shutdown
        @running = false
        super
      end

      private

      def run
        while @running
          log.info "start to poll message from MNS queue #{@mns.queue}"
          message = receive_message(@mns.queue, @mns.wait_seconds)
          process(Fluent::Plugin::MNS::Message.new(@mns.queue, message)) unless message.nil?
          sleep(@mns.poll_interval_seconds)
        end
      end

      def receive_message(queue, wait_seconds)
        request_opts = {}
        request_opts = { waitseconds: wait_seconds } if wait_seconds
        opts = {
          log: log,
          method: 'GET',
          endpoint: @mns.endpoint,
          path: "/queues/#{queue}/messages",
          access_key_id: @access_key_id,
          access_key_secret: @access_key_secret
        }
        Fluent::Plugin::MNS::Request.new(opts, {}, request_opts).execute
      end

      def process(message)
        objects = get_objects(message)
        objects.each do |object|
          key = object.key
          log.info "read object #{key}, size #{object.size} from OSS"

          if @bucket_handler.object_exists?(key)
            if @decompressor.save_to_local?
              io = Tempfile.new('chunk-' + @store_as + '-in-')
              io.binmode
              @bucket_handler.get_object(key) do |chunk|
                io.write(chunk)
              end
            else
              io = StringIO.new
              @bucket_handler.get_object(key) do |chunk|
                io << chunk
              end
            end

            io.rewind

            begin
              content = @decompressor.decompress(io)
            rescue StandardError => ex
              log.warn "#{ex}, skip object #{key}"
              next
            end

            es = Fluent::MultiEventStream.new
            content.each_line do |line|
              @parser.parse(line) do |time, record|
                es.add(time, record)
              end

              if es.size >= @flush_batch_lines
                router.emit_stream(@tag, es)
                es = Fluent::MultiEventStream.new
                if @flush_pause_milliseconds > 0
                  sleep(@flush_pause_milliseconds)
                end
              end
            end
            router.emit_stream(@tag, es)
            io.close(true) rescue nil if @decompressor.save_to_local?
          else
            log.warn "in_oss: object #{key} does not exist!"
          end
        end
        delete_message(@mns.queue, message)
      end

      def get_objects(message)
        objects = []
        events = JSON.parse(Base64.decode64(message.body))['events']
        events.each do |event|
          objects.push(OSSObject.new(event['eventName'],
                                     @bucket,
                                     event['oss']['object']['key'],
                                     event['oss']['object']['size'],
                                     event['oss']['object']['eTag']))
        end
        objects
      end

      def delete_message(queue, message)
        request_opts = { ReceiptHandle: message.receipt_handle }
        opts = {
          log: log,
          method: 'DELETE',
          endpoint: @mns.endpoint,
          path: "/queues/#{queue}/messages",
          access_key_id: @access_key_id,
          access_key_secret: @access_key_secret
        }
        Fluent::Plugin::MNS::Request.new(opts, {}, request_opts).execute
      end

      # OSS Object class from MNS events
      class OSSObject
        attr_reader :event_name, :bucket, :key, :size, :etag
        def initialize(event_name, bucket, key, size, etag)
          @event_name = event_name
          @bucket = bucket
          @key = key
          @size = size
          @etag = etag
        end
      end

      # Decompression base class.
      class Decompressor
        include Fluent::Configurable

        attr_reader :log

        def initialize(opts = {})
          super()
          @log = opts[:log]
        end

        def ext; end

        def save_to_local?
          true
        end

        def content_type; end

        def decompress(io); end

        private

        def check_command(command, encode = nil)
          require 'open3'

          encode = command if encode.nil?
          begin
            Open3.capture3("#{command} -V")
          rescue Errno::ENOENT
            raise Fluent::ConfigError,
                  "'#{command}' utility must be in PATH for #{encode} decompression"
          end
        end
      end

      # Gzip decompression.
      class GZipDecompressor < Decompressor
        def ext
          'gz'.freeze
        end

        def content_type
          'application/x-gzip'.freeze
        end

        def decompress(io)
          Zlib::GzipReader.wrap(io)
        end

        def save_to_local?
          config['store_local']
        end
      end

      # Text decompression.
      class TextDecompressor < Decompressor
        def ext
          'txt'.freeze
        end

        def content_type
          'text/plain'.freeze
        end

        def decompress(io)
          io
        end

        def save_to_local?
          config['store_local']
        end
      end

      # Json decompression.
      class JsonDecompressor < TextDecompressor
        def ext
          'json'.freeze
        end

        def content_type
          'application/json'.freeze
        end
      end

      DECOMPRESSOR_REGISTRY = Fluent::Registry.new(:oss_decompressor_type, 'fluent/plugin/oss_decompressor_')
      {
        'gzip' => GZipDecompressor,
        'text' => TextDecompressor,
        'json' => JsonDecompressor
      }.each do |name, decompressor|
        DECOMPRESSOR_REGISTRY.register(name, decompressor)
      end

      def self.register_decompressor(name, decompressor)
        DECOMPRESSOR_REGISTRY.register(name, decompressor)
      end
    end
  end
end
